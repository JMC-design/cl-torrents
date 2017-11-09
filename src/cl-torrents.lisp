(in-package :cl-user)
(defpackage cl-torrents
  (:use :cl)
  ;; see also Quickutil to import only the utility we need.
  ;; http://quickutil.org/lists/
  (:import-from :alexandria
                :assoc-value ;; get the val of an alist alone, not the (key val) couple.
                :flatten)
  (:import-from :cl-torrents.utils
                :colorize-all-keywords
                :keyword-color-pairs
                :exit
                :sublist)
  (:export :torrents
           :magnet
           :main))
;; to do: shadow-import to use search as a funnction name.
(in-package :cl-torrents)

(defparameter *last-search* nil "Remembering the last search (should be an hash-map).")
(defparameter *nb-results* 20 "Maximum number of search results to display.")
(defparameter *keywords* '() "List of keywords given as input by the user.")
(defvar *keywords-colors* nil
  "alist associating a keyword with a color. See `keyword-color-pairs'.")

(setf lparallel:*kernel* (lparallel:make-kernel 2))

(defun torrents (words &key (stream t) (nb-results *nb-results*))
  "Search on the different websites."
  (let ((terms (if (listp words)
                   words
                   ;; The main function gives words as a list,
                   ;; the user at the REPL a string.
                   (str:words words)))
        (res (tpb::torrents words)))
        ;; (res (torrentcd::torrents words))) ;; next: async call and merge of the various scrapers.
    (setf *keywords* terms)
    (setf *keywords-colors* (keyword-color-pairs terms))
    (setf *last-search* res)
    (display-results :results res :stream stream :nb-results nb-results)))

(defun async-torrents (words)
  "Call the scrapers in parallel."
  ;; With mapcar, we get a list of results. With mapcan, the results are concatenated.
  (let* ((res (mapcan (lambda (fun)
                        (lparallel:pfuncall fun words))
                      '(tpb:torrents kat:torrents torrentcd:torrents)))
         (sorted (sort res (lambda (a b)
                             ;; maybe a quicker way, to just give the key ?
                             (< (assoc-value a :seeders)
                                (assoc-value b :seeders))))))
    sorted))

(defun display-results (&key (results *last-search*) (stream t) (nb-results *nb-results*))
  "Results: list of plump nodes. We want to print a numbered list with the needed information (torrent title, the number of seeders,... Print at most *nb-results*."
  (mapcar (lambda (it)
            ;; xxx: do not rely on *last-search*.
            ;; I want to color the output.
            ;; Adding color characters for the terminal augments the string length.
            ;; We want a string padding for the title of 65 chars.
            ;; We must add to the padding the length of the extra color markers,
            ;; thus we must compute it and format the format string before printing the title.
            (let* ((title (assoc-value it :title))
                   (title-colored (colorize-all-keywords title *keywords-colors*))
                   (title-padding (+ 65
                                     (- (length title-colored)
                                        (length title))))
                   ;; ~~ prints a ~ so here ~~~aa with title-padding gives ~65a or ~75a.
                   (format-string (format nil "~~3@a: ~~~aa ~~3@a/~~3@a~~%" title-padding)))

              (format stream format-string
                    (position it results)
                    title-colored
                    (assoc-value it :seeders)
                    (assoc-value it :leechers)
                    )))
          (reverse (sublist results 0 nb-results)))
  t)

(defun find-magnet-link (parsed)
  "Extract the magnet link. `parsed': plump:parse result."
  (let* ((hrefs (mapcar (lambda (it)
                          (lquery-funcs:attr it "href"))
                        (coerce (lquery:$ parsed "a") 'list)))
         (magnet (remove-if-not (lambda (it)
                                  (str:starts-with? "magnet" it))
                                hrefs)))
    (first magnet)))

(defun request-details (url)
  "Get the html page of the given url. Mocked in unit tests."
  (dex:get url))

(defun magnet-link-from (alist)
  "Extract the magnet link from a `torrent' result."
  (let* ((url (assoc-value alist :href))
         (html (request-details url))
         (parsed (plump:parse html)))
    (find-magnet-link parsed)))

(defun magnet (index)
  "Search the magnet from last search's `index''s result."
  ;TODO: for all scrapers.
  ;; yeah, we could give more than one index at once.
  (magnet-link-from (elt *last-search* index)))

(defun main ()
  "Parse command line arguments (portable way) and call the program."

  ;; Define the cli args.
  (opts:define-opts
    (:name :help
           :description "print this help text"
           :short #\h
           :long "help")
    (:name :nb-results
           :description "maximum number of results to print."
           :short #\n
           :long "nb"
           :arg-parser #'parse-integer)
    (:name :magnet
           :description "get the magnet link of the given search result."
           :short #\m
           :long "magnet"
           :arg-parser #'parse-integer))


  (multiple-value-bind (options free-args)
      ;; opts:get-opts returns the list of options, as parsed,
      ;; and the remaining free args as second value.
      ;; There is no error handling yet (specially for options not having their argument).
      (opts:get-opts)

    (if (getf options :help)
        (progn
          (opts:describe
           :prefix "CL-torrents. Usage:"
           :args "[keywords]")
          (exit)))
    (if (getf options :nb-results)
        (setf *nb-results* (getf options :nb-results)))

    (torrents free-args)

    (if (getf options :magnet)
        ;; if we had caching we wouldn't have to search for torrents first.
        (progn
          (format t "~a~&" (magnet (getf options :magnet)))
          (exit)))))
