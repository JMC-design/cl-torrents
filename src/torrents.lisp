(in-package :cl-user)
(defpackage torrents
  (:use :cl
        :torrents.models
        :clache
        :cl-ansi-text)
  (:import-from :torrents.utils
                :colorize-all-keywords
                :keyword-color-pairs
                :exit
                :arg-parser-failed
                :unknown-option
                :missing-arg
                :when-option
                :find-magnet-link
                :sublist)
  (:export :make-torrent
           :search-torrents
           :async-torrents
           :title
           :href
           :seeders
           :leechers
           :source
           :magnet
           :magnet-link-from
           :browse
           :download
           :url
           :*nb-results*
           :*browser*
           :*torrent-client*
           :*cache-p*
           :main))

;; this package will be used for the lisp init file.
(defpackage torrents.user
  (:use :cl))

(in-package :torrents)

(defparameter *version* (uiop:read-file-form (asdf:system-relative-pathname :torrents #p"version.lisp-expr")))

(defparameter *last-search* nil "Remembering the last search.")
(defparameter *nb-results* 20 "Maximum number of search results to display.")
(defparameter *keywords* '() "List of keywords given as input by the user.")
(defvar *keywords-colors* nil
  "alist associating a keyword with a color. See `keyword-color-pairs'.")

(defparameter *browser* "firefox"
  "Default browser, in case $BROWSER is not set.")

(defparameter *torrent-client* "transmission-gtk"
  "Default torrent client.")

(defparameter *torrent-clients-list* '("transmission-gtk")
  "List of available torrent clients, along with the optional command line options.")

;; Parameters below: create at startup, not at build time.
(defparameter *config-directory* nil
  "The directory to put configuration files.")

(defparameter *cache-p* t
  "If true, use the cache.")

(defparameter *cache-directory* nil
  "The directory where cl-torrents stores its cache.")

(defparameter *store* nil
  "Cache. The directory must exist.")


(defun ensure-cache ()
  (setf *config-directory* (merge-pathnames #p".cl-torrents/" (user-homedir-pathname)))
  (setf *cache-directory* (merge-pathnames #p"cache/" *config-directory*))
  (ensure-directories-exist *cache-directory*))

(defun ensure-cache-and-store ()
  (setf *store* (progn
                  (ensure-cache)
                  (make-instance 'file-store :directory *cache-directory*))))

(defun assoc-value (alist key &key (test #'equalp))
  ;; Don't import Alexandria just for that.
  ;; See also Quickutil to import only the utility we need.
  ;; http://quickutil.org/lists/
  (cdr (assoc key alist :test test)))

(defun save-results (terms val &key (store *store*))
  "Save results in cache."
  (when (and *cache-p* val)
    (setcache terms val store)))

(defun get-cached-results (terms &key (store *store*))
  (when *cache-p*
    (when (getcache terms store)
      ;; If the cached results are alists (old version), make them torrent objects.
      (let (results)
        (setf results (getcache terms store))
        (log:info "Got cached results for ~a" terms)
        (when (consp (first results))
          (log:info "This old cache is an alist, we need to make it an object.")
          (setf results (loop for res in results
                           :collect (make-torrent
                                     :title (assoc-value res :title)
                                     :href (assoc-value res :href)
                                     :seeders (assoc-value res :seeders)
                                     :leechers (assoc-value res :leechers)
                                     :source (assoc-value res :source))))
          (save-results terms results))

        results))))

(defun search-torrents (words &key (stream t) (nb-results *nb-results*) (log-stream t))
  "Search for torrents on the different sources and print the results, sorted by number of seeders.

  `words': a string (space-separated keywords) or a list of strings.
  `nb-results': max number of results to print.
  `log-stream': used in tests to capture (and ignore) some output.
  "
  ;; Better way to define those before but also for the executable ?
  (unless *cache-directory*
    (ensure-cache))
  (unless *store*
    (ensure-cache-and-store))
  (let ((res (async-torrents words :log-stream log-stream)))
    (display-results :results res :stream stream :nb-results nb-results)))

(defvar *scrapers-alist* '(("1337" . torrents.1337:torrents)
                           ("downloadsme" . torrents.downloadsme:torrents))
  "Alist to associate a scraper name (str, for a user config) to its
  symbol function to call.")

(defvar *torrents-list* (mapcar #'cdr *scrapers-alist*)
  "List of scraper functions to call. Modified after reading the
  user's conf files.")

(defun async-torrents (words &key (log-stream t))
  "Call the scrapers in parallel and sort by seeders."
  ;; With mapcar, we get a list of results. With mapcan, the results are concatenated.
  (unless *cache-directory*
    (ensure-cache))
  (unless *store*
    (ensure-cache-and-store))
  (unless lparallel:*kernel*
    (setf lparallel:*kernel* (lparallel:make-kernel 2)))
  (let* ((terms (if (listp words)
                    ;; The main function gives words as a list,
                    ;; the user at the REPL a string.
                    words
                    (str:words words)))
         (joined-terms (str:join "+" terms))
         (cached-res (get-cached-results joined-terms))
         (res (if cached-res
                  cached-res
                  (mapcan (lambda (fun)
                            (lparallel:pfuncall fun terms :stream log-stream))
                          *torrents-list*)))
         (sorted (sort res (lambda (a b)
                             ;; maybe a quicker way, to just give the key ?
                             (> (seeders a)
                                (seeders b))))))
    (setf *keywords* terms)
    (setf *keywords-colors* (keyword-color-pairs terms))
    (setf *last-search* sorted)
    (unless cached-res
      (save-results joined-terms sorted))
    sorted))

(defun display-results (&key (results *last-search*) (stream t) (nb-results *nb-results*) (infos nil))
  "Results: list of plump nodes. We want to print a numbered list with the needed information (torrent title, the number of seeders,... Print at most *nb-results*."
  (mapcar (lambda (it)
            ;; I want to color the output.
            ;; Adding color characters for the terminal augments the string length.
            ;; We want a string padding for the title of 65 chars.
            ;; We must add to the padding the length of the extra color markers,
            ;; thus we must compute it and format the format string before printing the title.
            ;;
            ;; xxx see also the v directive: https://stackoverflow.com/questions/48868555/in-common-lisp-format-how-does-recursive-formatting-work
            (let* ((title (title it))
                   (title-colored (colorize-all-keywords title *keywords-colors*))
                   (title-padding (+ 65
                                     (- (length title-colored)
                                        (length title))))
                   ;; ~~ prints a ~ so here ~~~aa with title-padding gives ~65a or ~75a.
                   (format-string (format nil "~~3@a: ~~~aa ~~4@a/~~4@a ~~a~~%" title-padding)))

              (format stream format-string
                    (position it results)
                    title-colored
                    (seeders it)
                    (leechers it)
                    (source it)
                    )
              (if infos
                  (format stream "~a~&" (href it)))))
          (reverse (sublist results 0 nb-results)))
  t)

(defun request-details (url)
  "Get the html page of the given url. Mocked in unit tests."
  (dex:get url))

(defun magnet-link-from (torrent)
  "Extract the magnet link from a `torrent' result.

   Return the first href of the page that starts with 'magnet'."
  (let* ((url (href torrent))
         (html (request-details url))
         (parsed (plump:parse html)))
    (find-magnet-link parsed)))

(defun magnet (index)
  "Search the magnet from last search's `index''s result."
  (when (stringp index)
    (setf index (parse-integer index)))
  (if *last-search*
      (if (< index (length *last-search*))
          (magnet-link-from (elt *last-search* index))
          (format t "The search returned ~a results, we can not access the magnet link n°~a.~&" (length *last-search*) index))
      (format t "no search results to get the magnet link from.~&")))

(defun url (index)
  "Return the url from last search's `index''s result."
  (when (stringp index)
    (setf index (parse-integer index)))
  (if *last-search*
      (if (< index (length *last-search*))
          (href (elt *last-search* index))
          (format t "index too big, the last search only returned ~a results.~&" (length *last-search*)))
      (format t "no search results to get the url from.~&")))

(defparameter *commands* '(
                           ("search" . "<keywords> search torrents")
                           ("magnet" . "<i> get magnet link from search result nb i") ;; with arg
                           ("details" . "toggle the display of details")
                           ("download" . "<i> download the given magnet link with a torrent client (transmission-gtk by default)")
                           ("nb-results" . "<n> set the number of results to print")
                           ;; "nb"
                           ;; ("info" . "print a recap")
                           ("url" . "<i> get the torrent's page url")
                           ("open" . "<i> open this torrent page with the default browser")
                           ("firefox" . "<i> open this torrent page with firefox")
                           ("version" . "print cl-torrents version")
                           ("help" . "print this help")
                           ("quit" . "quit")
                           )
  "List of alist tuples, a verb and its doc, for completion on the REPL.")

(defparameter *verbs* (mapcar #'first *commands*)
  "List of verbs for completion. Strings.")

(defun common-prefix (items)
  ;; tmp waiting for cl-str 0.5 in Quicklisp february.
  "Find the common prefix between strings.

   Uses the built-in `mismatch', that returns the position at which
   the strings fail to match.

   Example: `(str:common-prefix '(\"foobar\" \"foozz\"))` => \"foo\"

   - items: list of strings
   - Return: a string.

  "
  ;; thanks koji-kojiro/cl-repl
  (when items (subseq
               (car items)
               0
               (apply
                #'min
                (mapcar
                 #'(lambda (i) (or (mismatch (car items) i) (length i)))
                 (cdr items))))))

(defun select-completions (text list)
  "Select all verbs from `list' that start with `text'."
  (let ((els (remove-if-not (alexandria:curry #'str:starts-with? text)
                            list)))
    (if (cdr els)
        (cons (common-prefix els) els)
        els)))

(defun custom-complete (text start end)
  "Complete a symbol when the cursor is at the beginning of the prompt."
  (declare (ignore end))
  (if (zerop start)
      (select-completions text *verbs*)))

(defun browse-elt (index)
  (let ((url (url index))
        (browser (or (uiop:getenv "BROWSER")
                     *browser*)))
    (declare (ignorable browser))
    (if url
        (uiop:launch-program (list browser
                                   url))
        (format t "couldn't find the url of ~a, got ~a~&" index url))))

(defun browse (index)
  "Open firefox to this search result's url. Use from the repl."
  (when (stringp index)
    (setf index (parse-integer index)))
  (browse-elt index))

(defun download (index &optional (soft "transmission-gtk"))
  "Download with a torrent client."
  (when (stringp index)
    (setf index (parse-integer index)))
  (uiop:launch-program (list (find soft *torrent-clients-list* :test #'equal)
                             (magnet-link-from (elt *last-search* index)))))

;; (defun confirm ()
;;   "Ask confirmation. Nothing means yes."
;;   ;; use replic:confirm (refacto, take settings into account).
;;   (member (rl:readline :prompt (format nil  "~%Do you want to quit ? [Y]/n : "))
;;           '("y" "Y" "")
;;           :test 'equal))

(defun process-options ()
  "Post-process options that need it.
   Here, get and set the scrapers list (they are read as a simple string).
   Reading and setting options was done with replic.config:apply-config.
  "
  (handler-case
      (progn
        (ensure-cache-and-store)
        (when (replic.config:has-option-p "scrapers")
          (setf *torrents-list* (config-scrapers))))
    (error (c) (format *error-output* "~&Error processing options:~&~a~&" c))))


(defun main ()
  "Parse command line arguments, read the config files and call the program."

  ;; if not inside a function, can not build an executable (can not
  ;; save core with multiple threads running).
  (setf lparallel:*kernel* (lparallel:make-kernel 2))

  ;; Read config file(s).
  (replic.config:apply-config :replic)
  (replic.config:apply-config :torrents ".torrents.conf")
  ;; Process options that need it.
  (process-options)


  ;; Define the cli args.
  (opts:define-opts
    (:name :help
           :description "print this help text"
           :short #\h
           :long "help")
    (:name :version
           :description "print the version"
           :short #\v
           :long "version")
    (:name :nb-results
           :description "maximum number of results to print."
           :short #\n
           :long "nb"
           :arg-parser #'parse-integer)
    (:name :details
           :description "print more details (like the torrent's url)"
           :short #\d
           :long "details")
    (:name :magnet
           :description "get the magnet link of the given search result."
           :short #\m
           :long "magnet"
           :arg-parser #'parse-integer)
    (:name :open
           :description "open with a torrent client (transmission-gtk by default)."
           :short #\o
           :long "open"
           :arg-parser #'parse-integer)
    (:name :load
           :description "load this given lisp file before startup."
           :short #\l
           :long "load"
           :arg-parser #'identity)
    (:name :no-userinit
           :description "don't load the user's lisp init file."
           :long "no-userinit")
    (:name :interactive
           :description "enter an interactive repl"
           :short #\i
           :long "interactive"))


  (multiple-value-bind (options free-args)
      ;; opts:get-opts returns the list of options, as parsed,
      ;; and the remaining free args as second value.
      (handler-bind ((opts:unknown-option #'unknown-option)
                     (opts:missing-arg #'missing-arg)
                     (opts:arg-parser-failed #'arg-parser-failed))
        ;; (opts:missing-required-option) ;; => upcoming version
        (opts:get-opts))

    (if (getf options :help)
        (progn
          (opts:describe
           :prefix (format nil "CL-torrents version ~a. Usage:" *version*)
           :args "[keywords]")
          (exit)))

    (if (getf options :version)
        (progn
          (format t "cl-torrents version ~a~&" *version*)
          (exit)))

    ;; Load the given lisp file.
    (when (and (getf options :load)
               (probe-file (getf options :load)))
      (replic:load-init (getf options :load))
      (replic.completion:functions-to-commands :torrents.user))

    ;; Read the lisp init file.
    (unless (getf options :no-userinit)
      (replic:load-init (merge-pathnames  ".torrents.lisp" (user-homedir-pathname)))
      ;; and load the commands from it.
      (replic.completion:functions-to-commands :torrents.user))

    (if (getf options :nb-results)
        (setf *nb-results* (getf options :nb-results)))

    (if (getf options :interactive)
        (progn
          (setf replic:*prompt* (green "torrents > "))
          (replic.completion:functions-to-commands :replic.base)
          (replic.completion:functions-to-commands :torrents.commands)
          ;; xxx names consistency
          (replic.completion:add-variables-from :torrents) ;; ok

          (when free-args
            (display-results :results (async-torrents free-args)
                             :nb-results *nb-results*
                             :infos (getf options :infos)))
          (replic:repl)
          (uiop:quit)))

    ;; This is the only way I found to catch a C-c.
    ;; https://github.com/fukamachi/clack/blob/master/src/clack.lisp
    ;; trivial-signal didn't work (see issue #3)
    (unless free-args
      (format t "You didn't say what to search for.")
      (opts:describe)
      (uiop:quit))
    (handler-case
        (display-results :results (async-torrents free-args)
                         :nb-results *nb-results*
                         :infos (getf options :infos))
      (#+sbcl sb-sys:interactive-interrupt
        #+ccl  ccl:interrupt-signal-condition
        #+clisp system::simple-interrupt-condition
        #+ecl ext:interactive-interrupt
        #+allegro excl:interrupt-signal
        () (progn
             (format *error-output* "Aborting.~&")
             (exit)))
      (error (c) (format t "Woops, an unknown error occured:~&~a~&" c)))

    (if (getf options :magnet)
        (progn
          (format t "~a~&" (magnet (getf options :magnet)))))

    (if (getf options :open)
        (progn
          (format t "opening in external client...")
          (download (getf options :open))))

    (exit)))
