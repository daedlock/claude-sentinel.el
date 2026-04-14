;;; claude-sentinel.el --- Monitor Claude Code CLI instances in vterm -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Contributors
;;
;; Author: Hossam Saraya
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (vterm "0.0.1"))
;; Keywords: tools convenience
;; URL: https://github.com/daedlock/claude-sentinel

;;; Commentary:
;;
;; claude-sentinel monitors Claude Code CLI instances running in vterm
;; buffers across Emacs workspaces.  It detects state changes by hooking
;; into vterm's title mechanism (OSC sequences sent by the Claude CLI),
;; maintains a registry of live instances, and exposes a hook that
;; consumers (modeline, dashboard, notifications) can subscribe to.
;;
;; Usage:
;;   (claude-sentinel-mode 1)
;;
;; Detected states:
;;   working  — Claude is actively processing (⠂/⠐ title prefix)
;;   waiting  — Claude is at the input prompt (✳ title prefix)
;;   shell    — No Claude session (empty title or shell prompt)
;;   dead     — The vterm buffer has been killed

;;; Code:

(require 'cl-lib)

;;; Customisation

(defgroup claude-sentinel nil
  "Monitor Claude Code CLI instances across Emacs workspaces."
  :group 'tools
  :prefix "claude-sentinel-")

(defcustom claude-sentinel-buffer-regexp "\\`claude\\["
  "Regexp matching buffer names that are Claude Code vterm instances."
  :type 'regexp
  :group 'claude-sentinel)

(defcustom claude-sentinel-working-prefixes '("⠂" "⠐")
  "Title prefixes emitted by Claude CLI while actively processing."
  :type '(repeat string)
  :group 'claude-sentinel)

(defcustom claude-sentinel-waiting-prefix "✳"
  "Title prefix emitted by Claude CLI when waiting for user input."
  :type 'string
  :group 'claude-sentinel)

(defcustom claude-sentinel-state-change-functions nil
  "Abnormal hook run when a Claude instance changes state.
Each function receives (INSTANCE OLD-STATE NEW-STATE) where states
are symbols: `working', `waiting', `shell', `dead'."
  :type 'hook
  :group 'claude-sentinel)

;;; Instance struct

(cl-defstruct (claude-sentinel-instance
               (:constructor claude-sentinel--make-instance)
               (:copier nil))
  "Represents a single Claude Code CLI session in a vterm buffer."
  buffer            ; the live vterm buffer
  project           ; project name string (derived from buffer name)
  workspace         ; persp/workspace name string or nil
  state             ; symbol: working | waiting | shell | dead
  state-changed-at  ; float-time of last state transition
  title             ; most recent raw terminal title string
  summary)          ; short description from last user prompt

;;; Registry

(defvar claude-sentinel--instances (make-hash-table :test 'eq)
  "Hash table: buffer object → `claude-sentinel-instance'.")

;;; State machine

(defun claude-sentinel--classify-title (title)
  "Return state symbol for TITLE string.
Returns `working', `waiting', or `shell'."
  (cond
   ((cl-some (lambda (p) (string-prefix-p p title))
             claude-sentinel-working-prefixes)
    'working)
   ((string-prefix-p claude-sentinel-waiting-prefix title)
    'waiting)
   (t 'shell)))

(defun claude-sentinel--project-name (buffer)
  "Derive a human-readable project name from BUFFER's name."
  (let ((name (buffer-name buffer)))
    (if (string-match "\\`claude\\[\\(.*?\\)\\]\\(?:<[0-9]+>\\)?\\'" name)
        (match-string 1 name)
      name)))

(defun claude-sentinel--buffer-workspace (buffer)
  "Return the workspace name that BUFFER belongs to, or nil.
Searches all live perspectives for one that contains BUFFER."
  (when (and (featurep 'persp-mode) (bound-and-true-p persp-mode))
    (cl-some (lambda (persp)
               (when (persp-contain-buffer-p buffer persp)
                 (safe-persp-name persp)))
             (persp-persps))))

(defun claude-sentinel--transition (instance new-state)
  "Move INSTANCE to NEW-STATE and run `claude-sentinel-state-change-functions'."
  (let ((old-state (claude-sentinel-instance-state instance)))
    (unless (eq old-state new-state)
      ;; Update summary when Claude starts working (user just sent a message)
      (when (and (eq new-state 'working)
                 (memq old-state '(waiting shell)))
        (claude-sentinel--update-summary instance))
      (setf (claude-sentinel-instance-state instance) new-state
            (claude-sentinel-instance-state-changed-at instance) (float-time))
      (run-hook-with-args 'claude-sentinel-state-change-functions
                          instance old-state new-state))))

;;; Summary via LLM

(defcustom claude-sentinel-summary-model "google/gemini-2.0-flash-lite-001"
  "OpenRouter model ID used for generating session summaries."
  :type 'string
  :group 'claude-sentinel)

(defcustom claude-sentinel-summary-api-key-env "OPENROUTER_API_KEY"
  "Environment variable holding the OpenRouter API key."
  :type 'string
  :group 'claude-sentinel)

(defun claude-sentinel--extract-conversation (buffer)
  "Extract conversation from BUFFER for summarization.
Takes a sample from the beginning and end for full context."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((total (- (point-max) (point-min)))
             (head (buffer-substring-no-properties
                    (point-min)
                    (min (+ (point-min) 3000) (point-max))))
             (tail (if (> total 6000)
                       (buffer-substring-no-properties
                        (max (- (point-max) 3000) (point-min))
                        (point-max))
                     "")))
        (string-trim (concat head "\n...\n" tail))))))

(defun claude-sentinel--request-summary (instance)
  "Asynchronously request a short session title from LLM for INSTANCE."
  (let* ((api-key (getenv claude-sentinel-summary-api-key-env))
         (buffer  (claude-sentinel-instance-buffer instance))
         (text    (claude-sentinel--extract-conversation buffer)))
    (when (and api-key text (> (length text) 20))
      (let* ((escaped-text (replace-regexp-in-string
                            "[\"\\\\]" "\\\\\\&"
                            (replace-regexp-in-string
                             "\n" "\\\\n"
                             (truncate-string-to-width text 4000))))
             (json (format "{\"model\":\"%s\",\"max_tokens\":40,\"messages\":[{\"role\":\"user\",\"content\":\"Summarize what this coding session is about in a short descriptive title (5-10 words). Return ONLY the title, nothing else.\\n\\n%s\"}]}"
                           claude-sentinel-summary-model escaped-text))
             (proc (start-process
                    "claude-sentinel-summary" nil
                    "curl" "-s"
                    "https://openrouter.ai/api/v1/chat/completions"
                    "-H" "Content-Type: application/json"
                    "-H" (format "Authorization: Bearer %s" api-key)
                    "-d" json)))
        (let ((output ""))
          (set-process-filter proc
                              (lambda (_p chunk) (setq output (concat output chunk))))
          (set-process-sentinel
           proc
           (lambda (_p event)
             (when (string-match-p "finished" event)
               (when-let* ((content (claude-sentinel--parse-summary-response output)))
                 (setf (claude-sentinel-instance-summary instance) content)
                 ;; Refresh dashboard and headerline
                 (run-hook-with-args 'claude-sentinel-state-change-functions
                                     instance nil nil))))))))))

(defun claude-sentinel--parse-summary-response (json-str)
  "Extract the summary text from the OpenRouter JSON response."
  (when (string-match "\"content\"[[:space:]]*:[[:space:]]*\"\\([^\"]+\\)\"" json-str)
    (let ((summary (match-string 1 json-str)))
      (when (and summary (> (length summary) 0) (< (length summary) 100))
        (string-trim summary)))))

(defun claude-sentinel--update-summary (instance)
  "Request an LLM-generated summary for INSTANCE asynchronously."
  (claude-sentinel--request-summary instance))

;;; vterm hook

(defun claude-sentinel--on-title-change (title)
  "Process vterm title change.  Installed as advice after `vterm--set-title'."
  (let ((buffer (current-buffer)))
    (when (string-match-p claude-sentinel-buffer-regexp (buffer-name buffer))
      (let ((instance (or (gethash buffer claude-sentinel--instances)
                          (claude-sentinel--register buffer))))
        (setf (claude-sentinel-instance-title instance) title)
        (claude-sentinel--transition instance
                                     (claude-sentinel--classify-title title))))))

(defun claude-sentinel--register (buffer)
  "Create and register a new instance for BUFFER."
  (let ((instance (claude-sentinel--make-instance
                   :buffer buffer
                   :project (claude-sentinel--project-name buffer)
                   :workspace (claude-sentinel--buffer-workspace buffer)
                   :state 'shell
                   :state-changed-at (float-time)
                   :title nil)))
    (puthash buffer instance claude-sentinel--instances)
    (with-current-buffer buffer
      ;; Headerline hook must run before sentinel cleanup (last added = first run)
      (add-hook 'kill-buffer-hook #'claude-sentinel--on-kill-buffer nil t)
      (add-hook 'kill-buffer-hook #'claude-sentinel-headerline--on-kill nil t)
      )
    instance))

(defun claude-sentinel--on-kill-buffer ()
  "Transition instance to `dead' and remove it when its buffer is killed."
  (let ((instance (gethash (current-buffer) claude-sentinel--instances)))
    (when instance
      (claude-sentinel--transition instance 'dead)
      (remhash (current-buffer) claude-sentinel--instances))))

;;; Garbage collection

(defvar claude-sentinel--gc-timer nil
  "Periodic timer that removes stale entries from the instance registry.")

(defun claude-sentinel--gc ()
  "Purge entries whose buffers are no longer live."
  (maphash (lambda (buf _)
             (unless (buffer-live-p buf)
               (remhash buf claude-sentinel--instances)))
           claude-sentinel--instances))

;;; Public API

(defun claude-sentinel-instances ()
  "Return a list of all tracked `claude-sentinel-instance' structs."
  (let (acc)
    (maphash (lambda (_ inst) (push inst acc))
             claude-sentinel--instances)
    acc))

(defun claude-sentinel-total-count ()
  "Return total number of tracked Claude instances."
  (hash-table-count claude-sentinel--instances))

(defun claude-sentinel-working-count ()
  "Return number of instances currently in the `working' state."
  (cl-count 'working (claude-sentinel-instances)
            :key #'claude-sentinel-instance-state))

(defun claude-sentinel-waiting-count ()
  "Return number of instances currently in the `waiting' state."
  (cl-count 'waiting (claude-sentinel-instances)
            :key #'claude-sentinel-instance-state))

(defun claude-sentinel-siblings (buffer)
  "Return all live Claude buffers sharing the same project as BUFFER.
Scans all buffers matching `claude-sentinel-buffer-regexp', not just
the registry, so newly created buffers appear immediately."
  (let ((base (claude-sentinel--project-name buffer)))
    (seq-filter (lambda (b)
                  (and (buffer-live-p b)
                       (string-match-p claude-sentinel-buffer-regexp
                                       (buffer-name b))
                       (string-equal base (claude-sentinel--project-name b))))
                (buffer-list))))

;;; Global minor mode

;;;###autoload
(define-minor-mode claude-sentinel-mode
  "Monitor Claude Code CLI instances running in vterm buffers.
When enabled, hooks into vterm's title mechanism to track state
across all buffers matching `claude-sentinel-buffer-regexp'."
  :global t
  :group 'claude-sentinel
  :lighter nil
  (if claude-sentinel-mode
      (progn
        (advice-add 'vterm--set-title :after #'claude-sentinel--on-title-change)
        (setq claude-sentinel--gc-timer
              (run-with-timer 30 30 #'claude-sentinel--gc)))
    (advice-remove 'vterm--set-title #'claude-sentinel--on-title-change)
    (when (timerp claude-sentinel--gc-timer)
      (cancel-timer claude-sentinel--gc-timer)
      (setq claude-sentinel--gc-timer nil))
    (clrhash claude-sentinel--instances)))

(provide 'claude-sentinel)
;;; claude-sentinel.el ends here
