(in-package #:clasp-cleavir)

(defun kwarg-presence (keyword required optional rest sys)
  (let ((result nil) (oddreq nil)
        (mems (list keyword)) (ktype (ctype:member sys keyword)))
    (loop for (param . r) on required by #'cddr
          ;; Check if it's definitely the keyword.
          when (and (ctype:member-p sys param)
                    (equal (ctype:member-members sys param) mems))
            do (return-from kwarg-presence t)
          ;; Check if it might be the keyword, if we haven't determined
          ;; this already.
          when (and (null result)
                    (ctype:subtypep ktype param sys))
            do (setf result :maybe)
          ;; Check for an odd number of required parameters.
          when (null r)
            do (setf oddreq t))
    ;; Now do the same thing with optionals, if we haven't got a maybe.
    ;; We don't need to check equality since optional means these might
    ;; not even be passed.
    (when (eq result :maybe) (return-from kwarg-presence result))
    (loop for (param) on (if oddreq (cdr optional) optional) by #'cddr
          when (ctype:subtypep ktype param sys)
            do (return-from kwarg-presence :maybe))
    ;; Finally the rest.
    (if (ctype:subtypep ktype rest sys)
        :maybe
        nil)))

(defun kwarg-type (keyword required optional rest sys)
  (let ((result (ctype:bottom sys)) (oddreq nil) (ambiguousp nil)
        (mems (list keyword)) (ktype (ctype:member sys keyword)))
    (loop for (param . r) on required by #'cddr
          ;; If this is the first param we've seen that could be the keyword,
          ;; and it must be the keyword, we're done.
          when (and (not ambiguousp)
                    (ctype:member-p sys param)
                    (equal (ctype:member-members sys param) mems))
            do (return-from kwarg-type (cond (r (first r))
                                             (optional (first optional))
                                             (t rest)))
          when (ctype:subtypep ktype param sys)
            do (setf result (ctype:disjoin sys result
                                           (cond (r (first r))
                                                 (optional (first optional))
                                                 (t rest)))
                     ;; Mark that we've seen the possible keyword, so that
                     ;; future iterations don't hit the short circuit above.
                     ambiguousp t)
          when (null r)
            do (setf oddreq t))
    (loop for (param . r) on (if oddreq (cdr optional) optional) by #'cddr
          when (ctype:subtypep ktype param sys)
            do (setf result (ctype:disjoin sys result
                                           (if r (first r) rest))))
    (if (ctype:subtypep ktype rest sys)
        (ctype:disjoin sys result rest)
        result)))

;;; Determines the real type of a keyword argument given its default type and the
;;; result of kwarg-presence. For example if the keyword only may be present, the
;;; default type is stuck in there.
(defun defaulted-kwarg-type (keyword presence default required optional rest sys)
  (ecase presence
    ((nil) default)
    ((t) (kwarg-type keyword required optional rest sys))
    ((:maybe)
     (ctype:disjoin sys default (kwarg-type keyword required optional rest sys)))))

;;;

(defmacro with-types (lambda-list argstype (&key default) &body body)
  (multiple-value-bind (req opt rest keyp keys)
      (core:process-lambda-list lambda-list 'function)
    ;; We ignore &allow-other-keys because it's too much effort for
    ;; type derivation. Approximate results are fine.
    (if (and (zerop (first req)) (zerop (first opt)) (not keyp))
        ;; If the whole lambda list is &rest, skip parsing entirely.
        `(let ((,rest ,argstype)) ,@body)
        ;; hard mode
        (let ((gsys (gensym "SYS")) (gargs (gensym "ARGSTYPE"))
              (greq (gensym "REQ")) (glr (gensym "LREQ"))
              (gopt (gensym "OPT"))
              (grest (gensym "REST")) (grb (gensym "REST-BOTTOM-P")))
          `(let* ((,gsys *clasp-system*) (,gargs ,argstype)
                  (,greq (ctype:values-required ,gargs ,gsys))
                  (,glr (length ,greq))
                  (,gopt (ctype:values-optional ,gargs ,gsys))
                  (,grest (ctype:values-rest ,gargs ,gsys))
                  (,grb (ctype:bottom-p ,grest ,gsys)))
             (if (or (and ,grb (< (+ ,glr (length ,gopt)) ,(first req)))
                     ,@(if (or rest keyp)
                           nil
                           `((> ,glr (+ ,(first req) ,(first opt))))))
                 ;; Not enough arguments, or too many
                 ,default
                 ;; Valid call
                 (let* (,@(loop for reqv in (rest req)
                                collect `(,reqv (or (pop ,greq)
                                                    (pop ,gopt) ,grest)))
                        ,@(loop for (optv default -p) on (rest opt) by #'cdddr
                                when -p
                                  collect `(,-p (cond (,greq t)
                                                      ((or ,gopt (not ,grb)) :maybe)
                                                      (t nil)))
                                collect `(,optv
                                          (or (pop ,greq)
                                              (ctype:disjoin ,gsys
                                                             (env:parse-type-specifier
                                                              ',default nil ,gsys)
                                                             (or (pop ,gopt) ,grest)))))
                        ,@(when rest
                            `((,rest (ctype:values ,greq ,gopt ,grest ,gsys))))
                        ,@(loop for (kw var def -p) on (rest keys) by #'cddddr
                                ;; We need a -p for processing
                                for r-p = (or -p (gensym "-P"))
                                ;; KLUDGE: If no default is specified
                                ;; we want T, not NIL
                                for r-def = (or def 't)
                                collect `(,r-p
                                          (kwarg-presence ',kw ,greq ,gopt ,grest
                                                          ,gsys))
                                collect `(,var
                                          (defaulted-kwarg-type
                                           ',kw ,r-p
                                           (env:parse-type-specifier
                                            ',r-def nil ,gsys)
                                           ,greq ,gopt ,grest ,gsys))))
                   ,@body)))))))

(defmacro with-deriver-types (lambda-list argstype &body body)
  `(with-types ,lambda-list ,argstype
     (:default (ctype:values-bottom *clasp-system*))
     ,@body))

;;; Lambda lists are basically ordinary lambda lists, but without &aux
;;; because &aux sucks.
;;; &optional defaults are incorporated into the type bound.
;;; suppliedp parameters will be bound to either T, :MAYBE, or NIL.
;;; T means an argument is definitely provided, :MAYBE that it may or
;;; may not be, and NIL that it definitely isn't.
;;; &rest parameters will be bound to a values type representing all
;;; remaining parameters, which is often more useful than a join.
;;; &key defaults are incorporated into the type bound, so e.g. if
;;; it's derived that a keyword _may_ be provided, within the deriver
;;; the type will be (or provided-type default-type). They are not
;;; evaluated but instead interpreted as type specifiers.
;;; &key is not supported yet.
(defmacro define-deriver (name lambda-list &body body)
  (let* ((fname (make-symbol (format nil "~a-DERIVER" (write-to-string name))))
         (as (gensym "ARGSTYPE")))
    `(progn
       (defun ,fname (,as)
         (block ,(core:function-block-name name)
           (with-deriver-types ,lambda-list ,as ,@body)))
       (setf (gethash ',name *derivers*) ',fname)
       ',name)))

(defmethod bir-transformations:derive-return-type ((inst bir:abstract-call)
                                                   identity argstype
                                                   (system clasp))
  (let ((deriver (gethash identity *derivers*)))
    (if deriver
        (funcall deriver argstype)
        (call-next-method))))

(defun sv (type) (ctype:single-value type *clasp-system*))

;;; Return the minimum and maximum values of a values type.
;;; NIL maximum means no bound.
(defun values-type-minmax (values-type sys)
  (let* ((nreq (length (ctype:values-required values-type sys))))
    (values nreq
            (if (ctype:bottom-p (ctype:values-rest values-type sys) sys)
                (+ nreq (length (ctype:values-optional values-type sys)))
                nil))))

;;; Derive the type of (typep object 'tspec), where objtype is the derived
;;; type of object.
(defun derive-type-predicate (objtype tspec sys)
  (ctype:single-value
   (let ((type (handler-case (env:parse-type-specifier tspec nil sys)
                 (serious-condition ()
                   (return-from derive-type-predicate
                     (ctype:single-value (ctype:member sys t nil) sys))))))
     (cond ((ctype:subtypep objtype type sys) (ctype:member sys t))
           ((ctype:disjointp objtype type sys) (ctype:member sys nil))
           (t (ctype:member sys t nil))))
   sys))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; (4) TYPES AND CLASSES

(define-deriver typep (obj type &optional env)
  (declare (ignore env))
  (let ((sys *clasp-system*))
    (if (ctype:member-p sys type)
        (let ((members (ctype:member-members sys type)))
          (if (= (length members) 1)
              (derive-type-predicate obj (first members) sys)
              (ctype:single-value (ctype:member sys t nil) sys)))
        (ctype:single-value (ctype:member sys t nil) sys))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; (5) DATA AND CONTROL FLOW

(define-deriver functionp (obj)
  (derive-type-predicate obj 'function *clasp-system*))
(define-deriver compiled-function-p (obj)
  (derive-type-predicate obj 'compiled-function *clasp-system*))

(defun derive-eq/l (arg1 arg2 sys)
  (ctype:single-value
   (if (ctype:disjointp arg1 arg2 sys)
       (ctype:member sys nil)
       ;; our eq/l always return a boolean.
       (ctype:member sys t nil))
   sys))

(define-deriver eq (a1 a2) (derive-eq/l a1 a2 *clasp-system*))
(define-deriver eql (a1 a2) (derive-eq/l a1 a2 *clasp-system*))

(define-deriver identity (arg) (sv arg))

(define-deriver values (&rest args) args)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; (8) STRUCTURES

(define-deriver copy-structure (structure) (sv structure))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; (12) NUMBERS

(defun contagion (ty1 ty2)
  (ecase ty1
    ((integer)
     (case ty2
       ((integer) ty1)
       ((ratio) 'rational)
       (t ty2)))
    ((ratio)
     (case ty2
       ((integer) 'rational)
       ((ratio) ty1)
       (t ty2)))
    ((rational)
     (case ty2
       ((integer ratio) ty1)
       (t ty2)))
    ((short-float)
     (case ty2
       ((integer ratio rational short-float) 'single-float)
       (t ty2)))
    ((single-float)
     (case ty2
       ((integer ratio rational short-float) ty1)
       (t ty2)))
    ((double-float)
     (case ty2
       ((integer ratio rational short-float single-float) ty1)
       (t ty2)))
    ((long-float)
     (case ty2
       ((integer ratio rational short-float single-float long-float) 'double-float)
       (t ty2)))
    ((float)
     (case ty2
       ((integer ratio rational short-float single-float double-float long-float) ty1)
       (t ty2)))
    ((real) ty1)))

;; integer/integer can be a ratio, so this is contagion but lifting to rational.
(defun divcontagion (ty1 ty2)
  (let ((cont (contagion ty1 ty2)))
    (if (member cont '(integer ratio))
        'rational
        cont)))

(defun range+ (ty1 ty2)
  (let* ((sys *clasp-system*)
         (k1 (ctype:range-kind ty1 sys)) (k2 (ctype:range-kind ty2 sys)))
    (multiple-value-bind (low1 lxp1) (ctype:range-low ty1 sys)
      (multiple-value-bind (high1 hxp1) (ctype:range-high ty1 sys)
        (multiple-value-bind (low2 lxp2) (ctype:range-low ty2 sys)
          (multiple-value-bind (high2 hxp2) (ctype:range-high ty2 sys)
            (ctype:range (contagion k1 k2)
                         (if (or (null low1) (null low2))
                             '*
                             (let ((sum (+ low1 low2)))
                               (if (or lxp1 lxp2) (list sum) sum)))
                         (if (or (null high1) (null high2))
                             '*
                             (let ((sum (+ high1 high2)))
                               (if (or hxp1 hxp2) (list sum) sum)))
                         sys)))))))

(defun ty+ (ty1 ty2)
  (if (and (ctype:rangep ty1 *clasp-system*) (ctype:rangep ty2 *clasp-system*))
      (range+ ty1 ty2)
      (env:parse-type-specifier 'number nil *clasp-system*)))

(defun range-negate (ty)
  (let ((sys *clasp-system*))
    (multiple-value-bind (low lxp) (ctype:range-low ty sys)
      (multiple-value-bind (high hxp) (ctype:range-high ty sys)
        (ctype:range (ctype:range-kind ty sys)
                     (cond ((null high) '*)
                           (hxp (list high))
                           (t high))
                     (cond ((null low) '*)
                           (lxp (list low))
                           (t low))
                     sys)))))

(defun ty-negate (ty)
  (if (ctype:rangep ty *clasp-system*)
      (range-negate ty)
      (env:parse-type-specifier 'number nil *clasp-system*)))

;;; Gives the result as the contagion of the inputs, while discarding range
;;; information. This is a very imprecise result, but can be applied fairly
;;; widely. Notably gives up on complexes, returning NUMBER, so this should
;;; be okay to use for e.g. (- complex complex) which can actually be real.
(defun ty-contagion (ty1 ty2)
  (let ((sys *clasp-system*))
    (if (and (ctype:rangep ty1 sys) (ctype:rangep ty2 sys))
        (ctype:range (contagion (ctype:range-kind ty1 sys) (ctype:range-kind ty2 sys))
                     '* '* sys)
        (env:parse-type-specifier 'number nil *clasp-system*))))
(defun ty-divcontagion (ty1 ty2)
  (let ((sys *clasp-system*))
    (if (and (ctype:rangep ty1 sys) (ctype:rangep ty2 sys))
        (ctype:range (divcontagion (ctype:range-kind ty1 sys)
                                   (ctype:range-kind ty2 sys))
                     '* '* sys)
        (env:parse-type-specifier 'number nil *clasp-system*))))

(defun ty-irrat-monotonic1 (ty function &key (inf '*) (sup '*))
  (let ((sys *clasp-system*))
    (ctype:single-value
     (if (ctype:rangep ty sys)
         (let* ((kind (ctype:range-kind ty sys))
                (mkind
                  (case kind
                    ((integer ratio rational) 'single-float)
                    (t kind))))
           (multiple-value-bind (low lxp) (ctype:range-low ty sys)
             (multiple-value-bind (high hxp) (ctype:range-high ty sys)
               (let ((olow (cond ((not low)
                                  (cond ((not (numberp inf)) inf)
                                        ((eq kind 'double-float) (float inf 0d0))
                                        (t (float inf 0f0))))
                                 (lxp (list (funcall function low)))
                                 (t (funcall function low))))
                     (ohigh (cond ((not high)
                                   (cond ((not (numberp sup)) sup)
                                         ((eq kind 'double-float) (float sup 0d0))
                                         (t (float sup 0f0))))
                                  (hxp (list (funcall function high)))
                                  (t (funcall function high)))))
                 (ctype:range mkind olow ohigh sys)))))
         (ctype:range 'real inf sup sys))
     sys)))

(defun ty-ash (intty countty)
  (let ((sys *clasp-system*))
    (if (and (ctype:rangep intty sys) (ctype:rangep countty sys))
        ;; We could end up with rational/real range inputs, in which case only the
        ;; integers are valid, so we can use ceiling/floor on the bounds.
        (if (and (member (ctype:range-kind intty sys) '(integer rational real))
                 (member (ctype:range-kind countty sys) '(integer rational real)))
            (flet ((pash (integer count default)
                     ;; "protected ASH": Avoid huge numbers when they don't really help.
                     (if (< count (* 2 core:cl-fixnum-bits)) ; arbitrary
                         (ash integer count)
                         default)))
              ;; FIXME: We just ignore exclusive bounds because that's easier and
              ;; doesn't affect the ranges too much. Ideally they should be
              ;; normalized away for integers anyway.
              (let ((ilow  (ctype:range-low  intty   sys))
                    (ihigh (ctype:range-high intty   sys))
                    (clow  (ctype:range-low  countty sys))
                    (chigh (ctype:range-high countty sys)))
                ;; Normalize out non-integers.
                (when ilow  (setf ilow  (ceiling ilow)))
                (when ihigh (setf ihigh (floor   ihigh)))
                (when clow  (setf clow  (ceiling clow)))
                (when chigh (setf chigh (floor   chigh)))
                ;; ASH with a positive count increases magnitude while a negative
                ;; count decreases it. Therefore: If the integer can be negative,
                ;; the low point of the range must be (ASH ILOW CHIGH). Even if
                ;; CHIGH is negative, this can at worst result in 0, which is <=
                ;; any lower bound from IHIGH. If the integer can't be negative,
                ;; low bound must be (ASH ILOW CLOW). Vice versa for the upper bound.
                (ctype:range 'integer
                             (cond ((not ilow) '*)
                                   ((< ilow 0)  (if chigh (pash ilow chigh  '*) '*))
                                   ((> ilow 0)  (if clow  (pash ilow clow    0)  0))
                                   (t 0))
                             (cond ((not ihigh) '*)
                                   ((< ihigh 0) (if clow  (pash ihigh clow  -1) -1))
                                   ((> ihigh 0) (if chigh (pash ihigh chigh '*) '*))
                                   (t 0))
                             sys)))
            (ctype:bottom sys))
        (ctype:range 'integer '* '* sys))))

;;;

(defun derive-ftrunc* (x y)
  ;; The definition of ftruncate in CLHS is kind of gibberish, as relates to
  ;; the types of the results. So just make sure this does what the function does.
  (let ((sys *clasp-system*))
    (ctype:values
     (mapcar (lambda (kind) (ctype:range kind '* '* sys))
             (if (and (ctype:rangep x sys) (ctype:rangep y sys))
                 (ecase (ctype:range-kind x sys)
                   ((integer rational)
                    (ecase (ctype:range-kind y sys)
                      ((integer rational) '(single-float integer))
                      ((single-float) '(single-float single-float))
                      ((double-float) '(double-float double-float))
                      ((float) '(float float))
                      ((real) '(float real))))
                   ((single-float)
                    (ecase (ctype:range-kind y sys)
                      ((integer rational single-float) '(single-float single-float))
                      ;; Despite the above note: This returns singles with the function,
                      ;; but I think it should return doubles; SBCL does. Why not?
                      ;; FIXME: Change ftruncate behavior.
                      ((double-float) '(float float))
                      ((float) '(float float))
                      ((real) '(float real))))
                   ((double-float) '(double-float double-float))
                   ((float) '(float float))
                   ((real) '(real real)))
                 '(float real)))
     nil (ctype:bottom sys) sys)))

(define-deriver ffloor (x &optional (y (integer 1 1))) (derive-ftrunc* x y))
(define-deriver fceiling (x &optional (y (integer 1 1))) (derive-ftrunc* x y))
(define-deriver ftruncate (x &optional (y (integer 1 1))) (derive-ftrunc* x y))
(define-deriver fround (x &optional (y (integer 1 1))) (derive-ftrunc* x y))

(define-deriver core:two-arg-+ (n1 n2) (sv (ty+ n1 n2)))
(define-deriver core:negate (arg) (sv (ty-negate arg)))
(define-deriver core:two-arg-- (n1 n2) (sv (ty+ n1 (ty-negate n2))))
;;; This is imprecise, e.g. a rational*integer can be an integer, but should
;;; still be sound.
(define-deriver core:two-arg-* (n1 n2) (sv (ty-contagion n1 n2)))
(define-deriver core:two-arg-/ (n1 n2) (sv (ty-divcontagion n1 n2)))
(define-deriver core:reciprocal (n)
  (sv (ty-divcontagion (ctype:range 'integer 1 1 *clasp-system*) n)))

(define-deriver exp (arg) (ty-irrat-monotonic1 arg #'exp :inf 0f0))

(define-deriver expt (x y)
  (let ((sys *clasp-system*))
    (ctype:single-value
     (if (and (ctype:rangep x sys) (ctype:rangep y sys))
         (ctype:range
          (ecase (ctype:range-kind x sys)
            ((single-float) (if (eq (ctype:range-kind y sys) 'double-float)
                                'double-float 'single-float))
            ((double-float) 'double-float)
            ((float) 'float)
            ((integer)
             (let ((ykind (ctype:range-kind y sys)))
               (case ykind
                 ((integer rational) 'rational) ; e.g. (expt 2 -3)
                 (otherwise ykind))))
            ((rational)
             (let ((ykind (ctype:range-kind y sys)))
               (case ykind
                 ((integer rational) 'rational)
                 (otherwise ykind))))
            ((real) 'real))
          '* '* sys)
         (env:parse-type-specifier 'number nil sys))
     sys)))

(defun ty-boundbelow-irrat-monotonic1 (ty function lowbound &key (inf '*) (sup '*))
  (let ((sys *clasp-system*))
    (if (ctype:rangep ty sys)
        (let ((low (ctype:range-low ty sys)))
          (if (and low (>= low lowbound))
              (ty-irrat-monotonic1 ty function :inf inf :sup sup)
              (ctype:single-value
               (env:parse-type-specifier 'number nil sys) sys)))
        (ctype:single-value (env:parse-type-specifier 'number nil sys) sys))))

(defun ty-bound-irrat-monotonic1 (ty function lowb highb &key (inf '*) (sup '*))
  (let ((sys *clasp-system*))
    (if (ctype:rangep ty sys)
        (let ((low (ctype:range-low ty sys))
              (high (ctype:range-high ty sys)))
          (if (and low (>= low lowb)
                   high (<= high highb))
              (ty-irrat-monotonic1 ty function :inf inf :sup sup)
              (ctype:single-value
               (env:parse-type-specifier 'number nil sys) sys)))
        (ctype:single-value (env:parse-type-specifier 'number nil sys) sys))))

(define-deriver sqrt (arg)
  (ty-boundbelow-irrat-monotonic1 arg #'sqrt 0 :inf 0f0))

(define-deriver log (arg &optional (base nil basep))
  (declare (ignore base))
  (if basep
      ;; FIXME
      (let ((sys *clasp-system*))
        (ctype:single-value (env:parse-type-specifier 'number nil sys) sys))
      (ty-boundbelow-irrat-monotonic1 arg #'log 0)))

;;; If the argument is a real, return [-1,1]. otherwise just NUMBER
;;; Technically the range could be reduced sometimes, but figuring out the
;;; exact values is kind of a pain and it doesn't seem that useful.
(defun derive-sincos (arg)
  (let ((sys *clasp-system*))
    (ctype:single-value
     (if (ctype:rangep arg sys)
         (let ((kind (ctype:range-kind arg sys)))
           (when (member kind '(integer rational))
             (setf kind 'single-float))
           (ctype:range kind (coerce -1 kind) (coerce 1 kind) sys))
         (env:parse-type-specifier 'number nil sys))
     sys)))
(define-deriver sin (arg) (derive-sincos arg))
(define-deriver cos (arg) (derive-sincos arg))

(defun ty-trig (arg)
  ;; Return an unbounded real range if given a real, else just NUMBER.
  (let ((sys *clasp-system*))
    (ctype:single-value
     (if (ctype:rangep arg sys)
         (let ((kind (ctype:range-kind arg sys)))
           (when (member kind '(integer rational))
             (setf kind 'single-float))
           (ctype:range kind '* '* sys))
         (env:parse-type-specifier 'number nil sys))
     sys)))

(define-deriver tan (arg) (ty-trig arg))

(define-deriver asin (arg)
  (ty-bound-irrat-monotonic1 arg #'asin -1 1 :inf (- (/ pi 2)) :sup (/ pi 2)))
(define-deriver acos (arg)
  ;; TODO: we could get better types here, since acos is monotone decreasing.
  (let ((sys *clasp-system*))
    (ctype:single-value
     (if (ctype:rangep arg sys)
         (let ((kind (ctype:range-kind arg sys))
               (low (ctype:range-low arg sys))
               (high (ctype:range-high arg sys)))
           (if (and low (>= low -1d0) high (<= high 1d0))
               (ecase kind
                 ((integer rational single-float)
                  (ctype:range 'single-float 0f0 (float pi 0f0) sys))
                 ((double-float) (ctype:range 'double-float 0d0 pi sys))
                 ((float real) (ctype:range 'float 0d0 pi sys)))
               (env:parse-type-specifier 'number nil sys)))
         (env:parse-type-specifier 'number nil sys))
     sys)))

(define-deriver sinh (arg) (ty-irrat-monotonic1 arg #'sinh))
(define-deriver cosh (arg) (ty-trig arg)) ; FIXME: limit to (1, \infty]

(define-deriver tanh (arg) (ty-irrat-monotonic1 arg #'tanh :inf -1f0 :sup 1f0))

(define-deriver asinh (arg) (ty-irrat-monotonic1 arg #'asinh))
(define-deriver acosh (arg) (ty-boundbelow-irrat-monotonic1 arg #'acosh 1 :inf 0f0))
(define-deriver atanh (arg) (ty-bound-irrat-monotonic1 arg #'atanh -1 1))

(define-deriver abs (arg)
  (let ((sys *clasp-system*))
    (ctype:single-value
     (if (ctype:rangep arg sys)
         (let ((kind (ctype:range-kind arg sys)))
           (multiple-value-bind (low lxp) (ctype:range-low arg sys)
             (multiple-value-bind (high hxp) (ctype:range-high arg sys)
               (ctype:range kind
                            (cond ((or (not low) (and low (minusp low)))
                                   (case kind
                                     ((single-float) 0f0)
                                     ((double-float float) 0d0)
                                     (t 0)))
                                  ((or (not high) (< low (abs high)))
                                   (if lxp (list low) low))
                                  (t (if hxp (list (abs high)) (abs high))))
                            (cond ((or (not high) (not low)) '*)
                                  ((< (abs low) (abs high))
                                   (if hxp (list (abs high)) (abs high)))
                                  (t (if lxp (list (abs low)) (abs low))))
                            sys))))
         (env:parse-type-specifier 'number nil sys))
     sys)))

(define-deriver ash (num shift) (sv (ty-ash num shift)))

(defun derive-to-float (realtype format sys)
  ;; TODO: disjunctions
  (if (ctype:rangep realtype sys)
      (multiple-value-bind (low lxp) (ctype:range-low realtype sys)
        (multiple-value-bind (high hxp) (ctype:range-high realtype sys)
          (ctype:range format
                       (cond ((not low) '*)
                             (lxp (list (coerce low format)))
                             (t (coerce low format)))
                       (cond ((not high) '*)
                             (hxp (list (coerce high format)))
                             (t (coerce high format)))
                       sys)))
      (ctype:range format '* '* sys)))

(define-deriver float (num &optional (proto nil protop))
  (let* ((sys *clasp-system*)
         (floatt (ctype:range 'float '* '* sys)))
    (flet ((float1 ()
             ;; TODO: disjunctions
             (cond ((ctype:subtypep num floatt sys) num) ; no coercion
                   ((ctype:subtypep num (ctype:negate floatt sys) sys)
                    (derive-to-float num 'single-float sys))
                   (t floatt)))
           (float2 ()
             (cond ((ctype:subtypep proto (ctype:range 'single-float '* '* sys) sys)
                    (derive-to-float num 'single-float sys))
                   ((ctype:subtypep proto (ctype:range 'double-float '* '* sys) sys)
                    (derive-to-float num 'double-float sys))
                   (t floatt))))
      (ctype:single-value
       (cond ((eq protop t) (float2)) ; definitely supplied
             ((eq protop :maybe)
              (ctype:disjoin sys (float1) (float2)))
             (t (float1)))
       sys))))
(define-deriver core:to-single-float (num)
  (let ((sys *clasp-system*))
    (ctype:single-value (derive-to-float num 'single-float sys) sys)))
(define-deriver core:to-double-float (num)
  (let ((sys *clasp-system*))
    (ctype:single-value (derive-to-float num 'double-float sys) sys)))

(define-deriver random (max &optional random-state)
  (declare (ignore random-state))
  (let ((sys *clasp-system*))
    (ctype:single-value
     (cond ((ctype:rangep max sys)
            (let* ((kind (ctype:range-kind max sys))
                   (phigh (ctype:range-high max sys)) ; x-p irrelevant here
                   (high (if phigh (list phigh) '*)))
              (case kind
                ((integer ratio rational) (ctype:range kind 0 high sys))
                ((real) (ctype:range kind 0 high sys))
                (t (ctype:range kind (coerce 0 kind) high sys)))))
           ((subtypep max (ctype:range 'integer 0 most-positive-fixnum sys))
            (ctype:range 'integer 0 most-positive-fixnum sys))
           ((subtypep max (ctype:range 'single-float 0f0 '* sys))
            (ctype:range 'single-float 0f0 '* sys))
           ((subtypep max (ctype:range 'double-float 0d0 '* sys))
            (ctype:range 'double-float 0d0 '* sys))
           (t (env:parse-type-specifier '(real 0) nil sys)))
     sys)))

;;; Get inclusive integer bounds from a type. NIL for unbounded.
;;; FIXME: For integer types we should just normalize away exclusivity at parse
;;; time, really.
(defun normalize-integer-bounds (ranget sys)
  (let ((kind (ctype:range-kind ranget sys)))
    (multiple-value-bind (low lxp) (ctype:range-low ranget sys)
      (multiple-value-bind (high hxp) (ctype:range-high ranget sys)
        (ecase kind
          ((integer) (values (if (and low lxp) (1+ low) low) (if (and high hxp) (1- high) high)))
          ((rational real)
           (values (if low
                       (multiple-value-bind (clow crem) (ceiling low)
                         (if (and (zerop crem) lxp) (1+ clow) clow))
                       low)
                   (if high
                       (multiple-value-bind (fhigh frem) (floor high)
                         (if (and (zerop frem) hxp) (1- fhigh) fhigh))
                       high))))))))

(define-deriver logcount (arg)
  ;; not optimal, but should be fine.
  ;; example non optimality: (logcount (integer 10 15)) could be (integer 2 4)
  (let ((sys *clasp-system*))
    (if (and (ctype:rangep arg sys)
             (member (ctype:range-kind arg sys) '(integer rational real)))
        (multiple-value-bind (low high) (normalize-integer-bounds arg sys)
          (if (and low high)
              (ctype:range 'integer
                           (if (or (> low 0) (< high -1)) 1 0)
                           (max (integer-length low) (integer-length high))
                           sys)
              (ctype:range 'integer '* '* sys)))
        (ctype:range 'integer '* '* sys))))

;;; LOGNOT (in Lisp's unbounded conception) is monotonic decreasing.
(define-deriver lognot (arg)
  (let* ((sys *clasp-system*))
    (ctype:single-value
     (if (and (ctype:rangep arg sys)
              (member (ctype:range-kind arg sys) '(integer rational real)))
         (multiple-value-bind (low high) (normalize-integer-bounds arg sys)
           (ctype:range 'integer
                        (if high (lognot high) '*)
                        (if low (lognot low) '*)
                        sys))
         (ctype:range 'integer '* '* sys))
     sys)))

;;; Getting good bounds for these functions is kind of nontrivial.
;;; For now we just mark them as returning fixnums if given them.
;;; TODO. Check Hacker's Delight and SBCL's compiler/bitops-derive-type.lisp.

(defmacro define-log2-deriver (name)
  `(define-deriver ,name (int1 int2)
     (let* ((sys *clasp-system*)
            (fixnum (ctype:range 'integer
                                 most-negative-fixnum most-positive-fixnum sys)))
       (ctype:single-value (if (and (ctype:subtypep int1 fixnum sys)
                                    (ctype:subtypep int2 fixnum sys))
                               fixnum
                               (ctype:range 'integer '* '* sys))
                           sys))))
(define-log2-deriver core:logand-2op)
(define-log2-deriver core:logior-2op)
(define-log2-deriver core:logxor-2op)
(define-log2-deriver logandc1)
(define-log2-deriver logandc2)
(define-log2-deriver logorc1)
(define-log2-deriver logorc2)
(define-log2-deriver core:logeqv-2op)
(define-log2-deriver lognand)
(define-log2-deriver lognor)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; (14) CONSES

(define-deriver cons (car cdr)
  (declare (ignore car cdr))
  ;; We can't forward the argument types into the cons type, since we don't
  ;; know if this cons will be mutated. So we just return the CONS type.
  ;; This is useful so that the compiler understands that CONS definitely
  ;; returns a CONS and it does not need to insert any runtime checks.
  (let* ((sys clasp-cleavir:*clasp-system*) (top (ctype:top sys)))
    (ctype:single-value (ctype:cons top top sys) sys)))

(define-deriver consp (obj)
  (derive-type-predicate obj 'cons *clasp-system*))
(define-deriver atom (obj)
  (derive-type-predicate obj 'atom *clasp-system*))

(defun type-car (type sys)
  (if (ctype:consp type sys)
      (ctype:cons-car type sys)
      (ctype:top sys)))
(defun type-cdr (type sys)
  (if (ctype:consp type sys)
      (ctype:cons-cdr type sys)
      (ctype:top sys)))
(defmacro defcr-type (name &rest ops)
  `(define-deriver ,name (obj)
     (let ((sys clasp-cleavir:*clasp-system*))
       (ctype:single-value
        ,(labels ((rec (ops)
                    (if ops
                        `(,(first ops) ,(rec (rest ops)) sys)
                        'obj)))
           (rec ops))
        sys))))
(defcr-type car type-car)
(defcr-type cdr type-cdr)
(defcr-type caar type-car type-car)
(defcr-type cadr type-car type-cdr)
(defcr-type cdar type-cdr type-car)
(defcr-type cddr type-cdr type-cdr)
(defcr-type caaar type-car type-car type-car)
(defcr-type caadr type-car type-car type-cdr)
(defcr-type cadar type-car type-cdr type-car)
(defcr-type caddr type-car type-cdr type-cdr)
(defcr-type cdaar type-cdr type-car type-car)
(defcr-type cdadr type-cdr type-car type-cdr)
(defcr-type cddar type-cdr type-cdr type-car)
(defcr-type cdddr type-cdr type-cdr type-cdr)
(defcr-type caaaar type-car type-car type-car type-car)
(defcr-type caaadr type-car type-car type-car type-cdr)
(defcr-type caadar type-car type-car type-cdr type-car)
(defcr-type caaddr type-car type-car type-cdr type-cdr)
(defcr-type cadaar type-car type-cdr type-car type-car)
(defcr-type cadadr type-car type-cdr type-car type-cdr)
(defcr-type caddar type-car type-cdr type-cdr type-car)
(defcr-type cadddr type-car type-cdr type-cdr type-cdr)
(defcr-type cdaaar type-cdr type-car type-car type-car)
(defcr-type cdaadr type-cdr type-car type-car type-cdr)
(defcr-type cdadar type-cdr type-car type-cdr type-car)
(defcr-type cdaddr type-cdr type-car type-cdr type-cdr)
(defcr-type cddaar type-cdr type-cdr type-car type-car)
(defcr-type cddadr type-cdr type-cdr type-car type-cdr)
(defcr-type cdddar type-cdr type-cdr type-cdr type-car)
(defcr-type cddddr type-cdr type-cdr type-cdr type-cdr)

(defcr-type rest type-cdr)
(defcr-type first type-car)
(defcr-type second type-car type-cdr)
(defcr-type third type-car type-cdr type-cdr)
(defcr-type fourth type-car type-cdr type-cdr type-cdr)
(defcr-type fifth type-car type-cdr type-cdr type-cdr type-cdr)
(defcr-type sixth type-car type-cdr type-cdr type-cdr type-cdr type-cdr)
(defcr-type seventh type-car
  type-cdr type-cdr type-cdr type-cdr type-cdr type-cdr)
(defcr-type eighth type-car
  type-cdr type-cdr type-cdr type-cdr type-cdr type-cdr type-cdr)
(defcr-type ninth type-car
  type-cdr type-cdr type-cdr type-cdr type-cdr type-cdr type-cdr type-cdr)
(defcr-type tenth type-car
  type-cdr type-cdr type-cdr type-cdr type-cdr type-cdr type-cdr type-cdr
  type-cdr)

(define-deriver list (&rest args)
  (let* ((sys *clasp-system*) (top (ctype:top sys)))
    (ctype:single-value
     (multiple-value-bind (min max) (values-type-minmax args sys)
       (cond ((> min 0) (ctype:cons top top sys))
             ((and max (zerop max)) (ctype:member sys nil))
             (t (ctype:disjoin sys (ctype:member sys nil)
                               (ctype:cons top top sys)))))
     sys)))

(define-deriver list* (arg &rest args)
  (let* ((sys *clasp-system*) (top (ctype:top sys)))
    (ctype:single-value
     (multiple-value-bind (min max) (values-type-minmax args sys)
       (cond ((> min 1) (ctype:cons top top sys))
             ((and max (zerop max)) arg)
             (t
              (ctype:disjoin sys arg (ctype:cons top top sys)))))
     sys)))

(define-deriver endp (obj) (derive-type-predicate obj 'null *clasp-system*))
(define-deriver null (obj) (derive-type-predicate obj 'null *clasp-system*))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; (15) ARRAYS

(define-deriver make-array (dimensions
                            &key (element-type (eql t))
                            initial-element initial-contents
                            (adjustable (eql nil))
                            (fill-pointer (eql nil)) (displaced-to (eql nil))
                            displaced-index-offset)
  (declare (ignore displaced-index-offset initial-element initial-contents))
  (let* ((sys *clasp-system*)
         (etypes (if (ctype:member-p sys element-type)
                     (ctype:member-members sys element-type)
                     '*))
         (complexity
           (let ((null (ctype:member sys nil)))
             (if (and (ctype:subtypep adjustable null sys)
                      (ctype:subtypep fill-pointer null sys)
                      (ctype:subtypep displaced-to null sys))
                 'simple-array
                 'array)))
         (dimensions
           (cond (;; If the array is adjustable, dimensions could change.
                  (eq complexity 'array) '*)
                 (;; FIXME: Clasp's subtypep returns NIL NIL on
                  ;; (member 23), (or fixnum (cons fixnum null)). Ouch!
                  (ctype:subtypep dimensions
                                  (env:parse-type-specifier 'fixnum nil sys)
                                  sys)
                  ;; TODO: Check for constant?
                  '(*))
                 ;; FIXME: Could be way better.
                 (t '*))))
    (ctype:single-value
     (cond ((eq etypes '*)
            (ctype:array etypes dimensions complexity sys))
           ((= (length etypes) 1)
            (ctype:array (first etypes) dimensions complexity sys))
           (t
            (apply #'ctype:disjoin sys
                   (loop for et in etypes
                         collect (ctype:array et dimensions complexity sys)))))
     sys)))

(defun type-aet (type sys)
  (if (ctype:arrayp type sys)
      (ctype:array-element-type type sys)
      (ctype:top sys)))

(defun derive-aref (array indices)
  (declare (ignore indices))
  (let ((sys *clasp-system*))
    (ctype:single-value (type-aet array sys) sys)))

(define-deriver aref (array &rest indices) (derive-aref array indices))
(define-deriver (setf aref) (value array &rest indices)
  (declare (ignore array indices))
  (sv value))

(defun type-array-rank-if-constant (type sys)
  (if (ctype:arrayp type sys)
      (let ((dims (ctype:array-dimensions type sys)))
        (if (eq dims '*)
            nil
            (length dims)))
      nil))

(define-deriver array-rank (array)
  (let ((sys *clasp-system*))
    (ctype:single-value (let ((rank (type-array-rank-if-constant array sys)))
                          (if rank
                              (ctype:range 'integer rank rank sys)
                              (ctype:range 'integer 0 (1- array-rank-limit) sys)))
                        sys)))

(define-deriver arrayp (object)
  (derive-type-predicate object 'array *clasp-system*))

(define-deriver row-major-aref (array index)
  (declare (ignore index))
  (sv (type-aet array *clasp-system*)))
(define-deriver (setf row-major-aref) (value array index)
  (declare (ignore array index))
  (sv value))

(define-deriver vectorp (object)
  (derive-type-predicate object 'vector *clasp-system*))

(define-deriver bit-vector-p (obj)
  (derive-type-predicate obj 'bit-vector *clasp-system*))
(define-deriver simple-bit-vector-p (obj)
  (derive-type-predicate obj 'simple-bit-vector *clasp-system*))

(macrolet ((def (fname etype)
             `(define-deriver ,fname (&rest ignore)
                (declare (ignore ignore))
                (let ((sys *clasp-system*))
                  (ctype:single-value
                   (ctype:array ',etype '(*) 'simple-array sys)
                   sys)))))
  (def core:make-simple-vector-t t)
  (def core:make-simple-vector-bit bit)
  (def core:make-simple-vector-base-char base-char)
  (def core:make-simple-vector-character character)
  (def core:make-simple-vector-single-float single-float)
  (def core:make-simple-vector-double-float double-float)
  (def core:make-simple-vector-int2 ext:integer2)
  (def core:make-simple-vector-byte2 ext:byte2)
  (def core:make-simple-vector-int4 ext:integer4)
  (def core:make-simple-vector-byte4 ext:byte4)
  (def core:make-simple-vector-int8 ext:integer8)
  (def core:make-simple-vector-byte8 ext:byte8)
  (def core:make-simple-vector-int16 ext:integer16)
  (def core:make-simple-vector-byte16 ext:byte16)
  (def core:make-simple-vector-int32 ext:integer32)
  (def core:make-simple-vector-byte32 ext:byte32)
  (def core:make-simple-vector-int64 ext:integer64)
  (def core:make-simple-vector-byte64 ext:byte64)
  (def core:make-simple-vector-fixnum fixnum))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; (16) STRINGS

(define-deriver simple-string-p (obj)
  (derive-type-predicate obj 'simple-string *clasp-system*))

(define-deriver stringp (obj)
  (derive-type-predicate obj 'string *clasp-system*))

(define-deriver make-string (size &key (initial-element character)
                                  (element-type (eql character)))
  (declare (ignore initial-element))
  (let* ((sys *clasp-system*)
         (etypes (if (ctype:member-p sys element-type)
                     (ctype:member-members sys element-type)
                     '*))
         ;; TODO? Right now we just check for constants.
         ;; really, we should probably normalize those to ranges...
         (size (if (ctype:member-p sys size)
                   (let ((mems (ctype:member-members sys size)))
                     (if (and (= (length mems) 1)
                              (integerp (first mems)))
                         (first mems)
                         '*))
                   '*)))
    (ctype:single-value
     (cond ((eq etypes '*)
            (ctype:array etypes (list size) 'simple-array sys))
           ((= (length etypes) 1)
            (ctype:array (first etypes) (list size) 'simple-array sys))
           (t
            (apply #'ctype:disjoin sys
                   (loop for et in etypes
                         collect (ctype:array et (list size)
                                              'simple-array sys)))))
     sys)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; (17) SEQUENCES

;;; We can't simply return cons types because these functions alter them.
;;; Non-simple array types might also be an issue.
(defun type-consless-id (type sys)
  (ctype:single-value
   (if (ctype:consp type sys)
       (let ((top (ctype:top sys))) (ctype:cons top top sys))
       type)
   sys))

(define-deriver fill (sequence item &rest keys)
  (declare (ignore item keys))
  (type-consless-id sequence *clasp-system*))

(define-deriver map-into (sequence function &rest seqs)
  (declare (ignore function seqs))
  (type-consless-id sequence *clasp-system*))
(define-deriver core::map-into-sequence (result function &rest sequences)
  (declare (ignore function sequences))
  (type-consless-id result *clasp-system*))
(define-deriver core::map-into-sequence/1 (result function sequence)
  (declare (ignore function sequence))
  (type-consless-id result *clasp-system*))

(define-deriver length (sequence)
  (let ((sys *clasp-system*))
    (ctype:single-value
     (cond ((ctype:arrayp sequence sys)
            (let ((dims (ctype:array-dimensions sequence sys)))
              (if (and (consp dims) (null (cdr dims)) (not (eq (car dims) '*)))
                  (ctype:range 'integer (car dims) (car dims) sys)
                  (ctype:range 'integer 0 (1- array-dimension-limit) sys))))
           ;; FIXME: Weak.
           (t (ctype:range 'integer 0 '* sys)))
     sys)))

(define-deriver sort (sequence predicate &rest keys)
  (declare (ignore predicate keys))
  (type-consless-id sequence *clasp-system*))
(define-deriver stable-sort (sequence predicate &rest keys)
  (declare (ignore predicate keys))
  (type-consless-id sequence *clasp-system*))

(define-deriver replace (seq1 seq2 &rest keys)
  (declare (ignore seq2 keys))
  (type-consless-id seq1 *clasp-system*))

(define-deriver core::concatenate-into-sequence (result &rest seqs)
  (declare (ignore seqs))
  (type-consless-id result *clasp-system*))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; (22) PRINTER

;;; WRITE et al. just return their first argument.
(define-deriver write (object &rest keys)
  (declare (ignore keys))
  (sv object))
(define-deriver prin1 (object &optional stream)
  (declare (ignore stream))
  (sv object))
(define-deriver print (object &optional stream)
  (declare (ignore stream))
  (sv object))
(define-deriver princ (object &optional stream)
  (declare (ignore stream))
  (sv object))
