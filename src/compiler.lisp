(in-package "PARENSCRIPT")

;;; reserved symbols/literals

(defvar *ps-reserved-symbol-names*
  (list "break" "case" "catch" "continue" "default" "delete" "do" "else"
        "finally" "for" "function" "if" "in" "instanceof" "new" "return"
        "switch" "this" "throw" "try" "typeof" "var" "void" "while" "with"
        "abstract" "boolean" "byte" "char" "class" "const" "debugger" "double"
        "enum" "export" "extends" "final" "float" "goto" "implements" "import"
        "int" "interface" "long" "native" "package" "private" "protected"
        "public" "short" "static" "super" "synchronized" "throws" "transient"
        "volatile"))

(defun add-ps-reserved-symbol (name)
  (pushnew (symbol-name-to-js-string name) *ps-reserved-symbol-names* :test #'equalp))

(defun ps-reserved-symbol-p (symbol)
  (when (symbolp symbol)
    (find (symbol-name-to-js-string symbol) *ps-reserved-symbol-names* :test #'equalp)))

;;; special forms

(defvar *ps-special-forms* (make-hash-table :test 'eq))

(defun get-ps-special-form (name)
  (gethash name *ps-special-forms*))

(defmacro define-ps-special-form (name lambda-list &rest body)
  "Define a special form NAME. The first argument (an anaphor called
'expecting' automatically added to the arglist) to the special form is
a keyword indicating whether the form is expected to produce
an :expression or a :statement."
  (let ((args (gensym "ps-arglist-")))
    `(setf (gethash ',name *ps-special-forms*)
           (lambda (&rest ,args)
             (destructuring-bind ,(cons 'expecting lambda-list)
                 ,args
               (declare (ignorable expecting))
               ,@body)))))

(defun undefine-ps-special-form (name)
  (remhash name *ps-special-forms*))

(defun ps-special-form-p (form)
  (and (consp form)
       (symbolp (car form))
       (gethash (car form) *ps-special-forms*)))

;;; scoping

(defvar *enclosing-lexical-block-declarations* ()
  "This special variable is expected to be bound to a fresh list by
special forms that introduce a new JavaScript lexical block (currently
function definitions and lambdas). Enclosed special forms are expected
to push variable declarations onto the list when the variables
declaration cannot be made by the enclosed form \(for example, a
\(x,y,z\) expression progn\). It is then the responsibility of the
enclosing special form to introduce the variable bindings in its
lexical block.")

(defvar *ps-special-variables* ())

(defun ps-special-variable-p (sym)
  (member sym *ps-special-variables*))

;;; form predicates

(defun comparison-form-p (form)
  (member (car form) '(< > <= >= == != === !==)))

(defun op-form-p (form)
  (and (listp form)
       (not (ps-special-form-p form))
       (not (null (op-precedence (first form))))))

(defun funcall-form-p (form)
  (and form
       (listp form)
       (not (op-form-p form))
       (not (ps-special-form-p form))))

;;; macro expansion
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun make-macro-dictionary ()
    (make-hash-table :test 'eq))
  
  (defvar *ps-macro-toplevel* (make-macro-dictionary)
    "Toplevel macro environment dictionary.")

  (defvar *ps-macro-env* (list *ps-macro-toplevel*)
    "Current macro environment.")

  (defvar *ps-symbol-macro-toplevel* (make-macro-dictionary))

  (defvar *ps-symbol-macro-env* (list *ps-symbol-macro-toplevel*))

  (defvar *ps-local-function-names* ())

  (defvar *ps-setf-expanders* (make-macro-dictionary)
    "Setf expander dictionary. Key is the symbol of the access
function of the place, value is an expansion function that takes the
arguments of the access functions as a first value and the form to be
stored as the second value.")

  (defparameter *ps-compilation-level* :toplevel
    "This value takes on the following values:
:toplevel indicates that we are traversing toplevel forms.
:inside-toplevel-form indicates that we are inside a call to compile-parenscript-form
nil indicates we are no longer toplevel-related."))

(defun lookup-macro-def (name env)
  (loop for e in env thereis (gethash name e)))

(defun make-ps-macro-function (args body)
  (let* ((whole-var (when (eql '&whole (first args)) (second args)))
         (effective-lambda-list (if whole-var (cddr args) args))
         (whole-arg (or whole-var (gensym "ps-macro-form-arg-"))))
    `(lambda (,whole-arg)
       (destructuring-bind ,effective-lambda-list
           (cdr ,whole-arg)
         ,@body))))

(defmacro defpsmacro (name args &body body)
  `(progn (undefine-ps-special-form ',name)
          (setf (gethash ',name *ps-macro-toplevel*) ,(make-ps-macro-function args body))
          ',name))

(defmacro define-ps-symbol-macro (symbol expansion)
  (let ((x (gensym)))
    `(progn (undefine-ps-special-form ',symbol)
            (setf (gethash ',symbol *ps-symbol-macro-toplevel*) (lambda (,x) (declare (ignore ,x)) ',expansion))
            ',symbol)))

(defun import-macros-from-lisp (&rest names)
  "Import the named Lisp macros into the ParenScript macro
environment. When the imported macro is macroexpanded by ParenScript,
it is first fully macroexpanded in the Lisp macro environment, and
then that expansion is further expanded by ParenScript."
  (dolist (name names)
    (eval `(defpsmacro ,name (&rest args)
             (macroexpand `(,',name ,@args))))))

(defmacro defmacro/ps (name args &body body)
  "Define a Lisp macro and import it into the ParenScript macro environment."
  `(progn (defmacro ,name ,args ,@body)
          (import-macros-from-lisp ',name)))

(defmacro defmacro+ps (name args &body body)
  "Define a Lisp macro and a ParenScript macro with the same macro
function (ie - the same result from macroexpand-1), for cases when the
two have different full macroexpansions (for example if the CL macro
contains implementation-specific code when macroexpanded fully in the
CL environment)."
  `(progn (defmacro ,name ,args ,@body)
          (defpsmacro ,name ,args ,@body)))

(defun ps-macroexpand (form)
  (aif (or (lookup-macro-def form *ps-symbol-macro-env*)
           (and (consp form) (lookup-macro-def (car form) *ps-macro-env*)))
       (values (ps-macroexpand (funcall it form)) t)
       form))

(defun maybe-rename-local-function (fun-name)
  (aif (lookup-macro-def fun-name *ps-local-function-names*)
       it
       fun-name))

;;;; compiler interface
(defgeneric compile-parenscript-form (form &key expecting)
  (:documentation "Compiles a ParenScript form to the intermediate
ParenScript representation. :expecting determines whether the form is
compiled to an :expression (the default), a :statement, or a
:symbol."))

(defun adjust-ps-compilation-level (form level)
  "Given the current *ps-compilation-level*, LEVEL, and the fully macroexpanded
form, FORM, returns the new value for *ps-compilation-level*."
  (cond ((or (and (consp form) (member (car form)
                       '(progn locally macrolet symbol-macrolet compile-file)))
         (and (symbolp form) (eq :toplevel level)))
     level)
    ((eq :toplevel level) :inside-toplevel-form)))


(defmethod compile-parenscript-form :around (form &key expecting)
  (assert (if expecting (member expecting '(:expression :statement :symbol)) t))
  (if (eq expecting :symbol)
      (compile-to-symbol form)
      (call-next-method)))

(defun compile-to-symbol (form)
  "Compiles the given Parenscript form and guarantees that the
resultant symbol has an associated script-package. Raises an error if
the form cannot be compiled to a symbol."
  (let ((exp (compile-parenscript-form form :expecting :expression)))
    (when (eq (first exp) 'js:variable)
      (setf exp (second exp)))
    (assert (symbolp exp) ()
            "~a is expected to be a symbol, but compiles to ~a (the ParenScript output for ~a alone is \"~a\"). This could be due to ~a being a special form." form exp form (ps* form) form)
    exp))

(defmethod compile-parenscript-form (form &key expecting)
  (declare (ignore expecting))
  (error "The object ~S cannot be compiled by ParenScript." form))

(defmethod compile-parenscript-form ((form number) &key expecting)
  (declare (ignore expecting))
  form)

(defmethod compile-parenscript-form ((form string) &key expecting)
  (declare (ignore expecting))
  form)

(defmethod compile-parenscript-form ((form character) &key expecting)
  (declare (ignore expecting))
  (compile-parenscript-form (string form)))

(defmethod compile-parenscript-form ((symbol symbol) &key expecting)
  (when (eq *ps-compilation-level* :toplevel)
    (multiple-value-bind (expansion expanded-p)
        (ps-macroexpand symbol)
      (when expanded-p 
        (return-from compile-parenscript-form (compile-parenscript-form expansion :expecting expecting)))))
  (cond ((keywordp symbol) symbol)
        ((ps-special-form-p (list symbol))
         (if (ps-reserved-symbol-p symbol)
             (funcall (get-ps-special-form symbol) :symbol)
             (error "Attempting to use Parenscript special form ~a as variable" symbol)))
        (t `(js:variable ,symbol))))

;;; operators

(defun op-precedence (op)
  (position op
            '((js:new js:slot-value js:aref)
              (postfix++ postfix--)
              (delete void typeof ++ -- unary+ unary- ~ !)
              (* / %)
              (+ -)
              (<< >> >>>)
              (< > <= >= js:instanceof js:in)
              (== != === !==)
              (&)
              (^)
              (\|)
              (\&\& and)
              (\|\| or)
              (js:?)
              (= *= /= %= += -= <<= >>= >>>= \&\= ^= \|=)
              (comma))
            :test #'member))

(defun ps-convert-op-name (op)
  (case op
    (and '\&\&)
    (or '\|\|)
    (not '!)
    (eql '\=\=)
    (=   '\=\=)
    (t op)))

(defun maybe-fix-nary-comparison-form (form)
  (if (< 2 (length (cdr form)))
      (values
       (let* ((operator (car form))
              (tmp-var-forms (butlast (cddr form)))
              (tmp-vars (loop repeat (length tmp-var-forms)
                           collect (ps-gensym "_cmp")))
              (all-comparisons (append (list (cadr form))
                                       tmp-vars
                                       (last form))))
         `(let ,(mapcar #'list tmp-vars tmp-var-forms)
            (and ,@(loop for x1 in all-comparisons
                      for x2 in (cdr all-comparisons)
                      collect (list operator x1 x2)))))
       t)
      form))

(defun compile-op-form (form)
  `(js:operator ,(ps-convert-op-name (compile-parenscript-form (car form) :expecting :symbol))
                ,@(mapcar (lambda (form)
                            (compile-parenscript-form (ps-macroexpand form) :expecting :expression))
                          (cdr form))))

(defun compile-funcall-form (form)
  `(js:funcall
    ,(compile-parenscript-form (if (symbolp (car form))
                                   (maybe-rename-local-function (car form))
                                   (ps-macroexpand (car form)))
                               :expecting :expression)
    ,@(mapcar (lambda (arg)
                (compile-parenscript-form (ps-macroexpand arg) :expecting :expression))
              (cdr form))))

(defmethod compile-parenscript-form ((form cons) &key (expecting :statement))
  (multiple-value-bind (form expanded-p)
      (ps-macroexpand form)
    (let ((*ps-compilation-level*
           (if expanded-p
               *ps-compilation-level*
               (adjust-ps-compilation-level form *ps-compilation-level*))))
      (cond (expanded-p
             (compile-parenscript-form form :expecting expecting))
            ((ps-special-form-p form)
             (apply (get-ps-special-form (car form)) (cons expecting (cdr form))))
            ((comparison-form-p form)
             (multiple-value-bind (form fixed?)
                 (maybe-fix-nary-comparison-form form)
               (if fixed?
                   (compile-parenscript-form form :expecting expecting)
                   (compile-op-form form))))
            ((op-form-p form) (compile-op-form form))
            ((funcall-form-p form) (compile-funcall-form form))
            (t (error "Cannot compile ~S to a ParenScript form." form))))))

(defvar *ps-gensym-counter* 0)

(defun ps-gensym (&optional (prefix "_js"))
  (let ((prefix (if (stringp prefix) prefix (symbol-to-js-string prefix nil))))
    (make-symbol (format nil "~A~:[~;_~]~A" prefix
                         (digit-char-p (char prefix (1- (length prefix))))
                         (incf *ps-gensym-counter*)))))

(defmacro with-ps-gensyms (symbols &body body)
  "Evaluate BODY with SYMBOLS bound to unique ParenScript identifiers.

Each element of SYMBOLS is either a symbol or a list of (symbol
gensym-prefix-string)."
  `(let* ,(mapcar (lambda (symbol)
                    (destructuring-bind (symbol &optional prefix)
                        (if (consp symbol)
                            symbol
                            (list symbol))
                      (if prefix
                          `(,symbol (ps-gensym ,prefix))
                          `(,symbol (ps-gensym ,(symbol-to-js-string symbol))))))
                  symbols)
     ,@body))

(defun %check-once-only-vars (vars)
  (let ((bad-var (find-if (lambda (x) (or (not (symbolp x)) (keywordp x))) vars)))
    (when bad-var
      (error "PS-ONLY-ONCE expected a non-keyword symbol but got ~s" bad-var))))

(defmacro ps-once-only ((&rest vars) &body body)
  (%check-once-only-vars vars)
  (let ((gensyms (mapcar (lambda (x) (ps-gensym (string x))) vars)))
    `(let ,(mapcar (lambda (g v) `(,g (ps-gensym ,(string v)))) gensyms vars)
       `(let* (,,@(mapcar (lambda (g v) ``(,,g ,,v)) gensyms vars))
          ,(let ,(mapcar (lambda (g v) `(,v ,g)) gensyms vars)
             ,@body)))))
