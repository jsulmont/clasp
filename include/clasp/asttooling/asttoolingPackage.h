/*
    File: asttoolingPackage.h
*/

/*
Copyright (c) 2014, Christian E. Schafmeister
 
CLASP is free software; you can redistribute it and/or
modify it under the terms of the GNU Library General Public
License as published by the Free Software Foundation; either
version 2 of the License, or (at your option) any later version.
 
See directory 'clasp/licenses' for full details.
 
The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*/
/* -^- */
#ifndef asttooling_asttoolingPackage_H
#define asttooling_asttoolingPackage_H

#include <clasp/core/common.h>

PACKAGE_USE("COMMON-LISP");
NAMESPACE_PACKAGE_ASSOCIATION(asttooling, AstToolingPkg, "AST-TOOLING");

namespace asttooling {

class AsttoolingExposer_O : public core::Exposer_O {
   LISP_CLASS(asttooling,AstToolingPkg,AsttoolingExposer_O,"AsttoolingExposer",core::Exposer_O);
public:
  AsttoolingExposer_O(core::LispPtr lisp) : Exposer_O(lisp, AstToolingPkg){

                                          };
  virtual void expose(core::LispPtr lisp, WhatToExpose what) const;
};


 
};
#endif
