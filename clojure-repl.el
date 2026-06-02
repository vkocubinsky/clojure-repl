;;; clojure-repl.el --- Clojure REPL interaction -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Valery Kocubinsky

;; Author: Valery Kocubinsky
;; URL: https://github.com/vkocubinsky/clojure-repl
;; Version: 0.2.0
;; Package-Requires: ((emacs "30.1") (clojure-mode "5.23.0"))
;; Keywords: clojure, languages, processes, lisp

;; This file is NOT part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; This package provides basic interaction with a Clojure subprocess (REPL).
;; It's based on ideas from `inferior-lisp' and `inf-clojure' packages.
;; `clojure-repl' provides a set of essential features for interactive
;; Clojure development:
;;
;; * REPL
;; * Interactive code evaluation
;; * Definition lookup
;; * Documentation lookup
;; * Macroexpansion
;; * Run tests
;; * Automatically switch namespace
;; * Automatically load namespace
;; * Automatically install repl functions
;; * Print stack trace

;;; Code:
(require 'comint)
(require 'clojure-mode)
(require 'thingatpt)
(require 'ansi-color)
(require 'subr-x)
(require 'project)

(defgroup clojure-repl nil
  "Run an external Clojure process (REPL) in an Emacs buffer."
  :group 'clojure)

(defcustom clojure-repl-program "clojure"
  "Program name for invoking Clojure."
  :type 'string
  :safe 'stringp)



(defcustom clojure-repl-auto-load-repl t
  "Automatically load repl functions, like user namespace do."
  :type 'boolean
  :safe 'booleanp
  )

(defcustom clojure-repl-auto-load t
  "Automatically load current namespace."
  :type 'boolean
  :safe 'booleanp
  )

(defcustom clojure-repl-auto-switch-ns t
  "Automatically switch to current namespace."
  :type 'boolean
  :safe 'booleanp
  )

(defun clojure-repl-auto-enable-all ()
  "Enable all auto variables.
   See:
   `clojure-repl-auto-load'
   `clojure-repl-auto-load-repl'
   `clojure-repl-auto-switch-ns'
   "
  (interactive)
  (setq clojure-repl-auto-load t
        clojure-repl-auto-load-repl t
        clojure-repl-auto-switch-ns t))


(defun clojure-repl-auto-disable-all ()
  "Enable all auto variables.
   See:
   `clojure-repl-auto-load'
   `clojure-repl-auto-load-repl'
   `clojure-repl-auto-switch-ns'
   "
  (interactive)
  (setq clojure-repl-auto-load nil
        clojure-repl-auto-load-repl nil
        clojure-repl-auto-switch-ns nil))


(defvar clojure-repl-load-command
  "(do (clojure.core/require '%s) :clojure-repl/load)"
  "Clojure load form with namespace parameter.")

(defvar clojure-repl-switch-ns-command
  "(do (in-ns '%s) :clojure-repl/in-ns)"
  "Clojure switch namespace form with namespace name parameter.")

(defvar clojure-repl-load-repl-command
  "(do
     (when-not (= *ns* (find-ns 'user))
       (require 'clojure.main)
       (apply require clojure.main/repl-requires))
     :clojure-repl/load-repl)"
  "Clojure load repl form.")

(defvar clojure-repl-load-file-command
  "(do (clojure.core/load-file \"%s\") :clojure-repl/load-file)"
  "Clojure load file form with namespace name parameter.")

(defvar clojure-repl-doc-command
  "(do (clojure.repl/doc %s) :clojure-repl/doc)"
  "Clojure doc form with var or special form name parameter.")

(defvar clojure-repl-source-command
  "(do (clojure.repl/source %s) :clojure-repl/source)"
  "Clojure source form with var or special form name parameter.")

(defvar clojure-repl-pst-command
  "(do (clojure.repl/pst) :clojure-repl/pst)"
  "Clojure print stack trace form.")

(defvar clojure-repl-macroexpand-command
  "(clojure.core/macroexpand '%s)"
  "Clojure macroexpand form with form text parameter.")

(defvar clojure-repl-macroexpand-1-command
  "(clojure.core/macroexpand-1 '%s)"
  "Clojure macroexpand-1 form with form text parameter.")

(defvar clojure-repl-reload-command
  "(do (clojure.core/require '%s :reload) :clojure-repl/reload)"
  "Clojure reload form with namespace name parameter.")

(defvar clojure-repl-reload-all-command
  "(do (clojure.core/require '%s :reload-all) :clojure-repl/reload-all)"
  "Clojure reload all form with namespace name parameter.")

(defvar clojure-repl-pprint-command
  "(do (clojure.core/require 'clojure.pprint)
      (clojure.pprint/pprint %s)
      :clojure-repl/pprint
      )"
  "Clojure pretty print form with form text parameter.")

(defvar clojure-repl-javadoc-command
  "(do
      (clojure.core/require 'clojure.java.javadoc)
      (clojure.java.javadoc/javadoc %s)
      :clojure-repl/javadoc)"
  "Clojure javadoc form with class or object parameter.")

(defvar clojure-repl-run-all-tests-command
  "(do
      (clojure.core/require 'clojure.test)
      (clojure.test/run-all-tests)
      :clojure-repl/run-all-tests)"
  "Clojure run all tests form")

(defvar clojure-repl-run-ns-tests-command
  "(do
      (clojure.core/require 'clojure.test)
      (clojure.test/run-tests)
      :clojure-repl/run-ns-tests)"
  "Clojure run current namespace tests form.")

(defvar clojure-repl-run-test-command
  "(do
      (clojure.core/require 'clojure.test)
      (clojure.test/run-test %s)
      :clojure-repl/run-test)"
  "Clojure run a test form with test name parameter.")

(defun clojure-repl--process-buffer-name ()
  (let ((proj (project-current)))
    ;; comint adds the asterisks to both sides
    (if proj
        (format "clojure-repl %s" (project-name proj))
      "clojure-repl")))

(defun clojure-repl--repl-buffer-name ()
  ;; comint adds the asterisks to both sides
    (format "*%s*" (clojure-repl--process-buffer-name)))

(defun clojure-repl--repl-buffer ()
  (get-buffer (clojure-repl--repl-buffer-name)))

(defun clojure-repl--repl-process ()
  "Return the current inferior Clojure process."
  (or (get-buffer-process (if (derived-mode-p 'clojure-repl-mode)
                              (current-buffer)
                            (clojure-repl--repl-buffer)))
      (error "No Clojure subprocess")))

(defun clojure-repl--modeline-info ()
  "Return modeline info for `clojure-repl-minor-mode'."
  (let ((repl-buffer (clojure-repl--repl-buffer)))
    (if (and (bufferp repl-buffer)
             (buffer-live-p repl-buffer))
        (with-current-buffer repl-buffer
          (format "[%s]" (buffer-name (current-buffer))))
      "[*clojure-repl no process*]")))

(defvar clojure-repl-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map comint-mode-map)
    (define-key map (kbd "C-x C-e") #'clojure-repl-eval-sexp)
    (define-key map (kbd "C-c C-n") #'clojure-repl-eval-newline)
    (define-key map (kbd "C-c C-l t") #'clojure-repl-load-repl)
    (define-key map (kbd "C-c C-v") #'clojure-repl-show-var-doc)
    (define-key map (kbd "C-c C-s") #'clojure-repl-show-var-source)
    (define-key map (kbd "C-c C-o") #'clojure-repl-clear-repl-buffer)
    (define-key map (kbd "C-c C-q") #'clojure-repl-quit)
    (define-key map (kbd "C-c C-z") #'clojure-repl-switch-to-recent-buffer)
    (easy-menu-define clojure-repl-mode-menu map
      "Clojure REPL Menu"
      '("Clojure-Repl"
        ["Eval sexp" clojure-repl-eval-sexp t]
        ["Eval newline" clojure-repl-eval-newline t]
        "--"
        ["Load repl" clojure-repl-load-repl t]
        "--"
        ["Show documentation for var" clojure-repl-show-var-doc t]
        ["Show source for var" clojure-repl-show-var-source t]
        "--"
        ["Clear REPL" clojure-repl-clear-repl-buffer]
        ["Restart" clojure-repl-restart]
        ["Quit" clojure-repl-quit]))
    map))

(defvar clojure-repl-minor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-M-x")  #'clojure-repl-eval-defun)     
    (define-key map (kbd "C-c C-c") #'clojure-repl-eval-paragraph)     
    (define-key map (kbd "C-x C-e") #'clojure-repl-eval-sexp)
    (define-key map (kbd "C-c C-e") #'clojure-repl-eval-sexp)
    (define-key map (kbd "C-c C-p") #'clojure-repl-pprint-sexp)
    (define-key map (kbd "C-c C-b") #'clojure-repl-eval-buffer)
    (define-key map (kbd "C-c C-r") #'clojure-repl-eval-region)
    (define-key map (kbd "C-c C-n") #'clojure-repl-eval-newline)
    (define-key map (kbd "C-c C-o") #'clojure-repl-clear-repl-buffer)
    
    (define-key map (kbd "C-c C-z") #'clojure-repl-switch-to-repl)
    (define-key map (kbd "C-c C-q") #'clojure-repl-quit)    

    (define-key map (kbd "C-c C-l n") #'clojure-repl-switch-ns)
    ;; quick shortcut for reload current namespace
    (define-key map (kbd "C-c C-k") #'clojure-repl-reload)
    (define-key map (kbd "C-c C-l f") #'clojure-repl-load-file)
    (define-key map (kbd "C-c C-l l") #'clojure-repl-load)
    (define-key map (kbd "C-c C-l r") #'clojure-repl-reload)
    (define-key map (kbd "C-c C-l a") #'clojure-repl-reload-all)
    (define-key map (kbd "C-c C-l t") #'clojure-repl-load-repl)
    
    (define-key map (kbd "C-c C-t a") #'clojure-repl-run-all-tests)
    (define-key map (kbd "C-c C-t n") #'clojure-repl-run-ns-tests)
    (define-key map (kbd "C-c C-t t") #'clojure-repl-run-test)
    
    (define-key map (kbd "C-c C-j") #'clojure-repl-javadoc)
    (define-key map (kbd "C-c C-a") #'clojure-repl-show-pst)
    (define-key map (kbd "C-c C-m") #'clojure-repl-macroexpand)
    (define-key map (kbd "C-c C-v") #'clojure-repl-show-var-doc)
    (define-key map (kbd "C-c C-s") #'clojure-repl-show-var-source)

    (easy-menu-define clojure-repl-minor-mode-menu map
      "Inferior Clojure Minor Mode Menu"
      '("Clojure-Interaction"
        ["Eval top-level sexp at point" clojure-repl-eval-defun t]
        ["Eval sexp" clojure-repl-eval-sexp t]
        ["Pretty print sexp" clojure-repl-pprint-sexp t]
        ["Eval region" clojure-repl-eval-region t]
        ["Eval buffer" clojure-repl-eval-buffer t]
        ["Eval newline" clojure-repl-eval-newline t]
        "--"
        ["Load file" clojure-repl-load-file t]
        ["Switch namespace" clojure-repl-switch-ns t]
        ["Load namespace" clojure-repl-load t]
        ["Reload namespace" clojure-repl-reload t]
        ["Reload all namespace" clojure-repl-reload-all t]
        ["Load repl" clojure-repl-load-repl t]
        "--"
        ["Print documentation for var" clojure-repl-show-var-doc t]
        ["Print source for var" clojure-repl-show-var-source t]
        ["Print stack trace" clojure-repl-show-pst t]
        ["Open javadoc" clojure-repl-javadoc t]
        ["Macroexpand" clojure-repl-macroexpand t]
        "--"
        ["Test all" clojure-repl-run-all-tests t]
        ["Test namespace" clojure-repl-run-ns-tests t]
        ["Test function" clojure-repl-run-test t]
        "--"
        ["Disable all auto load" clojure-repl-auto-disable-all]
        ["Enable all auto load" clojure-repl-auto-enable-all]
        "--"
        ["Switch to REPL" clojure-repl-switch-to-repl t]
        ["Clear REPL" clojure-repl-clear-repl-buffer]
        ["Restart REPL" clojure-repl-restart]
        ["Quit REPL" clojure-repl-quit]))
    map))


;;;###autoload
(defcustom clojure-repl-mode-line
  '(:eval (clojure-repl--modeline-info))
  "Mode line lighter for cider mode.

The value of this variable is a mode line template as in
`mode-line-format'.  See Info Node `(elisp)Mode Line Format' for details
about mode line templates.

Customize this variable to change how `clojure-repl-minor-mode'
displays its status in the mode line.  The default value displays
the current REPL.  Set this variable to nil to disable the
mode line entirely."
  :type 'sexp
  :risky t)

;;;###autoload
(define-minor-mode clojure-repl-minor-mode
  "Minor mode for interacting with the inferior Clojure process buffer.

The following commands are available:

\\{clojure-repl-minor-mode-map}"
  :lighter clojure-repl-mode-line
  :keymap clojure-repl-minor-mode-map
  )


(defcustom clojure-repl-repl-use-same-window nil
  "Controls whether to display the REPL buffer in the current window or not."
  :type '(choice (const :tag "same" t)
                 (const :tag "different" nil))
  :safe 'booleanp)

(defcustom clojure-repl-auto-mode t
  "Automatically enable `clojure-repl-minor-mode'.
All buffers in `clojure-mode' will automatically be in
`clojure-repl-minor-mode' unless set to nil."
  :type 'boolean
  :safe 'booleanp)

(defun clojure-repl--clojure-buffers ()
  "Return a list of all existing `clojure-mode' buffers."
  (seq-filter (lambda (buffer)
                      (with-current-buffer buffer
                        (derived-mode-p 'clojure-mode)))
                    (buffer-list)))

(defun clojure-repl-enable-on-existing-clojure-buffers ()
  "Enable clojure-repl's minor mode on existing Clojure buffers.
See command `clojure-repl-minor-mode'."
  (interactive)
  (add-hook (derived-mode-hook-name 'clojure-mode) #'clojure-repl-minor-mode)
  (dolist (buffer (clojure-repl--clojure-buffers))
    (with-current-buffer buffer
      (clojure-repl-minor-mode +1))))

(defun clojure-repl-disable-on-existing-clojure-buffers ()
  "Disable command `clojure-repl-minor-mode' on existing Clojure buffers."
  (interactive)
  (dolist (buffer (clojure-repl--clojure-buffers))
    (with-current-buffer buffer
      (clojure-repl-minor-mode -1))))


(defcustom clojure-repl-comint-prompt-regexp "^[^=> \n]+=> *"
  "Regexp to recognize prompts in the Inferior Clojure mode."
  :type 'regexp)



(define-derived-mode clojure-repl-mode comint-mode "Clojure Repl"
  "Major mode for run Clojure.

\\<clojure-repl-mode-map>

"
  ;;(setq-local comint-process-echoes t)
  (setq-local comint-use-prompt-regexp t)
  (setq-local comint-prompt-regexp clojure-repl-comint-prompt-regexp)
  (setq-local comint-prompt-read-only t)
  (setq-local mode-line-process '(":%s"))
  (clojure-mode-variables)
  (clojure-font-lock-setup)

  (ansi-color-for-comint-mode-on)
  (when clojure-repl-auto-mode
    (clojure-repl-enable-on-existing-clojure-buffers))
  
  )

(defun clojure-repl-clear-repl-buffer ()
  "Clear the REPL buffer."
  (interactive)
  (with-current-buffer (if (derived-mode-p 'clojure-repl-mode)
                           (current-buffer)
                         (clojure-repl--repl-buffer))
    (comint-clear-buffer)))

(defun clojure-repl--swap-to-buffer-window (to-buffer)
  "Switch to `TO-BUFFER''s window."
  (pop-to-buffer to-buffer '(display-buffer-reuse-window . ())))

(defun clojure-repl-switch-to-repl (eob-p)
  "Switch to the inferior Clojure process buffer.
With prefix argument EOB-P, positions cursor at end of buffer."
  (interactive "P")
  (let ((repl-buffer (clojure-repl--repl-buffer)))
    (if (get-buffer-process repl-buffer)
        (clojure-repl--swap-to-buffer-window repl-buffer)
      (call-interactively #'clojure-repl)))
  (when eob-p
    (push-mark)
    (goto-char (point-max))))

(defun clojure-repl-switch-to-recent-buffer ()
  "Switch to the most recently used `clojure-repl-minor-mode' buffer."
  (interactive)
  (let ((recent-clojure-repl-minor-mode-buffer (seq-find (lambda (buf)
                                                          (with-current-buffer buf (bound-and-true-p clojure-repl-minor-mode)))
                                                        (buffer-list))))
    (if recent-clojure-repl-minor-mode-buffer
        (clojure-repl--swap-to-buffer-window recent-clojure-repl-minor-mode-buffer)
      (user-error "clojure-repl: No recent buffer known."))))

(defun clojure-repl-quit (&optional buffer)
  "Kill the REPL buffer and its underlying process.

You can pass the target BUFFER as an optional parameter
to suppress the usage of the target buffer discovery logic."
  (interactive)
  (let ((repl-buffer (or buffer (clojure-repl--repl-buffer))))
    (when (get-buffer-process repl-buffer)
      (delete-process repl-buffer))
    (kill-buffer repl-buffer)))

(defun clojure-repl-restart ()
  "Restart the REPL buffer and its underlying process."
  (interactive)
  (let* ((repl-buffer (clojure-repl--repl-buffer)))
    (if (null repl-buffer)
        (user-error "No clojure-repl buffers found")
      (clojure-repl-quit repl-buffer)
      (call-interactively #'clojure-repl)  
        )))

;;;###autoload
(defun clojure-repl (cmd &optional suppress-message)
  "Run an inferior Clojure process. Uses `clojure-repl-program' if it is set.

 Runs the hooks from `clojure-repl-mode-hook' (after the
`comint-mode-hook' is run).  \(Type \\[describe-mode] in the
process buffer for a list of commands.)"
  (interactive (list (if current-prefix-arg
                         (read-string "Run clojure: " clojure-repl-program)
                           clojure-repl-program)))
  (let* ((proj (project-current))
         (repl-buffer-name (clojure-repl--repl-buffer-name))
         (process-buffer-name (clojure-repl--process-buffer-name)))
    ;; Create a new comint buffer if needed
    (unless (comint-check-proc repl-buffer-name)
      ;; run the new process in the project's root when in a project folder
      (let ((default-directory (or (when proj (project-root proj)) default-directory))
            (cmdlist (if (consp cmd)
                         (list cmd)
                       (split-string-and-unquote cmd)))
            )
        (unless suppress-message
          (message "Starting Clojure REPL via `%s'..." cmd))
        (with-current-buffer (apply #'make-comint
                                    process-buffer-name (car cmdlist) nil (cdr cmdlist))
          (clojure-repl-mode)
          (set-syntax-table clojure-mode-syntax-table)
          (hack-dir-local-variables-non-file-buffer))))
    (if clojure-repl-repl-use-same-window
        (pop-to-buffer-same-window repl-buffer-name)
      (pop-to-buffer repl-buffer-name))
    repl-buffer-name))

(defun clojure-repl--normalize-input (text)
  (if (string-suffix-p "\n" text) text (concat text "\n")))




(defun clojure-repl--eval-text-as-query (proc text)
  "Eval text use comint-proc-query."
  (comint-proc-query proc (clojure-repl--normalize-input text)))

(defun clojure-repl--eval-text-silently (proc text)
  "Eval text without echo"
  (comint-send-string proc (clojure-repl--normalize-input text))
  (display-buffer (clojure-repl--repl-buffer)))

(defun clojure-repl--eval-text (proc text query-p)
  (with-current-buffer (process-buffer (clojure-repl--repl-process))
      (comint-goto-process-mark)
      (insert "\n")
      (comint-set-process-mark))
  (if query-p (clojure-repl--eval-text-as-query proc text)
    (clojure-repl--eval-text-silently proc text)))

(defun clojure-repl-eval-newline ()
  "Execute defun."
  (interactive)
  (comint-send-string (clojure-repl--repl-process) "\n")
  )

(defun clojure-repl--eval-thing (thing query-p)
  "Eval things such as `sexp', `defun', `region', `buffer'"
  (let ((text (thing-at-point thing t)))
    (unless text
      (user-error (format "No %s found at point" thing)))
    (clojure-repl--eval-text (clojure-repl--repl-process) text query-p)))

(defun clojure-repl--eval-command-with-ns (command query-p)
  "Execute command template which accept namespace as an argument."
  (let* ((proc (clojure-repl--repl-process))
         (ns (clojure-find-ns)))
    (unless ns
      (user-error "No namespace found in current buffer"))
    (clojure-repl--eval-text proc (format command ns) query-p)))

(defun clojure-repl--eval-command-with-thing (command thing query-p)
  "Execute command template which accept things such
   as 'symbol, 'sexp as argument ."
  (let* ((text (thing-at-point thing t)))
    (unless text
      (user-error (format "No %s found at point" thing)))
    (clojure-repl--eval-text (clojure-repl--repl-process) (format command text) query-p)))

(defun clojure-repl-load ()
  "Execute repl load command.
   See variable `clojure-repl-load-command' and variable"
  (interactive)
  (clojure-repl--eval-command-with-ns clojure-repl-load-command t))

(defun clojure-repl-switch-ns ()
  "Execute switch ns command.
   See variable `clojure-repl-switch-ns-command'."
  (interactive)
  (clojure-repl--eval-command-with-ns clojure-repl-switch-ns-command t))

(defun clojure-repl-load-repl ()
  "Execute load repl command.
   See variables `clojure-repl-load-repl-command'"
  (interactive)
  (clojure-repl--eval-text (clojure-repl--repl-process) clojure-repl-load-repl-command t))

(defun clojure-repl--auto-load ()
  (when (derived-mode-p 'clojure-mode)
      (when clojure-repl-auto-load
        (save-excursion (clojure-repl-load)))
      (when clojure-repl-auto-switch-ns
        (save-excursion (clojure-repl-switch-ns)))
      (when clojure-repl-auto-load-repl
        (save-excursion (clojure-repl-load-repl)))))

(defun clojure-repl-eval-region ()
  "Execute region."
  (interactive)
  (clojure-repl--auto-load)
  (clojure-repl--eval-thing 'region nil))

(defun clojure-repl-eval-defun ()
  "Execute defun."
  (interactive)
  (clojure-repl--auto-load)
  (clojure-repl--eval-thing 'defun nil))

(defun clojure-repl-eval-paragraph ()
  "Execute defun."
  (interactive)
  (clojure-repl--auto-load)
  (clojure-repl--eval-thing 'paragraph nil))

(defun clojure-repl-eval-buffer ()
  "Execute buffer."
  (interactive)
  (clojure-repl--auto-load)
  (clojure-repl--eval-thing 'buffer nil))

(defun clojure-repl-eval-sexp ()
  "Execute sexp."
  (interactive)
  (clojure-repl--auto-load)
  (clojure-repl--eval-thing 'sexp nil))

(defun clojure-repl-load-file ()
  "Load current clojure file into the inferior Clojure process."
  (interactive)
  (let* ((proc (clojure-repl--repl-process))
         (file-name (buffer-file-name)))
    (if (and (derived-mode-p 'clojure-mode) file-name)
        (clojure-repl--eval-text proc (format clojure-repl-load-file-command file-name) t)
      (user-error "Current buffer file is not clojure or doesn't exists."))))

(defun clojure-repl-reload ()
  "Execute repl reload command.
   See variable `clojure-repl-reload-command' and variable"
  (interactive)
  (clojure-repl--eval-command-with-ns clojure-repl-reload-command t))

(defun clojure-repl-reload-all ()
  "Execute reload all command.
   See variable `clojure-repl-reload-all-command' and variable"
  (interactive)
  (clojure-repl--eval-command-with-ns clojure-repl-reload-all-command t))

(defun clojure-repl-show-var-doc ()
  "Execute doc command.
   See variable `clojure-repl-doc-command'."
  (interactive)
  (clojure-repl--auto-load)
  (clojure-repl--eval-command-with-thing clojure-repl-doc-command 'symbol t))

(defun clojure-repl-show-var-source ()
  "Execute source command.
   See variable `clojure-repl-var-source-form'."
  (interactive)
  (clojure-repl--auto-load)
  (clojure-repl--eval-command-with-thing clojure-repl-source-command 'symbol t))

(defun clojure-repl-show-pst ()
  "Execute print stack trace command.
   See variable `clojure-repl-pst-command'."
  (interactive)
  (clojure-repl--eval-command-with-ns clojure-repl-pst-command t))

(defun clojure-repl-run-all-tests ()
  "Execute test all namespaces command.
   See variable `clojure-repl-run-all-tests-command'"
  (interactive)
  (clojure-repl--auto-load)
  (clojure-repl--eval-text (clojure-repl--repl-process) clojure-repl-run-all-tests-command nil))

(defun clojure-repl-run-ns-tests ()
  "Excute test current namespace command.
   See variable `clojure-repl-run-ns-tests-command'"
  (interactive)
  (clojure-repl--auto-load)
  (clojure-repl--eval-text (clojure-repl--repl-process) clojure-repl-run-ns-tests-command nil))

(defun clojure-repl-run-test ()
  "Execute current test command.
   See variable `clojure-repl-run-test-command'"
  (interactive)
  (clojure-repl--auto-load)
  (when-let ((defun-name (clojure-current-defun-name)))
    (clojure-repl--eval-text (clojure-repl--repl-process) (format clojure-repl-run-test-command defun-name nil))))

(defun clojure-repl-pprint-sexp ()
  "Execute sexp at point as pretty print."
  (interactive)
  (clojure-repl--auto-load)
  (clojure-repl--eval-command-with-thing clojure-repl-pprint-command 'sexp nil))

(defun clojure-repl-macroexpand (&optional macro-1)
  "Execute macro expansion command.
   See variables `clojure-repl-macroexpand-command' and
   `clojure-repl-macroexpand-1-command'
   With a prefix arg MACRO-1 uses `clojure-repl-macroexpand-1-command'."
  (interactive "P")
  (clojure-repl--auto-load)
  (let* ((macroexpand-form (if macro-1
                               clojure-repl-macroexpand-1-command
                             clojure-repl-macroexpand-command)))
    (clojure-repl--eval-command-with-thing macroexpand-form 'sexp t)))

(defun clojure-repl-javadoc ()
  "Execute javadoc command.
   See variable `clojure-repl-javadoc-command'."
  (interactive)
  (clojure-repl--auto-load)
  (clojure-repl--eval-command-with-thing clojure-repl-javadoc-command 'symbol t))

(provide 'clojure-repl)

;; Local variables:
;; coding: utf-8
;; indent-tabs-mode: nil
;; End:

;;; clojure-repl.el ends here
