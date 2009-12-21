;;; Copyright (c) 2005, Michael Goffioul (michael dot goffioul at swing dot be)
;;;
;;;   This program is free software; you can redistribute it and/or
;;;   modify it under the terms of the GNU Library General Public
;;;   License as published by the Free Software Foundation; either
;;;   version 2 of the License, or (at your option) any later version.
;;;
;;;   See file '../../Copyright' for full details.
;;;
;;; ECL SPECIFIC OPERATIONS FOR ASDF
;;;

(in-package :asdf)
(require 'cmp)

;;;
;;; COMPILE-OP / LOAD-OP
;;;
;;; We change these operations to produce both FASL files and the
;;; object files that they are built from. Having both of them allows
;;; us to later on reuse the object files for bundles, libraries,
;;; standalone executables, etc.
;;;

(defmethod initialize-instance :after ((instance compile-op) &key &allow-other-keys)
  (setf (slot-value instance 'flags) '(:system-p t)))

(defmethod output-files ((o compile-op) (c cl-source-file))
  (list (compile-file-pathname (component-pathname c) :type :object)
        (compile-file-pathname (component-pathname c) :type :fasl)))

(defmethod perform :after ((o compile-op) (c cl-source-file))
  ;; Note how we use OUTPUT-FILES to find the binary locations
  ;; This allows the user to override the names.
  (let* ((input (output-files o c))
         (output (compile-file-pathname (first input) :type :fasl)))
    (c:build-fasl output :lisp-files (remove "fas" input :key #'pathname-type :test #'string=))))

(defmethod perform ((o load-op) (c cl-source-file))
  (loop for i in (input-files o c)
       unless (string= (pathname-type i) "fas")
       collect (let ((output (compile-file-pathname i)))
                 (load output))))

;;;
;;; BUNDLE-OP
;;;
;;; This operation takes all components from one or more systems and
;;; creates a single output file, which may be a FASL, a statically
;;; linked library, a shared library, etc The different targets are
;;; defined by specialization.
;;;

(defclass bundle-op (operation)
  ((type :reader bundle-op-type)
   (monolithic :initform nil :reader bundle-op-monolithic-p)
   (name-suffix :initarg :name-suffix :initform nil)
   (build-args :initarg :args :initform nil :accessor bundle-op-build-args)))

(defclass fasl-op (bundle-op)
  ((type :initform :fasl)))

(defclass lib-op (bundle-op)
  ((type :initform :lib)))

(defclass dll-op (bundle-op)
  ((type :initform :dll)))

(defclass monolithic-bundle-op (bundle-op)
  ((monolithic :initform t)
   (prologue-code :accessor monolithic-op-prologue-code)
   (epilogue-code :accessor monolithic-op-epilogue-code)))

(defclass monolithic-fasl-op (fasl-op monolithic-bundle-op) ())

(defclass monolithic-lib-op (lib-op monolithic-bundle-op)
  ((type :initform :lib)))

(defclass monolithic-dll-op (dll-op monolithic-bundle-op)
  ((type :initform :dll)))

(defclass program-op (monolithic-bundle-op)
  ((type :initform :program)))

(defmethod initialize-instance :after ((instance bundle-op) &rest initargs
                                       &key (name-suffix nil name-suffix-p)
                                       &allow-other-keys)
  (unless name-suffix-p
    (setf (slot-value instance 'name-suffix)
          (if (bundle-op-monolithic-p instance) "-mono" "")))
  (when (typep instance 'monolithic-bundle-op)
    (destructuring-bind (&rest original-initargs
                         &key prologue-code epilogue-code &allow-other-keys)
        (slot-value instance 'original-initargs)
      (setf (slot-value instance 'original-initargs)
            (remove-keys '(epilogue-code prologue-code) original-initargs)
            (monolithic-op-prologue-code instance) prologue-code
            (monolithic-op-epilogue-code instance) epilogue-code)))
  (setf (bundle-op-build-args instance)
        (remove-keys '(type monolithic name-suffix)
                     (slot-value instance 'original-initargs))))

(defvar *force-load-p* nil)

(defmethod operation-done-p :around ((operation load-op) c)
  (if *force-load-p* nil (call-next-method)))

(defun gather-components (op-type system &key filter-system filter-type include-self)
  ;; This function creates a list of components, matched together with an
  ;; operation. This list may be restricted to sub-components of SYSTEM if
  ;; GATHER-ALL = NIL (default), and it may include the system itself.
  (let* ((operation (make-instance op-type))
         (*force-load-p* t)
         (tree (traverse (make-instance 'load-op) system)))
    (append
     (loop for (op . component) in tree
        when (and (typep op 'load-op)
                  (typep component filter-type)
                  (or (not filter-system) (eq (component-system component) filter-system)))
        collect (progn
                  (when (eq component system) (setf include-self nil))
                  (cons operation component)))
     (and include-self (list (cons operation system))))))

;;;
;;; BUNDLE-SUB-OPERATIONS
;;;
;;; Builds a list of pairs (operation . component) which contains all the
;;; dependencies of this bundle. This list is used by TRAVERSE and also
;;; by INPUT-FILES. The dependencies depend on the strategy, as explained
;;; below.
;;;
(defgeneric bundle-sub-operations (operation component))
;;;
;;; First we handle monolithic bundles. These are standalone systems
;;; which contain everything, including other ASDF systems required
;;; by the current one. A PROGRAM is always monolithic.
;;;
;;; MONOLITHIC SHARED LIBRARIES, PROGRAMS, FASL
;;;
;;; Gather the static libraries of all components.
;;;
(defmethod bundle-sub-operations ((o monolithic-bundle-op) c)
  (gather-components 'lib-op c :filter-type 'system :include-self t))
;;;
;;; STATIC LIBRARIES
;;;
;;; Gather the object files of all components and, if monolithic, also
;;; of systems and subsystems.
;;;
(defmethod bundle-sub-operations ((o lib-op) c)
  (gather-components 'compile-op c
                     :filter-system (and (not (bundle-op-monolithic-p o)) c)
                     :filter-type '(not system)))
;;;
;;; SHARED LIBRARIES
;;;
;;; Gather the dynamically linked libraries of all components.
;;; They will be linked into this new shared library, together
;;; with the static library of this module.
;;;
(defmethod bundle-sub-operations ((o dll-op) c)
  (list (cons (make-instance 'lib-op) c)))
;;;
;;; FASL FILES
;;;
;;; Gather the statically linked library of this component.
;;;
(defmethod bundle-sub-operations ((o fasl-op) c)
  (list (cons (make-instance 'lib-op) c)))

(defmethod component-depends-on ((o bundle-op) (c system))
  (loop for (op . dep) in (bundle-sub-operations o c)
     when (typep dep 'system)
     collect (list (class-name (class-of op))
                   (component-name dep))))

(defmethod component-depends-on ((o lib-op) (c system))
  (list (list 'compile-op (component-name c))))

(defmethod component-depends-on ((o bundle-op) c)
  nil)

(defmethod input-files ((o bundle-op) (c system))
  (loop for (sub-op . sub-c) in (bundle-sub-operations o c)
     nconc (output-files sub-op sub-c)))

(defmethod output-files ((o bundle-op) (c system))
  (let ((name (concatenate 'base-string (component-name c)
                           (slot-value o 'name-suffix))))
    (list (merge-pathnames (compile-file-pathname name :type (bundle-op-type o))
                           (component-relative-pathname c)))))

(defmethod output-files ((o fasl-op) (c system))
  (loop for file in (call-next-method)
     collect (make-pathname :type "fasb" :defaults file)))

(defmethod perform ((o bundle-op) (c t))
  t)

(defmethod operation-done-p ((o bundle-op) (c source-file))
  t)

(defmethod perform ((o bundle-op) (c system))
  (let* ((object-files (remove "fas" (input-files o c) :key #'pathname-type :test #'string=))
         (output (output-files o c)))
    (ensure-directories-exist (first output))
    (apply #'c::builder (bundle-op-type o) (first output) :lisp-files object-files
           (append (bundle-op-build-args o)
                   (when (and (typep o 'monolithic-bundle-op)
                              (monolithic-op-prologue-code o))
                     `(:prologue-code ,(monolithic-op-prologue-code o)))
                   (when (and (typep o 'monolithic-bundle-op)
                              (monolithic-op-epilogue-code o))
                     `(:epilogue-code ,(monolithic-op-epilogue-code o)))))))

(defun select-operation (monolithic type)
  (ecase type
    ((:dll :shared-library)
     (if monolithic 'monolithic-dll-op 'dll-op))
    ((:lib :static-library)
     (if monolithic 'monolithic-lib-op 'lib-op))
    ((:fasl)
     (if monolithic 'monolithic-fasl-op 'fasl-op))
    ((:program)
     'program-op)))


(defun make-build (system &rest args &key (monolithic nil) (type :fasl)
                   &allow-other-keys)
  (apply #'operate (select-operation monolithic type)
         system
         (remove-keys '(monolithic type) args)))

;;;
;;; LOAD-FASL-OP
;;;
;;; This is like ASDF's LOAD-OP, but using monolithic fasl files.
;;;

(defclass load-fasl-op (operation) ())

(defun trivial-system-p (c)
  (every #'(lambda (c) (typep c 'compiled-file)) (module-components c)))

(defmethod component-depends-on ((o load-fasl-op) (c system))
  (unless (trivial-system-p c)
    (subst 'load-fasl-op 'load-op
           (subst 'fasl-op 'compile-op
                  (component-depends-on (make-instance 'load-op) c)))))

(defmethod input-files ((o load-fasl-op) (c system))
  (unless (trivial-system-p c)
    (output-files (make-instance 'fasl-op) c)))

(defmethod perform ((o load-fasl-op) (c t))
  nil)

(defmethod perform ((o load-fasl-op) (c system))
  (let ((l (input-files o c)))
    (and l
         (load (first l))
         (loop for i in (module-components c)
            do (setf (gethash 'load-op (component-operation-times i))
                     (get-universal-time))))))

;;;
;;; PRECOMPILED FILES
;;;
;;; This component can be used to distribute ASDF libraries in precompiled
;;; form. Only useful when the dependencies have also been precompiled.
;;;

(defclass compiled-file (component) ())
(defmethod component-relative-pathname ((component compiled-file))
  (compile-file-pathname
   (merge-component-relative-pathname
    (slot-value component 'relative-pathname)
    (component-name component)
    "fas")))

(defmethod output-files (o (c compiled-file))
  nil)
(defmethod input-files (o (c compiled-file))
  nil)
(defmethod perform ((o load-op) (c compiled-file))
  (load (component-pathname c)))
(defmethod perform ((o load-fasl-op) (c compiled-file))
  (load (component-pathname c)))
(defmethod perform (o (c compiled-file))
  nil)

;;;
;;; Final integration steps
;;;

(export '(make-build load-fasl-op))
(push '("fasb" . si::load-binary) si::*load-hooks*)

(require 'cmp)
(defvar *require-asdf-operator* 'load-op)

(defun module-provide-asdf (name)
  (handler-bind ((style-warning #'muffle-warning))
    (let* ((*verbose-out* (make-broadcast-stream))
           (system (asdf:find-system name nil)))
      (when system
        (asdf:operate *require-asdf-operator* name)
        t))))

(defun register-pre-built-system (name)
  (register-system name (make-instance 'system :name name)))

(setf si::*module-provider-functions*
      (loop for f in si::*module-provider-functions*
         unless (eq f 'module-provide-asdf)
         collect #'(lambda (name)
                     (let ((l (multiple-value-list (funcall f name))))
                       (and (first l) (register-pre-built-system name))
                       (values-list l)))))
#+win32 (push '("asd" . si::load-source) si::*load-hooks*)
(pushnew 'module-provide-asdf ext:*module-provider-functions*)
(pushnew (translate-logical-pathname "SYS:") *central-registry*)

(provide 'asdf)
