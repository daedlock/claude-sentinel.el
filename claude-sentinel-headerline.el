;;; claude-sentinel-headerline.el --- Tabbed header-line for claude-sentinel -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Contributors
;;
;; Package-Requires: ((emacs "28.1") (claude-sentinel "0.1.0"))
;; Keywords: tools convenience
;; URL: https://github.com/daedlock/claude-sentinel

;;; Commentary:
;;
;; Displays a tab bar in the header-line of Claude Code vterm buffers.
;; Each tab represents one Claude instance in the same project.
;; Clicking a tab (or using `claude-sentinel-headerline-next') switches
;; the displayed buffer in-place without changing the window layout.
;;
;; The header-line string is pre-built and stored directly in
;; `header-line-format'.  It is recomputed only on state changes,
;; never during rendering.
;;
;; Tabs only appear when 2+ instances share the same project.
;;
;; Usage:
;;   (claude-sentinel-headerline-mode 1)

;;; Code:

(require 'claude-sentinel)

;;; Faces

(defface claude-sentinel-tab-active
  '((t :inherit mode-line :weight bold))
  "Face for the currently visible Claude tab."
  :group 'claude-sentinel)

(defface claude-sentinel-tab-inactive
  '((t :inherit mode-line-inactive))
  "Face for non-active Claude tabs."
  :group 'claude-sentinel)

;;; Rendering

(defun claude-sentinel-headerline--build (buffer siblings)
  "Build a header-line string for BUFFER given its SIBLINGS list."
  (when (> (length siblings) 1)
    (let ((parts
           (mapcar
            (lambda (sib)
              (let* ((idx     (1+ (seq-position siblings sib)))
                     (inst    (gethash sib claude-sentinel--instances))
                     (state   (if inst (claude-sentinel-instance-state inst) 'shell))
                     (icon    (pcase state
                                ('working "⠂")
                                ('waiting "✳")
                                ('shell   "·")
                                (_        "?")))
                     (active  (eq sib buffer))
                     (face    (if active
                                  'claude-sentinel-tab-active
                                'claude-sentinel-tab-inactive))
                     (summary (when inst
                                (claude-sentinel-instance-summary inst)))
                     (label   (format " %s %d. %s " icon idx
                                      (if summary
                                          (truncate-string-to-width summary 20 nil nil "…")
                                        "")))
                     (map     (make-sparse-keymap)))
                ;; Capture `sib' for the click handler
                (let ((target sib))
                  (define-key map [header-line mouse-1]
                              (lambda () (interactive)
                                (when (buffer-live-p target)
                                  (let ((win (selected-window)))
                                    (set-window-dedicated-p win nil)
                                    (set-window-buffer win target)
                                    (set-window-dedicated-p win t))
                                  (claude-sentinel-headerline--refresh target)))))
                (propertize label
                            'face       face
                            'local-map  map
                            'mouse-face 'mode-line-highlight)))
            siblings)))
      (string-join parts " "))))

(defun claude-sentinel-headerline--refresh (buffer)
  "Recompute header-line for BUFFER and all its siblings."
  (let ((siblings (claude-sentinel-siblings buffer)))
    (dolist (sib siblings)
      (when (buffer-live-p sib)
        (with-current-buffer sib
          (setq header-line-format
                (claude-sentinel-headerline--build sib siblings)))
        ;; Force redisplay if visible
        (when-let ((win (get-buffer-window sib t)))
          (with-selected-window win
            (force-mode-line-update)))))))

;;; Hook

(defun claude-sentinel-headerline--on-state-change (instance _old _new)
  "Update header-lines for all siblings when any INSTANCE changes state."
  (claude-sentinel-headerline--refresh
   (claude-sentinel-instance-buffer instance)))

;;; Commands

;;;###autoload
(defun claude-sentinel-headerline-next ()
  "Switch to the next Claude instance tab in the current window."
  (interactive)
  (let* ((siblings (claude-sentinel-siblings (current-buffer)))
         (pos     (seq-position siblings (current-buffer)))
         (next    (when siblings
                    (nth (mod (1+ (or pos 0)) (length siblings)) siblings))))
    (when (and next (buffer-live-p next))
      (let ((win (selected-window)))
        (set-window-dedicated-p win nil)
        (set-window-buffer win next)
        (set-window-dedicated-p win t))
      (claude-sentinel-headerline--refresh next))))

;;;###autoload
(defun claude-sentinel-headerline-prev ()
  "Switch to the previous Claude instance tab in the current window."
  (interactive)
  (let* ((siblings (claude-sentinel-siblings (current-buffer)))
         (pos     (seq-position siblings (current-buffer)))
         (prev    (when siblings
                    (nth (mod (1- (or pos 0)) (length siblings)) siblings))))
    (when (and prev (buffer-live-p prev))
      (let ((win (selected-window)))
        (set-window-dedicated-p win nil)
        (set-window-buffer win prev)
        (set-window-dedicated-p win t))
      (claude-sentinel-headerline--refresh prev))))

;;; Kill handling

(defun claude-sentinel-headerline--on-kill ()
  "Before a Claude buffer dies, show a sibling in its window."
  (let* ((buf (current-buffer))
         (siblings (cl-remove buf (claude-sentinel-siblings buf)))
         (next (car siblings)))
    (when next
      (dolist (win (get-buffer-window-list buf nil t))
        (set-window-dedicated-p win nil)
        (set-window-buffer win next)
        (set-window-dedicated-p win t))
      ;; Refresh tabs on remaining siblings
      (run-with-timer 0 nil #'claude-sentinel-headerline--refresh next))))

;;; Minor mode

;;;###autoload
(define-minor-mode claude-sentinel-headerline-mode
  "Show tabbed header-line in Claude Code vterm buffers.
Tabs appear only when 2+ instances share the same project."
  :global t
  :group 'claude-sentinel
  :lighter nil
  (if claude-sentinel-headerline-mode
      (add-hook 'claude-sentinel-state-change-functions
                #'claude-sentinel-headerline--on-state-change)
    (remove-hook 'claude-sentinel-state-change-functions
                 #'claude-sentinel-headerline--on-state-change)
    ;; Clean up header-lines from all claude buffers
    (dolist (inst (claude-sentinel-instances))
      (let ((buf (claude-sentinel-instance-buffer inst)))
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (setq header-line-format nil)))))))

(provide 'claude-sentinel-headerline)
;;; claude-sentinel-headerline.el ends here
