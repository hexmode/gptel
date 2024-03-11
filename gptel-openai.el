;;; gptel-openai.el ---  ChatGPT suppport for gptel  -*- lexical-binding: t; -*-

;; Copyright (C) 2023  Karthik Chikmagalur

;; Author: Karthik Chikmagalur <karthikchikmagalur@gmail.com>

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This file adds support for the ChatGPT API to gptel

;;; Code:
(require 'cl-generic)
(eval-when-compile
  (require 'cl-lib))
(require 'map)

(defvar gptel-model)
(defvar gptel-stream)
(defvar gptel-use-curl)
(defvar gptel-backend)
(defvar gptel-temperature)
(defvar gptel-max-tokens)
(defvar gptel--system-message)
(defvar gptel--known-backends)
(defvar json-object-type)

(declare-function gptel--get-api-key "gptel")
(declare-function prop-match-value "text-property-search")
(declare-function text-property-search-backward "text-property-search")
(declare-function json-read "json")
(declare-function gptel-prompt-prefix-string "gptel")
(declare-function gptel-response-prefix-string "gptel")

;;; Common backend struct for LLM support
(cl-defstruct
    (gptel-backend (:constructor gptel--make-backend)
                   (:copier gptel--copy-backend))
  name host header protocol stream
  endpoint key models url curl-args)

;;; OpenAI (ChatGPT)
(cl-defstruct (gptel-openai (:constructor gptel--make-openai)
                            (:copier nil)
                            (:include gptel-backend)))

(cl-defmethod gptel-curl--parse-stream ((_backend gptel-openai) _info)
  (let* ((json-object-type 'plist)
         (content-strs))
    (condition-case nil
        (while (re-search-forward "^data:" nil t)
          (save-match-data
            (unless (looking-at " *\\[DONE\\]")
              (when-let* ((response (json-read))
                          (delta (map-nested-elt
                                  response '(:choices 0 :delta)))
                          (content (plist-get delta :content)))
                (push content content-strs)))))
      (error
       (goto-char (match-beginning 0))))
    (apply #'concat (nreverse content-strs))))

(cl-defmethod gptel--parse-response ((_backend gptel-openai) response _info)
  (map-nested-elt response '(:choices 0 :message :content)))

(cl-defmethod gptel--request-data ((_backend gptel-openai) prompts)
  "JSON encode PROMPTS for sending to ChatGPT."
  (let ((prompts-plist
         `(:model ,gptel-model
           :messages [,@prompts]
           :stream ,(or (and gptel-stream gptel-use-curl
                         (gptel-backend-stream gptel-backend))
                     :json-false))))
    (when gptel-temperature
      (plist-put prompts-plist :temperature gptel-temperature))
    (when gptel-max-tokens
      (plist-put prompts-plist :max_tokens gptel-max-tokens))
    prompts-plist))

(cl-defmethod gptel--parse-buffer ((_backend gptel-openai) &optional max-entries)
  (let ((prompts) (prop))
    (while (and
            (or (not max-entries) (>= max-entries 0))
            (setq prop (text-property-search-backward
                        'gptel 'response
                        (when (get-char-property (max (point-min) (1- (point)))
                                                 'gptel)
                          t))))
      (push (list :role (if (prop-match-value prop) "assistant" "user")
                  :content
                  (gptel--parse-prompt
                   gptel-backend (intern gptel-model) (prop-match-value prop)
                   (prop-match-beginning prop) (prop-match-end prop)))
            prompts)
      (and max-entries (cl-decf max-entries)))
    (cons (list :role "system"
                :content gptel--system-message)
          prompts)))

(declare-function org-element-context "org-element")
(declare-function org-element-property "org-element-ast")
(declare-function org-element-begin "org-element-ast")
(declare-function org-element-end "org-element-ast")
(defvar org-link-plain-re)
(declare-function org-export-inline-image-p "ox")

(cl-defgeneric gptel--parse-prompt (backend model responsep beg end)
  "Parse prompt between BEG and END.

BEG and END are the limits of the prompt.
BACKEND is the active gptel backend.
MODE is the current major mode.
RESPONSEP is true if the region is a gptel response.")

(cl-defmethod gptel--parse-prompt ((_backend gptel-openai) _model _responsep beg end)
  (string-trim
   (buffer-substring-no-properties beg end)
   (format "[\t\r\n ]*\\(?:%s\\)?[\t\r\n ]*"
           (regexp-quote (gptel-prompt-prefix-string)))
   (format "[\t\r\n ]*\\(?:%s\\)?[\t\r\n ]*"
           (regexp-quote (gptel-response-prefix-string)))))

(declare-function org-element-contents-end "org-element")
(declare-function org-element-contents-begin "org-element")
(declare-function org-element-lineage "org-element")

(defun gptel-org--object-stand-alone-p (object)
  (let ((par (org-element-lineage object 'paragraph)))
    (and (= (org-element-begin object)
            (save-excursion
              (goto-char (org-element-contents-begin par))
              (skip-chars-forward "\t ")
              (point)))                 ;account for leading space
                                        ;before object
         (<= (- (org-element-contents-end par)
                (org-element-end object))
             1))))

(cl-defmethod gptel--parse-prompt ((_backend gptel-openai) (_model (eql 'gpt-4-vision-preview))
                                   (_responsep (eql nil)) beg end
                                   &context (major-mode (eql 'org-mode)))
  (goto-char beg)
  (when (looking-at (format "[\t\r\n ]*\\(?:%s\\)?[\t\r\n ]*"
                            (regexp-quote (gptel-prompt-prefix-string))))
    (goto-char (match-end 0)))
  (let ((parts) (from-pt (point)))
    (while (re-search-forward org-link-plain-re end t)
      (when-let* ((link (org-element-context))
                  ((gptel-org--object-stand-alone-p link))
                  (raw-link (org-element-property :raw-link link))
                  (path (org-element-property :path link))
                  (type (org-element-property :type link))
                  ((member type '("file" "http" "https" "ftp"))))
        (cond
         ((equal type "file")
          (if (and (not (file-remote-p path))
                   (file-exists-p path)
                   (org-export-inline-image-p link))
              ;; Collect text up to this image, and
              ;; Collect this image
              (let ((ext (file-name-extension path)))
                (when (equal ext "jpg") (setq ext "jpeg"))
                (push `(:type "text" :text ,(buffer-substring-no-properties from-pt (org-element-begin link)))
                      parts)
                (push `(:type "image_url"
                        :image_url (:url ,(concat "data:image/" ext ";base64," (gptel--base64-encode path))))
                      parts)
                (goto-char (org-element-end link))
                (setq from-pt (point)))))
         ((and (member type '("http" "https" "ftp"))
               (string-match-p (image-file-name-regexp) path))
          ;; Collect text up to this image, and
          ;; Collect this image url
          (push `(:type "text" :text ,(buffer-substring-no-properties from-pt (org-element-begin link))) parts)
          (push `(:type "image_url" :image_url (:url ,raw-link)) parts)
          (goto-char (org-element-end link))
          (setq from-pt (point))))))
    (when (looking-back (format "[\t\r\n ]*\\(?:%s\\)?[\t\r\n ]*"
                                (regexp-quote (gptel-response-prefix-string)))
                        from-pt)
      (goto-char (match-beginning 0)))
    (push `(:type "text" :text ,(buffer-substring-no-properties from-pt (point))) parts)
    (goto-char beg)
    (apply #'vector (nreverse parts))))

;;;###autoload
(cl-defun gptel-make-openai
    (name &key curl-args models stream key
          (header
           (lambda () (when-let (key (gptel--get-api-key))
                   `(("Authorization" . ,(concat "Bearer " key))))))
          (host "api.openai.com")
          (protocol "https")
          (endpoint "/v1/chat/completions"))
  "Register an OpenAI API-compatible backend for gptel with NAME.

Keyword arguments:

CURL-ARGS (optional) is a list of additional Curl arguments.

HOST (optional) is the API host, typically \"api.openai.com\".

MODELS is a list of available model names.

STREAM is a boolean to toggle streaming responses, defaults to
false.

PROTOCOL (optional) specifies the protocol, https by default.

ENDPOINT (optional) is the API endpoint for completions, defaults to
\"/v1/chat/completions\".

HEADER (optional) is for additional headers to send with each
request. It should be an alist or a function that retuns an
alist, like:
((\"Content-Type\" . \"application/json\"))

KEY (optional) is a variable whose value is the API key, or
function that returns the key."
  (declare (indent 1))
  (let ((backend (gptel--make-openai
                  :curl-args curl-args
                  :name name
                  :host host
                  :header header
                  :key key
                  :models models
                  :protocol protocol
                  :endpoint endpoint
                  :stream stream
                  :url (if protocol
                           (concat protocol "://" host endpoint)
                         (concat host endpoint)))))
    (prog1 backend
      (setf (alist-get name gptel--known-backends
                       nil nil #'equal)
                  backend))))

;;; Azure
;;;###autoload
(cl-defun gptel-make-azure
    (name &key curl-args host
          (protocol "https")
          (header (lambda () `(("api-key" . ,(gptel--get-api-key)))))
          (key 'gptel-api-key)
          models stream endpoint)
  "Register an Azure backend for gptel with NAME.

Keyword arguments:

CURL-ARGS (optional) is a list of additional Curl arguments.

HOST is the API host.

MODELS is a list of available model names.

STREAM is a boolean to toggle streaming responses, defaults to
false.

PROTOCOL (optional) specifies the protocol, https by default.

ENDPOINT is the API endpoint for completions.

HEADER (optional) is for additional headers to send with each
request. It should be an alist or a function that retuns an
alist, like:
((\"Content-Type\" . \"application/json\"))

KEY (optional) is a variable whose value is the API key, or
function that returns the key.

Example:
-------

(gptel-make-azure
 \"Azure-1\"
 :protocol \"https\"
 :host \"RESOURCE_NAME.openai.azure.com\"
 :endpoint
 \"/openai/deployments/DEPLOYMENT_NAME/completions?api-version=2023-05-15\"
 :stream t
 :models \\='(\"gpt-3.5-turbo\" \"gpt-4\"))"
  (declare (indent 1))
  (let ((backend (gptel--make-openai
                  :curl-args curl-args
                  :name name
                  :host host
                  :header header
                  :key key
                  :models models
                  :protocol protocol
                  :endpoint endpoint
                  :stream stream
                  :url (if protocol
                           (concat protocol "://" host endpoint)
                         (concat host endpoint)))))
    (prog1 backend
      (setf (alist-get name gptel--known-backends
                       nil nil #'equal)
            backend))))

;; GPT4All
;;;###autoload
(defalias 'gptel-make-gpt4all 'gptel-make-openai
  "Register a GPT4All backend for gptel with NAME.

Keyword arguments:

CURL-ARGS (optional) is a list of additional Curl arguments.

HOST is where GPT4All runs (with port), typically localhost:8491

MODELS is a list of available model names.

STREAM is a boolean to toggle streaming responses, defaults to
false.

PROTOCOL specifies the protocol, https by default.

ENDPOINT (optional) is the API endpoint for completions, defaults to
\"/api/v1/completions\"

HEADER (optional) is for additional headers to send with each
request. It should be an alist or a function that retuns an
alist, like:
((\"Content-Type\" . \"application/json\"))

KEY (optional) is a variable whose value is the API key, or
function that returns the key. This is typically not required for
local models like GPT4All.

Example:
-------

(gptel-make-gpt4all
 \"GPT4All\"
 :protocol \"http\"
 :host \"localhost:4891\"
 :models \\='(\"mistral-7b-openorca.Q4_0.gguf\"))")

(provide 'gptel-openai)
;;; gptel-backends.el ends here
