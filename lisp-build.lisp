;;;; -------------------------------------------------------------------------
;;;; Support to build (compile and load) Lisp files

(asdf/package:define-package :asdf/lisp-build
  (:recycle :asdf/interface :asdf :asdf/lisp-build)
  (:use :asdf/common-lisp :asdf/package :asdf/utility
        :asdf/pathname :asdf/stream :asdf/os :asdf/image)
  (:export
   ;; Variables
   #:*compile-file-warnings-behaviour* #:*compile-file-failure-behaviour*
   #:*output-translation-function*
   #:*optimization-settings* #:*previous-optimization-settings*
   #:compile-condition #:compile-file-error #:compile-warned-error #:compile-failed-error
   #:compile-warned-warning #:compile-failed-warning
   #:check-lisp-compile-results #:check-lisp-compile-warnings
   #:*uninteresting-compiler-conditions* #:*uninteresting-loader-conditions*
   ;; Functions & Macros
   #:get-optimization-settings #:proclaim-optimization-settings
   #:call-with-muffled-compiler-conditions #:with-muffled-compiler-conditions
   #:call-with-muffled-loader-conditions #:with-muffled-loader-conditions
   #:reify-simple-sexp #:unreify-simple-sexp
   #:reify-deferred-warnings #:reify-undefined-warning #:unreify-deferred-warnings
   #:reset-deferred-warnings #:save-deferred-warnings #:check-deferred-warnings
   #:with-saved-deferred-warnings #:warnings-file-p #:warnings-file-type #:*warnings-file-type*
   #:call-with-asdf-compilation-unit #:with-asdf-compilation-unit
   #:current-lisp-file-pathname #:load-pathname
   #:lispize-pathname #:compile-file-type #:call-around-hook
   #:compile-file* #:compile-file-pathname*
   #:load* #:load-from-string #:combine-fasls)
  (:intern #:defaults #:failure-p #:warnings-p #:s #:y #:body))
(in-package :asdf/lisp-build)

(defvar *compile-file-warnings-behaviour*
  (or #+clisp :ignore :warn)
  "How should ASDF react if it encounters a warning when compiling a file?
Valid values are :error, :warn, and :ignore.")

(defvar *compile-file-failure-behaviour*
  (or #+(or mkcl sbcl) :error #+clisp :ignore :warn)
  "How should ASDF react if it encounters a failure (per the ANSI spec of COMPILE-FILE)
when compiling a file, which includes any non-style-warning warning.
Valid values are :error, :warn, and :ignore.
Note that ASDF ALWAYS raises an error if it fails to create an output file when compiling.")


;;; Optimization settings

(defvar *optimization-settings* nil)
(defvar *previous-optimization-settings* nil)
(defun* get-optimization-settings ()
  "Get current compiler optimization settings, ready to PROCLAIM again"
  (let ((settings '(speed space safety debug compilation-speed #+(or cmu scl) c::brevity)))
    #-(or clisp clozure cmu ecl sbcl scl)
    (warn "xcvb-driver::get-optimization-settings does not support your implementation. Please help me fix that.")
    #.`(loop :for x :in settings
         ,@(or #+clozure '(:for v :in '(ccl::*nx-speed* ccl::*nx-space* ccl::*nx-safety* ccl::*nx-debug* ccl::*nx-cspeed*))
               #+ecl '(:for v :in '(c::*speed* c::*space* c::*safety* c::*debug*))
               #+(or cmu scl) '(:for f :in '(c::cookie-speed c::cookie-space c::cookie-safety c::cookie-debug c::cookie-cspeed c::cookie-brevity)))
         :for y = (or #+clisp (gethash x system::*optimize*)
                      #+(or clozure ecl) (symbol-value v)
                      #+(or cmu scl) (funcall f c::*default-cookie*)
                      #+sbcl (cdr (assoc x sb-c::*policy*)))
         :when y :collect (list x y))))
(defun* proclaim-optimization-settings ()
  "Proclaim the optimization settings in *OPTIMIZATION-SETTINGS*"
  (proclaim `(optimize ,@*optimization-settings*))
  (let ((settings (get-optimization-settings)))
    (unless (equal *previous-optimization-settings* settings)
      (setf *previous-optimization-settings* settings))))


;;; Condition control

#+sbcl
(progn
  (defun sb-grovel-unknown-constant-condition-p (c)
    (and (typep c 'sb-int:simple-style-warning)
         (string-enclosed-p
          "Couldn't grovel for "
          (simple-condition-format-control c)
          " (unknown to the C compiler).")))
  (deftype sb-grovel-unknown-constant-condition ()
    '(and style-warning (satisfies sb-grovel-unknown-constant-condition-p))))

(defvar *uninteresting-compiler-conditions*
  (append
   ;;#+clozure '(ccl:compiler-warning)
   #+cmu '("Deleting unreachable code.")
   #+sbcl
   '(sb-c::simple-compiler-note
     "&OPTIONAL and &KEY found in the same lambda list: ~S"
     sb-int:package-at-variance
     sb-kernel:uninteresting-redefinition
     sb-kernel:undefined-alien-style-warning
     ;; sb-ext:implicit-generic-function-warning ; Controversial. Let's allow it by default.
     sb-kernel:lexical-environment-too-complex
     sb-grovel-unknown-constant-condition ; defined above.
     ;; BEWARE: the below four are controversial to include here.
     sb-kernel:redefinition-with-defun
     sb-kernel:redefinition-with-defgeneric
     sb-kernel:redefinition-with-defmethod
     sb-kernel::redefinition-with-defmacro) ; not exported by old SBCLs
   '("No generic function ~S present when encountering macroexpansion of defmethod. Assuming it will be an instance of standard-generic-function.")) ;; from closer2mop
  "Conditions that may be skipped while compiling")

(defvar *uninteresting-loader-conditions*
  (append
   '("Overwriting already existing readtable ~S." ;; from named-readtables
     #(#:finalizers-off-warning :asdf-finalizers)) ;; from asdf-finalizers
   #+clisp '(clos::simple-gf-replacing-method-warning))
  "Additional conditions that may be skipped while loading")

;;;; ----- Filtering conditions while building -----

(defun* call-with-muffled-compiler-conditions (thunk)
  (call-with-muffled-conditions
    thunk *uninteresting-compiler-conditions*))
(defmacro with-muffled-compiler-conditions ((&optional) &body body)
  "Run BODY where uninteresting compiler conditions are muffled"
  `(call-with-muffled-compiler-conditions #'(lambda () ,@body)))
(defun* call-with-muffled-loader-conditions (thunk)
  (call-with-muffled-conditions
   thunk (append *uninteresting-compiler-conditions* *uninteresting-loader-conditions*)))
(defmacro with-muffled-loader-conditions ((&optional) &body body)
  "Run BODY where uninteresting compiler and additional loader conditions are muffled"
  `(call-with-muffled-loader-conditions #'(lambda () ,@body)))


;;;; Handle warnings and failures
(define-condition compile-condition (condition)
  ((context-format
    :initform nil :reader compile-condition-context-format :initarg :context-format)
   (context-arguments
    :initform nil :reader compile-condition-context-arguments :initarg :context-arguments)
   (description
    :initform nil :reader compile-condition-description :initarg :description))
  (:report (lambda (c s)
               (format s (compatfmt "~@<~A~@[ while ~?~]~@:>")
                       (or (compile-condition-description c) (type-of c))
                       (compile-condition-context-format c)
                       (compile-condition-context-arguments c)))))
(define-condition compile-file-error (compile-condition error) ())
(define-condition compile-warned-warning (compile-condition warning) ())
(define-condition compile-warned-error (compile-condition error) ())
(define-condition compile-failed-warning (compile-condition warning) ())
(define-condition compile-failed-error (compile-condition error) ())

(defun* check-lisp-compile-warnings (warnings-p failure-p
                                                &optional context-format context-arguments)
  (when failure-p
    (case *compile-file-failure-behaviour*
      (:warn (warn 'compile-failed-warning
                   :description "Lisp compilation failed"
                   :context-format context-format
                   :context-arguments context-arguments))
      (:error (error 'compile-failed-error
                   :description "Lisp compilation failed"
                   :context-format context-format
                   :context-arguments context-arguments))
      (:ignore nil)))
  (when warnings-p
    (case *compile-file-warnings-behaviour*
      (:warn (warn 'compile-warned-warning
                   :description "Lisp compilation had style-warnings"
                   :context-format context-format
                   :context-arguments context-arguments))
      (:error (error 'compile-warned-error
                   :description "Lisp compilation had style-warnings"
                   :context-format context-format
                   :context-arguments context-arguments))
      (:ignore nil))))

(defun* check-lisp-compile-results (output warnings-p failure-p
                                           &optional context-format context-arguments)
  (unless output
    (error 'compile-file-error :context-format context-format :context-arguments context-arguments))
  (check-lisp-compile-warnings warnings-p failure-p context-format context-arguments))


;;;; Deferred-warnings treatment, originally implemented by Douglas Katzman.
;;
;; To support an implementation, three functions must be implemented:
;; reify-deferred-warnings unreify-deferred-warnings reset-deferred-warnings
;; See their respective docstrings.

(defun reify-simple-sexp (sexp)
  (etypecase sexp
    (symbol (reify-symbol sexp))
    ((or number character simple-string pathname) sexp)
    (cons (cons (reify-simple-sexp (car sexp)) (reify-simple-sexp (cdr sexp))))))
(defun unreify-simple-sexp (sexp)
  (etypecase sexp
    ((or symbol number character simple-string pathname) sexp)
    (cons (cons (unreify-simple-sexp (car sexp)) (unreify-simple-sexp (cdr sexp))))
    ((simple-vector 2) (unreify-symbol sexp))))

#+clozure
(progn
  (defun reify-source-note (source-note)
    (when source-note
      (with-accessors ((source ccl::source-note-source) (filename ccl:source-note-filename)
                       (start-pos ccl:source-note-start-pos) (end-pos ccl:source-note-end-pos)) source-note
          (declare (ignorable source))
          (list :filename filename :start-pos start-pos :end-pos end-pos
                #|:source (reify-source-note source)|#))))
  (defun unreify-source-note (source-note)
    (when source-note
      (destructuring-bind (&key filename start-pos end-pos source) source-note
        (ccl::make-source-note :filename filename :start-pos start-pos :end-pos end-pos
                               :source (unreify-source-note source)))))
  (defun reify-deferred-warning (deferred-warning)
    (with-accessors ((warning-type ccl::compiler-warning-warning-type)
                     (args ccl::compiler-warning-args)
                     (source-note ccl:compiler-warning-source-note)
                     (function-name ccl:compiler-warning-function-name)) deferred-warning
      (list :warning-type warning-type :function-name (reify-simple-sexp function-name)
            :source-note (reify-source-note source-note) :args (reify-simple-sexp args))))
  (defun unreify-deferred-warning (reified-deferred-warning)
    (destructuring-bind (&key warning-type function-name source-note args)
        reified-deferred-warning
      (make-condition (or (cdr (ccl::assq warning-type ccl::*compiler-whining-conditions*))
                          'ccl::compiler-warning)
                      :function-name (unreify-simple-sexp function-name)
                      :source-note (unreify-source-note source-note)
                      :warning-type warning-type
                      :args (unreify-simple-sexp args)))))

#+sbcl
(defun reify-undefined-warning (warning)
  ;; Extracting undefined-warnings from the compilation-unit
  ;; To be passed through the above reify/unreify link, it must be a "simple-sexp"
  (list*
   (sb-c::undefined-warning-kind warning)
   (sb-c::undefined-warning-name warning)
   (sb-c::undefined-warning-count warning)
   (mapcar
    #'(lambda (frob)
        ;; the lexenv slot can be ignored for reporting purposes
        `(:enclosing-source ,(sb-c::compiler-error-context-enclosing-source frob)
          :source ,(sb-c::compiler-error-context-source frob)
          :original-source ,(sb-c::compiler-error-context-original-source frob)
          :context ,(sb-c::compiler-error-context-context frob)
          :file-name ,(sb-c::compiler-error-context-file-name frob) ; a pathname
          :file-position ,(sb-c::compiler-error-context-file-position frob) ; an integer
          :original-source-path ,(sb-c::compiler-error-context-original-source-path frob)))
    (sb-c::undefined-warning-warnings warning))))

(defun reify-deferred-warnings ()
  "return a portable S-expression, portably readable and writeable in any Common Lisp implementation
using READ within a WITH-SAFE-IO-SYNTAX, that represents the warnings currently deferred by
WITH-COMPILATION-UNIT. One of three functions required for deferred-warnings support in ASDF."
  #+clozure
  (mapcar 'reify-deferred-warning
          (if-let (dw ccl::*outstanding-deferred-warnings*)
            (let ((mdw (ccl::ensure-merged-deferred-warnings dw)))
              (ccl::deferred-warnings.warnings mdw))))
  #+sbcl
  (when sb-c::*in-compilation-unit*
    ;; Try to send nothing through the pipe if nothing needs to be accumulated
    `(,@(when sb-c::*undefined-warnings*
          `((sb-c::*undefined-warnings*
             ,@(mapcar #'reify-undefined-warning sb-c::*undefined-warnings*))))
      ,@(loop :for what :in '(sb-c::*aborted-compilation-unit-count*
                              sb-c::*compiler-error-count*
                              sb-c::*compiler-warning-count*
                              sb-c::*compiler-style-warning-count*
                              sb-c::*compiler-note-count*)
              :for value = (symbol-value what)
              :when (plusp value)
                :collect `(,what . ,value)))))

(defun unreify-deferred-warnings (reified-deferred-warnings)
  "given a S-expression created by REIFY-DEFERRED-WARNINGS, reinstantiate the corresponding
deferred warnings as to be handled at the end of the current WITH-COMPILATION-UNIT.
Handle any warning that has been resolved already,
such as an undefined function that has been defined since.
One of three functions required for deferred-warnings support in ASDF."
  (declare (ignorable reified-deferred-warnings))
  #+clozure
  (let ((dw (or ccl::*outstanding-deferred-warnings*
                (setf ccl::*outstanding-deferred-warnings* (ccl::%defer-warnings t)))))
    (appendf (ccl::deferred-warnings.warnings dw)
             (mapcar 'unreify-deferred-warning reified-deferred-warnings)))
  #+sbcl
  (dolist (item reified-deferred-warnings)
    ;; Each item is (symbol . adjustment) where the adjustment depends on the symbol.
    ;; For *undefined-warnings*, the adjustment is a list of initargs.
    ;; For everything else, it's an integer.
    (destructuring-bind (symbol . adjustment) item
      (case symbol
        ((sb-c::*undefined-warnings*)
         (setf sb-c::*undefined-warnings*
               (nconc (mapcan
                       #'(lambda (stuff)
                           (destructuring-bind (kind name count . rest) stuff
                             (unless (case kind (:function (fboundp name)))
                               (list
                                (sb-c::make-undefined-warning
                                 :name name
                                 :kind kind
                                 :count count
                                 :warnings
                                 (mapcar #'(lambda (x)
                                             (apply #'sb-c::make-compiler-error-context x))
                                         rest))))))
                       adjustment)
                      sb-c::*undefined-warnings*)))
        (otherwise
         (set symbol (+ (symbol-value symbol) adjustment)))))))

(defun reset-deferred-warnings ()
  "Reset the set of deferred warnings to be handled at the end of the current WITH-COMPILATION-UNIT.
One of three functions required for deferred-warnings support in ASDF."
  #+clozure
  (if-let (dw ccl::*outstanding-deferred-warnings*)
    (let ((mdw (ccl::ensure-merged-deferred-warnings dw)))
      (setf (ccl::deferred-warnings.warnings mdw) nil)))
  #+sbcl
  (when sb-c::*in-compilation-unit*
    (setf sb-c::*undefined-warnings* nil
          sb-c::*aborted-compilation-unit-count* 0
          sb-c::*compiler-error-count* 0
          sb-c::*compiler-warning-count* 0
          sb-c::*compiler-style-warning-count* 0
          sb-c::*compiler-note-count* 0)))

(defun* save-deferred-warnings (warnings-file)
  "Save forward reference conditions so they may be issued at a latter time,
possibly in a different process."
  (with-open-file (s warnings-file :direction :output :if-exists :supersede)
    (with-safe-io-syntax ()
      (write (reify-deferred-warnings) :stream s :pretty t :readably t)
      (terpri s)))
  (reset-deferred-warnings))

(defun* warnings-file-type (&optional implementation-type)
  (case (or implementation-type *implementation-type*)
    (:sbcl "sbcl-warnings")
    ((:clozure :ccl) "ccl-warnings")))

(defvar *warnings-file-type* (warnings-file-type)
  "Type for warnings files")

(defun* warnings-file-p (file &optional implementation-type)
  (if-let (type (if implementation-type
                    (warnings-file-type implementation-type)
                    *warnings-file-type*))
    (equal (pathname-type file) type)))

(defun* check-deferred-warnings (files &optional context-format context-arguments)
  (let ((file-errors nil)
        (failure-p nil)
        (warnings-p nil))
    (handler-bind
        ((warning #'(lambda (c)
                      (setf warnings-p t)
                      (unless (typep c 'style-warning)
                        (setf failure-p t)))))
      (with-compilation-unit (:override t)
        (reset-deferred-warnings)
        (dolist (file files)
          (unreify-deferred-warnings
           (handler-case (safe-read-file-form file)
             (error (c)
               (delete-file-if-exists file)
               (push c file-errors)
               nil))))))
    (dolist (error file-errors) (error error))
    (check-lisp-compile-warnings
     (or failure-p warnings-p) failure-p context-format context-arguments)))


;;;; Deferred warnings
#|
Mini-guide to adding support for deferred warnings on an implementation.

First, look at what such a warning looks like:

(describe
 (handler-case
     (and (eval '(lambda () (some-undefined-function))) nil)
   (t (c) c)))

Then you can grep for the condition type in your compiler sources
and see how to catch those that have been deferred,
and/or read, clear and restore the deferred list.

ccl::
undefined-function-reference
verify-deferred-warning
report-deferred-warnings

|#

(defun* call-with-saved-deferred-warnings (thunk warnings-file)
  (if warnings-file
      (with-compilation-unit (:override t)
        (let (#+sbcl (sb-c::*undefined-warnings* nil))
          (multiple-value-prog1
              (with-muffled-compiler-conditions ()
                (funcall thunk))
            (save-deferred-warnings warnings-file)
            (reset-deferred-warnings))))
      (funcall thunk)))

(defmacro with-saved-deferred-warnings ((warnings-file) &body body)
  "If WARNINGS-FILE is not nil, records the deferred-warnings around the BODY
and saves those warnings to the given file for latter use,
possibly in a different process. Otherwise just run the BODY."
  `(call-with-saved-deferred-warnings #'(lambda () ,@body) ,warnings-file))


;;; from ASDF

(defun* current-lisp-file-pathname ()
  (or *compile-file-pathname* *load-pathname*))

(defun* load-pathname ()
  *load-pathname*)

(defun* lispize-pathname (input-file)
  (make-pathname :type "lisp" :defaults input-file))

(defun* compile-file-type (&rest keys)
  "pathname TYPE for lisp FASt Loading files"
  (declare (ignorable keys))
  #-(or ecl mkcl) (load-time-value (pathname-type (compile-file-pathname "foo.lisp")))
  #+(or ecl mkcl) (pathname-type (apply 'compile-file-pathname "foo" keys)))

(defun* call-around-hook (hook function)
  (call-function (or hook 'funcall) function))

(defun* compile-file-pathname* (input-file &rest keys &key output-file &allow-other-keys)
  (let* ((keys
           (remove-plist-keys `(#+(and allegro (not (version>= 8 2))) :external-format
                            ,@(unless output-file '(:output-file))) keys)))
    (if (absolute-pathname-p output-file)
        ;; what cfp should be doing, w/ mp* instead of mp
        (let* ((type (pathname-type (apply 'compile-file-type keys)))
               (defaults (make-pathname
                          :type type :defaults (merge-pathnames* input-file))))
          (merge-pathnames* output-file defaults))
        (funcall *output-translation-function*
                 (apply 'compile-file-pathname input-file keys)))))

(defun* (compile-file*) (input-file &rest keys
                                    &key compile-check output-file warnings-file
                                    #+clisp lib-file #+(or ecl mkcl) object-file
                                    &allow-other-keys)
  "This function provides a portable wrapper around COMPILE-FILE.
It ensures that the OUTPUT-FILE value is only returned and
the file only actually created if the compilation was successful,
even though your implementation may not do that, and including
an optional call to an user-provided consistency check function COMPILE-CHECK;
it will call this function if not NIL at the end of the compilation
with the arguments sent to COMPILE-FILE*, except with :OUTPUT-FILE TMP-FILE
where TMP-FILE is the name of a temporary output-file.
It also checks two flags (with legacy british spelling from ASDF1),
*COMPILE-FILE-FAILURE-BEHAVIOUR* and *COMPILE-FILE-WARNINGS-BEHAVIOUR*
with appropriate implementation-dependent defaults,
and if a failure (respectively warnings) are reported by COMPILE-FILE
with consider it an error unless the respective behaviour flag
is one of :SUCCESS :WARN :IGNORE.
If WARNINGS-FILE is defined, deferred warnings are saved to that file.
On ECL or MKCL, it creates both the linkable object and loadable fasl files.
On implementations that erroneously do not recognize standard keyword arguments,
it will filter them appropriately."
  #+ecl (when (and object-file (equal (compile-file-type) (pathname object-file)))
          (format t "Whoa, some funky ASDF upgrade switched ~S calling convention for ~S and ~S~%"
                  'compile-file* output-file object-file)
          (rotatef output-file object-file))
  (let* ((keywords (remove-plist-keys
                    `(:output-file :compile-check :warnings-file
                      #+clisp :lib-file #+(or ecl mkcl) :object-file
                      #+gcl2.6 ,@'(:external-format :print :verbose)) keys))
         (output-file
           (or output-file
               (apply 'compile-file-pathname* input-file :output-file output-file keywords)))
         #+ecl
         (object-file
           (unless (use-ecl-byte-compiler-p)
             (or object-file
                 (compile-file-pathname output-file :type :object))))
         #+mkcl
         (object-file
           (or object-file
               (compile-file-pathname output-file :fasl-p nil)))
         (tmp-file (tmpize-pathname output-file))
         #+clisp
         (tmp-lib (make-pathname :type "lib" :defaults tmp-file)))
    (multiple-value-bind (output-truename warnings-p failure-p)
        (with-saved-deferred-warnings (warnings-file)
          (or #-(or ecl mkcl) (apply 'compile-file input-file :output-file tmp-file keywords)
              #+ecl (apply 'compile-file input-file :output-file
                           (if object-file
                               (list* object-file :system-p t keywords)
                               (list* tmp-file keywords)))
              #+mkcl (apply 'compile-file input-file
                            :output-file object-file :fasl-p nil keywords)))
      (cond
        ((and output-truename
              (flet ((check-flag (flag behaviour)
                       (or (not flag) (member behaviour '(:success :warn :ignore)))))
                (and (check-flag failure-p *compile-file-failure-behaviour*)
                     (check-flag warnings-p *compile-file-warnings-behaviour*)))
              (progn
                #+(or ecl mkcl)
                (when (and #+ecl object-file)
                  (setf output-truename
                        (compiler::build-fasl
                         tmp-file #+ecl :lisp-files #+mkcl :lisp-object-files
                                  (list object-file))))
                (or (not compile-check)
                    (apply compile-check input-file :output-file tmp-file keywords))))
         (delete-file-if-exists output-file)
         (when output-truename
           #+clisp (when lib-file (rename-file-overwriting-target tmp-lib lib-file))
           (rename-file-overwriting-target output-truename output-file)
           (setf output-truename (truename output-file)))
         #+clisp (delete-file-if-exists tmp-lib))
        (t ;; error or failed check
         (delete-file-if-exists output-truename)
         (setf output-truename nil)))
      (values output-truename warnings-p failure-p))))

(defun* load* (x &rest keys &key &allow-other-keys)
  (etypecase x
    ((or pathname string #-(or allegro clozure gcl2.6 genera) stream)
     (apply 'load x
            #-gcl2.6 keys #+gcl2.6 (remove-plist-key :external-format keys)))
    ;; GCL 2.6, Genera can't load from a string-input-stream
    ;; ClozureCL 1.6 can only load from file input stream
    ;; Allegro 5, I don't remember but it must have been broken when I tested.
    #+(or allegro clozure gcl2.6 genera)
    (stream ;; make do this way
     (let ((*package* *package*)
           (*readtable* *readtable*)
           (*load-pathname* nil)
           (*load-truename* nil))
       (eval-input x)))))

(defun* load-from-string (string)
  "Portably read and evaluate forms from a STRING."
  (with-input-from-string (s string) (load* s)))

;;; Links FASLs together
(defun* combine-fasls (inputs output)
  #-(or allegro clisp clozure cmu lispworks sbcl scl xcl)
  (error "~A does not support ~S~%inputs ~S~%output  ~S"
         (implementation-type) 'combine-fasls inputs output)
  #+clozure (ccl:fasl-concatenate output inputs :if-exists :supersede)
  #+(or allegro clisp cmu sbcl scl xcl) (concatenate-files inputs output)
  #+lispworks
  (let (fasls)
    (unwind-protect
         (progn
           (loop :for i :in inputs
                 :for n :from 1
                 :for f = (add-pathname-suffix
                           output (format nil "-FASL~D" n))
                 :do #-lispworks-personal-edition (lispworks:copy-file i f)
                     #+lispworks-personal-edition (concatenate-files (list i) f)
                     (push f fasls))
           (ignore-errors (lispworks:delete-system :fasls-to-concatenate))
           (eval `(scm:defsystem :fasls-to-concatenate
                    (:default-pathname ,(pathname-directory-pathname output))
                    :members
                    ,(loop :for f :in (reverse fasls)
                           :collect `(,(namestring f) :load-only t))))
           (scm:concatenate-system output :fasls-to-concatenate))
      (loop :for f :in fasls :do (ignore-errors (delete-file f)))
      (ignore-errors (lispworks:delete-system :fasls-to-concatenate)))))

