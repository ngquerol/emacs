;;; erc-dcc.el --- CTCP DCC module for ERC  -*- lexical-binding: t; -*-

;; Copyright (C) 1993-2025 Free Software Foundation, Inc.

;; Author: Ben A. Mesander <ben@gnu.ai.mit.edu>
;;         Noah Friedman <friedman@prep.ai.mit.edu>
;;         Per Persson <pp@sno.pp.se>
;; Maintainer: Amin Bandali <bandali@gnu.org>, F. Jason Park <jp@neverwas.me>
;; Keywords: comm
;; Created: 1994-01-23

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This file provides Direct Client-to-Client support for ERC.
;;
;; The original code was taken from zenirc-dcc.el, heavily mangled and
;; rewritten to support the way how ERC operates.  Server socket support
;; was added for DCC CHAT and SEND afterwards.  Thanks
;; to the original authors for their work.

;;; Usage:

;; To use this file, put
;;  (require 'erc-dcc)
;; in your .emacs.
;;
;; Provided commands
;;  /dcc chat nick - Either accept pending chat offer from nick, or offer
;;                   DCC chat to nick
;;  /dcc close type [nick] - Close DCC connection (SEND/GET/CHAT) with nick
;;  /dcc get [-t][-s] nick [--] file - Accept DCC offer from nick
;;  /dcc list - List all DCC offers/connections
;;  /dcc send nick file - Offer DCC SEND to nick

;;; Code:

(require 'erc)
;; Strictly speaking, should only be needed at compile time.
;; Require at run-time too to silence compiler.
(require 'pcomplete)

(defgroup erc-dcc nil
  "DCC stands for Direct Client Communication, where you and your
friend's client programs connect directly to each other,
bypassing IRC servers and their occasional \"lag\" or \"split\"
problems.  Like /MSG, the DCC chat is completely private.

Using DCC get and send, you can transfer files directly from and to other
IRC users."
  :group 'erc)

;;;###autoload(autoload 'erc-dcc-mode "erc-dcc")
(define-erc-module dcc nil
  "Provide Direct Client-to-Client support for ERC."
  ((add-hook 'erc-server-401-functions #'erc-dcc-no-such-nick))
  ((remove-hook 'erc-server-401-functions #'erc-dcc-no-such-nick)))

(defcustom erc-dcc-verbose nil
  "If non-nil, be verbose about DCC activity reporting."
  :type 'boolean)

(defconst erc-dcc-connection-types
  '("CHAT" "GET" "SEND")
  "List of valid DCC connection types.
All values of the list must be uppercase strings.")

(defvar erc-dcc-list nil
  "List of DCC connections.
Looks like:
  ((:nick \"nick!user@host\" :type GET :peer proc
    :parent proc :size size :file file)
   (:nick \"nick!user@host\" :type CHAT :peer proc :parent proc)
   (:nick \"nick\" :type SEND :peer server-proc :parent parent-proc :file
   file :sent <marker> :confirmed <marker>))

 :nick - a user or userhost for the peer.  Combine with :parent to reach them

 :type - the type of DCC connection - SEND for outgoing files, GET for
         incoming, and CHAT for both directions.  To tell which end started
         the DCC chat, look at :peer

 :peer - the other end of the DCC connection.  In the case of outgoing DCCs,
         this represents a server process until a connection is established

 :parent - the server process where the dcc connection was established.
           Note that this can be nil or an invalid process since a DCC
           connection is in general independent from a particular server
           connection after it was established.

 :file - for outgoing sends, the full path to the file.  For incoming sends,
         the suggested filename or vetted filename

 :size - size of the file, may be nil on incoming DCCs

 :secure - optional item indicating sender support for TLS

 :turbo - optional item indicating sender support for TSEND")

(defun erc-dcc-list-add (type nick peer parent &rest args)
  "Add a new entry of type TYPE to `erc-dcc-list' and return it."
  (car
   (setq erc-dcc-list
         (cons
          (append (list :nick nick :type type :peer peer :parent parent) args)
          erc-dcc-list))))

;; This function takes all the usual args as open-network-stream, plus one
;; more: the entry data from erc-dcc-list for this particular process.
(defvar erc-dcc-connect-function 'erc-dcc-open-network-stream)

(defun erc-dcc-open-network-stream (procname buffer addr port entry)
  ;; FIXME: Time to try activating this again!?
  (if nil;  (fboundp 'open-network-stream-nowait)  ;; this currently crashes
                                                   ;; cvs emacs
      (open-network-stream-nowait procname buffer addr port)
    (open-network-stream procname buffer addr port
                         :type (and (plist-get entry :secure) 'tls))))

(erc--define-catalog english
  ((dcc-chat-discarded
    . "DCC: previous chat request from %n (%u@%h) discarded")
   (dcc-chat-ended . "DCC: chat with %n ended %t: %e")
   (dcc-chat-no-request . "DCC: chat request from %n not found")
   (dcc-chat-offered . "DCC: chat offered by %n (%u@%h:%p)")
   (dcc-chat-offer . "DCC: offering chat to %n")
   (dcc-chat-accept . "DCC: accepting chat from %n")
   (dcc-chat-privmsg . "=%n= %m")
   (dcc-closed . "DCC: Closed %T from %n")
   (dcc-command-undefined
    . "DCC: %c undefined subcommand. GET, CHAT and LIST are defined.")
   (dcc-ctcp-errmsg . "DCC: `%s' is not a DCC subcommand known to this client")
   (dcc-ctcp-unknown . "DCC: unknown dcc command `%q' from %n (%u@%h)")
   (dcc-get-bytes-received . "DCC: %f: %b bytes received")
   (dcc-get-complete
    . "DCC: file %f transfer complete (%s bytes in %t seconds)")
   (dcc-get-failed . "DCC: file %f transfer failed at %s of %v in %t seconds")
   (dcc-get-cmd-aborted . "DCC: Aborted getting %f from %n")
   (dcc-get-file-too-long
    . "DCC: %f: File longer than sender claimed; aborting transfer")
   (dcc-get-notfound . "DCC: %n hasn't offered %f for DCC transfer")
   (dcc-list-head . "DCC: From      Type  Active  Size               Filename")
   (dcc-list-line . "DCC: --------  ----  ------  -----------------  --------")
   (dcc-list-item . "DCC: %-8n  %-4t  %-6a  %-17s  %f%u")
   (dcc-list-end  . "DCC: End of list.")
   (dcc-malformed . "DCC: error: %n (%u@%h) sent malformed request: %q")
   (dcc-privileged-port
    . "DCC: possibly bogus request: %p is a privileged port.")
   (dcc-request-bogus . "DCC: bogus dcc `%r' from %n (%u@%h)")
   (dcc-send-finished . "DCC: SEND of %f to %n finished (size %s)")
   (dcc-send-offered . "DCC: file %f offered by %n (%u@%h) (size %s)")
   (dcc-send-offer . "DCC: offering %f to %n")))

;;; Misc macros and utility functions

(defun erc-dcc-member (&rest args)
  "Return first matching entry in `erc-dcc-list' satisfying constraints in ARGS.
ARGS is a plist.  Return nil on no match.

The property :nick is treated specially, if it contains a `!' character,
it is treated as a nick!user@host string, and compared with the :nick property
value of the individual elements using `string-equal'.  Otherwise it is
compared with `erc-nick-equal-p' which is IRC case-insensitive."
  (let ((list erc-dcc-list)
        result test)
    ;; for each element in erc-dcc-list
    (while (and list (not result))
      (let ((elt (car list))
            (prem args)
            (cont t))
        ;; loop through the constraints
        (while (and prem cont)
          (let ((prop (car prem))
                (val (cadr prem)))
            (setq prem (cddr prem)
                  test (cadr (plist-member elt prop)))
            ;; if the property exists and is equal, we continue, else, try the
            ;; next element of the list
            (or (and (eq prop :nick) (string-search "!" val)
                     test (string-equal test val))
                (and (eq prop :nick)
                     test val
                     (erc-nick-equal-p
                      (erc-extract-nick test)
                      (erc-extract-nick val)))
                ;; not a nick
                (equal test val)
                (setq cont nil))))
        (if cont
            (setq result elt)
          (setq list (cdr list)))))
    result))

(defun erc-pack-int (value)
  "Convert integer into a packed string in network byte order, which is big-endian."
  ;; make sure value is not negative
  (when (< value 0)
    (error "ERC-DCC (erc-pack-int): packet size is negative"))
  ;; make sure size is not larger than 4 bytes
  (let ((len (if (= value 0) 0
               (ceiling (/ (ceiling (/ (log value) (log 2))) 8.0)))))
    (when (> len 4)
      (error "ERC-DCC (erc-pack-int): packet too large")))
  ;; pack
  (let ((str (make-string 4 0))
        (i 3))
    (while (and (>= i 0) (> value 0))
      (aset str i (% value 256))
      (setq value (/ value 256))
      (setq i (1- i)))
    str))

(defun erc-unpack-int (str)
  "Unpack a packed string into an integer."
  (let ((len (length str)))
    ;; strip leading 0-bytes
    (let ((start 0))
      (while (and (> len start) (eq (aref str start) 0))
        (setq start (1+ start)))
      (when (> start 0)
        (setq str (substring str start))
        (setq len (- len start))))
    ;; unpack
    (let ((num 0)
          (count 0))
      (while (< count len)
        (setq num (+ num (ash (aref str (- len count 1)) (* 8 count))))
        (setq count (1+ count)))
      num)))

(defconst erc-dcc-ipv4-regexp
  (concat "^"
          (mapconcat #'identity (make-list 4 "\\([0-9]\\{1,3\\}\\)") "\\.")
          "$"))

(defun erc-ip-to-decimal (ip)
  "Convert IP address to its decimal representation.
Argument IP is the address as a string.  The result is also a string."
  (interactive "sIP Address: ")
  (if (not (string-match erc-dcc-ipv4-regexp ip))
      (error "Not an IP address")
    (let* ((ips (mapcar
                 (lambda (str)
                   (let ((n (string-to-number str)))
                     (if (and (>= n 0) (< n 256))
                         n
                       (error "%d out of range" n))))
                 (split-string ip "\\.")))
           (res (+ (* (car ips) 16777216.0)
                   (* (nth 1 ips) 65536.0)
                   (* (nth 2 ips) 256.0)
                   (nth 3 ips))))
      (if (called-interactively-p 'interactive)
          (message "%s is %.0f" ip res)
        (format "%.0f" res)))))

(defun erc-decimal-to-ip (dec)
  "Convert a decimal representation DEC to an IP address.
The result is also a string."
  (when (stringp dec)
    (setq dec (string-to-number (concat dec ".0"))))
  (let* ((first (floor (/ dec 16777216.0)))
         (first-rest (- dec (* first 16777216.0)))
         (second (floor (/ first-rest 65536.0)))
         (second-rest (- first-rest (* second 65536.0)))
         (third (floor (/ second-rest 256.0)))
         (third-rest (- second-rest (* third 256.0)))
         (fourth (floor third-rest)))
    (format "%s.%s.%s.%s" first second third fourth)))

;;; Server code

(defcustom erc-dcc-listen-host nil
  "IP address to listen on when offering files.
Should be set to a string or nil.  If nil, automatic detection of
the host interface to use will be attempted."
  :type (list 'choice (list 'const :tag "Auto-detect" nil)
              (list 'string :tag "IP-address"
                    :valid-regexp erc-dcc-ipv4-regexp)))

(defcustom erc-dcc-public-host nil
  "IP address to use for outgoing DCC offers.
Should be set to a string or nil.  If nil, use the value of
`erc-dcc-listen-host'."
  :type (list 'choice (list 'const :tag "Same as erc-dcc-listen-host" nil)
              (list 'string :tag "IP-address"
                    :valid-regexp erc-dcc-ipv4-regexp)))

(defcustom erc-dcc-send-request 'ask
  "How to treat incoming DCC Send requests.
`ask' - Report the Send request, and wait for the user to manually accept it
        You might want to set `erc-dcc-auto-masks' for this.
`auto' - Automatically accept the request and begin downloading the file
`ignore' - Ignore incoming DCC Send requests completely."
  :type '(choice (const ask) (const auto) (const ignore)))

(defun erc-dcc-get-host (proc)
  "Return the local IP address used for an open process PROC."
  (format-network-address (process-contact proc :local) t))

(defun erc-dcc-host ()
  "Determine the IP address we are using.
If variable `erc-dcc-host' is non-nil, use it.  Otherwise call
`erc-dcc-get-host' on the erc-server-process."
  (or erc-dcc-listen-host (erc-dcc-get-host erc-server-process)
      (error "Unable to determine local address")))

(defcustom erc-dcc-port-range nil
  "If nil, any available user port is used for outgoing DCC connections.
If set to a cons, it specifies a range of ports to use in the form (min . max)"
  :type '(choice
          (const :tag "Any port" nil)
          (cons :tag "Port range"
                (integer :tag "Lower port")
                (integer :tag "Upper port"))))

(defcustom erc-dcc-auto-masks nil
  "List of regexps matching user identifiers whose DCC send offers should be
accepted automatically.  A user identifier has the form \"nick!login@host\".
For instance, to accept all incoming DCC send offers automatically, add the
string \".*!.*@.*\" to this list."
  :type '(repeat regexp))

(defun erc-dcc-server (name filter sentinel)
  "Start listening on a port for an incoming DCC connection.
Returns the newly created subprocess, or nil."
  (let ((port (or (and erc-dcc-port-range (car erc-dcc-port-range)) t))
        (upper (and erc-dcc-port-range (cdr erc-dcc-port-range)))
        process)
    (while (not process)
      (condition-case err
          (progn
            (setq process
                  (make-network-process :name name
                                        :buffer nil
                                        :host (erc-dcc-host)
                                        :service port
                                        :noquery nil
                                        :filter filter
                                        :sentinel sentinel
                                        :log #'erc-dcc-server-accept
                                        :server t))
            (when (processp process)
              (when (fboundp 'set-process-coding-system)
                (set-process-coding-system process 'binary 'binary))))
        (file-error
         (unless (and (string= "Cannot bind server socket" (nth 1 err))
                      (string= "address already in use" (downcase (nth 2 err))))
           (signal (car err) (cdr err)))
         (setq port (1+ port))
         (unless (< port upper)
           (error "No available ports in erc-dcc-port-range")))))
    process))

(defun erc-dcc-server-accept (server client message)
  "Log an accepted DCC offer, then terminate the listening process and set up
the accepted connection."
  (erc-log (format "(erc-dcc-server-accept): server %s client %s message %s"
           server client message))
  (when (and (string-match "^accept from " message)
             (processp server) (processp client))
    (let ((elt (erc-dcc-member :peer server)))
      ;; change the entry in erc-dcc-list from the listening process to the
      ;; accepted process
      (setq elt (plist-put elt :peer client))
      ;; delete the listening process, as we've accepted the connection
      (delete-process server))))

;;; Interactive command handling

(defcustom erc-dcc-get-default-directory nil
  "Default directory for incoming DCC file transfers.
If this is nil, then the current value of `default-directory' is used."
  :type '(choice (const :value nil :tag "Default directory") directory))

;;;###autoload
(defun erc-cmd-DCC (line &rest compat-args)
  "Parser for /dcc command.
This figures out the dcc subcommand and calls the appropriate routine to
handle it.  The function dispatched should be named \"erc-dcc-do-FOO-command\",
where FOO is one of CLOSE, GET, SEND, LIST, CHAT, etc."
  (let (cmd args)
    ;; Called as library function (i.e., not directly as /dcc)
    (if compat-args
        (setq cmd line
              args compat-args)
      (setq args (delete "" (erc--split-string-shell-cmd line))
            cmd (pop args)))
    (let ((fn (intern-soft (concat "erc-dcc-do-" (upcase cmd) "-command"))))
      (if fn
          (apply fn erc-server-process args)
        (erc-display-message
         nil 'notice 'active
         'dcc-command-undefined ?c cmd)
        (apropos "erc-dcc-do-.*-command")
        t))))

(put 'erc-cmd-DCC 'do-not-parse-args t)
(autoload 'pcomplete-erc-all-nicks "erc-pcomplete")

;;;###autoload(put 'erc-cmd-DCC 'erc--cmd-help 'erc-dcc--cmd-help)
(defun erc-dcc--cmd-help (&rest args)
  (describe-function
   (or (and args (intern-soft (concat "erc-dcc-do-"
                                      (upcase (car args)) "-command")))
       'erc-cmd-DCC)))

;;;###autoload
(defun pcomplete/erc-mode/DCC ()
  "Provide completion for the /DCC command."
  (pcomplete-here (append '("chat" "close" "get" "list")
                          (when (fboundp 'make-network-process) '("send"))))
  (when (equal "get" (downcase (pcomplete-arg 1)))
    (pcomplete-opt "ts")
    (pcomplete-opt (if (equal "-s" (pcomplete-arg 'first 2)) "t" "s")))
  (pcomplete-here
   (pcase (intern (downcase (pcomplete-arg 'first 1)))
     ('chat (mapcar (lambda (elt) (plist-get elt :nick))
                    (cl-remove-if-not
                     (lambda (elt)
                       (eq (plist-get elt :type) 'CHAT))
                     erc-dcc-list)))
     ('close (delete-dups
              (mapcar (lambda (elt) (symbol-name (plist-get elt :type)))
                      erc-dcc-list)))
     ('get (mapcar #'erc-dcc-nick
                   (cl-remove-if-not
                    (lambda (elt)
                      (eq (plist-get elt :type) 'GET))
                    erc-dcc-list)))
     ('send (pcomplete-erc-all-nicks))))
  (when (equal "get" (downcase (pcomplete-arg 'first 1)))
    (pcomplete-opt "-"))
  (pcomplete-here
   (pcase (intern (downcase (pcomplete-arg 'first 1)))
     ('get (mapcar (lambda (elt)
                     (combine-and-quote-strings (list (plist-get elt :file))))
                   (cl-remove-if-not
                    (lambda (elt)
                      (and (eq (plist-get elt :type) 'GET)
                           (erc-nick-equal-p (erc-extract-nick
                                              (plist-get elt :nick))
                                             (pcase (pcomplete-arg 1)
                                               ("--" (pcomplete-arg 2))
                                               (v v)))))
                    erc-dcc-list)))
     ('close (mapcar #'erc-dcc-nick
                     (cl-remove-if-not
                      (lambda (elt)
                        (eq (plist-get elt :type)
                            (intern (upcase (pcomplete-arg 1)))))
                      erc-dcc-list)))
     ('send (pcomplete-entries)))))

(defun erc-dcc-do-CHAT-command (proc &optional nick)
  (when nick
    (let ((elt (erc-dcc-member :nick nick :type 'CHAT :parent proc)))
      (if (and elt (not (processp (plist-get elt :peer))))
          ;; accept an existing chat offer
          ;; FIXME: perhaps /dcc accept like other clients?
          (progn (erc-dcc-chat-accept elt erc-server-process)
                 (erc-display-message
                  nil 'notice 'active
                  'dcc-chat-accept ?n nick)
                 t)
        (erc-dcc-chat nick erc-server-process)
        (erc-display-message
         nil 'notice 'active
         'dcc-chat-offer ?n nick)
        t))))

(defun erc-dcc-do-CLOSE-command (_proc &optional type nick)
  "Close a connection.  Usage: /dcc close type nick.
At least one of TYPE and NICK must be provided."
  ;; disambiguate type and nick if only one is provided
  (when (and type (null nick)
             (not (member (upcase type) erc-dcc-connection-types)))
    (setq nick type)
    (setq type nil))
  ;; validate nick argument
  (unless (and nick (string-match (concat "\\`" erc-valid-nick-regexp "\\'")
                                  nick))
    (setq nick nil))
  ;; validate type argument
  (if (and type (member (upcase type) erc-dcc-connection-types))
      (setq type (intern (upcase type)))
    (setq type nil))
  (when (or nick type)
    (let ((ret t))
      (while ret
        (cond ((and nick type)
               (setq ret (erc-dcc-member :type type :nick nick)))
              (nick
               (setq ret (erc-dcc-member :nick nick)))
              (type
               (setq ret (erc-dcc-member :type type)))
              (t
               (setq ret nil)))
        (when ret
          ;; found a match - delete process if it exists.
          (and (processp (plist-get ret :peer))
               (delete-process (plist-get ret :peer)))
          (setq erc-dcc-list (delq ret erc-dcc-list))
          (erc-display-message
           nil 'notice 'active
           'dcc-closed
           ?T (plist-get ret :type)
           ?n (erc-extract-nick (plist-get ret :nick))))))
    t))

(defun erc-dcc-do-GET-command (proc &rest args)
  "Perform a DCC GET command.
Recognize input conforming to the following usage syntax:

  /DCC GET [-t|-s] nick [--] filename

  nick     The person who is sending the file.
  filename The filename to be downloaded.  Can be split into multiple
           arguments that are then joined by a space.
  flags    \"-t\" sets `:turbo' in `erc-dcc-list'
           \"-s\" sets `:secure' in `erc-dcc-list'
           \"--\" indicates end of options
           All of which are optional.

Expect PROC to be the server process and ARGS to contain
everything after the subcommand \"GET\" in the usage description
above."
  ;; Despite the advertised syntax above, we currently respect flags
  ;; in these positions: [flag] nick [flag] filename [flag]
  (let* ((trailing (and-let* ((trailing (member "--" args)))
                     (setq args (butlast args (length trailing)))
                     (cdr trailing)))
         (args (seq-group-by (lambda (s) (eq ?- (aref s 0))) args))
         (flags (prog1 (cdr (assq t args))
                  (setq args (nconc (cdr (assq nil args)) trailing))))
         (nick (pop args))
         (file (and args (mapconcat #'identity args " ")))
         (elt (erc-dcc-member :nick nick :type 'GET :file file))
         (filename (or file (plist-get elt :file) "unknown")))
    (if elt
        (let* ((file (read-file-name
                      (format-prompt "Local filename"
                                     (file-name-nondirectory filename))
                      (or erc-dcc-get-default-directory
                          default-directory)
                      (expand-file-name (file-name-nondirectory filename)
                                        (or erc-dcc-get-default-directory
                                            default-directory)))))
          (cond ((file-exists-p file)
                 (if (yes-or-no-p (format "File %s exists.  Overwrite? "
                                          file))
                     (erc-dcc-get-file elt file proc)
                   (erc-display-message
                    nil '(notice error) proc
                    'dcc-get-cmd-aborted
                    ?n nick ?f filename)))
                (t
                 (erc-dcc-get-file elt file proc)))
          (when (member "-s" flags)
            (setq erc-dcc-list (cons (plist-put elt :secure t)
                                     (delq elt erc-dcc-list))))
          (when (member "-t" flags)
            (setq erc-dcc-list (cons (plist-put elt :turbo t)
                                     (delq elt erc-dcc-list)))))
      (erc-display-message
       nil '(notice error) 'active
       'dcc-get-notfound ?n nick ?f filename))))

(defvar-local erc-dcc-byte-count nil)

(defun erc-dcc-do-LIST-command (_proc)
  "This is the handler for the /dcc list command.
It lists the current state of `erc-dcc-list' in an easy to read manner."
  (let ((alist erc-dcc-list)
        size elt)
    (erc-display-message
     nil 'notice 'active
     'dcc-list-head)
    (erc-display-message
     nil 'notice 'active
     'dcc-list-line)
    (while alist
      (setq elt (car alist)
            alist (cdr alist))

      (setq size (or (and (plist-member elt :size)
                          (plist-get elt :size))
                     ""))
      (setq size
            (cond ((null size) "")
                 ((numberp size) (number-to-string size))
                 ((string= size "") "unknown")))
      (erc-display-message
       nil 'notice 'active
       'dcc-list-item
       ?n (erc-dcc-nick elt)
       ?t (plist-get elt :type)
       ?a (if (processp (plist-get elt :peer))
              (process-status (plist-get elt :peer))
            "no")
       ?s (concat size
                  ;; FIXME consider uniquified names, e.g., foo.bin<2>
                  (if (and (eq 'GET (plist-get elt :type))
                           (plist-member elt :file)
                           (buffer-live-p (get-buffer (plist-get elt :file)))
                           (plist-member elt :size))
                      (let ((byte-count (with-current-buffer
                                            (plist-get elt :file)
                                          (+ (buffer-size) 0.0
                                             erc-dcc-byte-count))))
                        (format " (%d%%)"
                                (floor (* 100.0 byte-count)
                                       (plist-get elt :size))))))
       ?f (or (and (plist-member elt :file) (plist-get elt :file)) "")
       ?u (if-let* ((flags (concat (and (plist-get elt :turbo) "t")
                                   (and (plist-get elt :secure) "s")))
                    ((not (string-empty-p flags))))
              (concat " (" flags ")")
            "")))
    (erc-display-message
     nil 'notice 'active
     'dcc-list-end)
    t))

(defun erc-dcc-do-SEND-command (proc nick &rest file)
  "Offer FILE to NICK by sending a ctcp dcc send message.
If FILE is split into multiple arguments, re-join the arguments,
separated by a space."
  (setq file (and file (mapconcat #'identity file " ")))
  (if (file-exists-p file)
      (progn
        (erc-display-message
         nil 'notice 'active
         'dcc-send-offer ?n nick ?f file)
        (erc-dcc-send-file nick file) t)
    (erc-display-message nil '(notice error) proc "File not found") t))

;;; Server message handling (i.e. messages from remote users)

;;;###autoload
(defvar erc-ctcp-query-DCC-hook '(erc-ctcp-query-DCC)
  "Hook variable for CTCP DCC queries.")

(defvar erc-dcc-query-handler-alist
  '(("SEND" . erc-dcc-handle-ctcp-send)
    ("TSEND" . erc-dcc-handle-ctcp-send)
    ("SSEND" . erc-dcc-handle-ctcp-send)
    ("TSSEND" . erc-dcc-handle-ctcp-send)
    ("STSEND" . erc-dcc-handle-ctcp-send)
    ("CHAT" . erc-dcc-handle-ctcp-chat)))

;;;###autoload
(defun erc-ctcp-query-DCC (proc nick login host to query)
  "The function called when a CTCP DCC request is detected by the client.
It examines the DCC subcommand, and calls the appropriate routine for
that subcommand."
  (let* ((cmd (cadr (split-string query " ")))
         (handler (cdr (assoc cmd erc-dcc-query-handler-alist))))
    (if handler
        (funcall handler proc query nick login host to)
      ;; FIXME: Send a ctcp error notice to the remote end?
      (erc-display-message
       nil '(notice error) proc
       'dcc-ctcp-unknown
       ?q query ?n nick ?u login ?h host))))

(defconst erc-dcc-ctcp-query-send-regexp
  (rx bot "DCC " (group-n 6 (: (** 0 2 (any "TS")) "SEND")) " "
          ;; Following part matches either filename without spaces
          ;; or filename enclosed in double quotes with any number
          ;; of escaped double quotes inside.
      (: (or (: ?\" (group-n 1 (+ (or (: ?\\ ?\") (not (any ?\" ?\\))))) ?\")
             (group-n 2 (+ (not " ")))))
      (: " " (group-n 3 (+ digit))
         " " (group-n 4 (+ digit))
         (* " ") (group-n 5 (* digit)))
      eot))

(define-inline erc-dcc-unquote-filename (filename)
  (inline-quote
   (string-replace "\\\\" "\\" (string-replace "\\\"" "\"" ,filename))))

(defun erc-dcc-handle-ctcp-send (proc query nick login host to)
  "This is called if a CTCP DCC SEND subcommand is sent to the client.
It extracts the information about the dcc request and adds it to
`erc-dcc-list'."
  (unless (eq erc-dcc-send-request 'ignore)
    (cond
     ((not (erc-current-nick-p to))
      ;; DCC SEND requests must be sent to you, and you alone.
      (erc-display-message
       nil 'notice proc
       'dcc-request-bogus
       ?r "SEND" ?n nick ?u login ?h host))
     ((string-match erc-dcc-ctcp-query-send-regexp query)
      (let* ((filename (or (match-string 2 query)
                           (erc-dcc-unquote-filename (match-string 1 query))))
             (ip (erc-decimal-to-ip (match-string 3 query)))
             (port (match-string 4 query))
             (size (match-string 5 query))
             (sub (substring (match-string 6 query) 0 -4))
             (secure (string-search "S" sub))
             (turbo (string-search "T" sub)))
        ;; FIXME: a warning really should also be sent
        ;; if the ip address != the host the dcc sender is on.
        (erc-display-message
         nil 'notice proc
         'dcc-send-offered
         ?f filename ?n nick ?u login ?h host
         ?s (if (string= size "") "unknown" size))
        (and (< (string-to-number port) 1025)
             (erc-display-message
              nil 'notice proc
              'dcc-privileged-port
              ?p port))
        (erc-dcc-list-add
         'GET (format "%s!%s@%s" nick login host)
         nil proc
         :ip ip :port port :file filename
         :size (string-to-number size)
         :turbo (and turbo t)
         :secure (and secure t))
        (if (and (eq erc-dcc-send-request 'auto)
                 (erc-dcc-auto-mask-p (format "\"%s!%s@%s\"" nick login host)))
            (erc-dcc-get-file (car erc-dcc-list) filename proc))))
     (t
      (erc-display-message
       nil 'notice proc
       'dcc-malformed
       ?n nick ?u login ?h host ?q query)))))

(defun erc-dcc-auto-mask-p (spec)
  "Match SPEC against `erc-dcc-auto-masks'.
SPEC is a full spec of a user in the form \"nick!login@host\", which
is matched against all the regexps in `erc-dcc-auto-masks'.  Return
the matching regexp, or nil if none found."
  (let ((lst erc-dcc-auto-masks))
    (while (and lst
                (not (string-match (car lst) spec)))
      (setq lst (cdr lst)))
    (and lst (car lst))))

(defconst erc-dcc-ctcp-query-chat-regexp
  "^DCC CHAT +chat +\\([0-9]+\\) +\\([0-9]+\\)")

(defcustom erc-dcc-chat-request 'ask
  "How to treat incoming DCC Chat requests.
`ask' - Report the Chat request, and wait for the user to manually accept it
`auto' - Automatically accept the request and open a new chat window
`ignore' - Ignore incoming DCC chat requests completely."
  :type '(choice (const ask) (const auto) (const ignore)))

(defun erc-dcc-handle-ctcp-chat (proc query nick login host to)
  (unless (eq erc-dcc-chat-request 'ignore)
    (cond
     (;; DCC CHAT requests must be sent to you, and you alone.
      (not (erc-current-nick-p to))
      (erc-display-message
       nil '(notice error) proc
       'dcc-request-bogus ?r "CHAT" ?n nick ?u login ?h host))
     ((string-match erc-dcc-ctcp-query-chat-regexp query)
      ;; We need to use let* here, since erc-dcc-member might clutter
      ;; the match value.
      (let* ((ip   (erc-decimal-to-ip (match-string 1 query)))
             (port (match-string 2 query))
             (elt  (erc-dcc-member :nick nick :type 'CHAT)))
        ;; FIXME: A warning really should also be sent if the ip
        ;; address != the host the dcc sender is on.
        (erc-display-message
         nil 'notice proc
         'dcc-chat-offered
         ?n nick ?u login ?h host ?p port)
        (and (< (string-to-number port) 1025)
             (erc-display-message
              nil 'notice proc
              'dcc-privileged-port ?p port))
        (cond (elt
               ;; XXX: why are we updating ip/port on the existing connection?
               (setq elt (plist-put (plist-put elt :port port) :ip ip))
               (erc-display-message
                nil 'notice proc
                'dcc-chat-discarded ?n nick ?u login ?h host))
              (t
               (erc-dcc-list-add
                'CHAT (format "%s!%s@%s" nick login host)
                nil proc
                :ip ip :port port)))
        (if (eq erc-dcc-chat-request 'auto)
            (erc-dcc-chat-accept (erc-dcc-member :nick nick :type 'CHAT)
                                 proc))))
     (t
      (erc-display-message
       nil '(notice error) proc
       'dcc-malformed ?n nick ?u login ?h host ?q query)))))


(defvar-local erc-dcc-entry-data nil
  "Holds the `erc-dcc-list' entry for this DCC connection.")

;;; SEND handling

(defcustom erc-dcc-block-size 1024
  "Block size to use for DCC SEND sessions."
  :type 'integer)

(defcustom erc-dcc-pump-bytes nil
  "If an integer, keep sending until that number of bytes are unconfirmed."
  :type '(choice (const nil) integer))

(define-inline erc-dcc-get-parent (proc)
  (inline-quote (plist-get (erc-dcc-member :peer ,proc) :parent)))

(defun erc-dcc-send-block (proc)
  "Send one block of data.
PROC is the process-object of the DCC connection.  Returns the number of
bytes sent."
  (let* ((elt (erc-dcc-member :peer proc))
         (confirmed-marker (plist-get elt :confirmed))
         (sent-marker (plist-get elt :sent)))
    (with-current-buffer (process-buffer proc)
      (when erc-dcc-verbose
        (erc-display-message
         nil 'notice (erc-dcc-get-parent proc)
         (format "DCC: Confirmed %d, sent %d, sending block now"
                 (- confirmed-marker (point-min))
               (- sent-marker (point-min)))))
      (let* ((end (min (+ sent-marker erc-dcc-block-size)
                       (point-max)))
             (string (buffer-substring-no-properties sent-marker end)))
        (when (< sent-marker end)
          (set-marker sent-marker end)
          (process-send-string proc string))
        (length string)))))

(defun erc-dcc-send-filter (proc string)
  (let* ((size (erc-unpack-int string))
         (elt (erc-dcc-member :peer proc))
         (parent (plist-get elt :parent))
         (sent-marker (plist-get elt :sent))
         (confirmed-marker (plist-get elt :confirmed)))
    (with-current-buffer (process-buffer proc)
      (set-marker confirmed-marker (+ (point-min) size))
      (cond
       ((and (= confirmed-marker sent-marker)
             (= confirmed-marker (point-max)))
        (erc-display-message
         nil 'notice parent
         'dcc-send-finished
         ?n (plist-get elt :nick)
         ?f buffer-file-name
         ?s (number-to-string (- sent-marker (point-min))))
        (setq erc-dcc-list (delete elt erc-dcc-list))
        (set-buffer-modified-p nil)
        (delete-process proc)
        (kill-buffer (current-buffer)))
       ((<= confirmed-marker sent-marker)
        (while (and (< (- sent-marker confirmed-marker)
                       (or erc-dcc-pump-bytes
                           erc-dcc-block-size))
                    (> (erc-dcc-send-block proc) 0))))
       ((> confirmed-marker sent-marker)
        (erc-display-message
         nil 'notice parent
         (format "DCC: Client confirmed too much (%s vs %s)!"
                 (marker-position confirmed-marker)
                 (marker-position sent-marker)))
        (set-buffer-modified-p nil)
        (delete-process proc)
        (kill-buffer (current-buffer)))))))

(defun erc-dcc-display-send (proc)
  (erc-display-message
   nil 'notice (erc-dcc-get-parent proc)
   (format "DCC: SEND connect from %s"
           (format-network-address (process-contact proc :remote)))))

(defcustom erc-dcc-send-connect-hook
  '(erc-dcc-display-send erc-dcc-send-block)
  "Hook run when remote end of a DCC SEND offer connected to your listening port."
  :type 'hook)

(defun erc-dcc-nick (plist)
  "Extract the nickname portion of the :nick property value in PLIST."
  (erc-extract-nick (plist-get plist :nick)))

(defun erc-dcc-send-sentinel (proc event)
  (let* ((elt (erc-dcc-member :peer proc)))
    (cond
     ((string-match "^open from " event)
      (when elt
        (let ((buf (marker-buffer (plist-get elt :sent))))
          (with-current-buffer buf
            (set-process-buffer proc buf)
            (setq erc-dcc-entry-data elt)))
        (run-hook-with-args 'erc-dcc-send-connect-hook proc))))))

(defun erc-dcc-find-file (file)
  (with-current-buffer (generate-new-buffer (file-name-nondirectory file))
    (insert-file-contents-literally file)
    (setq buffer-file-name file)
    (current-buffer)))

(defun erc-dcc-file-to-name (file)
  (with-temp-buffer
    (insert (file-name-nondirectory file))
    (subst-char-in-region (point-min) (point-max) ?  ?_ t)
    (buffer-string)))

(defun erc-dcc-send-file (nick file &optional pproc)
  "Open socket for incoming connections and send a CTCP send request to the
other client."
  (interactive "sNick: \nfFile: ")
  (when (null pproc) (if (processp erc-server-process)
                         (setq pproc erc-server-process)
                       (error "Can not find parent process")))
  (if (featurep 'make-network-process)
      (let* ((buffer (erc-dcc-find-file file))
             (size (buffer-size buffer))
             (start (with-current-buffer buffer
                      (point-min-marker)))
             (sproc (erc-dcc-server "dcc-send"
                                    'erc-dcc-send-filter
                                    'erc-dcc-send-sentinel))
             (contact (process-contact sproc)))
        (erc-dcc-list-add
         'SEND nick sproc pproc
         :file file :size size
         :sent start :confirmed (copy-marker start))
        (process-send-string
         pproc (format "PRIVMSG %s :\C-aDCC SEND %s %s %d %d\C-a\n"
                       nick (erc-dcc-file-to-name file)
                       (erc-ip-to-decimal (or erc-dcc-public-host
                                              (nth 0 contact)))
                       (nth 1 contact)
                       size)))
    (error "`make-network-process' not supported by your Emacs")))

;;; GET handling

(defcustom erc-dcc-receive-cache (* 1024 512)
  "Number of bytes to let the receive buffer grow before flushing it."
  :type 'integer)

(defvar-local erc-dcc-file-name nil)

(defun erc-dcc-get-file (entry file parent-proc)
  "Set up a transfer from the remote client to the local over a TCP connection.
This involves setting up a process filter and a process sentinel,
and making the connection."
  (let* ((buffer (generate-new-buffer (file-name-nondirectory file)))
         proc)
    (with-current-buffer buffer
      (fundamental-mode)
      (buffer-disable-undo (current-buffer))
      ;; This is necessary to have the buffer saved as-is in GNU
      ;; Emacs.
      (set-buffer-multibyte nil)

      (setq mode-line-process '(":%s")
            buffer-read-only t)
      (setq erc-dcc-file-name file)

      ;; Truncate the given file to size 0 before appending to it.
      (let ((inhibit-file-name-handlers
             (append '(jka-compr-handler image-file-handler)
                     inhibit-file-name-handlers))
            (inhibit-file-name-operation 'write-region))
        (write-region (point) (point) erc-dcc-file-name nil 'nomessage))

      (setq erc-server-process parent-proc)
      (setq erc-dcc-byte-count 0)
      (setq proc
            (funcall erc-dcc-connect-function
                     "dcc-get" buffer
                     (plist-get entry :ip)
                     (string-to-number (plist-get entry :port))
                     entry))
      (set-process-buffer proc buffer)
      (set-process-coding-system proc 'binary 'binary)
      (set-buffer-file-coding-system 'binary t)

      (set-process-filter proc #'erc-dcc-get-filter)
      (set-process-sentinel proc #'erc-dcc-get-sentinel)
      (setq erc-dcc-entry-data (plist-put (plist-put entry :peer proc)
                                          :start-time (erc-current-time))))))

(defun erc-dcc-append-contents (buffer _file)
  "Append the contents of BUFFER to FILE.
The contents of the BUFFER will then be erased."
  (with-current-buffer buffer
    (let ((coding-system-for-write 'binary)
          (inhibit-read-only t)
          (inhibit-file-name-handlers
           (append '(jka-compr-handler image-file-handler)
                   inhibit-file-name-handlers))
          (inhibit-file-name-operation 'write-region))
      (write-region (point-min) (point-max) erc-dcc-file-name t 'nomessage)
      (setq erc-dcc-byte-count (+ (buffer-size) erc-dcc-byte-count))
      (erase-buffer))))

;; If people really need this, we can convert it into a proper option.

(defvar erc-dcc--send-final-turbo-ack nil
  "Workaround for maverick turbo senders that only require a final ACK.
The only known culprit is WeeChat, with its xfer.network.fast_send
option, which is on by default.  Leaving this set to nil and calling
/DCC GET -t works just fine, but WeeChat sees it as a failure even
though the file arrives in its entirety.  Setting this to t may
alleviate such problems.")

(defun erc-dcc-get-filter (proc str)
  "This is the process filter for transfers from other clients to this one.
It reads incoming bytes from the network and stores them in the DCC
buffer, and sends back the replies after each block of data per the DCC
protocol spec.  Well not really.  We write back a reply after each read,
rather than every 1024 byte block, but nobody seems to care."
  (with-current-buffer (process-buffer proc)
    (let ((inhibit-read-only t)
          received-bytes)
      (goto-char (point-max))
      (when str
        (cl-assert (not (multibyte-string-p str)))
        (insert str))

      (when (> (point-max) erc-dcc-receive-cache)
        (erc-dcc-append-contents (current-buffer) erc-dcc-file-name))
      (setq received-bytes (buffer-size))
      (if erc-dcc-byte-count
          (setq received-bytes (+ received-bytes erc-dcc-byte-count)))

      (and erc-dcc-verbose
           (erc-display-message
            nil 'notice erc-server-process
            'dcc-get-bytes-received
            ?f (file-name-nondirectory (buffer-name))
            ?b (number-to-string received-bytes)))
      (cond
       ((and (> (plist-get erc-dcc-entry-data :size) 0)
             (> received-bytes (plist-get erc-dcc-entry-data :size)))
        (erc-display-message
         nil '(notice error) 'active
         'dcc-get-file-too-long
         ?f (file-name-nondirectory (buffer-name)))
        (delete-process proc))
       ;; Some senders want us to hang up.  Only observed w. TSEND.
       ((and (plist-get erc-dcc-entry-data :turbo)
             (= received-bytes (plist-get erc-dcc-entry-data :size)))
        (when erc-dcc--send-final-turbo-ack
          (process-send-string proc (erc-pack-int received-bytes)))
        (delete-process proc))
       ((not (or (plist-get erc-dcc-entry-data :turbo)
                 (process-get proc :reportingp)))
        (process-put proc :reportingp t)
        (process-send-string proc (erc-pack-int received-bytes))
        (process-put proc :reportingp nil))))))

(defun erc-dcc-get-sentinel (proc event)
  "This is the process sentinel for CTCP DCC SEND connections.
It shuts down the connection and notifies the user that the
transfer is complete."
  ;; FIXME, we should look at EVENT, and also check size.
  (unless (member event '("connection broken by remote peer\n"
                          "deleted\n"))
    (lwarn 'erc :warning "Unexpected sentinel event %S for %s"
           (string-trim-right event) proc))
  (with-current-buffer (process-buffer proc)
    (delete-process proc)
    (setq erc-dcc-list (delete erc-dcc-entry-data erc-dcc-list))
    (unless (= (point-min) (point-max))
      (erc-dcc-append-contents (current-buffer) erc-dcc-file-name))
    (let ((done (= erc-dcc-byte-count (plist-get erc-dcc-entry-data :size))))
      (erc-display-message
       nil (if done 'notice '(notice error)) erc-server-process
       (if done 'dcc-get-complete 'dcc-get-failed)
       ?v (plist-get erc-dcc-entry-data :size)
       ?f erc-dcc-file-name
       ?s (number-to-string erc-dcc-byte-count)
       ?t (format "%.0f"
                  (erc-time-diff (plist-get erc-dcc-entry-data :start-time)
                                 nil))))
    (kill-buffer)))

;;; CHAT handling

(defcustom erc-dcc-chat-buffer-name-format "DCC-CHAT-%s"
  "Format to use for DCC Chat buffer names."
  :type 'string)

(defcustom erc-dcc-chat-mode-hook nil
  "Hook calls when `erc-dcc-chat-mode' finished setting up the buffer."
  :type 'hook)

(defcustom erc-dcc-chat-connect-hook nil
  "" ; FIXME
  :type 'hook)

(defcustom erc-dcc-chat-exit-hook nil
  "" ; FIXME
  :type 'hook)

(defun erc-cmd-CREQ (line &optional _force)
  "Set or get the DCC chat request flag.
Possible values are: ask, auto, ignore."
  (when (string-match "^\\s-*\\(auto\\|ask\\|ignore\\)?$" line)
    (let ((cmd (match-string 1 line)))
      (if (stringp cmd)
          (erc-display-message
           nil 'notice 'active
           (format "Set DCC Chat requests to %S"
                   (setq erc-dcc-chat-request (intern cmd))))
        (erc-display-message nil 'notice 'active
                             (format "DCC Chat requests are set to %S"
                                     erc-dcc-chat-request)))
      t)))

(defun erc-cmd-SREQ (line &optional _force)
  "Set or get the DCC send request flag.
Possible values are: ask, auto, ignore."
  (when (string-match "^\\s-*\\(auto\\|ask\\|ignore\\)?$" line)
    (let ((cmd (match-string 1 line)))
      (if (stringp cmd)
          (erc-display-message
           nil 'notice 'active
           (format "Set DCC Send requests to %S"
                   (setq erc-dcc-send-request (intern cmd))))
        (erc-display-message nil 'notice 'active
                             (format "DCC Send requests are set to %S"
                                     erc-dcc-send-request)))
      t)))

(defun pcomplete/erc-mode/CREQ ()
  (pcomplete-here '("auto" "ask" "ignore")))
(defalias 'pcomplete/erc-mode/SREQ #'pcomplete/erc-mode/CREQ)

(defvar erc-dcc-chat-filter-functions '(erc-dcc-chat-parse-output)
  "Abnormal hook run after parsing (and maybe inserting) a DCC message.
Each function is called with two arguments: the ERC process and
the unprocessed output.")

(defvar erc-dcc-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'erc-send-current-line)
    (define-key map "\t" #'completion-at-point)
    map)
  "Keymap for `erc-dcc-mode'.")

(define-derived-mode erc-dcc-chat-mode fundamental-mode "DCC-Chat"
  "Major mode for wasting time via DCC chat."
  (setq mode-line-process '(":%s")
        erc-send-input-line-function #'erc-dcc-chat-send-input-line
        erc-default-recipients '(dcc))
  (add-hook 'completion-at-point-functions #'erc-complete-word-at-point nil t))

(defun erc-dcc-chat-send-input-line (recipient line &optional _force)
  "Send LINE to the remote end.
Argument RECIPIENT should always be the symbol dcc, and force
is ignored."
  ;; FIXME: We need to get rid of all force arguments one day!
  (if (eq recipient 'dcc)
      (process-send-string
       (get-buffer-process (current-buffer)) line)
    (error "erc-dcc-chat-send-input-line in %s" (current-buffer))))

(defun erc-dcc-chat (nick &optional pproc)
  "Open a socket for incoming connections, and send a chat request to the
other client."
  (interactive "sNick: ")
  (when (null pproc) (if (processp erc-server-process)
                         (setq pproc erc-server-process)
                       (error "Can not find parent process")))
  (let* ((sproc (erc-dcc-server "dcc-chat-out"
                                'erc-dcc-chat-filter
                                'erc-dcc-chat-sentinel))
         (contact (process-contact sproc)))
    (erc-dcc-list-add 'OCHAT nick sproc pproc)
    (process-send-string pproc
     (format "PRIVMSG %s :\C-aDCC CHAT chat %s %d\C-a\n"
             nick
             (erc-ip-to-decimal (nth 0 contact)) (nth 1 contact)))))

(defvar erc-dcc-from)
(make-variable-buffer-local 'erc-dcc-from)

(defvar erc-dcc-unprocessed-output)
(make-variable-buffer-local 'erc-dcc-unprocessed-output)

(defun erc-dcc-chat-setup (entry)
  "Setup a DCC chat buffer, returning the buffer."
  (let* ((nick (erc-extract-nick (plist-get entry :nick)))
         (buffer (generate-new-buffer
                  (format erc-dcc-chat-buffer-name-format nick)))
         (proc (plist-get entry :peer))
         (parent-proc (plist-get entry :parent)))
    (erc-setup-buffer buffer)
    (with-current-buffer buffer
      (erc-dcc-chat-mode)
      (setq erc-server-process parent-proc
            erc-dcc-from nick
            erc-dcc-entry-data entry
            erc-dcc-unprocessed-output ""
            erc-input-marker (make-marker))
      (erc--initialize-markers (point) nil)
      (set-process-buffer proc buffer)
      (add-hook 'kill-buffer-hook #'erc-dcc-chat-buffer-killed nil t)
      (run-hook-with-args 'erc-dcc-chat-connect-hook proc))
    buffer))

(defun erc-dcc-chat-accept (entry parent-proc)
  "Accept an incoming DCC connection and open a DCC window."
  (let* (;; (nick (erc-extract-nick (plist-get entry :nick)))
         proc) ;; buffer
    (setq proc
          (funcall erc-dcc-connect-function
                   "dcc-chat" nil
                   (plist-get entry :ip)
                   (string-to-number (plist-get entry :port))
                   entry))
    ;; XXX: connected, should we kill the ip/port properties?
    (setq entry (plist-put entry :peer proc))
    (setq entry (plist-put entry :parent parent-proc))
    (set-process-filter proc #'erc-dcc-chat-filter)
    (set-process-sentinel proc #'erc-dcc-chat-sentinel)
    ;; (setq buffer
    (erc-dcc-chat-setup entry))) ;; )

(defun erc-dcc-chat-filter (proc str)
  (let ((orig-buffer (current-buffer)))
    (unwind-protect
        (progn
          (set-buffer (process-buffer proc))
          (setq erc-dcc-unprocessed-output
                (concat erc-dcc-unprocessed-output str))
          (run-hook-with-args 'erc-dcc-chat-filter-functions
                              proc erc-dcc-unprocessed-output))
      (set-buffer orig-buffer))))

(defun erc-dcc-chat-parse-output (proc str)
  (save-match-data
    (let ((posn 0)
          (erc--msg-prop-overrides `((erc--spkr . ,erc-dcc-from)))
          (nick (propertize (erc--speakerize-nick erc-dcc-from)
                            'font-lock-face 'erc-nick-default-face))
          line)
      (while (string-match "\n" str posn)
        (setq line (substring str posn (match-beginning 0)))
        (setq posn (match-end 0))
        (erc-display-message
         nil nil proc
         'dcc-chat-privmsg ?n nick ?m line))
      (setq erc-dcc-unprocessed-output (substring str posn)))))

(defun erc-dcc-chat-buffer-killed ()
  (erc-dcc-chat-close "killed buffer"))

(defun erc-dcc-chat-close (&optional event)
  "Close a DCC chat, removing any associated processes and tidying up
`erc-dcc-list'"
  (let ((proc (plist-get erc-dcc-entry-data :peer))
        (evt (or event "")))
    (when proc
      (setq erc-dcc-list (delq erc-dcc-entry-data erc-dcc-list))
      (run-hook-with-args 'erc-dcc-chat-exit-hook proc)
      (delete-process proc)
      (erc-display-message
       nil 'notice erc-server-process
       'dcc-chat-ended ?n erc-dcc-from ?t (current-time-string) ?e evt)
      (setq erc-dcc-entry-data (plist-put erc-dcc-entry-data :peer nil)))))

(defun erc-dcc-chat-sentinel (proc event)
  (let ((buf (current-buffer))
        (elt (erc-dcc-member :peer proc)))
    ;; the sentinel is also notified when the connection is opened, so don't
    ;; immediately kill it again
    ;(message "buf %s elt %S evt %S" buf elt event)
    (unwind-protect
        (if (string-match "^open from" event)
            (erc-dcc-chat-setup elt)
          (erc-dcc-chat-close event))
      (set-buffer buf))))

(defun erc-dcc-no-such-nick (proc parsed)
  "Detect and handle no-such-nick replies from the IRC server."
  (let* ((elt (erc-dcc-member :nick (nth 1 (erc-response.command-args parsed))
                              :parent proc))
         (peer (plist-get elt :peer)))
    (when (or (and (processp peer) (not (eq (process-status peer) 'open)))
              elt)
      ;; Since we already created an entry before sending the CTCP
      ;; message, we now remove it, if it doesn't point to a process
      ;; which is already open.
      (setq erc-dcc-list (delq elt erc-dcc-list))
      (if (processp peer) (delete-process peer)))
    nil))

(provide 'erc-dcc)

;;; erc-dcc.el ends here
;;
;; Local Variables:
;; generated-autoload-file: "erc-loaddefs.el"
;; End:
