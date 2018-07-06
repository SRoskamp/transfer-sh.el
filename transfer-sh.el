;;; transfer-sh.el --- Simple interface for sending buffer contents to transfer.sh

;; Copyright (C) 2016 Steffen Roskamp

;; Author: S. Roskamp <steffen.roskamp@gmail.com>
;; Keywords: cloud, upload, share
;; Package-Requires: ((async "1.0"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This package provides an interface to the transfer-sh website.
;; Calling the transfer-sh-upload function will upload either the
;; currently active region or the complete buffer (if no region is
;; active) to transfer.sh.  The remote file name is determined by the
;; buffer name and the prefix/suffix variables.

;;; Code:
(defgroup transfer-sh nil
  "Interface to transfer.sh uploading service."
  :group 'external)

(defcustom transfer-sh-temp-file-location "/tmp/transfer-sh.tmp"
  "The temporary file to use for uploading to transfer.sh."
  :type 'string
  :group 'transfer-sh)

(defcustom transfer-sh-remote-prefix nil
  "A prefix added to each remote file name."
  :type 'string
  :group 'transfer-sh)

(defcustom transfer-sh-remote-suffix nil
  "A suffix added to each remote file name."
  :type 'string
  :group 'transfer-sh)

(defcustom transfer-sh-upload-agent-command
  (cond
   ((executable-find "curl")
    "curl")
   ((executable-find "wget")
    "wget"))
  "Command used to upload files to transfer.sh"
  :type 'string
  :group 'transfer-sh)

(defcustom transfer-sh-upload-agent-arguments
  (cond
   ((executable-find "curl")
    (list "--silent" "--upload-file"))
   ((executable-find "wget")
    (list "--method" "PUT" "--output-document" "-"  "--no-verbose" "--quiet" "--body-file")))
  "Suffix arguments to `transfer-sh-upload-agent-command'"
  :type '(repeat string)
  :group 'transfer-sh)

(defvar transfer-sh-gpg-keys-hash-table nil
  "Hash table storing available public GPG keys from the keyring.

Can be updated by calling function `transfer-sh-refresh-gpg-keys'.")

(defvar transfer-sh-gpg-key-reference-separator " - "
  "Separator used in the reference name of all GPG keys.")

;;;###autoload
(defun transfer-sh-upload-file-async (local-filename &optional remote-filename)
  "Upload file LOCAL-FILENAME to transfer.sh in background.

REMOTE-FILENAME is the name used in the transfer.sh link. If not
provided, query the user.

This function uses `transfer-sh-run-upload-agent'."
  (interactive "ffile: ")
  (or remote-filename
      (setq remote-filename (url-encode-url
                             (read-from-minibuffer
                              (format "Remote filename (default %s): "
                                      (file-name-nondirectory local-filename))
                              (file-name-nondirectory local-filename)))))
  (async-start
   `(lambda ()
      ,(async-inject-variables "local-filename")
      ,(async-inject-variables "remote-filename")
      ,(transfer-sh-run-upload-agent local-filename remote-filename))))

;;;###autoload
(defun transfer-sh-upload-file (local-filename &optional remote-filename)
  "Uploads file LOCAL-FILENAME to transfer.sh.

REMOTE-FILENAME is the name used in the transfer.sh link. If not
provided, query the user.

This function uses `transfer-sh-run-upload-agent'."
  (interactive "ffile: ")
  (transfer-sh-run-upload-agent
   local-filename
   (or remote-filename
       (url-encode-url
        (read-from-minibuffer
         (format "Remote filename (default %s): "
                 (file-name-nondirectory local-filename))
         (file-name-nondirectory local-filename))))))

(defun transfer-sh-run-upload-agent (local-filename &optional remote-filename)
  "Upload LOCAL-FILENAME to transfer.sh using `transfer-sh-upload-agent-command'.

If no REMOTE-FILE is given, LOCAL-FILENAME is used."
  (let* ((filename-without-directory (file-name-nondirectory local-filename))
         (remote-filename (or remote-filename filename-without-directory))
         (transfer-link (with-temp-buffer
                          (apply 'call-process
                                 transfer-sh-upload-agent-command
                                 nil t nil
                                 (append transfer-sh-upload-agent-arguments
                                         (list local-filename
                                               (concat "https://transfer.sh/" remote-filename))))
                          (buffer-string))))
    (kill-new transfer-link)
    (minibuffer-message "File %S uploaded: %s" filename-without-directory transfer-link)))

;;;###autoload
(defalias 'transfer-sh-upload 'transfer-sh-upload-region)

;;;###autoload
(defun transfer-sh-upload-region (async)
  "Upload either active region or complete buffer to transfer.sh.

If a region is active, that region is exported to a file and then
uploaded, otherwise the complete buffer is uploaded.

This function uses `transfer-sh-upload-file' and
`transfer-sh-upload-file-async'."
  (interactive "P")
  (let* ((remote-filename (concat
                           transfer-sh-remote-prefix
                           (buffer-name)
                           transfer-sh-remote-suffix))
         (local-filename (if (use-region-p)
                             (progn
                               (write-region
                                (region-beginning)
                                (region-end)
                                transfer-sh-temp-file-location nil 0)
                               transfer-sh-temp-file-location)
                           (or buffer-file-name
                               (write-region
                                (point-min)
                                (point-max)
                                transfer-sh-temp-file-location nil 0)
                               transfer-sh-temp-file-location))))
    (funcall (if async
                 'transfer-sh-upload-file-async
               'transfer-sh-upload-file)
             local-filename)))

;;;###autoload
(defalias 'transfer-sh-upload-gpg 'transfer-sh-encrypt-upload-region)

;;;###autoload
(defun transfer-sh-encrypt-upload-region (async)
  "Encrypt and upload the active region/complete buffer to transfer.sh.

If a region is active, use that region, otherwise the complete
buffer.

Query user for the GPG key(s) to use for encryption. If no key is
selected by user, then use symmetric encryption (and ask for a
symmetric passphrase).

The encrypted file is stored in `temporary-file-directory' and
uploaded to transfer.sh using `transfer-sh-run-upload-agent'."
  (interactive "P")
  (or transfer-sh-gpg-keys-hash-table
      (transfer-sh-refresh-gpg-keys))
  (let* ((text (if (use-region-p)
                   (buffer-substring-no-properties (region-beginning)
                                                   (region-end))
                 (buffer-substring-no-properties (point-min)
                                                 (point-max))))
         (selected-keys (completing-read-multiple
                         "GPG keys (default is symetric encryption. Press <tab> for completion): "
                         transfer-sh-gpg-keys-hash-table))
         (cipher-text
          (condition-case
              epg-encryption-error
              (epg-encrypt-string (epg-context--make epa-protocol)
                                  text
                                  (and selected-keys
                                       (mapcar
                                        (lambda (reference)
                                          (gethash reference transfer-sh-gpg-keys-hash-table))
                                        selected-keys)))
            (epg-error
             (user-error "GPG-error: %s" (cdr epg-encryption-error)))))
         (default-filename (concat (buffer-name)
                                   ".gpg"))
         (remote-filename (read-from-minibuffer
                           (format "Remote filename (default %s): "
                                   default-filename)
                           default-filename))
         (file-to-be-uploaded (make-temp-file remote-filename)))
    (with-temp-buffer
      (insert cipher-text)
      (let ((buffer-file-coding-system 'no-conversion))
        (write-region (point-min)
                      (point-max)
                      file-to-be-uploaded)))
    (funcall (if async
                 'transfer-sh-upload-file-async
               'transfer-sh-upload-file)
             file-to-be-uploaded
             remote-filename)))

;;;###autoload
(defun transfer-sh-encrypt-upload-file (local-filename)
  "Encrypt LOCAL-FILENAME using gpg and upload file to transfer.sh.

Query user for the GPG key(s) to use for encryption. If no key is
selected by user, then use symmetric encryption (and ask for a
symmetric passphrase).

The encrypted file is stored in `temporary-file-directory' and uploaded to
transfer.sh using `transfer-sh-run-upload-agent'."
  (interactive "ffile: ")
  (or transfer-sh-gpg-keys-hash-table
      (transfer-sh-refresh-gpg-keys))
  (let* ((remote-filename (read-from-minibuffer
                           (format "Remote filename (default %s): "
                                   (concat
                                    (file-name-nondirectory local-filename)
                                    ".gpg"))
                           (concat
                            (file-name-nondirectory local-filename)
                            ".gpg")))
         (file-to-be-uploaded (make-temp-file remote-filename))
         (selected-keys (completing-read-multiple
                         "GPG keys (default is symetric encryption. Press <tab> for completion): "
                         transfer-sh-gpg-keys-hash-table)))
    (condition-case
        epg-encryption-error
        (epg-encrypt-file (epg-make-context epa-protocol)
                          local-filename
                          (mapcar
                           (lambda (reference)
                             (gethash reference transfer-sh-gpg-keys-hash-table))
                           selected-keys)
                          file-to-be-uploaded)
      (epg-error
       (user-error "GPG-error: %s" (cdr epg-encryption-error))))
    (transfer-sh-run-upload-agent file-to-be-uploaded remote-filename)))

;;;###autoload
(defun transfer-sh-refresh-gpg-keys ()
  "Generate a hash table containing all GPG keys in the key ring.

Each hash table entry is referred by a GPG key reference
generated by `transfer-sh-create-gpg-key-reference'."
  (interactive)
  (if transfer-sh-gpg-keys-hash-table
      (clrhash transfer-sh-gpg-keys-hash-table)
    (setq transfer-sh-gpg-keys-hash-table (make-hash-table
                                           :test 'equal)))
  (let ((keys (epg-list-keys
               (epg-make-context epa-protocol))))
    (dolist (key keys)
      (puthash
       (transfer-sh-create-gpg-key-reference key)
       key
       transfer-sh-gpg-keys-hash-table))))

(defun transfer-sh-create-gpg-key-reference (key)
  "Create a reference name for the GPG key KEY.

Return a string that contains the name, email and fingerprint of
KEY.  Separator between each field is controlled by
`transfer-sh-gpg-key-reference-separator'."
  (require 'rx)
  (let* ((user-id (split-string
                   (epg-user-id-string (car (epg-key-user-id-list key)))
                   (rx (or " <" ">"))
                   t))
         (name (car user-id))
         (email (nth 1 user-id))
         (fingerprint (epg-sub-key-id (car (epg-key-sub-key-list key)))))
    (concat
     name
     transfer-sh-gpg-key-reference-separator
     email
     transfer-sh-gpg-key-reference-separator
     fingerprint)))


(provide 'transfer-sh)

;;; transfer-sh.el ends here
