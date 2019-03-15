;;; telega-media.el --- Media support for telega  -*- lexical-binding:t -*-

;; Copyright (C) 2018-2019 by Zajcev Evgeny.

;; Author: Zajcev Evgeny <zevlg@yandex.ru>
;; Created: Tue Jul 10 15:20:09 2018
;; Keywords:

;; telega is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; telega is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with telega.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Code to work with media in telega:
;;  - Download/upload files to cloud
;;  - Thumbnails
;;  - Stickers
;;  - Animations
;;  - Web pages
;;  etc

;;; Code:
(require 'telega-core)
(require 'telega-server)

(defvar telega-emoji-svg-images nil
  "Cache of SVG images for emoji.
Alist with elements in form (emoji . image)")

;;; Files downloading/uploading
(defun telega--getFile (file-id &optional callback)
  (declare (indent 1))
  (telega-server--call
   (list :@type "getFile"
         :file_id file-id)
   callback))

(defsubst telega-file--ensure (file)
  "Ensure FILE is in `telega--files'.
Return FILE."
  (puthash (plist-get file :id) file telega--files)
  file)

(defun telega-file-get (file-id)
  "Return file associated with FILE-ID."
  (or (gethash file-id telega--files)
      (telega-file--ensure (telega--getFile file-id))))

(defun telega-file--renew (place prop)
  "Renew file value at PLACE and PROP."
  (let* ((ppfile (plist-get place prop))
         (file-id (plist-get ppfile :id))
         (file (or (gethash file-id telega--files)
                   (telega-file--ensure ppfile))))
    (plist-put place prop file)
    file))

(defun telega--downloadFile (file-id &optional priority)
  "Asynchronously downloads a file by its FILE-ID from the cloud.
`telega--on-updateFile' will be called to notify about the
download progress and successful completion of the download.
PRIORITY is integer in range 1-32 (higher downloads faster), default is 1."
  ;; We use `telega-server--send' instead of `telega-server--call' to
  ;; not block waiting for result.  We catch the result with
  ;; `telega--on-file'
  (telega-server--send
   (list :@type "downloadFile"
         :file_id file-id
         :priority (or priority 1))))

(defun telega--cancelDownloadFile (file-id &optional only-if-pending)
  "Stop downloading the file denoted by FILE-ID.
If ONLY-IF-PENDING is non-nil then stop downloading only if it
hasn't been started, i.e. request hasn't been sent to server."
  (telega-server--send
   (list :@type "cancelDownloadFile"
         :file_id file-id
         :only_if_pending (or only-if-pending :false))))

(defun telega--deleteFile (file-id)
  "Delete file from cache."
  (telega-server--send
   (list :@type "deleteFile"
         :file_id file-id)))

(defun telega--on-file (file)
  "FILE has been returned from some call to `telega-server--send'."
  (telega-file--ensure file)

  ;; Run update callbacks
  (let* ((callbacks (gethash (plist-get file :id) telega--files-updates))
         (left-cbs (cl-loop for cb in callbacks
                            when (funcall cb file)
                            collect cb)))
    (puthash (plist-get file :id) left-cbs telega--files-updates)))

(defun telega--on-updateFile (event)
  "File has been updated, call all the associated hooks."
  (telega--on-file (plist-get event :file)))

(defsubst telega-file--size (file)
  "Return FILE size."
  ;; NOTE: fsize is 0 if unknown, in this case esize is approximate
  ;; size
  (let ((fsize (plist-get file :size))
        (esize (plist-get file :expected_size)))
    (if (zerop fsize) esize fsize)))

(defsubst telega-file--downloaded-p (file)
  "Return non-nil if FILE has been downloaded."
  (telega--tl-get file :local :is_downloading_completed))

(defsubst telega-file--downloading-p (file)
  "Return non-nil if FILE is downloading right now."
  (telega--tl-get file :local :is_downloading_active))

(defsubst telega-file--can-download-p (file)
  "Return non-nil if FILE can be downloaded.
May return nil even when `telega-file--downloaded-p' returns non-nil."
  (telega--tl-get file :local :can_be_downloaded))

(defsubst telega-file--need-download-p (file)
  (and (telega-file--can-download-p file)
       (not (telega-file--downloaded-p file))))

(defsubst telega-file--downloading-progress (file)
  "Return progress of file downloading as float from 0 to 1."
  (color-clamp (/ (float (telega--tl-get file :local :downloaded_size))
                  (telega-file--size file))))

(defun telega-file--callback-wrap (callback check-fun)
  "Wrapper for CALLBACK.
Removes callback in case downloading is canceled or completed."
  (when callback
    (lambda (file)
      (funcall callback file)
      (funcall check-fun file))))

(defun telega-file--download (file &optional priority callback)
  "Download file denoted by FILE-ID."
  (declare (indent 2))
  ;; - If file already downloaded, then just call the callback
  ;; - If file already downloading, then just install the callback
  ;; - If file can be downloaded, install the callback and download
  ;;   the file
  (let* ((file-id (plist-get file :id))
         (dfile (telega-file-get file-id))
         (cbwrap (telega-file--callback-wrap
                  callback 'telega-file--downloading-p)))
    (cond ((telega-file--downloaded-p dfile)
           (when cbwrap
             (funcall cbwrap dfile)))

          ((telega--tl-get dfile :local :can_be_downloaded)
           (when cbwrap
             (let ((cb-list (gethash file-id telega--files-updates)))
               (puthash file-id (cons cbwrap cb-list)
                        telega--files-updates)))

           (unless (telega-file--downloading-p dfile)
             (telega--downloadFile file-id priority))))
    ))

(defun telega--uploadFile (filename &optional file-type priority)
  "Asynchronously upload file denoted by FILENAME.
FILE-TYPE is one of `photo', `animation', etc
PRIORITY is same as for `telega-file--download'."
  (telega-server--call
   (list :@type "uploadFile"
         :file (list :@type "inputFileLocal" :path filename)
         :file_type (list :@type (format "fileType%S" (or file-type 'Unknown)))
         :priority (or priority 1))))

(defun telega--cancelUploadFile (file-id)
  "Stop uploading file denoted by FILE-ID."
  (telega-server--send
   (list :@type "cancelUploadFile"
         :file_id file-id)))

(defsubst telega-file--uploaded-p (file)
  "Return non-nil if FILE has been uploaded."
  (telega--tl-get file :remote :is_uploading_completed))

(defsubst telega-file--uploading-p (file)
  "Return non-nil if FILE is uploading right now."
  (telega--tl-get file :remote :is_uploading_active))

(defsubst telega-file--uploading-progress (file)
  "Return progress of file uploading as float from 0 to 1."
  (color-clamp (/ (float (telega--tl-get file :remote :uploaded_size))
                  (telega-file--size file))))

(defun telega-file--upload (filename &optional file-type priority callback)
  "Upload FILENAME to the cloud.
Return file object, obtained from `telega--uploadFile'."
  (declare (indent 3))
  (let* ((file (telega--uploadFile filename file-type priority))
         (file-id (plist-get file :id))
         (cbwrap (telega-file--callback-wrap
                  callback 'telega-file--uploading-p)))
    (if (telega-file--uploaded-p file)
        (when cbwrap
          (funcall cbwrap file))

      (when cbwrap
        (let ((cb-list (gethash file-id telega--files-updates)))
          (puthash file-id (cons cbwrap cb-list)
                   telega--files-updates))))
    file))


;;; Photos
(defmacro telega-thumbnail--get (type thumbnails)
  "Get thumbnail of TYPE from list of THUMBNAILS.
Thumbnail TYPE and its sizes:
\"s\"  box   100x100
\"m\"  box   320x320
\"x\"  box   800x800
\"y\"  box   1280x1280
\"w\"  box   2560x2560
\"a\"  crop  160x160
\"b\"  crop  320x320
\"c\"  crop  640x640
\"d\"  crop  1280x1280"
  `(cl-find ,type ,thumbnails :test 'string= :key (telega--tl-prop :type)))

(defun telega-photo--highres (photo)
  "Return thumbnail of highest resolution for the PHOTO.
Return thumbnail that can be downloaded."
  (cl-some (lambda (tn)
             (let ((tn-file (telega-file--renew tn :photo)))
               (when (or (telega-file--downloaded-p tn-file)
                         (telega-file--can-download-p tn-file))
                 tn)))
           ;; From highest res to lower
           (reverse (plist-get photo :sizes))))

(defun telega-photo--thumb (photo)
  "While downloading best photo, get small thumbnail for the PHOTO."
  (let ((photo-sizes (plist-get photo :sizes)))
    (or (cl-some (lambda (tn)
                   (when (telega-file--downloaded-p
                          (telega-file--renew tn :photo))
                     tn))
                 photo-sizes)
        (cl-some (lambda (tn)
                   (when (telega-file--downloading-p
                          (telega-file--renew tn :photo))
                     tn))
                 photo-sizes)
        (cl-some (lambda (tn)
                   (when (telega-file--can-download-p
                          (telega-file--renew tn :photo))
                     tn))
                 photo-sizes)
        )))

(defun telega-photo--best (photo &optional limits)
  "Select best thumbnail from PHOTO suiting LIMITS.
By default LIMITS is `telega-photo-maxsize'."
  (unless limits
    (setq limits telega-photo-maxsize))

  ;; NOTE: `reverse' is used to start from highes sizes
  (let ((lim-xwidth (* (frame-char-width (telega-x-frame))
                       (car limits)))
        (lim-xheight (* (frame-char-height (telega-x-frame))
                        (cdr limits)))
        (photo-sizes (reverse (plist-get photo :sizes)))
        ret)
    (setq ret (aref photo-sizes 0))
    (dotimes (idx (length photo-sizes))
      (let* ((thumb (aref photo-sizes idx))
             (thumb-file (telega-file--renew thumb :photo))
             (tw (plist-get thumb :width))
             (th (plist-get thumb :height)))
        (when (and (or (telega-file--downloaded-p thumb-file)
                       (telega-file--can-download-p thumb-file))
                   (or (and (>= tw lim-xwidth)
                            (<= (* th (/ lim-xwidth tw 1.0)) lim-xheight))
                       (and (>= th lim-xheight)
                            (<= (* tw (/ lim-xheight th 1.0)) lim-xwidth))))
          (setq ret thumb))))
    ret))


;;; Auto-downloading media
(defun telega-media--autodownload-on-chat (chat)
  "Autodownload CHAT's avatar."
  (let* ((photo (plist-get chat :photo))
         (photo-file (telega-file--renew photo :small)))
    (when (and (telega-file--need-download-p photo-file)
               (not (telega-file--downloading-p photo-file)))
      (telega-file--download photo-file 32))))

(defun telega-media--autodownload-on-user (user)
  "Autodownload USER's profile avatar."
  (let* ((photo (plist-get user :profile_photo))
         (photo-file (telega-file--renew photo :small)))
    (when (and (telega-file--need-download-p photo-file)
               (not (telega-file--downloading-p photo-file)))
      (telega-file--download photo-file 32))))

(defun telega-media--autodownload-on-msg (msg _disable-notification)
  "Autodownload media in MSG according to `telega-auto-download'.
Always download \"s\" type (for one-line reply/edit formatting).
Downloads highres photos according to `telega-auto-download'."
  (let ((chat (telega-chat-get (plist-get msg :chat_id)))
        (content (plist-get msg :content)))
    (cl-case (telega--tl-type content)
      (messagePhoto
       (let* ((photo (plist-get content :photo))
              (lowres (telega-photo--thumb photo))
              (lowres-file (plist-get lowres :photo))
              (highres (telega-photo--highres photo))
              (highres-file (plist-get highres :photo)))

         ;; Always download lowres files
         (cl-assert lowres-file)
         (when (telega-file--need-download-p lowres-file)
           (telega-debug "Autodownload LOWRES: %S" lowres-file)
           (telega-file--download lowres-file 32))

         (cl-assert highres-file)
         (when (and (telega-file--need-download-p highres-file)
                    (telega-filter-chats
                     (alist-get 'photos telega-auto-download) (list chat)))
           (telega-debug "Autodownload HIGH-RES: %S" highres-file)
           (telega-file--download highres-file 5))))
      ;; TODO
      (messageVideo
       )
      (messageDocument
       )
      )))

;;;###autoload
(defun telega-media-auto-download-mode (&optional arg)
  "Toggle automatic media download for incoming messages.
With positive ARG - enables automatic downloads, otherwise disables.
To customize automatic downloads, use `telega-auto-download'."
  (interactive "p")
  (if (> arg 0)
      (progn
        (add-hook 'telega-user-update-hook 'telega-media--autodownload-on-user)
        (add-hook 'telega-chat-created-hook 'telega-media--autodownload-on-chat)
        (add-hook 'telega-chat-pre-message-hook 'telega-media--autodownload-on-msg))

    (remove-hook 'telega-chat-pre-message-hook 'telega-media--autodownload-on-msg)
    (remove-hook 'telega-chat-created-hook 'telega-media--autodownload-on-chat)
    (remove-hook 'telega-user-update-hook 'telega-media--autodownload-on-user)))


;; Avatars
(defun telega-photo--progress-svg (best cheight)
  "Generate svg for BEST variant of the photo."
  (let* ((h (* (frame-char-height) cheight))
         (cwidth-xmargin (telega-media--cwidth-xmargin
                          (plist-get best :width)
                          (plist-get best :height)
                          cheight))
         (w-chars (car cwidth-xmargin))
         (w (* (telega-chars-width 1) w-chars))
         (svg (svg-create w h))
         (progress (telega-file--downloading-progress
                    (telega-file--renew best :photo))))
    (telega-svg-progress svg progress)
    (svg-image svg :scale 1.0
               :ascent 'center
               :mask 'heuristic
               ;; text of correct width
               :telega-text (make-string w-chars ?X))))

(defun telega-media--cwidth-xmargin (width height char-height &optional max-cwidth)
  "Calculate width in chars and margins X pixels.
MAX-CWIDTH is maximum width in chars.
Return cons cell, where car is width in char and cdr is margin value."
  ;; NOTE: handle case where WIDTH or HEIGHT can be zero
  (let* ((pix-h (* (frame-char-height) char-height))
         (pix-w (if (zerop height)
                    0
                  (* (/ (float width) height) pix-h)))
         (cw (telega-chars-in-width pix-w))
         (xmargin (/ (- (telega-chars-width cw) pix-w) 2)))
;    (cl-assert (> cw 0))
    (cons cw (floor xmargin))))

(defun telega-thumb--create-image (thumb &optional file cheight)
  "Create image for the thumbnail THUMB.
CHEIGHT is the height in chars (default=1)."
  ;; Always renew thumb file, even if FILE is given
  (setq file (telega-file--renew thumb :photo))
  (unless cheight
    (setq cheight 1))
  (if (telega-file--downloaded-p file)
      (let ((cwidth-xmargin (telega-media--cwidth-xmargin
                             (plist-get thumb :width)
                             (plist-get thumb :height)
                             cheight)))
        (create-image (telega--tl-get file :local :path)
                      'imagemagick nil
                      :height (* cheight (frame-char-height (telega-x-frame)))
                      :scale 1.0
                      :ascent 'center
                      :margin (cons (cdr cwidth-xmargin) 0)
                      :telega-text (make-string (car cwidth-xmargin) ?X)))

    (telega-photo--progress-svg thumb cheight)))

(defun telega-thumb--create-image-one-line (thumb &optional file)
  "Create image for thumbnail (photoSize) for one line use."
  (telega-thumb--create-image thumb file 1))

(defun telega-thumb--create-image-as-is (thumb &optional file)
  "Create image for thumbnail THUMB (photoSize) with size as is."
  (telega-thumb--create-image
   thumb file (telega-chars-in-height (plist-get thumb :height))))

(defun telega-media--image-update (obj-spec file)
  "Called to update the image contents for the OBJ-SPEC.
OBJ-SPEC is cons of object and create image function.
Create image function accepts two arguments - object and FILE.
Return updated image, cached or created with create image function."
  (let ((cached-image (plist-get (car obj-spec) :telega-image))
        (simage (funcall (cdr obj-spec) (car obj-spec) file)))
    (unless (equal cached-image simage)
      ;; Update the image
      (if cached-image
          (setcdr cached-image (cdr simage))
        (setq cached-image simage))
      (plist-put (car obj-spec) :telega-image cached-image))
    cached-image))

(defun telega-media--image (obj-spec file-spec &optional force-update)
  "Return image for media object specified by OBJ-SPEC.
File is specified with FILE-SPEC."
  (let ((cached-image (plist-get (car obj-spec) :telega-image)))
    (when (or force-update (not cached-image))
      (let ((media-file (telega-file--renew (car file-spec) (cdr file-spec))))
        ;; First time image is created or update is forced
        (setq cached-image
              (telega-media--image-update obj-spec media-file))

        ;; Possible initiate file downloading
        (when (or (telega-file--need-download-p media-file)
                  (telega-file--downloading-p media-file))
          (telega-file--download media-file nil
            (lambda (dfile)
              (cl-assert (plist-get (car obj-spec) :telega-image))
              (telega-media--image-update obj-spec dfile)
              (force-window-update))))))
    cached-image))

(defun telega-photo--image (photo limits)
  "Return best suitable image for the PHOTO."
  (let* ((best (telega-photo--best photo limits))
         (lim-xheight (* (frame-char-height (telega-x-frame))
                         (cdr limits)))
         (th (plist-get best :height))
         (cheight (if (> th lim-xheight)
                      (cdr limits)
                    (telega-chars-in-height th)))
         (create-image-fun
          (progn
            (cl-assert (<= cheight (cdr limits)))
            (lambda (_photoignored &optional _fileignored)
              ;; 1) FILE downloaded, show photo
              ;; 2) Thumbnail is downloaded, use it
              ;; 3) FILE downloading, fallback to progress svg
              (let ((best-file (telega-file--renew best :photo)))
                (if (telega-file--downloaded-p best-file)
                    (telega-thumb--create-image best best-file cheight)
                  (let* ((thumb (telega-photo--thumb photo))
                         (thumb-file (telega-file--renew thumb :photo)))
                    (if (telega-file--downloaded-p thumb-file)
                        (telega-thumb--create-image thumb thumb-file cheight)
                      (telega-photo--progress-svg best cheight)))))))))

;    (telega-photo--progress-svg best cheight)))
    (telega-media--image
     (cons photo create-image-fun)
     (cons best :photo))))
;     'force-update)))

(defun telega-avatar--create-image (chat-or-user file)
  "Create image for CHAT-OR-USER avatar."
  (let* ((photofile (telega--tl-get file :local :path))
         (cfactor (or (car telega-avatar-factors) 0.9))
         (mfactor (or (cdr telega-avatar-factors) 0.1))
         (xh (* 2 (frame-char-height (telega-x-frame))))
         (margin (* mfactor xh))
         (ch (* cfactor xh))
         (cfull (+ ch margin))
         (aw-chars (telega-chars-in-width cfull))
         (xw (telega-chars-width aw-chars))
         (svg (svg-create xw xh)))
    (if (telega-file-exists-p photofile)
        (let ((file-ext (downcase (file-name-extension photofile)))
              (clip (telega-svg-clip-path svg "clip")))
          (svg-circle clip (/ xw 2) (/ cfull 2) (/ ch 2))
          (svg-embed svg photofile
                     (if (string= file-ext "png") "image/png" "image/jpeg")
                     nil
                     :x (/ (- xw ch) 2) :y (/ margin 2)
                     :width ch :height ch
                     :clip-path "url(#clip)"))

      ;; Draw initials
      (let ((fsz (/ ch 2))
            color name)
        (if (eq (telega--tl-type chat-or-user) 'user)
            (setq color (telega-user-color chat-or-user)
                  name (telega-user--name chat-or-user))
          (setq color (telega-chat-color chat-or-user)
                name (telega-chat-title chat-or-user)))

        (svg-gradient svg "cgrad" 'linear
                      (list (cons 0 (cadr color)) (cons ch (caddr color))))
        (svg-circle svg (/ xw 2) (/ cfull 2) (/ ch 2) :gradient "cgrad")
        (svg-text svg (substring name 0 1)
                  :font-size (/ ch 2)
                  :font-weight "bold"
                  :fill "white"
                  :font-family "monospace"
                  ;; XXX insane X/Y calculation
                  :x (- (/ xw 2) (/ fsz 3))
                  :y (+ (/ fsz 3) (/ cfull 2)))))

    (svg-image svg :scale 1.0
               :ascent 'center
               :mask 'heuristic
               :width xw :height xh
               ;; text of correct width
               :telega-text (make-string aw-chars ?X))))

(defun telega-media--emoji-image (emoji)
  "Create svg image for the EMOJI."
  (let ((image (assoc emoji telega-emoji-svg-images)))
    (unless image
      (let* ((xframe (telega-x-frame))
             (xh (frame-char-height xframe))
             (font-size (- xh (/ xh 4)))
             (aw-chars (telega-chars-in-width font-size))
             (xw (telega-chars-width aw-chars))
             (svg (svg-create xw xh)))
        (svg-text svg (substring emoji 0 1)
                  :font-size font-size
                  :x 0 :y font-size)
        (setq image (svg-image svg :scale 1.0
                               :ascent 'center
                               :mask 'heuristic
                               :width xw :height xh
                               :telega-text (make-string aw-chars ?E)))))
    image))

(defun telega-symbol-emojify (emoji)
  "Attach `display' property with emoji svg to EMOJI string.
Typical usage is to emojify `telega-symbol-XXX' values.
Like (telega-symbol-emojify telega-symbol-pin).
EMOJY must be single char string."
  (cl-assert (= (length emoji) 1))
  (add-text-properties 0 1 (list 'rear-nonsticky '(display)
                                 'display (telega-media--emoji-image emoji))
                       emoji))


;; Location
(defun telega--getMapThumbnailFile (loc &optional zoom width height scale chat callback)
  "Get file with the map showing LOC.
ZOOM - zoom level in [13-20], default=13
WIDTH/HEIGHT - in [16-1024]
SCALE - in [1-3]"
  (declare (indent 6))
  (telega-server--call
   (list :@type "getMapThumbnailFile"
         :location loc
         :zoom (or zoom 13)
         :width (or width 300)
         :height (or height 200)
         :scale (or scale 1)
         :chat_id (if chat
                      (plist-get chat :id)
                    0))
   callback))

(provide 'telega-media)

;;; telega-media.el ends here
