;;; rinari.el --- Rinari Is Not A Rails IDE

;; Copyright (C) 2008 Phil Hagelberg, Eric Schulte

;; Author: Phil Hagelberg, Eric Schulte
;; URL: https://github.com/eschulte/rinari
;; Version: DEV
;; Created: 2006-11-10
;; Keywords: ruby, rails, project, convenience, web
;; EmacsWiki: Rinari
;; Package-Requires: ((ruby-mode "1.1") (inf-ruby "2.2.1") (ruby-compilation "0.8") (jump "2.0"))

;; This file is NOT part of GNU Emacs.

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; Rinari Is Not A Ruby IDE.

;; Well, ok it kind of is.  Rinari is a set of Emacs Lisp modes that is
;; aimed towards making Emacs into a top-notch Ruby and Rails
;; development environment.

;; Rinari can be installed through ELPA (see http://tromey.com/elpa/)

;; To install from source, copy the directory containing this file
;; into your Emacs Lisp directory, assumed here to be ~/.emacs.d.  Add
;; these lines of code to your .emacs file:

;; ;; rinari
;; (add-to-list 'load-path "~/.emacs.d/rinari")
;; (require 'rinari)

;; Whether installed through ELPA or from source you probably want to
;; add the following lines to your .emacs file:

;; ;; ido
;; (require 'ido)
;; (ido-mode t)

;; Note: if you cloned this from a git repo, you will have to grab the
;; submodules which can be done by running the following commands from
;; the root of the rinari directory

;;  git submodule init
;;  git submodule update

;;; Code:
;;;###begin-elpa-ignore
(let* ((this-dir (file-name-directory (or load-file-name buffer-file-name)))
       (util-dir (file-name-as-directory (expand-file-name "util" this-dir)))
       (inf-ruby-dir (file-name-as-directory (expand-file-name "inf-ruby" util-dir)))
       (jump-dir (file-name-as-directory (expand-file-name "jump" util-dir))))
  (dolist (dir (list util-dir inf-ruby-dir jump-dir))
    (when (file-exists-p dir)
      (add-to-list 'load-path dir))))
;;;###end-elpa-ignore
(require 'ruby-mode)
(require 'inf-ruby)
(require 'ruby-compilation)
(require 'jump)
(require 'cl)

;; fill in some missing variables for XEmacs
(when (featurep 'xemacs)
  ;;this variable does not exist in XEmacs
  (defvar safe-local-variable-values ())
  ;;find-file-hook is not defined and will otherwise not be called by XEmacs
  (define-compatible-variable-alias 'find-file-hook 'find-file-hooks))

(defgroup rinari nil
  "Rinari customizations."
  :prefix "rinari-"
  :group 'rinari)

(defcustom rinari-tags-file-name
  "TAGS"
  "Path to your TAGS file inside of your rails project.  See `tags-file-name'."
  :group 'rinari)

(defvar rinari-minor-mode-hook nil
  "*Hook for customising Rinari.")

(defcustom rinari-rails-env nil
  "Use this to force a value for RAILS_ENV when running rinari.
Leave this set to nil to not force any value for RAILS_ENV, and
leave this to the environment variables outside of Emacs.")

(defvar rinari-minor-mode-prefixes
  (list ";" "'")
  "List of characters, each of which will be bound (with control-c) as a prefix for `rinari-minor-mode-map'.")

(defcustom rinari-inf-ruby-prompt-pattern
  "\\(^>> .*\\)\\|\\(^\\(irb([^)]+)\\|\\(\[[0-9]+\] \\)?[Pp]ry ?([^)]+)\\|\\(jruby-\\|JRUBY-\\)?[1-9]\\.[0-9]\\.[0-9]+\\(-?p?[0-9]+\\)?\\) ?\\(:[0-9]+\\)* ?[\]>*\"'/`]>? *\\)"
  "The value used for `inf-ruby-prompt-pattern' in `rinari-console' buffers."
  :group 'rinari)

(defvar rinari-partial-regex
  "render \\(:partial *=> \\)?*[@'\"]?\\([A-Za-z/_]+\\)['\"]?"
  "Regex that matches a partial rendering call.")

(defadvice ruby-compilation-do (around rinari-compilation-do activate)
  "Set default directory to the rails root before running ruby processes."
  (let ((default-directory (or (rinari-root) default-directory)))
    ad-do-it
    (rinari-launch)))

(defadvice ruby-compilation-rake (around rinari-compilation-rake activate)
  "Set default directory to the rails root before running rake processes."
  (let ((default-directory (or (rinari-root) default-directory)))
    ad-do-it
    (rinari-launch)))

(defadvice ruby-compilation-cap (around rinari-compilation-cap activate)
  "Set default directory to the rails root before running cap processes."
  (let ((default-directory (or (rinari-root) default-directory)))
    ad-do-it
    (rinari-launch)))

(defun rinari-parse-yaml ()
  "Parse key/value pairs out of a simple yaml file."
  (let ((start (point))
        (end (save-excursion (re-search-forward "^[^:]*$" nil t) (point)))
        alist)
    (while (and (< (point) end)
                (re-search-forward "^ *\\(.*\\): \\(.*\\)$" nil t))
      (setf alist (cons (cons (match-string 1) (match-string 2)) alist)))
    alist))

(defun rinari-root (&optional dir home)
  "Return the root directory of the project within which DIR is found.
Optional argument HOME is ignored."
  (or dir (setq dir default-directory))
  (if (file-exists-p (expand-file-name
                      "environment.rb" (expand-file-name "config" dir)))
      dir
    (let ((new-dir (expand-file-name (file-name-as-directory "..") dir)))
      ;; regexp to match windows roots, tramp roots, or regular posix roots
      (unless (string-match "\\(^[[:alpha:]]:/$\\|^/[^\/]+:/?$\\|^/$\\)" dir)
        (rinari-root new-dir)))))

;;--------------------------------------------------------------------------------
;; user functions

(defun rinari-rake (&optional task edit-cmd-args)
  "Select and run a rake TASK.
Rake output is dumped to a compilation buffer allowing jumping
between errors and source code.
Optional prefix argument EDIT-CMD-ARGS lets the user edit the
rake command arguments."
  (interactive "P")
  (ruby-compilation-rake task edit-cmd-args
                         (if rinari-rails-env (list (cons "RAILS_ENV" rinari-rails-env)))))

(defun rinari-cap (&optional task edit-cmd-args)
  "Select and run a capistrano TASK.
Cap output is dumped to a compilation buffer allowing jumping
between errors and source code.
Optional prefix argument EDIT-CMD-ARGS lets the user edit the
cap command arguments."
  (interactive "P")
  (ruby-compilation-cap task edit-cmd-args
                        (if rinari-rails-env (list (cons "RAILS_ENV" rinari-rails-env)))))

(defun rinari-discover-rails-commands ()
  "Return a list of commands supported by the main rails script."
  (let ((root (rinari-root))
        (commands nil))
    (if (file-executable-p (concat root "script/rails"))
        (let ((s (shell-command-to-string (concat root "script/rails")))
              (start 0))
          (save-excursion
            (loop while (string-match "^ \\([a-z]+\\)[[:space:]].*$" s start)
                  do (setq start (match-end 0))
                  collecting (substring-no-properties (match-string 1 s))))))))

(defvar rinari-rails-commands-cache nil
  "Cached values for commands that can be used with 'script/rails' in Rails 3.")

(defun rinari-get-rails-commands ()
  "Return a cached list of commands supported by the main rails script."
  (if (null rinari-rails-commands-cache)
      (setq rinari-rails-commands-cache (rinari-discover-rails-commands)))
  rinari-rails-commands-cache)

(defun rinari-script (&optional script)
  "Select and run SCRIPT from the script/ directory of the rails application."
  (interactive)
  (let* ((root (rinari-root))
         (rails3 (file-executable-p (concat root "script/rails")))
         (completions (append (directory-files (concat root "script") nil "^[^.]")
                              (rinari-get-rails-commands)))
         (script (or script (jump-completing-read "Script: " completions)))
         (ruby-compilation-error-regexp-alist ;; for jumping to newly created files
          (if (equal script "generate")
              '(("^ +\\(exists\\|create\\) +\\([^[:space:]]+\\.rb\\)" 2 3))
            ruby-compilation-error-regexp-alist))
         (script (if (file-executable-p (concat root "script/" script))
                     (concat "script/" script " ")
                   (concat "script/rails " script " "))))
    (ruby-compilation-run (concat root script (read-from-minibuffer script)))))

(defun rinari-test (&optional edit-cmd-args)
  "Run the current ruby function as a test, or run the corresponding test.
If current function is not a test,`rinari-find-test' is used to
find the corresponding test.  Output is sent to a compilation buffer
allowing jumping between errors and source code.  Optional prefix
argument EDIT-CMD-ARGS lets the user edit the test command
arguments."
  (interactive "P")
  (or (rinari-test-function-name)
      (string-match "test" (or (ruby-add-log-current-method)
                               (file-name-nondirectory (buffer-file-name))))
      (rinari-find-test))
  (let* ((fn (rinari-test-function-name))
         (path (buffer-file-name))
         (ruby-options (list "-I" (expand-file-name "test" (rinari-root)) path))
         (default-command (mapconcat
                           'identity
                           (append (list path) (if fn (list "--name" (concat "/" fn "/"))))
                           " "))
         (command (if edit-cmd-args
                      (read-string "Run w/Compilation: " default-command)
                    default-command)))
    (if path (ruby-compilation-run command ruby-options)
      (message "no test available"))))

(defun rinari-test-function-name()
  "Return the name of the test function at point, or nil if not found."
  (save-excursion
    (if (re-search-backward (concat "^[ \t]*\\(def\\|test\\)[ \t]+"
                                    "\\([\"'].*?[\"']\\|" ruby-symbol-re "*\\)"
                                    "[ \t]*") nil t)
        (let ((name (match-string 2)))
          (if (string-match "^[\"']\\(.*\\)[\"']$" name)
              (replace-regexp-in-string
               "\\?" "\\\\\\\\?"
               (replace-regexp-in-string " +" "_" (match-string 1 name)))
            (if (string-match "^test" name)
              name))))))


(defun rinari-console (&optional edit-cmd-args)
  "Run a Rails console in a compilation buffer.
The buffer will support command history and links between errors
and source code.  Optional prefix argument EDIT-CMD-ARGS lets the
user edit the console command arguments."
  (interactive "P")
  (let* ((default-directory (rinari-root))
         (script (rinari-script-path))
         (command
          (expand-file-name
           (if (file-exists-p (expand-file-name "console" script))
               "console"
             "rails console")
           script)))

    ;; Start console in correct environment.
    (if rinari-rails-env
        (setq command (concat command " " rinari-rails-env)))

    ;; For customization of the console command with prefix arg.
    (setq command (if edit-cmd-args
                      (read-string "Run Ruby: " (concat command " "))
                    command))

    (run-ruby command)
    (with-current-buffer "*ruby*"
      (set (make-local-variable 'inf-ruby-prompt-pattern)
           rinari-inf-ruby-prompt-pattern)
      (set (make-local-variable 'inf-ruby-first-prompt-pattern) inf-ruby-prompt-pattern)
      (rinari-launch))))

(defun rinari-sql-buffer-name (env)
  "Return the name of the sql buffer for ENV."
  (format "*%s-sql*" env))

(defun rinari-sql ()
  "Browse the application's database.
Looks up login information from your conf/database.sql file."
  (interactive)
  (let* ((environment (or rinari-rails-env (getenv "RAILS_ENV") "development"))
         (sql-buffer (get-buffer (rinari-sql-buffer-name environment))))
    (if sql-buffer
        (pop-to-buffer sql-buffer)
      (let* ((database-alist (save-excursion
                               (with-temp-buffer
                                 (insert-file-contents
                                  (expand-file-name
                                   "database.yml"
                                   (file-name-as-directory
                                    (expand-file-name "config" (rinari-root)))))
                                 (goto-char (point-min))
                                 (re-search-forward (concat "^" environment ":"))
                                 (rinari-parse-yaml))))
             (adapter (or (cdr (assoc "adapter" database-alist)) "sqlite"))
             (sql-user (or (cdr (assoc "username" database-alist)) "root"))
             (sql-password (or (cdr (assoc "password" database-alist)) ""))
             (sql-password (if (> (length sql-password) 0) sql-password nil))
             (sql-database (or (cdr (assoc "database" database-alist))
                               (concat (file-name-nondirectory (rinari-root))
                                       "_" environment)))
             (server (or (cdr (assoc "host" database-alist)) "localhost"))
             (port (cdr (assoc "port" database-alist)))
             (sql-server (if port (concat server ":" port) server)))
        (cond ((string-match "mysql" adapter)
               (setf adapter "mysql"))
              ((string-match "sqlite" adapter)
               (setf adapter "sqlite"))
              ((string-match "postgresql" adapter)
               (setf adapter "postgres")))
        (eval (list (intern (concat "sql-" adapter))))
        (rename-buffer sql-buffer)
        (rinari-launch)))))

(defun rinari-web-server (&optional edit-cmd-args)
  "Start a Rails webserver.
Dumps output to a compilation buffer allowing jumping between
errors and source code.  Optional prefix argument EDIT-CMD-ARGS
lets the user edit the server command arguments."
  (interactive "P")
  (let* ((default-directory (rinari-root))
         (script (rinari-script-path))
         (command
          (expand-file-name
           (if (file-exists-p (expand-file-name "server" script))
               "server"
             "rails server")
           script)))

    ;; Start web server in correct environment.
    ;; NOTE: Rails 3 has a bug and does not start in any environment but development for now.
    (if rinari-rails-env
        (setq command (concat command " -e " rinari-rails-env)))

    ;; For customization of the web server command with prefix arg.
    (setq command (if edit-cmd-args
                      (read-string "Run Ruby: " (concat command " "))
                    command))

    (ruby-compilation-run command nil "server"))
  (rinari-launch))

(defun rinari-web-server-restart (&optional edit-cmd-args)
  "Ensure a fresh `rinari-web-server' is running, first killing any old one.
Optional prefix argument EDIT-CMD-ARGS lets the user edit the
server command arguments."
  (interactive "P")
  (let ((rinari-web-server-buffer "*server*"))
    (when (get-buffer rinari-web-server-buffer)
      (set-process-query-on-exit-flag (get-buffer-process rinari-web-server-buffer) nil)
      (kill-buffer rinari-web-server-buffer))
    (rinari-web-server edit-cmd-args)))

(defun rinari-insert-erb-skeleton (no-equals)
  "Insert an erb skeleton at point.
With optional prefix argument NO-EQUALS, don't include an '='."
  (interactive "P")
  (insert "<%") (if no-equals (insert "  -") (insert "=  ")) (insert "%>")
  (if no-equals (backward-char 4) (backward-char 3)))

(defun rinari-extract-partial (begin end partial-name)
  "Extracts the region from BEGIN to END into a partial called PARTIAL-NAME."
  (interactive "r\nsName your partial: ")
  (let ((path (buffer-file-name))
        (ending (rinari-ending)))
    (if (string-match "view" path)
        (let ((partial-name
               (replace-regexp-in-string "[[:space:]]+" "_" partial-name)))
          (kill-region begin end)
          (if (string-match "\\(.+\\)/\\(.+\\)" partial-name)
              (let ((default-directory (expand-file-name (match-string 1 partial-name)
                                                         (expand-file-name ".."))))
                (find-file (concat "_" (match-string 2 partial-name) ending)))
            (find-file (concat "_" partial-name ending)))
          (yank) (pop-to-buffer nil)
          (rinari-insert-partial partial-name ending))
      (message "not in a view"))))

(defun rinari-insert-partial (partial-name ending)
  "Insert a call to PARTIAL-NAME, formatted for the file's ENDING.

Supported markup languages are: Erb, Haml"
  (let ((prefix) (suffix))
    (cond
     ((string-match "\\(html\\)?\\.erb" ending)
      (setq prefix "<%= ")
      (setq suffix " %>"))
     ((string-match "\\(html\\)?\\.haml" ending)
      (setq prefix "= ")
      (setq suffix " ")))
    (insert (concat prefix "render :partial => \"" partial-name "\"" suffix "\n"))))

(defun rinari-goto-partial ()
  "Visits the partial that is called on the current line."
  (interactive)
  (let ((line (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
    (when (string-match rinari-partial-regex line)
      (setq line (match-string 2 line))
      (let ((file))
        (if (string-match "/" line)
            (setq file (concat (rinari-root) "app/views/" (replace-regexp-in-string "\\([^/]+\\)/\\([^/]+\\)$" "\\1/_\\2" line)))
          (setq file (concat default-directory "_" line)))
        (find-file (concat file (rinari-ending)))))))

(defvar rinari-rgrep-file-endings
  "*.[^l]*"
  "Ending of files to search for matches using `rinari-rgrep'.")

(defun rinari-rgrep (&optional arg)
  "Search through the rails project for a string or `regexp'.
With optional prefix argument ARG, just run `rgrep'."
  (interactive "P")
  (grep-compute-defaults)
  (if arg (call-interactively 'rgrep)
    (let ((query))
      (if mark-active
          (setq query (buffer-substring-no-properties (point) (mark)))
        (setq query (thing-at-point 'word)))
      (funcall 'rgrep (read-from-minibuffer "search for: " query)
               rinari-rgrep-file-endings (rinari-root)))))

(defun rinari-ending ()
  "Return the file extension of the current file."
  (let* ((path (buffer-file-name))
         (ending
          (and (string-match ".+?\\(\\.[^/]*\\)$" path)
               (match-string 1 path))))
    ending))

(defun rinari-script-path ()
  "Return the absolute path to the script folder."
  (concat (file-name-as-directory (expand-file-name "script" (rinari-root)))))

;;--------------------------------------------------------------------
;; rinari movement using jump.el

(defun rinari-generate (type name)
  "Run the generate command to generate a TYPE called NAME."
  (let* ((default-directory (rinari-root))
         (script (rinari-script-path))
         (command
          (expand-file-name
           (if (file-exists-p (expand-file-name "generate" script))
               "generate"
             "rails generate")
           script)))
    (message (shell-command-to-string (concat command " " type " " (read-from-minibuffer (format "create %s: " type) name))))))

(defvar rinari-ruby-hash-regexp
  "\\(:[^[:space:]]*?\\)[[:space:]]*\\(=>[[:space:]]*[\"\':]?\\([^[:space:]]*?\\)[\"\']?[[:space:]]*\\)?[,){}\n]"
  "Regexp to match subsequent key => value pairs of a ruby hash.")

(defun rinari-ruby-values-from-render (controller action)
  "Return (CONTROLLER . ACTION) after adjusting for the hash values at point."
  (let ((end (save-excursion
               (re-search-forward "[^,{(]$" nil t)
               (+ 1 (point)))))
    (save-excursion
      (while (and (< (point) end)
                  (re-search-forward rinari-ruby-hash-regexp end t))
        (if (> (length (match-string 3)) 1)
            (case (intern (match-string 1))
              (:partial
               (let ((partial (match-string 3)))
                 (if (string-match "\\(.+\\)/\\(.+\\)" partial)
                     (progn
                       (setf controller (match-string 1 partial))
                       (setf action (concat "_" (match-string 2 partial))))
                   (setf action (concat "_" partial)))))
              (:action  (setf action (match-string 3)))
              (:controller (setf controller (match-string 3)))))))
    (cons controller action)))

(defun rinari-which-render (renders)
  "Select and parse one of the RENDERS supplied."
  (let ((path (jump-completing-read
               "Follow: "
               (mapcar (lambda (lis)
                         (concat (car lis) "/" (cdr lis)))
                       renders))))
    (string-match "\\(.*\\)/\\(.*\\)" path)
    (cons (match-string 1 path) (match-string 2 path))))

(defun rinari-follow-controller-and-action (controller action)
  "Follow CONTROLLER and ACTION through to the final controller or view.
The user is prompted to follow through any intermediate renders
and redirects."
  (save-excursion ;; if we can find the controller#action pair
    (if (and (jump-to-path (format "app/controllers/%s_controller.rb#%s" controller action))
             (equalp (jump-method) action))
        (let ((start (point)) ;; demarcate the borders
              (renders (list (cons controller action))) render view)
          (ruby-forward-sexp)
          ;; collect redirection options and pursue
          (while (re-search-backward "re\\(?:direct_to\\|nder\\)" start t)
            (add-to-list 'renders (rinari-ruby-values-from-render controller action)))
          (let ((render (if (equalp 1 (length renders))
                            (car renders)
                          (rinari-which-render renders))))
            (if (and (equalp (cdr render) action)
                     (equalp (car render) controller))
                (list controller action) ;; directed to here so return
              (rinari-follow-controller-and-action (or (car render)
                                                       controller)
                                                   (or (cdr render)
                                                       action)))))
      ;; no controller entry so return
      (list controller action))))

(defvar rinari-jump-schema
 '((model
    "m"
    (("app/controllers/\\1_controller.rb#\\2$" . "app/models/\\1.rb#\\2")
     ("app/views/\\1/.*"                       . "app/models/\\1.rb")
     ("app/helpers/\\1_helper.rb"              . "app/models/\\1.rb")
     ("db/migrate/.*create_\\1.rb"             . "app/models/\\1.rb")
     ("spec/models/\\1_spec.rb"                . "app/models/\\1.rb")
     ("spec/controllers/\\1_controller_spec.rb". "app/models/\\1.rb")
     ("spec/views/\\1/.*"                      . "app/models/\\1.rb")
     ("spec/fixtures/\\1.yml"                  . "app/models/\\1.rb")
     ("test/functional/\\1_controller_test.rb" . "app/models/\\1.rb")
     ("test/unit/\\1_test.rb#test_\\2$"        . "app/models/\\1.rb#\\2")
     ("test/unit/\\1_test.rb"                  . "app/models/\\1.rb")
     ("test/fixtures/\\1.yml"                  . "app/models/\\1.rb")
     (t                                        . "app/models/"))
    (lambda (path)
      (rinari-generate "model"
                       (and (string-match ".*/\\(.+?\\)\.rb" path)
                            (match-string 1 path)))))
   (controller
    "c"
    (("app/models/\\1.rb"                      . "app/controllers/\\1_controller.rb")
     ("app/views/\\1/\\2\\..*"                 . "app/controllers/\\1_controller.rb#\\2")
     ("app/helpers/\\1_helper.rb"              . "app/controllers/\\1_controller.rb")
     ("db/migrate/.*create_\\1.rb"             . "app/controllers/\\1_controller.rb")
     ("spec/models/\\1_spec.rb"                . "app/controllers/\\1_controller.rb")
     ("spec/controllers/\\1_spec.rb"           . "app/controllers/\\1.rb")
     ("spec/views/\\1/\\2\\.*_spec.rb"         . "app/controllers/\\1_controller.rb#\\2")
     ("spec/fixtures/\\1.yml"                  . "app/controllers/\\1_controller.rb")
     ("test/functional/\\1_test.rb#test_\\2$"  . "app/controllers/\\1.rb#\\2")
     ("test/functional/\\1_test.rb"            . "app/controllers/\\1.rb")
     ("test/unit/\\1_test.rb#test_\\2$"        . "app/controllers/\\1_controller.rb#\\2")
     ("test/unit/\\1_test.rb"                  . "app/controllers/\\1_controller.rb")
     ("test/fixtures/\\1.yml"                  . "app/controllers/\\1_controller.rb")
     (t                                        . "app/controllers/"))
    (lambda (path)
      (rinari-generate "controller"
                       (and (string-match ".*/\\(.+?\\)_controller\.rb" path)
                            (match-string 1 path)))))
   (view
    "v"
    (("app/models/\\1.rb"                      . "app/views/\\1/.*")
     ((lambda () ;; find the controller/view
        (let* ((raw-file (and (buffer-file-name)
                              (file-name-nondirectory (buffer-file-name))))
               (file (and raw-file
                          (string-match "^\\(.*\\)_controller.rb" raw-file)
                          (match-string 1 raw-file))) ;; controller
               (raw-method (ruby-add-log-current-method))
               (method (and file raw-method ;; action
                            (string-match "#\\(.*\\)" raw-method)
                            (match-string 1 raw-method))))
          (if (and file method) (rinari-follow-controller-and-action file method))))
      . "app/views/\\1/\\2.*")
     ("app/controllers/\\1_controller.rb"      . "app/views/\\1/.*")
     ("app/helpers/\\1_helper.rb"              . "app/views/\\1/.*")
     ("db/migrate/.*create_\\1.rb"             . "app/views/\\1/.*")
     ("spec/models/\\1_spec.rb"                . "app/views/\\1/.*")
     ("spec/controllers/\\1_spec.rb"           . "app/views/\\1/.*")
     ("spec/views/\\1/\\2_spec.rb"             . "app/views/\\1/\\2.*")
     ("spec/fixtures/\\1.yml"                  . "app/views/\\1/.*")
     ("test/functional/\\1_controller_test.rb" . "app/views/\\1/.*")
     ("test/unit/\\1_test.rb#test_\\2$"        . "app/views/\\1/_?\\2.*")
     ("test/fixtures/\\1.yml"                  . "app/views/\\1/.*")
     (t                                        . "app/views/.*"))
    t)
   (test
    "t"
    (("app/models/\\1.rb#\\2$"                 . "test/unit/\\1_test.rb#test_\\2")
     ("app/controllers/\\1.rb#\\2$"            . "test/functional/\\1_test.rb#test_\\2")
     ("app/views/\\1/_?\\2\\..*"               . "test/functional/\\1_controller_test.rb#test_\\2")
     ("app/helpers/\\1_helper.rb"              . "test/functional/\\1_controller_test.rb")
     ("db/migrate/.*create_\\1.rb"             . "test/unit/\\1_test.rb")
     ("test/functional/\\1_controller_test.rb" . "test/unit/\\1_test.rb")
     ("test/unit/\\1_test.rb"                  . "test/functional/\\1_controller_test.rb")
     (t                                        . "test/.*"))
    t)
   (rspec
    "r"
    (("app/\\1\\.rb"                           . "spec/\\1_spec.rb")
     ("app/\\1$"                               . "spec/\\1_spec.rb")
     ("spec/views/\\1_spec.rb"                 . "app/views/\\1")
     ("spec/\\1_spec.rb"                       . "app/\\1.rb")
     (t                                        . "spec/.*"))
    t)
   (fixture
    "x"
    (("app/models/\\1.rb"                      . "test/fixtures/\\1.yml")
     ("app/controllers/\\1_controller.rb"      . "test/fixtures/\\1.yml")
     ("app/views/\\1/.*"                       . "test/fixtures/\\1.yml")
     ("app/helpers/\\1_helper.rb"              . "test/fixtures/\\1.yml")
     ("db/migrate/.*create_\\1.rb"             . "test/fixtures/\\1.yml")
     ("spec/models/\\1_spec.rb"                . "test/fixtures/\\1.yml")
     ("spec/controllers/\\1_controller_spec.rb". "test/fixtures/\\1.yml")
     ("spec/views/\\1/.*"                      . "test/fixtures/\\1.yml")
     ("test/functional/\\1_controller_test.rb" . "test/fixtures/\\1.yml")
     ("test/unit/\\1_test.rb"                  . "test/fixtures/\\1.yml")
     (t                                        . "test/fixtures/"))
    t)
   (rspec-fixture
    "z"
    (("app/models/\\1.rb"                      . "spec/fixtures/\\1.yml")
     ("app/controllers/\\1_controller.rb"      . "spec/fixtures/\\1.yml")
     ("app/views/\\1/.*"                       . "spec/fixtures/\\1.yml")
     ("app/helpers/\\1_helper.rb"              . "spec/fixtures/\\1.yml")
     ("db/migrate/.*create_\\1.rb"             . "spec/fixtures/\\1.yml")
     ("spec/models/\\1_spec.rb"                . "spec/fixtures/\\1.yml")
     ("spec/controllers/\\1_controller_spec.rb". "spec/fixtures/\\1.yml")
     ("spec/views/\\1/.*"                      . "spec/fixtures/\\1.yml")
     ("test/functional/\\1_controller_test.rb" . "spec/fixtures/\\1.yml")
     ("test/unit/\\1_test.rb"                  . "spec/fixtures/\\1.yml")
     (t                                        . "spec/fixtures/"))
    t)
   (helper
    "h"
    (("app/models/\\1.rb"                      . "app/helpers/\\1_helper.rb")
     ("app/controllers/\\1_controller.rb"      . "app/helpers/\\1_helper.rb")
     ("app/views/\\1/.*"                       . "app/helpers/\\1_helper.rb")
     ("app/helpers/\\1_helper.rb"              . "app/helpers/\\1_helper.rb")
     ("db/migrate/.*create_\\1.rb"             . "app/helpers/\\1_helper.rb")
     ("spec/models/\\1_spec.rb"                . "app/helpers/\\1_helper.rb")
     ("spec/controllers/\\1_spec.rb"           . "app/helpers/\\1_helper.rb")
     ("spec/views/\\1/.*"                      . "app/helpers/\\1_helper.rb")
     ("test/functional/\\1_controller_test.rb" . "app/helpers/\\1_helper.rb")
     ("test/unit/\\1_test.rb#test_\\2$"        . "app/helpers/\\1_helper.rb#\\2")
     ("test/unit/\\1_test.rb"                  . "app/helpers/\\1_helper.rb")
     (t                                        . "app/helpers/"))
    t)
   (migration
    "i"
    (("app/controllers/\\1_controller.rb"      . "db/migrate/.*create_\\1.rb")
     ("app/views/\\1/.*"                       . "db/migrate/.*create_\\1.rb")
     ("app/helpers/\\1_helper.rb"              . "db/migrate/.*create_\\1.rb")
     ("app/models/\\1.rb"                      . "db/migrate/.*create_\\1.rb")
     ("spec/models/\\1_spec.rb"                . "db/migrate/.*create_\\1.rb")
     ("spec/controllers/\\1_spec.rb"           . "db/migrate/.*create_\\1.rb")
     ("spec/views/\\1/.*"                      . "db/migrate/.*create_\\1.rb")
     ("test/functional/\\1_controller_test.rb" . "db/migrate/.*create_\\1.rb")
     ("test/unit/\\1_test.rb#test_\\2$"        . "db/migrate/.*create_\\1.rb#\\2")
     ("test/unit/\\1_test.rb"                  . "db/migrate/.*create_\\1.rb")
     (t                                        . "db/migrate/"))
    (lambda (path)
      (rinari-generate "migration"
                       (and (string-match ".*create_\\(.+?\\)\.rb" path)
                            (match-string 1 path)))))
   (cells
    "C"
    (("app/cells/\\1_cell.rb"                  . "app/cells/\\1/.*")
     ("app/cells/\\1/\\2.*"                    . "app/cells/\\1_cell.rb#\\2")
     (t                                        . "app/cells/"))
    (lambda (path)
      (rinari-generate "cells"
                       (and (string-match ".*/\\(.+?\\)_cell\.rb" path)
                            (match-string 1 path)))))
   (features "F" ((t . "features/.*feature")) nil)
   (steps "S" ((t . "features/step_definitions/.*")) nil)
   (environment "e" ((t . "config/environments/")) nil)
   (application "a" ((t . "config/application.rb")) nil)
   (configuration "n" ((t . "config/")) nil)
   (script "s" ((t . "script/")) nil)
   (lib "l" ((t . "lib/")) nil)
   (log "o" ((t . "log/")) nil)
   (worker "w" ((t . "lib/workers/")) nil)
   (public "p" ((t . "public/")) nil)
   (stylesheet "y" ((t . "public/stylesheets/.*")
                    (t . "app/assets/stylesheets/.*")) nil)
   (sass "Y" ((t . "public/stylesheets/sass/.*")
              (t . "app/stylesheets/.*")) nil)
   (javascript "j" ((t . "public/javascripts/.*")
                    (t . "app/assets/javascripts/.*")) nil)
   (plugin "u" ((t . "vendor/plugins/")) nil)
   (mailer "M" ((t . "app/mailers/")) nil)
   (file-in-project "f" ((t . ".*")) nil)
   (by-context
    ";"
    (((lambda () ;; Find-by-Context
        (let ((path (buffer-file-name))
              cv)
          (when (string-match ".*/\\(.+?\\)/\\(.+?\\)\\..*" path)
            (setf cv (cons (match-string 1 path) (match-string 2 path)))
            (when (re-search-forward "<%=[ \n\r]*render(? *" nil t)
              (setf cv (rinari-ruby-values-from-render (car cv) (cdr cv)))
              (list (car cv) (cdr cv))))))
      . "app/views/\\1/\\2.*"))))
 "Jump schema for rinari.")

(defun rinari-apply-jump-schema (schema)
  "Define the rinari-find-* functions by passing each element SCHEMA to `defjump'."
  (mapcar
   (lambda (type)
     (let ((name (first type))
           (specs (third type))
           (make (fourth type)))
       (eval `(defjump
                ,(intern (format "rinari-find-%S" name))
                ,specs
                rinari-root
                ,(format "Go to the most logical %S given the current location" name)
                ,(if make `(quote ,make))
                'ruby-add-log-current-method))))
   schema))
(rinari-apply-jump-schema rinari-jump-schema)

;;--------------------------------------------------------------------
;; minor mode and keymaps

(defvar rinari-minor-mode-map
  (let ((map (make-sparse-keymap)))
    map)
  "Key map for Rinari minor mode.")

(defun rinari-bind-key-to-func (key func)
  "Bind KEY to FUNC with each of the `rinari-minor-mode-prefixes'."
  (dolist (prefix rinari-minor-mode-prefixes)
    (eval `(define-key rinari-minor-mode-map
             ,(format "\C-c%s%s" prefix key) ,func))))

(defvar rinari-minor-mode-keybindings
  '(("s" . 'rinari-script)              ("q" . 'rinari-sql)
    ("e" . 'rinari-insert-erb-skeleton) ("t" . 'rinari-test)
    ("r" . 'rinari-rake)                ("c" . 'rinari-console)
    ("w" . 'rinari-web-server)          ("g" . 'rinari-rgrep)
    ("x" . 'rinari-extract-partial)     ("p" . 'rinari-goto-partial)
    (";" . 'rinari-find-by-context)     ("'" . 'rinari-find-by-context)
    ("d" . 'rinari-cap))
  "Alist mapping of keys to functions in `rinari-minor-mode-map'.")

(dolist (el (append (mapcar (lambda (el)
                              (cons (concat "f" (second el))
                                    (read (format "'rinari-find-%S" (first el)))))
                            rinari-jump-schema)
                    rinari-minor-mode-keybindings))
  (rinari-bind-key-to-func (car el) (cdr el)))

;;;###autoload
(defun rinari-launch ()
  "Call function `rinari-minor-mode' if inside a rails project.
Otherwise, disable that minor mode if currently enabled."
  (interactive)
  (let* ((root (rinari-root)) (r-tags-path (concat root rinari-tags-file-name)))
    (if root (progn
               (set (make-local-variable 'tags-file-name)
                    (and (file-exists-p r-tags-path) r-tags-path))
               (run-hooks 'rinari-minor-mode-hook)
               (rinari-minor-mode t))
      (if (and (fboundp 'rinari-minor-mode) rinari-minor-mode) (rinari-minor-mode)))))

;;;###autoload
(defvar rinari-major-modes
  (if (boundp 'rinari-major-modes)
      rinari-major-modes
    (list 'find-file-hook 'mumamo-after-change-major-mode-hook 'dired-mode-hook))
  "Major Modes from which to launch Rinari.")

;;;###autoload
(dolist (hook rinari-major-modes) (add-hook hook 'rinari-launch))

(defadvice cd (after rinari-on-cd activate)
  "Call `rinari-launch' when changing directories.
This will activate/deactivate rinari as necessary when changing
into and out of rails project directories."
  (rinari-launch))

;;;###autoload
(define-minor-mode rinari-minor-mode
  "Enable Rinari minor mode to support working with the Ruby on Rails framework."
  nil
  " Rinari"
  rinari-minor-mode-map)

(provide 'rinari)

;; Local Variables:
;; coding: utf-8
;; byte-compile-warnings: (not cl-functions)
;; eval: (checkdoc-minor-mode 1)
;; End:

;;; rinari.el ends here
