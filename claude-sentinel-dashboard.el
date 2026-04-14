;;; claude-sentinel-dashboard.el --- Tree dashboard for claude-sentinel -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Contributors
;;
;; Package-Requires: ((emacs "28.1") (claude-sentinel "0.1.0"))
;; Keywords: tools convenience
;; URL: https://github.com/daedlock/claude-sentinel

;;; Commentary:
;;
;; Provides a tree-structured dashboard buffer grouping Claude Code CLI
;; instances by workspace.  Each workspace is a collapsible root node;
;; instances appear as indented children with project name and duration.
;;
;; Keybindings:
;;   RET / TAB   Toggle workspace fold, or jump to instance
;;   g           Refresh
;;   q           Quit

;;; Code:

(require 'claude-sentinel)

;;; Faces

(defface claude-sentinel-workspace
  '((t :inherit (bold default)))
  "Face for workspace root nodes in the dashboard."
  :group 'claude-sentinel)

(defface claude-sentinel-working
  '((t :inherit warning))
  "Face for instances in the `working' state."
  :group 'claude-sentinel)

(defface claude-sentinel-waiting
  '((t :inherit success))
  "Face for instances in the `waiting' state."
  :group 'claude-sentinel)

(defface claude-sentinel-shell
  '((t :inherit shadow))
  "Face for instances in the `shell' state."
  :group 'claude-sentinel)

(defface claude-sentinel-dead
  '((t :inherit error))
  "Face for instances in the `dead' state."
  :group 'claude-sentinel)

;;; Buffer-local state

(defvar-local claude-sentinel-dashboard--collapsed nil
  "List of workspace names currently folded.")

;;; Helpers

(defvar claude-sentinel-dashboard--spinner-frames '("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  "Braille spinner frames for working instances.")

(defvar claude-sentinel-dashboard--spinner-index 0
  "Current spinner frame index.")

(defun claude-sentinel-dashboard--state-icon (state)
  "Return a propertized status icon for STATE."
  (pcase state
    ('working (propertize
               (nth (mod claude-sentinel-dashboard--spinner-index
                        (length claude-sentinel-dashboard--spinner-frames))
                    claude-sentinel-dashboard--spinner-frames)
               'face 'claude-sentinel-working))
    ('waiting (propertize "✳" 'face 'claude-sentinel-waiting))
    ('shell   (propertize "·" 'face 'claude-sentinel-shell))
    ('dead    (propertize "✗" 'face 'claude-sentinel-dead))
    (_        (propertize "?" 'face 'shadow))))

(defun claude-sentinel-dashboard--duration (since)
  "Return a human-readable elapsed-time string since float-time SINCE."
  (let ((secs (max 0 (round (- (float-time) since)))))
    (cond
     ((< secs 60)   (format "%ds"     secs))
     ((< secs 3600) (format "%dm %ds" (/ secs 60) (% secs 60)))
     (t             (format "%dh %dm" (/ secs 3600) (/ (% secs 3600) 60))))))

(defun claude-sentinel-dashboard--grouped ()
  "Return instances as an alist of (workspace-name . instances), sorted.
Also includes unregistered claude buffers as synthetic shell instances."
  (let ((table (make-hash-table :test 'equal))
        (seen  (make-hash-table :test 'eq)))
    ;; Registered instances
    (dolist (inst (claude-sentinel-instances))
      (let* ((buf (claude-sentinel-instance-buffer inst))
             (ws (or (claude-sentinel--buffer-workspace buf) "—")))
        (puthash buf t seen)
        (puthash ws (cons inst (gethash ws table)) table)))
    ;; Unregistered claude buffers (newly created, no title yet)
    (dolist (buf (buffer-list))
      (when (and (buffer-live-p buf)
                 (string-match-p claude-sentinel-buffer-regexp (buffer-name buf))
                 (not (gethash buf seen)))
        (let* ((ws (or (claude-sentinel--buffer-workspace buf) "—"))
               (inst (claude-sentinel--make-instance
                      :buffer buf
                      :project (claude-sentinel--project-name buf)
                      :workspace ws
                      :state 'shell
                      :state-changed-at (float-time)
                      :title nil)))
          (puthash ws (cons inst (gethash ws table)) table))))
    (let (groups)
      (maphash (lambda (ws instances)
                 (push (cons ws (nreverse instances)) groups))
               table)
      (sort groups (lambda (a b) (string< (car a) (car b)))))))

;;; Renderer

(defun claude-sentinel-dashboard--render ()
  "Redraw the tree into the current buffer."
  (let ((inhibit-read-only t)
        (saved-line (line-number-at-pos))
        (groups (claude-sentinel-dashboard--grouped)))
    (erase-buffer)
    (if (null groups)
        (insert (propertize "  No Claude instances detected.\n" 'face 'shadow))
      (dolist (group groups)
        (let* ((ws        (car group))
               (instances (cdr group))
               (collapsed (member ws claude-sentinel-dashboard--collapsed))
               (fold-icon (if collapsed "▶ " "▼ ")))
          ;; Workspace header line
          (insert
           (propertize
            (concat fold-icon ws
                    (propertize (format "  (%d)" (length instances)) 'face 'shadow)
                    "\n")
            'face                    'claude-sentinel-workspace
            'claude-sentinel-workspace ws
            'help-echo               "RET/TAB: toggle fold"))
          ;; Instance lines (hidden when collapsed)
          (unless collapsed
            (cl-loop for inst in instances for idx from 1 do
              (let* ((buf     (claude-sentinel-instance-buffer inst))
                     (name    (if (buffer-live-p buf) (buffer-name buf) "dead"))
                     (summary (claude-sentinel-instance-summary inst))
                     (label   (format "%d. %s" idx
                                      (or summary
                                          (claude-sentinel-instance-project inst)))))
                (insert
                 (propertize
                  (format "    %s  %-30s  %s\n"
                          (claude-sentinel-dashboard--state-icon
                           (claude-sentinel-instance-state inst))
                          label
                          (propertize
                           (claude-sentinel-dashboard--duration
                            (claude-sentinel-instance-state-changed-at inst))
                           'face 'shadow))
                  'claude-sentinel-instance inst
                  'help-echo (format "RET: jump to %s" name)))))))))
    ;; Restore approximate position
    (goto-char (point-min))
    (forward-line (1- (max 1 saved-line)))))

;;; Auto-refresh

(defun claude-sentinel-dashboard--on-state-change (&rest _)
  "Refresh the dashboard if it is currently visible.  Advances spinner."
  (cl-incf claude-sentinel-dashboard--spinner-index)
  (when-let* ((buf (get-buffer "*Claude Sentinel*"))
              ((get-buffer-window buf t)))
    (with-current-buffer buf
      (claude-sentinel-dashboard--render))))

;;; Point helpers

(defun claude-sentinel-dashboard--instance-at-point ()
  "Return the instance at the current line, or nil."
  (get-text-property (line-beginning-position) 'claude-sentinel-instance))

(defun claude-sentinel-dashboard--workspace-at-point ()
  "Return the workspace name at the current line, or nil."
  (get-text-property (line-beginning-position) 'claude-sentinel-workspace))

;;; Commands

(defun claude-sentinel-dashboard-toggle-fold ()
  "Toggle the collapsed state of the workspace at point."
  (interactive)
  (when-let ((ws (claude-sentinel-dashboard--workspace-at-point)))
    (setq claude-sentinel-dashboard--collapsed
          (if (member ws claude-sentinel-dashboard--collapsed)
              (delete ws claude-sentinel-dashboard--collapsed)
            (cons ws claude-sentinel-dashboard--collapsed)))
    (claude-sentinel-dashboard--render)))

(defcustom claude-sentinel-dashboard-display-function
  #'claude-sentinel-dashboard--default-display
  "Function to display a Claude buffer when selected from the dashboard.
Called with one argument: the buffer to display."
  :type 'function
  :group 'claude-sentinel)

(defun claude-sentinel-dashboard--default-display (buffer)
  "Display BUFFER in a right side window."
  (let ((win (display-buffer-in-side-window
              buffer
              `((side . right)
                (slot . 0)
                (window-width . ,(round (* (frame-width) 0.4)))))))
    (select-window win)
    (set-window-dedicated-p win t)))

(defun claude-sentinel-dashboard-goto ()
  "Jump to the instance at point, or toggle fold if on a workspace header."
  (interactive)
  (cond
   ((claude-sentinel-dashboard--workspace-at-point)
    (claude-sentinel-dashboard-toggle-fold))
   ((claude-sentinel-dashboard--instance-at-point)
    (let* ((instance (claude-sentinel-dashboard--instance-at-point))
           (buffer   (claude-sentinel-instance-buffer instance)))
      (unless (buffer-live-p buffer)
        (user-error "Claude buffer no longer exists"))
      (when-let ((ws (claude-sentinel--buffer-workspace buffer)))
        (when (fboundp '+workspace-switch)
          (+workspace-switch ws)))
      (if-let ((win (get-buffer-window buffer t)))
          (select-window win)
        (funcall claude-sentinel-dashboard-display-function buffer))))
   (t
    (user-error "No instance or workspace at point"))))

(defun claude-sentinel-dashboard-kill ()
  "Kill the Claude instance at point."
  (interactive)
  (let ((inst (claude-sentinel-dashboard--instance-at-point)))
    (unless inst
      (user-error "No instance at point"))
    (let ((buf (claude-sentinel-instance-buffer inst)))
      (unless (buffer-live-p buf)
        (user-error "Buffer already dead"))
      (when (yes-or-no-p (format "Kill %s?" (buffer-name buf)))
        (kill-buffer buf)
        (claude-sentinel-dashboard--render)))))

(defun claude-sentinel-dashboard-refresh ()
  "Manually refresh the dashboard."
  (interactive)
  (claude-sentinel-dashboard--render))

;;; Mode

(defvar-keymap claude-sentinel-dashboard-mode-map
  :doc "Keymap for `claude-sentinel-dashboard-mode'."
  "RET" #'claude-sentinel-dashboard-goto
  "TAB" #'claude-sentinel-dashboard-toggle-fold
  "g"   #'claude-sentinel-dashboard-refresh
  "d"   #'claude-sentinel-dashboard-kill
  "q"   #'quit-window)

(with-eval-after-load 'evil
  (evil-define-key 'normal claude-sentinel-dashboard-mode-map
    (kbd "RET") #'claude-sentinel-dashboard-goto
    (kbd "TAB") #'claude-sentinel-dashboard-toggle-fold
    (kbd "g")   #'claude-sentinel-dashboard-refresh
    (kbd "d")   #'claude-sentinel-dashboard-kill
    (kbd "q")   #'quit-window))

(define-derived-mode claude-sentinel-dashboard-mode special-mode
  "Claude Sentinel"
  "Tree dashboard for Claude Code CLI instances grouped by workspace.

\\{claude-sentinel-dashboard-mode-map}"
  :interactive nil
  (setq-local truncate-lines t
              cursor-type    'box
              revert-buffer-function
              (lambda (&rest _) (claude-sentinel-dashboard--render))))

;;; Minor mode

;;;###autoload
(define-minor-mode claude-sentinel-dashboard-mode-global
  "Auto-refresh the Claude Sentinel dashboard on state changes."
  :global t
  :group 'claude-sentinel
  :lighter nil
  (if claude-sentinel-dashboard-mode-global
      (add-hook 'claude-sentinel-state-change-functions
                #'claude-sentinel-dashboard--on-state-change)
    (remove-hook 'claude-sentinel-state-change-functions
                 #'claude-sentinel-dashboard--on-state-change)))

;;; Entry point

;;;###autoload
(defun claude-sentinel-dashboard ()
  "Open or switch to the *Claude Sentinel* dashboard."
  (interactive)
  ;; Ensure auto-refresh is active
  (claude-sentinel-dashboard-mode-global 1)
  (let ((buf (get-buffer-create "*Claude Sentinel*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'claude-sentinel-dashboard-mode)
        (claude-sentinel-dashboard-mode))
      (claude-sentinel-dashboard--render)
      (goto-char (point-min))
      (forward-line 1))
    (pop-to-buffer buf)))

(provide 'claude-sentinel-dashboard)
;;; claude-sentinel-dashboard.el ends here
