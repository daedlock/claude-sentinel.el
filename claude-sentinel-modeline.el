;;; claude-sentinel-modeline.el --- Modeline integration for claude-sentinel -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Contributors
;;
;; Package-Requires: ((emacs "28.1") (claude-sentinel "0.1.0"))
;; Keywords: tools convenience
;; URL: https://github.com/daedlock/claude-sentinel

;;; Commentary:
;;
;; Provides a modeline indicator showing the status of all Claude Code
;; CLI instances.  The display string is pre-rendered and cached; it is
;; recomputed only when instance state changes, never on every render.
;;
;; When doom-modeline is present a named segment `claude-sentinel' is
;; defined, which the user can splice into their modeline layout.
;; Without doom-modeline the segment is appended to `mode-line-misc-info'.
;;
;; Usage:
;;   (claude-sentinel-modeline-mode 1)
;;
;;   ; For doom-modeline users, add `claude-sentinel' to your layout:
;;   (doom-modeline-def-modeline 'main
;;     '(...)
;;     '(... claude-sentinel ...))

;;; Code:

(require 'claude-sentinel)

;;; Cache — the only string ever read by the modeline renderer

(defvar claude-sentinel-modeline--cache ""
  "Pre-rendered propertized string for modeline display.
Updated reactively via `claude-sentinel-state-change-functions';
never computed inside a modeline renderer.")

(defun claude-sentinel-modeline--build ()
  "Compute and store the cached modeline string from current counts.
This is the only place counts are aggregated; it is called on state
changes, not during rendering."
  (let* ((total   (claude-sentinel-total-count))
         (working (claude-sentinel-working-count))
         (waiting (claude-sentinel-waiting-count)))
    (setq claude-sentinel-modeline--cache
          (if (zerop total)
              ""
            (let ((map (make-sparse-keymap)))
              (define-key map [mode-line mouse-1] #'claude-sentinel-dashboard)
              (propertize
               (if (> working 0)
                   (format " ⠂%d/%d " working total)
                 (format " ✳%d " waiting))
               'face      (if (> working 0) 'warning 'success)
               'local-map map
               'mouse-face 'mode-line-highlight
               'help-echo  (format
                            "Claude: %d working, %d waiting, %d total\nmouse-1: open dashboard"
                            working waiting total)))))))

(defun claude-sentinel-modeline--on-state-change (&rest _)
  "Recompute cache and refresh modeline.  Subscribed to state-change hook."
  (claude-sentinel-modeline--build)
  (force-mode-line-update t))

;;; doom-modeline segment

(with-eval-after-load 'doom-modeline
  (doom-modeline-def-segment claude-sentinel
    "Claude Code instance summary.
Reads `claude-sentinel-modeline--cache'; never does any computation."
    (when (doom-modeline--active)
      claude-sentinel-modeline--cache)))

;;; Vanilla mode-line fallback

(defvar claude-sentinel-modeline--entry
  '(:eval claude-sentinel-modeline--cache)
  "The `mode-line-misc-info' entry for vanilla Emacs.")

(defun claude-sentinel-modeline--add-vanilla ()
  "Prepend sentinel entry to `mode-line-misc-info' if absent."
  (unless (member claude-sentinel-modeline--entry mode-line-misc-info)
    (push claude-sentinel-modeline--entry mode-line-misc-info)))

(defun claude-sentinel-modeline--remove-vanilla ()
  "Remove sentinel entry from `mode-line-misc-info'."
  (setq mode-line-misc-info
        (delete claude-sentinel-modeline--entry mode-line-misc-info)))

;;; Minor mode

;;;###autoload
(define-minor-mode claude-sentinel-modeline-mode
  "Show Claude Code instance status in the modeline."
  :global t
  :group 'claude-sentinel
  :lighter nil
  (if claude-sentinel-modeline-mode
      (progn
        (add-hook 'claude-sentinel-state-change-functions
                  #'claude-sentinel-modeline--on-state-change)
        (claude-sentinel-modeline--build)
        (unless (featurep 'doom-modeline)
          (claude-sentinel-modeline--add-vanilla)))
    (remove-hook 'claude-sentinel-state-change-functions
                 #'claude-sentinel-modeline--on-state-change)
    (unless (featurep 'doom-modeline)
      (claude-sentinel-modeline--remove-vanilla))
    (setq claude-sentinel-modeline--cache "")))

(provide 'claude-sentinel-modeline)
;;; claude-sentinel-modeline.el ends here
