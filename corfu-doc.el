;;; corfu-doc.el --- Documentation popup for Corfu -*- lexical-binding: t -*-

;; Copyright (C) 2021-2022 Yuwei Tian

;; Author: Yuwei Tian <ibluefocus@NOSPAM.gmail.com>
;; URL: https://github.com/galeo/corfu-doc
;; Version: 0.0.3
;; Keywords: corfu popup documentation convenience
;; Package-Requires: ((emacs "26.0")(corfu "0.16.0"))

;; This file is not part of GNU Emacs.

;;; License
;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; see the file LICENSE. If not, see
;; <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Display candidate's documentation in another frame

;;; Code:

(eval-when-compile
  (require 'cl-lib)
  (require 'subr-x))
(require 'corfu)

(defgroup corfu-doc nil
  "Display documentation popup alongside corfu."
  :group 'corfu
  :prefix "corfu-doc-")

(defcustom corfu-doc-delay 1
  "The number of seconds to wait before displaying the documentation popup."
  :type 'float
  :safe #'floatp
  :group 'corfu-doc)

(defcustom corfu-doc-max-width 60
  "The max width of the corfu doc frame in characters."
  :type 'integer
  :safe #'integerp
  :group 'corfu-doc)

(defcustom corfu-doc-max-height 10
  "The max height of the corfu doc frame in characters."
  :type 'integer
  :safe #'integerp
  :group 'corfu-doc)

(defvar corfu-doc--frame nil
  "Doc frame.")

(defvar corfu-doc--frame-parameters
  (let* ((cw (default-font-width))
         (lm (* cw corfu-left-margin-width))
         (rm (* cw corfu-right-margin-width)))
    (map-merge 'alist
               corfu--frame-parameters
               `((left-fringe . ,(ceiling lm))
                 (right-fringe . ,(ceiling rm)))))
  "Default doc child frame parameters.")

(defvar corfu-doc--window nil
  "Current window corfu is in.")

(defvar-local corfu-doc--timer nil
  "Corfu doc idle timer.")

(defvar-local corfu-doc--candidate nil
  "Completion candidate to show doc for.")

(defvar-local corfu-doc--cf-frame-edges nil
  "Coordinates of the corfu frame's edges.")

;; Function adapted from corfu.el by Daniel Mendler
(defun corfu-doc--redirect-focus ()
  "Redirect focus from doc."
  (redirect-frame-focus corfu-doc--frame (frame-parent corfu-doc--frame)))

;; Function adapted from corfu.el by Daniel Mendler
(defun corfu-doc--make-buffer (content)
  "Create corfu doc buffer with CONTENT."
  (let ((fr face-remapping-alist)
        (buffer (get-buffer-create " *corfu-doc*")))
    (with-current-buffer buffer
      ;;; XXX HACK install redirect focus hook
      (add-hook 'pre-command-hook #'corfu-doc--redirect-focus nil 'local)
      ;;; XXX HACK install mouse ignore map
      (use-local-map corfu--mouse-ignore-map)
      (dolist (var corfu--buffer-parameters)
        (set (make-local-variable (car var)) (cdr var)))
      (setq-local indicate-empty-lines nil)
      (setq-local face-remapping-alist (copy-tree fr))
      (cl-pushnew 'corfu-default (alist-get 'default face-remapping-alist))
      (let ((inhibit-modification-hooks t)
            (inhibit-read-only t))
        (erase-buffer)
        (insert content)
        (visual-line-mode 1)  ;; turn on word wrap
        (goto-char (point-min))))
    buffer))

;; Function adapted from corfu.el by Daniel Mendler
(defun corfu-doc--make-frame (x y width height content)
  "Show child frame at X/Y with WIDTH/HEIGHT and CONTENT."
  (let* ((window-min-height 1)
         (window-min-width 1)
         (x-gtk-resize-child-frames
          (let ((case-fold-search t))
            (and
             ;; XXX HACK to fix resizing on gtk3/gnome taken from posframe.el
             ;; More information:
             ;; * https://github.com/minad/corfu/issues/17
             ;; * https://gitlab.gnome.org/GNOME/mutter/-/issues/840
             ;; * https://lists.gnu.org/archive/html/emacs-devel/2020-02/msg00001.html
             (string-match-p "gtk3" system-configuration-features)
             (string-match-p "gnome\\|cinnamon" (or (getenv "XDG_CURRENT_DESKTOP")
                                                    (getenv "DESKTOP_SESSION") ""))
             'resize-mode)))
         (after-make-frame-functions)
         (border (alist-get 'child-frame-border-width corfu-doc--frame-parameters))
         (buffer (corfu-doc--make-buffer content)))
    (unless (and (frame-live-p corfu-doc--frame)
                 (eq (frame-parent corfu-doc--frame) (window-frame)))
      (when corfu-doc--frame (delete-frame corfu-doc--frame))
      (setq corfu-doc--frame (make-frame
                              `((parent-frame . ,(window-frame))
                                (minibuffer . ,(minibuffer-window (window-frame)))
                                (line-spacing . ,line-spacing)
                                ;; Set `internal-border-width' for Emacs 27
                                (internal-border-width . ,border)
                                ,@corfu-doc--frame-parameters))))
    ;; XXX HACK Setting the same frame-parameter/face-background is not a nop (BUG!).
    ;; Check explicitly before applying the setting.
    ;; Without the check, the frame flickers on Mac.
    (let* ((face (if (facep 'child-frame-border) 'child-frame-border 'internal-border))
	       (internal-border-color (face-attribute 'corfu-border :background nil 'default))
           (bg-color (face-attribute 'corfu-default :background nil 'default)))
      (unless (and (equal (face-attribute face :background corfu-doc--frame 'default)
                          internal-border-color)
                   (equal (frame-parameter corfu--frame 'background-color) bg-color))
	    (set-face-background face internal-border-color corfu-doc--frame)
        ;; XXX HACK We have to apply the face background before adjusting the frame parameter,
        ;; otherwise the border is not updated (BUG!).
        (set-frame-parameter corfu-doc--frame 'background-color bg-color))
      ;; set fringe color
      (unless (equal (face-attribute 'fringe :background corfu-doc--frame 'default)
                     bg-color)
        (set-face-background 'fringe bg-color corfu-doc--frame)))
    (let ((win (frame-root-window corfu-doc--frame)))
      (set-window-buffer win buffer)
      ;; Mark window as dedicated to prevent frame reuse (#60)
      (set-window-dedicated-p win t))
    ;; XXX HACK Make the frame invisible before moving the popup in order to avoid flicker.
    (unless (eq (cdr (frame-position corfu-doc--frame)) y)
      (make-frame-invisible corfu-doc--frame))
    (set-frame-position corfu-doc--frame x y)
    (set-frame-size corfu-doc--frame width height t)
    (make-frame-visible corfu-doc--frame)))

;; Function adapted from corfu.el by Daniel Mendler
(defun corfu-doc-fetch-documentation ()
  "Fetch documentation buffer of current candidate."
  (cond
    ((= corfu--total 0)
     (user-error "No candidates"))
    ((< corfu--index 0)
     (user-error "No candidate selected"))
    (t
     (if-let* ((fun (plist-get corfu--extra :company-doc-buffer))
               (res
                ;; fix showing candidate location when fetch helpful documentation
                (save-excursion
                  (funcall fun (nth corfu--index corfu--candidates)))))
         (let ((buf (or (car-safe res) res)))
           (with-current-buffer buf
             (buffer-string)))
       (user-error "No documentation available")))))

(defun corfu-doc--calculate-doc-frame-position ()
  "Calculate doc frame position (x, y), pixel width and height."
  (let* (x y
         (space 1)  ;; 1 pixel space between corfu frame and corfu doc frame
         (cf-parent-frame (frame-parent corfu--frame))
         (cf-frame--pos (frame-position corfu--frame))
         (cf-frame-x (car cf-frame--pos))  ;; corfu--frame x pos
         (cf-frame-y (cdr cf-frame--pos))
         (cf-frame-width (frame-pixel-width corfu--frame))
         (cf-parent-frame-x  ;; corfu parent frame x pos
           ;; Get inner frame left top edge for corfu frame's parent frame
           ;; See "(elisp) Frame Layout" in Emacs manual
           (car (cl-subseq (frame-edges cf-parent-frame 'inner) 0 2)))
         (cf-parent-frame-width (frame-pixel-width cf-parent-frame))
         (cf-doc-frame-width
           ;; left border + left margin + inner width + right margin + right-border
           (+ 1
              (alist-get 'left-fringe corfu-doc--frame-parameters 0)
              (* (frame-char-width) corfu-doc-max-width)
              (alist-get 'right-fringe corfu-doc--frame-parameters 0)
              1))
         (cf-doc-frame-height (* (frame-char-height) corfu-doc-max-height))
         (display-geometry (assq 'geometry (frame-monitor-attributes corfu--frame)))
         (display-width (nth 3 display-geometry))
         (display-x (nth 1 display-geometry))
         (cf-parent-frame-rel-x (- cf-parent-frame-x display-x))
         (display-space-right
           (- display-width (+ (+ cf-frame-x cf-frame-width space)
                               cf-parent-frame-rel-x)))
         (display-space-left (- (+ cf-frame-x cf-parent-frame-rel-x)
                                space)))
    (setq x (or
             (and (> cf-doc-frame-width display-space-right)
                  (> display-space-left cf-doc-frame-width)
                  ;; space that right edge of the DOC-FRAME
                  ;; to the right edge of the parent frame
                  ;;   calculation:
                  ;; (- (+ cf-frame-x cf-parent-frame-x)
                  ;;    space
                  ;;    (+ cf-parent-frame-x cf-parent-frame-width))
                  (- cf-frame-x space cf-parent-frame-width))
             (let* ((x-on-left-side-of-cp-frame
                      (- cf-frame-x space cf-doc-frame-width)))
               (or
                ;; still positioned in completion frame's parent frame
                (and (> x-on-left-side-of-cp-frame 0)
                     ;; and x point is visible in display
                     (> (+ x-on-left-side-of-cp-frame cf-parent-frame-x) 0)
                     x-on-left-side-of-cp-frame)
                (+ cf-frame-x cf-frame-width space))))
          y cf-frame-y)
    (list x y cf-doc-frame-width cf-doc-frame-height)))

(defun corfu-doc--show ()
  (let ((candidate (and (> corfu--total 0)
                        (nth corfu--index corfu--candidates)))
        (cf-frame-edges (frame-edges corfu--frame 'inner)))
    (if candidate
        (when (and (and (fboundp 'corfu-mode) corfu-mode)
                   (frame-visible-p corfu--frame))
          (unless (and (string= corfu-doc--candidate candidate)
                       (frame-visible-p corfu-doc--frame)
                       (equal cf-frame-edges corfu-doc--cf-frame-edges)
                       (eq (selected-window) corfu-doc--window))
            ;; show doc frame
            (when-let* ((doc (ignore-errors (corfu-doc-fetch-documentation))))
              (eval `(corfu-doc--make-frame
                      ,@(corfu-doc--calculate-doc-frame-position) ,doc)))))
      (corfu-doc--hide))
    (setq corfu-doc--candidate candidate)
    (setq corfu-doc--cf-frame-edges cf-frame-edges)
    (setq corfu-doc--window (selected-window))))

(defun corfu-doc--hide ()
  (when (frame-live-p corfu-doc--frame)
    (make-frame-invisible corfu-doc--frame)
    (with-current-buffer
        (window-buffer (frame-root-window corfu-doc--frame))
      (let ((inhibit-read-only t))
        (erase-buffer)))))

(defun corfu-doc-manually ()
  (interactive)
  (let ((corfu-doc-delay 0))
    (corfu-doc--set-timer)))

(defun corfu-doc--set-timer (&rest _args)
  (when (or (null corfu-doc--timer)
            (eq this-command #'corfu-doc-manually))
    (setq corfu-doc--timer
          (run-with-timer
           (if (and (frame-live-p corfu-doc--frame)
                    (frame-visible-p corfu-doc--frame))
               0
             corfu-doc-delay)
           nil #'corfu-doc-show))))

(defun corfu-doc--cancel-timer ()
  (when (timerp corfu-doc--timer)
    (cancel-timer corfu-doc--timer)
    (setq corfu-doc--timer nil)))

(defun corfu-doc-show ()
  (corfu-doc--cancel-timer)
  (corfu-doc--show))

(defun corfu-doc-hide ()
  (when corfu-doc-delay
    (corfu-doc--cancel-timer))
  (corfu-doc--hide))

(defun corfu-doc--funcall (function &rest args)
  (when-let ((cf-doc-buf (and (frame-live-p corfu-doc--frame)
                              (frame-visible-p corfu-doc--frame)
                              (get-buffer " *corfu-doc*"))))
    (when (functionp function)
      (with-selected-frame corfu-doc--frame
        (with-current-buffer cf-doc-buf
          (apply function args))))))

;;;###autoload
(defun corfu-doc-scroll-up (&optional arg)
  (interactive "^P")
  (corfu-doc--funcall #'scroll-up-command arg))

;;;###autoload
(defun corfu-doc-scroll-down (&optional arg)
  (interactive "^P")
  (corfu-doc--funcall #'scroll-down-command arg))

;;;###autoload
(define-minor-mode corfu-doc-mode
  "Corfu doc minor mode."
  :global nil
  :group 'corfu
  (cond
    (corfu-doc-mode
     (advice-add 'corfu--popup-show :after #'corfu-doc--set-timer)
     (advice-add 'corfu--popup-hide :after #'corfu-doc-hide))
    (t
     (advice-remove 'corfu--popup-show #'corfu-doc--set-timer)
     (advice-remove 'corfu--popup-hide #'corfu-doc-hide))))


(provide 'corfu-doc)
;;; corfu-doc.el ends here
