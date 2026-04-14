;;; claude-sentinel-notify.el --- Desktop notifications for claude-sentinel -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Contributors
;;
;; Package-Requires: ((emacs "28.1") (claude-sentinel "0.1.0"))
;; Keywords: tools convenience
;; URL: https://github.com/daedlock/claude-sentinel

;;; Commentary:
;;
;; Provides desktop notifications when Claude instances change state.
;; Uses `notifications-notify' (D-Bus) when available, falls back to
;; `notify-send', and finally falls back to `message'.
;;
;; Notifications for the `waiting' state are debounced: Claude briefly
;; enters `waiting' between tool calls, so we only fire after the state
;; has been sustained for `claude-sentinel-notify-debounce-seconds'.
;;
;; Usage:
;;   (claude-sentinel-notify-mode 1)

;;; Code:

(require 'claude-sentinel)

;;; Customisation

(defgroup claude-sentinel-notify nil
  "Desktop notification settings for claude-sentinel."
  :group 'claude-sentinel
  :prefix "claude-sentinel-notify-")

(defcustom claude-sentinel-notify-on-waiting t
  "Send a desktop notification when Claude finishes and awaits input."
  :type 'boolean
  :group 'claude-sentinel-notify)

(defcustom claude-sentinel-notify-on-dead t
  "Send a desktop notification when a Claude process exits unexpectedly."
  :type 'boolean
  :group 'claude-sentinel-notify)

(defcustom claude-sentinel-notify-when-focused nil
  "When non-nil, send notifications even if the Claude buffer is visible.
When nil (default), suppress notifications while the buffer is displayed
in any window on any frame."
  :type 'boolean
  :group 'claude-sentinel-notify)

(defcustom claude-sentinel-notify-debounce-seconds 3
  "Seconds to wait before treating `waiting' state as genuine.
Claude briefly enters `waiting' between tool calls; this debounce
prevents false notifications during multi-step operations."
  :type 'number
  :group 'claude-sentinel-notify)

(defcustom claude-sentinel-notify-function #'claude-sentinel-notify--dispatch
  "Function used to deliver a notification.
Called with two string arguments: TITLE and BODY."
  :type 'function
  :group 'claude-sentinel-notify)

;;; Delivery backends

(defun claude-sentinel-notify--dispatch (title body)
  "Deliver a desktop notification with TITLE and BODY.
Tries `notifications-notify' (D-Bus), then `notify-send', then `message'."
  (cond
   ((and (featurep 'dbus) (fboundp 'notifications-notify))
    (notifications-notify
     :app-name "Claude Sentinel"
     :title    title
     :body     body
     :urgency  'normal))
   ((executable-find "notify-send")
    (start-process "claude-sentinel-notify" nil
                   "notify-send" "-a" "Claude Sentinel" title body))
   (t
    (message "[Claude Sentinel] %s — %s" title body))))

;;; Debounce timers — one per buffer

(defvar claude-sentinel-notify--timers (make-hash-table :test 'eq)
  "Hash table: buffer → debounce timer for waiting notifications.")

(defun claude-sentinel-notify--cancel-timer (buffer)
  "Cancel any pending waiting notification timer for BUFFER."
  (when-let ((timer (gethash buffer claude-sentinel-notify--timers)))
    (cancel-timer timer)
    (remhash buffer claude-sentinel-notify--timers)))

(defun claude-sentinel-notify--fire-waiting (buffer)
  "Fire the waiting notification for BUFFER if it's still in `waiting' state."
  (remhash buffer claude-sentinel-notify--timers)
  (when-let ((instance (gethash buffer claude-sentinel--instances)))
    (when (eq (claude-sentinel-instance-state instance) 'waiting)
      (let* ((project (claude-sentinel-instance-project instance))
             (ws      (claude-sentinel--buffer-workspace buffer))
             (context (if ws (format "%s (%s)" ws project) project))
             (visible (get-buffer-window buffer t)))
        (when (or claude-sentinel-notify-when-focused (not visible))
          (funcall claude-sentinel-notify-function
                   context
                   "Claude is waiting for your input"))))))

;;; State change handler

(defun claude-sentinel-notify--on-state-change (instance old-state new-state)
  "Handle a state transition for INSTANCE from OLD-STATE to NEW-STATE."
  (when old-state ; skip synthetic initial registration
    (let ((buffer (claude-sentinel-instance-buffer instance)))
      (cond
       ;; working→waiting: start debounce timer
       ((and claude-sentinel-notify-on-waiting
             (eq old-state 'working)
             (eq new-state 'waiting))
        (claude-sentinel-notify--cancel-timer buffer)
        (puthash buffer
                 (run-with-timer claude-sentinel-notify-debounce-seconds nil
                                 #'claude-sentinel-notify--fire-waiting buffer)
                 claude-sentinel-notify--timers))
       ;; waiting→working: cancel pending notification (was a brief pause)
       ((and (eq old-state 'waiting)
             (eq new-state 'working))
        (claude-sentinel-notify--cancel-timer buffer))
       ;; dead: notify immediately, cancel any pending timer
       ((and claude-sentinel-notify-on-dead
             (eq new-state 'dead)
             (memq old-state '(working waiting)))
        (claude-sentinel-notify--cancel-timer buffer)
        (let* ((project (claude-sentinel-instance-project instance))
               (ws      (claude-sentinel--buffer-workspace buffer))
               (context (if ws (format "%s (%s)" ws project) project))
               (visible (get-buffer-window buffer t)))
          (when (or claude-sentinel-notify-when-focused (not visible))
            (funcall claude-sentinel-notify-function
                     context
                     "Claude process has exited"))))))))

;;; Minor mode

;;;###autoload
(define-minor-mode claude-sentinel-notify-mode
  "Send desktop notifications on Claude Code instance state changes."
  :global t
  :group 'claude-sentinel-notify
  :lighter nil
  (if claude-sentinel-notify-mode
      (add-hook 'claude-sentinel-state-change-functions
                #'claude-sentinel-notify--on-state-change)
    (remove-hook 'claude-sentinel-state-change-functions
                 #'claude-sentinel-notify--on-state-change)
    ;; Cancel all pending timers
    (maphash (lambda (_ timer) (cancel-timer timer))
             claude-sentinel-notify--timers)
    (clrhash claude-sentinel-notify--timers)))

(provide 'claude-sentinel-notify)
;;; claude-sentinel-notify.el ends here
