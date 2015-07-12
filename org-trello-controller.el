;;; org-trello-controller.el --- Controller of org-trello mode
;;; Commentary:
;;; Code:

(require 'org-trello-setup)
(require 'org-trello-log)
(require 'org-trello-buffer)
(require 'org-trello-data)
(require 'org-trello-hash)
(require 'org-trello-api)
(require 'org-trello-entity)
(require 'org-trello-cbx)
(require 'org-trello-action)
(require 'org-trello-backend)
(require 'org-trello-buffer)
(require 'org-trello-input)
(require 'org-trello-proxy)
(require 's)
(require 'ido)

(org-trello/require-cl)

(defun orgtrello-controller/--list-user-entries (properties)
  "List the users entries from PROPERTIES."
  (--filter (string-match-p org-trello--label-key-user-prefix (car it)) properties))

(defun orgtrello-controller/hmap-id-name (org-keywords properties)
  "Given an ORG-KEYWORDS and a PROPERTIES, return a map.
This map is a key/value of (trello-id, trello-list-name-and-org-keyword-name).
If either org-keywords or properties is nil, return an empty hash-map."
  (if (or (null org-keywords) (null properties))
      (orgtrello-hash/empty-hash)
    (--reduce-from (orgtrello-hash/puthash-data (orgtrello-buffer/org-get-property it properties) it acc)
                   (orgtrello-hash/empty-hash)
                   org-keywords)))

(defun orgtrello-setup/display-current-buffer-setup!()
  "Display current buffer's setup."
  (list :users-id-name org-trello--hmap-users-id-name
        :users-name-id org-trello--hmap-users-name-id
        :user-logged-in org-trello--user-logged-in
        :org-keyword-trello-list-names org-trello--org-keyword-trello-list-names
        :org-keyword-id-name org-trello--hmap-list-orgkeyword-id-name))

(defun orgtrello-controller/setup-properties! (&optional args)
  "Setup the org-trello properties according to the 'org-mode' setup in the current buffer.
Return :ok.
ARGS is not used."
  ;; read the setup
  (orgtrello-action/reload-setup!)
  ;; now exploit some
  (let* ((org-keywords        (orgtrello-buffer/filtered-kwds!))
         (org-file-properties (orgtrello-buffer/org-file-properties!))
         (org-trello-users    (orgtrello-controller/--list-user-entries org-file-properties)))

    (setq org-trello--org-keyword-trello-list-names org-keywords)
    (setq org-trello--hmap-list-orgkeyword-id-name  (orgtrello-controller/hmap-id-name org-keywords org-file-properties))
    (setq org-trello--hmap-users-id-name            (orgtrello-hash/make-transpose-properties org-trello-users))
    (setq org-trello--hmap-users-name-id            (orgtrello-hash/make-properties org-trello-users))
    (orgtrello-setup/set-user-logged-in             (or (orgtrello-buffer/me!) (orgtrello-setup/user-logged-in)))

    (mapc (lambda (color) (add-to-list 'org-tag-alist color))
          '(("red" . ?r) ("green" . ?g) ("yellow" . ?y) ("blue" . ?b) ("purple" . ?p) ("orange" . ?o)))
    :ok))

(defun orgtrello-controller/control-properties! (&optional args)
  "Org-trello needs some header buffer properties set (board id, list ids, ...).
Return :ok if ok, or the error message if problems.
ARGS is not used."
  (let ((hmap-count (hash-table-count org-trello--hmap-list-orgkeyword-id-name)))
    (if (and (orgtrello-buffer/org-file-properties!) (orgtrello-buffer/board-id!) (= (length org-trello--org-keyword-trello-list-names) hmap-count))
        :ok
      "Setup problem.\nEither you did not connect your org-mode buffer with a trello board, to correct this:\n  * attach to a board through C-c o I or M-x org-trello-install-board-metadata\n  * or create a board from scratch with C-c o b or M-x org-trello-create-board-and-install-metadata).\nEither your org-mode's todo keyword list and your trello board lists are not named the same way (which they must).\nFor this, connect to trello and rename your board's list according to your org-mode's todo list.\nAlso, you can specify on your org-mode buffer the todo list you want to work with, for example: #+TODO: TODO DOING | DONE FAIL (hit C-c C-c to refresh the setup)")))

(defun orgtrello-controller/migrate-user-setup! (&optional args)
  "Migrate user's setup file.
From:
- ~/.trello/config.el to ~/.emacs.d/.trello/<trello-login>.el.
- Also the names of the constants have changed to *consumer-key* to
  org-trello-consumer-key and from *access-key* to org-trello-access-key.
ARGS is not used."
  (when (file-exists-p org-trello--old-config-dir) ;; ok, old setup exists, begin migration
    ;; load old setup
    (load org-trello--old-config-file)
    ;; write new setup
    (apply 'orgtrello-controller/--do-install-config-file (cons (orgtrello-buffer/me!)
                                                                (if *consumer-key*
                                                                    `(,*consumer-key* ,*access-token*)
                                                                  `(,org-trello-consumer-key ,org-trello-access-token))))
    ;; delete old setup file
    (delete-directory org-trello--old-config-dir 'with-contents))
  :ok)

(defun orgtrello-controller/config-file! (&optional username)
  "Determine the configuration file as per user logged in.
If USERNAME is supplied, do not look into the current buffer."
  (format org-trello--config-file (if username username (orgtrello-setup/user-logged-in))))

(defun orgtrello-controller/user-config-files ()
  "List the actual possible users."
  (when (file-exists-p org-trello--config-dir)
    (directory-files org-trello--config-dir 'full-name "^.*\.el")))

(defalias 'orgtrello-controller/user-account-from-config-file 'file-name-base)

(defun orgtrello-controller/list-user-accounts (user-config-files)
  "Given a list of USER-CONFIG-FILES, return the trello accounts list."
  (mapcar #'orgtrello-controller/user-account-from-config-file user-config-files))

(defun orgtrello-controller/--choose-account! (accounts)
  "Let the user decide which account (s)he wants to use.
Return such account name."
  (message "account: %s" accounts)
  (ido-completing-read "Select org-trello account (TAB to complete): " accounts nil 'user-must-input-from-list))

(defun orgtrello-controller/set-account! (&optional args)
  "Set the org-trello account.
ARGS is not used."
  (let ((user-account-elected (-if-let (user-account (orgtrello-buffer/me!))
                                  user-account ;; if already set, keep using the actual account
                                ;; otherwise, user not logged in, determine which account to use
                                (let ((user-accounts (orgtrello-controller/list-user-accounts (orgtrello-controller/user-config-files))))
                                  (if (= 1 (length user-accounts))
                                      (car user-accounts)
                                    (orgtrello-controller/--choose-account! user-accounts))))))
    (orgtrello-setup/set-user-logged-in user-account-elected)
    :ok))

(defun orgtrello-controller/load-keys! (&optional args)
  "Load the credentials keys from the configuration file.
ARGS is not used."
  (let ((user-config-file (orgtrello-controller/config-file!)))
    (if (and (file-exists-p user-config-file) (load user-config-file))
        :ok
      "Setup problem - Problem during credentials loading (consumer-key and read/write access-token) - C-c o i or M-x org-trello-install-key-and-token")))

(defun orgtrello-controller/control-keys! (&optional args)
  "Org-trello needs the org-trello-consumer-key and org-trello-access-token for trello resources.
Returns :ok if everything is ok, or the error message if problems.
ARGS is not used."
  (if (and org-trello-consumer-key org-trello-access-token)
      :ok
    "Setup problem - You need to install the consumer-key and the read/write access-token - C-c o i or M-x org-trello-install-key-and-token"))

(defun orgtrello-controller/--on-entity-p (entity)
  "Compute if the org-trello ENTITY exists.
If it does not not, error."
  (if entity :ok "You need to be on an org-trello entity (card/checklist/item) for this action to occur!"))

(defun orgtrello-controller/--right-level-p (entity)
  "Compute if the ENTITY level is correct (not higher than level 4)."
  (if (and entity (< (-> entity orgtrello-data/current orgtrello-data/entity-level) org-trello--out-of-bounds-level)) :ok "Wrong level. Do not deal with entity other than card/checklist/item!"))

(defun orgtrello-controller/--already-synced-p (entity)
  "Compute if the ENTITY has already been synchronized."
  (if (-> entity orgtrello-data/current orgtrello-data/entity-id) :ok "Entity must been synchronized with trello first!"))

(defun orgtrello-controller/--entity-mandatory-name-ok-p (simple-entity)
  "Ensure SIMPLE-ENTITY can be synced regarding the mandatory data."
  (if simple-entity
    (let* ((level   (orgtrello-data/entity-level simple-entity))
           (name    (orgtrello-data/entity-name simple-entity)))
      (if (and name (< 0 (length name)))
          :ok
        (cond ((= level org-trello--card-level)      org-trello--error-sync-card-missing-name)
              ((= level org-trello--checklist-level) org-trello--error-sync-checklist-missing-name)
              ((= level org-trello--item-level)      org-trello--error-sync-item-missing-name))))
    :ok))

(defun orgtrello-controller/--mandatory-name-ok-p (entity)
  "Ensure ENTITY can be synced regarding the mandatory data."
  (-> entity
    orgtrello-data/current
    orgtrello-controller/--entity-mandatory-name-ok-p))

(defun orgtrello-controller/checks-then-delete-simple ()
  "Do the deletion of an entity."
  (orgtrello-action/functional-controls-then-do '(orgtrello-controller/--on-entity-p orgtrello-controller/--right-level-p orgtrello-controller/--already-synced-p)
                                                (orgtrello-buffer/safe-entry-full-metadata!)
                                                'orgtrello-controller/delete-card!
                                                (current-buffer)))

(defun orgtrello-controller/delete-card! (full-meta &optional buffer-name)
  "Execute on FULL-META the ACTION.
BUFFER-NAME to specify the buffer with which we currently work."
  (with-current-buffer buffer-name
    (let* ((current (orgtrello-data/current full-meta))
           (marker  (orgtrello-buffer/--compute-marker-from-entry current)))
      (orgtrello-buffer/set-marker-if-not-present! current marker)
      (orgtrello-data/put-entity-id marker current)
      (eval (orgtrello-proxy/--delete current)))))

(defun orgtrello-controller/checks-then-sync-card-to-trello! ()
  "Execute checks then do the actual sync if everything is ok."
  (orgtrello-action/functional-controls-then-do '(orgtrello-controller/--on-entity-p orgtrello-controller/--right-level-p orgtrello-controller/--mandatory-name-ok-p)
                                                (orgtrello-buffer/safe-entry-full-metadata!)
                                                'orgtrello-controller/sync-card-to-trello!
                                                (current-buffer)))

(defun orgtrello-controller/sync-card-to-trello! (full-meta &optional buffer-name)
  "Do the actual card creation/update - from card to item."
  (let ((current-checksum (orgtrello-buffer/card-checksum!))
        (previous-checksum (orgtrello-buffer/get-card-local-checksum!)))
    (if (string= current-checksum previous-checksum)
        (orgtrello-log/msg orgtrello-log-info "Card already synchronized, nothing to do!")
      (progn
        (orgtrello-log/msg orgtrello-log-info "Synchronizing card on board '%s'..." (orgtrello-buffer/board-name!))
        (org-show-subtree) ;; we need to show the subtree, otherwise https://github.com/org-trello/org-trello/issues/53
        (-> buffer-name
          orgtrello-buffer/build-org-card-structure!
          orgtrello-controller/execute-sync-entity-structure!)))))

(defun orgtrello-controller/do-sync-buffer-to-trello! ()
  "Full org-mode file synchronisation."
  (orgtrello-log/msg orgtrello-log-warn "Synchronizing org-mode file to the board '%s'. This may take some time, some coffee may be a good idea..." (orgtrello-buffer/board-name!))
  (-> (current-buffer)
    orgtrello-buffer/build-org-entities!
    orgtrello-controller/execute-sync-entity-structure!))

(defun orgtrello-controller/--sync-buffer-with-trello-data (data)
  "Update the current buffer with DATA (entities and adjacency)."
  (let ((entities (car data))
        (adjacency (cadr data)))
    (goto-char (point-max)) ;; go at the end of the file
    (maphash
     (lambda (new-id entity)
       (when (orgtrello-data/entity-card-p entity)
         (orgtrello-buffer/write-card! new-id entity entities adjacency)))
     entities)
    (goto-char (point-min))                 ;; go back to the beginning of file
    (ignore-errors (org-sort-entries t ?o)) ;; sort the entries on their keywords and ignore if there are errors (if nothing to sort for example)
    (org-global-cycle '(4))))               ;; fold all entries

(defun orgtrello-controller/--cleanup-org-entries ()
  "Cleanup org-entries from the buffer.
Does not preserve position."
  (goto-char (point-min))
  (outline-next-heading)
  (orgtrello-buffer/remove-overlays! (point-at-bol) (point-max))
  (kill-region (point-at-bol) (point-max)))

(defun orgtrello-controller/sync-buffer-with-trello-cards! (buffer-name org-trello-cards)
  "Synchronize the buffer BUFFER-NAME with the TRELLO-CARDS."
  (with-local-quit
    (with-current-buffer buffer-name
      (save-excursion
        (let ((entities-from-org-buffer (orgtrello-buffer/build-org-entities! buffer-name)))
          (-> org-trello-cards
            orgtrello-backend/compute-org-trello-card-from
            (orgtrello-data/merge-entities-trello-and-org entities-from-org-buffer)
            ((lambda (entry) (orgtrello-controller/--cleanup-org-entries) entry))   ;; hack to clean the org entries just before synchronizing the buffer
            orgtrello-controller/--sync-buffer-with-trello-data))))))

(defun orgtrello-controller/do-sync-buffer-from-trello! ()
  "Full org-mode file synchronisation. Beware, this will block emacs as the request is synchronous."
  (lexical-let ((buffer-name (current-buffer))
                (board-name  (orgtrello-buffer/board-name!))
                (point-start (point))
                (board-id (orgtrello-buffer/board-id!)))
    (orgtrello-log/msg orgtrello-log-info "Synchronizing the trello board '%s' to the org-mode file..." board-name)
    (deferred:$ ;; In emacs 25, deferred:parallel blocks in this context. I don't understand why so I retrieve sequentially for the moment. People, feel free to help and improve.
      (deferred:next
        (lambda ()
          (-> board-id
              orgtrello-api/get-archived-cards
              (orgtrello-query/http-trello 'sync)
              list)))
      (deferred:nextc it
        (lambda (cards)
          (-> board-id
              orgtrello-api/get-full-cards
              (orgtrello-query/http-trello 'sync)
              (cons cards))))
      (deferred:nextc it
        (lambda (trello-opened-and-archived-cards)
          (orgtrello-log/msg orgtrello-log-debug "Opened and archived trello-cards: %S" trello-opened-and-archived-cards)
          (let ((trello-cards          (car  trello-opened-and-archived-cards))
                (trello-archived-cards (cadr trello-opened-and-archived-cards)))
            ;; first archive the cards that needs to be
            (orgtrello-log/msg orgtrello-log-debug "Archived trello-cards: %S" trello-archived-cards)
            (orgtrello-buffer/archive-cards! trello-archived-cards)
            ;; Then update the buffer with the other opened trello cards
            (orgtrello-log/msg orgtrello-log-debug "Opened trello-cards: %S" trello-cards)
            (->> trello-cards
                 (mapcar 'orgtrello-data/to-org-trello-card)
                 (orgtrello-controller/sync-buffer-with-trello-cards! buffer-name)))))
      (deferred:nextc it
        (lambda ()
          (orgtrello-buffer/save-buffer buffer-name)
          (goto-char point-start)
          (orgtrello-log/msg orgtrello-log-info "Synchronizing the trello board '%s' to the org-mode file '%s' done!" board-name buffer-name)))
      (deferred:error it
        (lambda (err) (orgtrello-log/msg orgtrello-log-error "Sync buffer from trello - Catch error: %S" err))))))

(defun orgtrello-controller/check-trello-connection! ()
  "Full org-mode file synchronisation. Beware, this will block emacs as the request is synchronous."
  (orgtrello-log/msg orgtrello-log-info "Checking trello connection...")
  (deferred:$
    (deferred:next (lambda () (orgtrello-query/http-trello (orgtrello-api/get-me) 'sync)))
    (deferred:nextc it
      (lambda (user-me)
        (orgtrello-log/msg orgtrello-log-info
                           (if user-me
                               (format "Account '%s' configured! Everything is ok!" (orgtrello-data/entity-username user-me))
                             "There is a problem with your credentials.\nMake sure you used M-x org-trello-install-key-and-token and installed correctly the consumer-key and access-token.\nSee http://org-trello.github.io/trello-setup.html#credentials for more information."))))
    (deferred:error it
      (lambda (err) (orgtrello-log/msg orgtrello-log-error "Setup ko - '%s'" err)))))

(defun orgtrello-controller/execute-sync-entity-structure! (entity-structure)
  "Execute synchronization of ENTITY-STRUCTURE (entities at first position, adjacency list in second position).
The entity-structure is self contained.
Synchronization is done here.
Along the way, the buffer BUFFER-NAME is written with new informations."
  (lexical-let ((entities             (car entity-structure))
                (entities-adjacencies entity-structure)
                (card-computations))
    (maphash (lambda (id entity)
               (when (and (orgtrello-data/entity-card-p entity) (eq :ok (orgtrello-controller/--entity-mandatory-name-ok-p entity)))
                 (-> entity
                   (orgtrello-proxy/--sync-entity entities-adjacencies)
                   (push card-computations))))
             entities)

    (if card-computations
        (-> card-computations
          nreverse
          (orgtrello-proxy/execute-async-computations "card(s) sync ok!" "FAILURE! cards(s) sync KO!"))
      (orgtrello-log/msg orgtrello-log-info "No card(s) to sync."))))

(defun orgtrello-controller/compute-and-overwrite-card! (buffer-name org-trello-card)
  "Given BUFFER-NAME and TRELLO-CARD, compute, merge and update the buffer-name."
  (when org-trello-card
    (with-local-quit
      (with-current-buffer buffer-name
        (save-excursion
          (let* ((card-id                  (orgtrello-data/entity-id org-trello-card))
                 (region                   (orgtrello-entity/compute-card-region!))
                 (entities-from-org-buffer (apply 'orgtrello-buffer/build-org-entities! (cons buffer-name region)))
                 (entities-from-trello     (orgtrello-backend/compute-org-trello-card-from (list org-trello-card)))
                 (merged-entities          (orgtrello-data/merge-entities-trello-and-org entities-from-trello entities-from-org-buffer))
                 (entities                 (car merged-entities))
                 (entities-adj             (cadr merged-entities)))
            (orgtrello-buffer/overwrite-card! region (gethash card-id entities) entities entities-adj)))))))

(defun orgtrello-controller/checks-then-sync-card-from-trello! ()
  "Execute checks then do the actual sync if everything is ok."
  (orgtrello-action/functional-controls-then-do '(orgtrello-controller/--on-entity-p orgtrello-controller/--right-level-p orgtrello-controller/--already-synced-p)
                                                (orgtrello-buffer/safe-entry-full-metadata!)
                                                'orgtrello-controller/sync-card-from-trello!
                                                (current-buffer)))

(defun orgtrello-controller/sync-card-from-trello! (full-meta &optional buffer-name)
  "Entity (card/checklist/item) synchronization (with its structure) from trello.
Optionally, SYNC permits to synchronize the query."
  (lexical-let* ((buffer-name buffer-name)
                 (point-start (point))
                 (card-meta (progn (when (not (orgtrello-entity/card-at-pt!)) (orgtrello-entity/back-to-card!))
                                   (orgtrello-data/current (orgtrello-buffer/entry-get-full-metadata!))))
                 (card-name (orgtrello-data/entity-name card-meta)))
    (orgtrello-log/msg orgtrello-log-info "Synchronizing the trello card to the org-mode file...")
    (deferred:$
      (deferred:next
        (lambda ()
          (-> card-meta
            orgtrello-data/entity-id
            orgtrello-api/get-full-card
            (orgtrello-query/http-trello 'sync))))
      (deferred:nextc it
        (lambda (trello-card) ;; We have the full result in one query, now we can compute the translation in org-trello model
          (orgtrello-log/msg orgtrello-log-debug "trello-card: %S" trello-card)
          (->> trello-card
            orgtrello-data/to-org-trello-card
            (orgtrello-controller/compute-and-overwrite-card! buffer-name))))
      (deferred:nextc it
        (lambda ()
          (orgtrello-buffer/save-buffer buffer-name)
          (goto-char point-start)
          (orgtrello-log/msg orgtrello-log-info "Synchronizing the trello card '%s' to the org-mode file done!" card-name)))
      (deferred:error it
        (lambda (err) (orgtrello-log/msg orgtrello-log-error "Catch error: %S" err))))))

(defun orgtrello-controller/--do-delete-card ()
  "Delete the card."
  (when (orgtrello-entity/card-at-pt!)
    (orgtrello-controller/checks-then-delete-simple)))

(defun orgtrello-controller/do-delete-entities ()
  "Launch a batch deletion of every single entities present on the buffer.
SYNC flag permit to synchronize the http query."
  (org-map-entries 'orgtrello-controller/--do-delete-card t 'file))

(defun orgtrello-controller/checks-and-do-archive-card ()
  "Check the functional requirements, then if everything is ok, archive the card."
  (let ((buffer-name (current-buffer)))
    (with-current-buffer buffer-name
      (save-excursion
        (let ((card-meta (progn (when (orgtrello-entity/org-checkbox-p!) (orgtrello-entity/back-to-card!))
                                (orgtrello-buffer/entry-get-full-metadata!))))
          (orgtrello-action/functional-controls-then-do '(orgtrello-controller/--right-level-p orgtrello-controller/--already-synced-p)
                                                        card-meta
                                                        'orgtrello-controller/do-archive-card
                                                        buffer-name))))))

(defun orgtrello-controller/do-archive-card (card-meta &optional buffer-name)
  "Archive current CARD-META at point.
BUFFER-NAME specifies the buffer onto which we work."
  (save-excursion
    (lexical-let* ((buffer-name buffer-name)
                   (point-start (point))
                   (card-meta   (orgtrello-data/current card-meta))
                   (card-name   (orgtrello-data/entity-name card-meta)))
      (deferred:$
        (deferred:next
          (lambda () ;; trello archive
            (orgtrello-log/msg orgtrello-log-info "Archive card '%s'..." card-name)
            (orgtrello-log/msg orgtrello-log-debug "Archive card '%s' in trello...\n" card-name)
            (-> card-meta
              orgtrello-data/entity-id
              orgtrello-api/archive-card
              (orgtrello-query/http-trello 'sync))))
        (deferred:nextc it
          (lambda (card-result) ;; org archive
            (orgtrello-log/msg orgtrello-log-debug "Archive card '%s' in org..." card-name)
            (with-current-buffer buffer-name
              (goto-char point-start)
              (org-archive-subtree))))
        (deferred:nextc it
          (lambda () ;; save buffer
            (orgtrello-buffer/save-buffer buffer-name)
            (orgtrello-log/msg orgtrello-log-info "Archive card '%s' done!" card-name)))))))

(defun orgtrello-controller/--do-install-config-file (user-login consumer-key access-token &optional ask-for-overwrite)
  "Persist the setup file with USER-LOGIN, CONSUMER-KEY and ACCESS-TOKEN.
ASK-FOR-OVERWRITE is a flag that needs to be set if we want to prevent some overwriting."
  (let ((new-user-config-file (orgtrello-controller/config-file! user-login)))
    (make-directory org-trello--config-dir 'do-create-parent-if-need-be)
    (with-temp-file new-user-config-file
      (erase-buffer)
      (goto-char (point-min))
      (insert (format "(setq org-trello-consumer-key \"%s\")\n" consumer-key))
      (insert (format "(setq org-trello-access-token \"%s\")" access-token))
      (write-file new-user-config-file ask-for-overwrite))))

(defun orgtrello-controller/do-install-key-and-token ()
  "Procedure to install the org-trello-consumer-key and the token for the user in the config-file."
  (lexical-let* ((user-login       (read-string "Trello login account (you need to be logged accordingly in trello.com as we cannot check this for you): "))
                 (user-config-file (orgtrello-controller/config-file! user-login)))
    (if (file-exists-p user-config-file)
        (orgtrello-log/msg orgtrello-log-info "Configuration for user '%s' already existing (file '%s'), skipping." user-login user-config-file)
      (deferred:$
        (deferred:next
          (lambda () (browse-url (org-trello/compute-url "/1/appKey/generate"))))
        (deferred:nextc it
          (lambda (user-login)
            (let ((consumer-key (read-string "Consumer key: ")))
              (browse-url (org-trello/compute-url (format "/1/authorize?response_type=token&name=org-trello&scope=read,write&expiration=never&key=%s" consumer-key)))
              (list consumer-key user-login))))
        (deferred:nextc it
          (lambda (consumer-key-user-login)
            (orgtrello-log/msg orgtrello-log-debug "user-login + consumer-key: %S" consumer-key-user-login)
            (let ((access-token (read-string "Access token: ")))
              (mapcar 's-trim (cons access-token consumer-key-user-login)))))
        (deferred:nextc it
          (lambda (access-token-consumer-key-user-login)
            (orgtrello-log/msg orgtrello-log-debug "user-login + consumer-key + access-token: %S" access-token-consumer-key-user-login)
            (->> access-token-consumer-key-user-login
                 (cons 'do-ask-for-overwrite)
                 nreverse
                 (apply 'orgtrello-controller/--do-install-config-file))))
        (deferred:nextc it
          (lambda () (orgtrello-log/msg orgtrello-log-info "Setup key and token done!")))))))

(defun orgtrello-controller/--name-id (entities)
  "Given a list of ENTITIES, return a map of (id, name)."
  (--reduce-from (orgtrello-hash/puthash-data (orgtrello-data/entity-name it) (orgtrello-data/entity-id it) acc) (orgtrello-hash/empty-hash) entities))

(defun orgtrello-controller/--list-boards! ()
  "Return the map of the existing boards associated to the current account. (Synchronous request)"
  (orgtrello-query/http-trello (orgtrello-api/get-boards "open") 'sync))

(defun orgtrello-controller/--list-board-lists! (board-id)
  "Return the map of the existing list of the board with id board-id. (Synchronous request)"
  (orgtrello-query/http-trello (orgtrello-api/get-lists board-id) 'sync))

(defun orgtrello-controller/choose-board! (boards)
  "Given a map of boards, ask the user to choose the boards.
This returns the identifier of such board."
  (-> (ido-completing-read "Board to install (TAB to complete): " (orgtrello-hash/keys boards) nil 'user-must-input-something-from-list)
      (gethash boards)))

(defun orgtrello-controller/--convention-property-name (name)
  "Given a NAME, use the right convention for the property used in the headers of the 'org-mode' file."
  (replace-regexp-in-string " " "-" name))

(defun orgtrello-controller/--delete-buffer-property! (property-name)
  "A simple routine to delete a #+PROPERTY: entry from the org-mode buffer."
  (save-excursion
    (goto-char (point-min))
    (-when-let (current-point (search-forward property-name nil t))
      (goto-char current-point)
      (beginning-of-line)
      (kill-line)
      (kill-line))))

(defun orgtrello-controller/compute-property (property-name &optional property-value)
  "Compute a formatted property in org buffer from PROPERTY-NAME and optional PROPERTY-VALUE."
  (format "#+PROPERTY: %s %s" property-name (if property-value property-value "")))

(defun orgtrello-controller/--compute-hash-name-id-to-list (users-hash-name-id)
  "Compute the hash of name id to list from USERS-HASH-NAME-ID."
  (let ((res-list nil))
    (maphash (lambda (name id) (--> name
                                 (replace-regexp-in-string org-trello--label-key-user-prefix "" it)
                                 (format "%s%s" org-trello--label-key-user-prefix it)
                                 (orgtrello-controller/compute-property it id)
                                 (push it res-list)))
             users-hash-name-id)
    res-list))

(defun orgtrello-controller/--remove-properties-file! (org-keywords users-hash-name-id user-me &optional update-todo-keywords)
  "Remove the current org-trello header metadata."
  (with-current-buffer (current-buffer)
    ;; compute the list of properties to purge
    (->> `(":PROPERTIES"
           ,(orgtrello-controller/compute-property org-trello--property-board-name)
           ,(orgtrello-controller/compute-property org-trello--property-board-id)
           ,@(--map (orgtrello-controller/compute-property (orgtrello-controller/--convention-property-name it)) org-keywords)
           ,@(orgtrello-controller/--compute-hash-name-id-to-list users-hash-name-id)
           ,(orgtrello-controller/compute-property org-trello--property-user-me user-me)
           ,(when update-todo-keywords "#+TODO: ")
           ":red" ":blue" ":yellow" ":green" ":orange" ":purple"
           ":END:")
      (mapc 'orgtrello-controller/--delete-buffer-property!))))

(defun orgtrello-controller/--properties-labels (board-labels)
  "Compute properties labels from BOARD-LABELS."
  (let ((res-list))
    (maphash (lambda (name id)
               (push (format "#+PROPERTY: %s %s" name id) res-list))
             board-labels)
    res-list))

(defun orgtrello-controller/--compute-metadata! (board-name board-id board-lists-hash-name-id board-users-hash-name-id user-me board-labels &optional update-todo-keywords)
  "Compute the org-trello metadata to dump on header file."
  `(":PROPERTIES:"
    ,(orgtrello-controller/compute-property org-trello--property-board-name board-name)
    ,(orgtrello-controller/compute-property org-trello--property-board-id board-id)
    ,@(orgtrello-controller/--compute-board-lists-hash-name-id board-lists-hash-name-id)
    ,(if update-todo-keywords (orgtrello-controller/--properties-compute-todo-keywords-as-string board-lists-hash-name-id) "")
    ,@(orgtrello-controller/--properties-compute-users-ids board-users-hash-name-id)
    ,@(orgtrello-controller/--properties-labels board-labels)
    ,(format "#+PROPERTY: %s %s" org-trello--property-user-me (if user-me user-me org-trello--user-logged-in))
    ":END:"))

(defun orgtrello-controller/--compute-keyword-separation (name)
  "Given a keyword NAME (case insensitive) return a string '| done' or directly the keyword."
  (if (string= "done" (downcase name)) (format "| %s" name) name))

(defun orgtrello-controller/--compute-board-lists-hash-name-id (board-lists-hash-name-id)
  "Compute board lists of key/name from BOARD-LISTS-HASH-NAME-ID."
  (let ((res-list))
    (maphash (lambda (name id) (--> (orgtrello-controller/--convention-property-name name)
                                 (format "#+PROPERTY: %s %s" it id)
                                 (push it res-list)))
             board-lists-hash-name-id)
    res-list))

(defun orgtrello-controller/--properties-compute-todo-keywords-as-string (board-lists-hash-name-id)
  "Compute org keywords from the BOARD-LISTS-HASH-NAME-ID."
  (mapconcat 'identity `("#+TODO: "
                         ,@(let ((res-list))
                             (maphash (lambda (name _) (--> name
                                                         (orgtrello-controller/--convention-property-name it)
                                                         (orgtrello-controller/--compute-keyword-separation it)
                                                         (format "%s " it)
                                                         (push it res-list)))
                                      board-lists-hash-name-id)
                             (nreverse res-list))) ""))

(defun orgtrello-controller/--properties-compute-users-ids (board-users-hash-name-id)
  "Given BOARD-USERS-HASH-NAME-ID, compute the properties for users."
  (let ((res-list))
    (maphash (lambda (name id) (--> name
                                 (format "#+PROPERTY: %s%s %s" org-trello--label-key-user-prefix it id)
                                 (push it res-list)))
             board-users-hash-name-id)
    res-list))

(defun orgtrello-controller/--update-orgmode-file-with-properties! (board-name board-id board-lists-hash-name-id board-users-hash-name-id user-me board-labels &optional update-todo-keywords)
  "Update the orgmode file with the needed headers for org-trello to work."
  (with-current-buffer (current-buffer)
    (goto-char (point-min))
    (set-buffer-file-coding-system 'utf-8-auto) ;; force utf-8
    (->> (orgtrello-controller/--compute-metadata! board-name board-id board-lists-hash-name-id board-users-hash-name-id user-me board-labels update-todo-keywords)
         (mapc (lambda (it) (insert it "\n"))))
    (goto-char (point-min))
    (org-cycle)))

(defun orgtrello-controller/--user-logged-in! ()
  "Compute the current user."
  (-> (orgtrello-api/get-me)
      (orgtrello-query/http-trello 'sync)))

(defun orgtrello-controller/do-install-board-and-lists ()
  "Command to install the list boards."
  (lexical-let ((buffer-name (current-buffer)))
    (deferred:$
      (deferred:parallel ;; retrieve in parallel the open boards and the currently logged in user
        (deferred:next
          'orgtrello-controller/--list-boards!)
        (deferred:next
          'orgtrello-controller/--user-logged-in!))
      (deferred:nextc it
        (lambda (boards-and-user-logged-in)
          (let* ((boards         (elt boards-and-user-logged-in 0))
                 (user-logged-in (orgtrello-data/entity-username (elt boards-and-user-logged-in 1)))
                 (selected-id-board (->> boards
                                         orgtrello-controller/--name-id
                                         orgtrello-controller/choose-board!)))
            (list selected-id-board user-logged-in))))
      (deferred:nextc it
        (lambda (board-id-and-user-logged-in)
          (-> board-id-and-user-logged-in
              car
              orgtrello-api/get-board
              (orgtrello-query/http-trello 'sync)
              (cons board-id-and-user-logged-in))))
      (deferred:nextc it
        (lambda (board-and-user)
          (cl-destructuring-bind (board board-id user-logged-in) board-and-user
            (let ((members (->> board
                                orgtrello-data/entity-memberships
                                orgtrello-controller/--compute-user-properties
                                orgtrello-controller/--compute-user-properties-hash)))
              (orgtrello-controller/do-write-board-metadata! board-id
                                                             (orgtrello-data/entity-name board)
                                                             user-logged-in
                                                             (orgtrello-data/entity-lists board)
                                                             (orgtrello-data/entity-labels board)
                                                             members)))))
      (deferred:nextc it
        (lambda ()
          (orgtrello-buffer/save-buffer buffer-name)
          (orgtrello-action/reload-setup!)
          (orgtrello-log/msg orgtrello-log-info "Install board and list ids done!"))))))

(defun orgtrello-controller/--compute-user-properties (memberships-map)
  "Given a map MEMBERSHIPS-MAP, extract the map of user information."
  (mapcar 'orgtrello-data/entity-member memberships-map))

(defun orgtrello-controller/--compute-user-properties-hash (user-properties)
  "Compute user's properties from USER-PROPERTIES."
  (--reduce-from (orgtrello-hash/puthash-data (orgtrello-data/entity-username it) (orgtrello-data/entity-id it) acc) (orgtrello-hash/empty-hash) user-properties))

(defun orgtrello-controller/--create-board (board-name &optional board-description)
  "Create a board with name BOARD-NAME and optionally a BOARD-DESCRIPTION."
  (orgtrello-log/msg orgtrello-log-info "Creating board '%s' with description '%s'" board-name board-description)
  (orgtrello-query/http-trello (orgtrello-api/add-board board-name board-description) 'sync))

(defun orgtrello-controller/--close-lists (list-ids)
  "Given a list of ids LIST-IDS, close those lists."
  (orgtrello-proxy/execute-async-computations
   (--map (lexical-let ((list-id it))
            (orgtrello-query/http-trello (orgtrello-api/close-list it) nil (lambda (response) (orgtrello-log/msg orgtrello-log-info "Closed list with id %s" list-id)) (lambda ())))
         list-ids)
   "List(s) closed."
   "FAILURE - Problem during closing list."))

(defun orgtrello-controller/--create-lists-according-to-keywords (board-id org-keywords)
  "For the BOARD-ID, create the list names from ORG-KEYWORDS.
The list order in the trello board is the same as the ORG-KEYWORDS.
Return the hashmap (name, id) of the new lists created."
  (car
   (--reduce-from (cl-destructuring-bind (hash pos) acc
                    (orgtrello-log/msg orgtrello-log-info "Board id %s - Creating list '%s'" board-id it)
                    (list (orgtrello-hash/puthash-data it (orgtrello-data/entity-id (orgtrello-query/http-trello (orgtrello-api/add-list it board-id pos) 'sync)) hash) (+ pos 1)))
                  (list (orgtrello-hash/empty-hash) 1)
                  org-keywords)))

(defun orgtrello-controller/do-create-board-and-install-metadata ()
  "Command to create a board and the lists."
  (lexical-let ((org-keywords (orgtrello-buffer/filtered-kwds!))
                (buffer-name  (current-buffer)))
    (deferred:$
      (deferred:next
        (lambda ()
          (orgtrello-log/msg orgtrello-log-debug "Input from the user.")
          (let ((input-board-name        (orgtrello-input/read-not-empty! "Please, input the desired board name: "))
                (input-board-description (read-string "Please, input the board description (empty for none): ")))
            (list input-board-name input-board-description))))
      (deferred:parallel
        (deferred:nextc it
          (lambda (input-board-name-and-description) ;; compute the current board's information
            (orgtrello-log/msg orgtrello-log-debug "Create the board. - %S" input-board-name-and-description)
            (apply 'orgtrello-controller/--create-board input-board-name-and-description)))
        (deferred:next
          (lambda () ;; compute the current user's information
            (orgtrello-log/msg orgtrello-log-debug "Computer user information.")
            (orgtrello-controller/--user-logged-in!))))
      (deferred:nextc it
        (lambda (board-and-user-logged-in)
          (orgtrello-log/msg orgtrello-log-debug "Computer default board lists - %S" board-and-user-logged-in)
          (let ((board (elt board-and-user-logged-in 0))
                (user  (elt board-and-user-logged-in 1)))
            (->> board
              orgtrello-data/entity-id
              orgtrello-controller/--list-board-lists!
              (mapcar 'orgtrello-data/entity-id)
              (list board user)))))
      (deferred:nextc it
        (lambda (board-user-list-ids)
          (orgtrello-log/msg orgtrello-log-debug "Close default lists - %S" board-user-list-ids)
          (cl-destructuring-bind (_ _ list-ids) board-user-list-ids
            (orgtrello-controller/--close-lists list-ids))
          board-user-list-ids))
      (deferred:nextc it
        (lambda (board-user-list-ids)
          (orgtrello-log/msg orgtrello-log-debug "Create user's list in board - %S" board-user-list-ids)
          (cl-destructuring-bind (board user list-ids) board-user-list-ids
            (--> board
              (orgtrello-data/entity-id it)
              (orgtrello-controller/--create-lists-according-to-keywords it org-keywords)
              (list board user it)))))
      (deferred:nextc it
        (lambda (board-user-list-ids)
          (orgtrello-log/msg orgtrello-log-debug "Update buffer with metadata - %S" board-user-list-ids)
          (cl-destructuring-bind (board user board-lists-hname-id) board-user-list-ids
            (orgtrello-controller/do-cleanup-from-buffer!)
            (orgtrello-controller/--update-orgmode-file-with-properties! (orgtrello-data/entity-name board)
                                                                         (orgtrello-data/entity-id board)
                                                                         board-lists-hname-id
                                                                         (orgtrello-hash/make-properties `((,(orgtrello-data/entity-username user) . ,(orgtrello-data/entity-id user))))
                                                                         (orgtrello-data/entity-username user)
                                                                         (orgtrello-hash/make-properties '((:red . "") (:green . "") (:yellow . "") (:purple . "") (:blue . "") (:orange . "")))
                                                                         org-keywords))))
      (deferred:nextc it
        (lambda ()
          (orgtrello-buffer/save-buffer buffer-name)
          (orgtrello-action/reload-setup!)
          (orgtrello-log/msg orgtrello-log-info "Create board and lists done!"))))))

(defun orgtrello-controller/--add-user (user users)
  "Add the USER to the USERS list."
  (if (member user users) users (cons user users)))

(defun orgtrello-controller/--remove-user (user users)
  "Remove the USER from the USERS list."
  (if (member user users) (remove user users) users users))

(defun orgtrello-controller/do-assign-me ()
  "Command to assign oneself to the card."
  (--> (orgtrello-buffer/get-usernames-assigned-property!)
    (orgtrello-data/--users-from it)
    (orgtrello-controller/--add-user org-trello--user-logged-in it)
    (orgtrello-data/--users-to it)
    (orgtrello-buffer/set-usernames-assigned-property! it)))

(defun orgtrello-controller/do-unassign-me ()
  "Command to unassign oneself of the card."
  (--> (orgtrello-buffer/get-usernames-assigned-property!)
       (orgtrello-data/--users-from it)
       (orgtrello-controller/--remove-user org-trello--user-logged-in it)
       (orgtrello-data/--users-to it)
       (orgtrello-buffer/set-usernames-assigned-property! it)))

(defun orgtrello-controller/do-add-card-comment! ()
  "Wait for the input to add a comment to the current card."
  (save-excursion
    (orgtrello-entity/back-to-card!)
    (let ((card-id (-> (orgtrello-buffer/entity-metadata!) orgtrello-data/entity-id)))
      (if (or (null card-id) (string= "" card-id))
          (orgtrello-log/msg orgtrello-log-info "Card not sync'ed so cannot add comment - skip.")
        (orgtrello-controller/add-comment! card-id)))))

(defun orgtrello-controller/do-delete-card-comment! ()
  "Execute checks then do the actual card deletion if everything is ok."
  (orgtrello-action/functional-controls-then-do '(orgtrello-controller/--on-entity-p orgtrello-controller/--right-level-p orgtrello-controller/--already-synced-p)
                                                (orgtrello-buffer/safe-entry-full-metadata!)
                                                'orgtrello-controller/--do-delete-card-comment!
                                                (current-buffer)))

(defun orgtrello-controller/--do-delete-card-comment! (card-meta &optional buffer-name)
  "Delete the comment at point."
  (save-excursion
    (lexical-let ((card-id    (-> card-meta orgtrello-data/parent orgtrello-data/entity-id))
                  (comment-id (-> card-meta orgtrello-data/current orgtrello-data/entity-id)))
      (if (or (null card-id) (string= "" card-id) (string= "" comment-id))
          (orgtrello-log/msg orgtrello-log-info "No comment to delete - skip.")
        (deferred:$
          (deferred:next (lambda () (-> card-id
                                 (orgtrello-api/delete-card-comment comment-id)
                                 (orgtrello-query/http-trello 'sync))))
          (deferred:nextc it
            (lambda (data)
              (apply 'delete-region (orgtrello-entity/compute-comment-region!))
              (orgtrello-log/msg orgtrello-log-info "Comment deleted!"))))))))


(defun orgtrello-controller/do-sync-card-comment! ()
  "Execute checks then do the actual sync if everything is ok."
  (orgtrello-action/functional-controls-then-do '(orgtrello-controller/--on-entity-p orgtrello-controller/--right-level-p orgtrello-controller/--already-synced-p)
                                                (progn
                                                  (org-back-to-heading)
                                                  (orgtrello-buffer/safe-entry-full-metadata!))
                                                'orgtrello-controller/--do-sync-card-comment!
                                                (current-buffer)))

(defun orgtrello-controller/--do-sync-card-comment! (card-meta &optional buffer-name)
  "Delete the comment at point."
  (save-excursion
    (lexical-let* ((card-id        (-> card-meta orgtrello-data/parent orgtrello-data/entity-id))
                   (entity-comment (-> card-meta orgtrello-data/current))
                   (comment-id     (orgtrello-data/entity-id entity-comment))
                   (comment-text   (orgtrello-data/entity-description entity-comment)))
      (if (or (null card-id) (string= "" card-id) (string= "" comment-id))
          (orgtrello-log/msg orgtrello-log-info "No comment to sync - skip.")
        (deferred:$
          (deferred:next (lambda () (-> card-id
                                 (orgtrello-api/update-card-comment comment-id comment-text)
                                 (orgtrello-query/http-trello 'sync))))
          (deferred:nextc it
            (lambda (data)
              (orgtrello-log/msg orgtrello-log-info "Comment sync'ed!"))))))))

(defun orgtrello-controller/do-cleanup-from-buffer! (&optional globally-flag)
  "Clean org-trello data in current buffer.
When GLOBALLY-FLAG is not nil, remove also local entities properties."
  (orgtrello-controller/--remove-properties-file! org-trello--org-keyword-trello-list-names org-trello--hmap-users-name-id org-trello--user-logged-in t) ;; remove any orgtrello relative entries
  (when globally-flag
    (mapc 'orgtrello-buffer/delete-property! `(,org-trello--label-key-id ,org-trello--property-users-entry))))

(defun orgtrello-controller/do-write-board-metadata! (board-id board-name user-logged-in board-lists board-labels board-users-name-id)
  "Given a board id, write in the current buffer the updated data."
  (let* ((board-lists-hname-id (orgtrello-controller/--name-id board-lists))
         (board-list-keywords  (orgtrello-hash/keys board-lists-hname-id)))
    (orgtrello-controller/do-cleanup-from-buffer!)
    (orgtrello-controller/--update-orgmode-file-with-properties! board-name
                                                                 board-id
                                                                 board-lists-hname-id
                                                                 board-users-name-id
                                                                 user-logged-in
                                                                 board-labels
                                                                 board-list-keywords)))

(defun orgtrello-controller/do-update-board-metadata! ()
  "Update metadata about the current board we are connected to."
  (lexical-let ((buffer-name (current-buffer)))
    (deferred:$
      (deferred:next
        (lambda ()
          (-> (orgtrello-buffer/board-id!)
            orgtrello-api/get-board
            (orgtrello-query/http-trello 'sync))))
      (deferred:nextc it
        (lambda (board)
          (let ((members (->> board
                           orgtrello-data/entity-memberships
                           orgtrello-controller/--compute-user-properties
                           orgtrello-controller/--compute-user-properties-hash)))
            (orgtrello-controller/do-write-board-metadata! (orgtrello-data/entity-id board)
                                                           (orgtrello-data/entity-name board)
                                                           (orgtrello-buffer/me!)
                                                           (orgtrello-data/entity-lists board)
                                                           (orgtrello-data/entity-labels board)
                                                           members))))
      (deferred:nextc it
        (lambda ()
          (orgtrello-buffer/save-buffer buffer-name)
          (orgtrello-action/reload-setup!)
          (orgtrello-log/msg orgtrello-log-info "Update board information done!"))))))

(defun orgtrello-controller/do-show-board-labels! ()
  "Open a pop and display the board's labels."
  (->> (orgtrello-buffer/labels!)
    orgtrello-data/format-labels
    (orgtrello-buffer/pop-up-with-content! "Labels")))

(defun orgtrello-controller/jump-to-card! ()
  "Given a current entry, execute the extraction and the jump to card action."
  (let* ((full-meta       (orgtrello-buffer/entry-get-full-metadata!))
         (entity          (orgtrello-data/current full-meta))
         (right-entity-fn (cond ((orgtrello-data/entity-item-p entity)      'orgtrello-data/grandparent)
                                ((orgtrello-data/entity-checklist-p entity) 'orgtrello-data/parent)
                                ((orgtrello-data/entity-card-p entity)      'orgtrello-data/current))))
    (-when-let (card-id (->> full-meta (funcall right-entity-fn) orgtrello-data/entity-id))
        (browse-url (org-trello/compute-url (format "/c/%s" card-id))))))

(defun orgtrello-controller/jump-to-board! ()
  "Given the current position, execute the information extraction and jump to board action."
  (->> (orgtrello-buffer/board-id!)
       (format "/b/%s")
       org-trello/compute-url
       browse-url))

(defun orgtrello-controller/delete-setup! ()
  "Global org-trello metadata clean up."
  (orgtrello-controller/do-cleanup-from-buffer! t)
  (orgtrello-log/msg orgtrello-log-no-log "Cleanup done!"))

(defvar orgtrello-controller/register "*orgtrello-register*"
  "The variable holding the Emacs' org-trello register.")

(defvar orgtrello-controller/card-id nil
  "The variable holding the card-id needed to sync the comment.")

(defvar orgtrello-controller/return nil
  "The variable holding the list `'buffer-name`', position.
This, to get back to when closing the popup window.")

(make-local-variable 'orgtrello-controller/return)
(make-local-variable 'orgtrello-controller/card-id)

(defun orgtrello-controller/add-comment! (card-id)
  "Pop up a window for the user to input a comment.
CARD-ID is the needed id to create the comment."
  (setq orgtrello-controller/return (list (current-buffer) (point)))
  (setq orgtrello-controller/card-id card-id)
  (window-configuration-to-register orgtrello-controller/register)
  (delete-other-windows)
  (org-switch-to-buffer-other-window org-trello--title-buffer-information)
  (erase-buffer)
  (let ((org-inhibit-startup t))
    (org-mode)
    (insert (format "# Insert comment.\n# Finish with C-c C-c, or cancel with C-c C-k.\n\n"))
    (define-key org-mode-map [remap org-ctrl-c-ctrl-c] 'orgtrello-controller/kill-buffer-and-write-new-comment!)
    (define-key org-mode-map [remap org-kill-note-or-show-branches] 'orgtrello-controller/close-popup!)))

(defun orgtrello-controller/close-popup! ()
  "Close the buffer at point."
  (interactive)
  (kill-buffer (current-buffer))
  (jump-to-register orgtrello-controller/register)
  (define-key org-mode-map [remap org-ctrl-c-ctrl-c] nil)
  (define-key org-mode-map [remap org-kill-note-or-show-branches] nil)
  (let ((buffer-name (car orgtrello-controller/return))
        (pos         (cadr orgtrello-controller/return)))
    (pop-to-buffer buffer-name)
    (goto-char pos)))

(defun orgtrello-controller/kill-buffer-and-write-new-comment! ()
  "Write comment present in the popup buffer."
  (interactive)
  (deferred:$
    (deferred:next
      (lambda ()
        (let ((comment (orgtrello-buffer/trim-input-comment (buffer-string))))
          (orgtrello-controller/close-popup!)
          comment)))
    (deferred:nextc it
      (lambda (comment)
        (lexical-let ((new-comment comment))
          (deferred:$
            (deferred:next (lambda () (-> orgtrello-controller/card-id
                                     (orgtrello-api/add-card-comment new-comment)
                                     (orgtrello-query/http-trello 'sync))))
            (deferred:nextc it
              (lambda (data)
                (orgtrello-log/msg orgtrello-log-trace "Add card comment - response data: %S" data)
                (orgtrello-controller/checks-then-sync-card-from-trello!)))))))))

(defun orgtrello-controller/prepare-buffer! ()
  "Prepare the buffer to receive org-trello data."
  (when (and (eq major-mode 'org-mode) org-trello--mode-activated-p)
    (orgtrello-buffer/install-overlays!)
    (orgtrello-buffer/indent-card-descriptions!)
    (orgtrello-buffer/indent-card-data!)))

(defun orgtrello-controller/mode-on-hook-fn ()
  "Start org-trello hook function to install some org-trello setup."
  ;; Activate org-trello--mode-activated-p
  (setq org-trello--mode-activated-p 'activated)
  ;; buffer-invisibility-spec
  (add-to-invisibility-spec '(org-trello-cbx-property)) ;; for an ellipsis (-> ...) change to '(org-trello-cbx-property . t)
  ;; Setup the buffer
  (orgtrello-controller/setup-properties!)
  ;; installing hooks
  (add-hook 'before-save-hook 'orgtrello-controller/prepare-buffer!)
  ;; prepare the buffer at activation time
  (orgtrello-controller/prepare-buffer!)
  ;; run hook at startup
  (run-hooks 'org-trello-mode-hook))

(defun orgtrello-controller/mode-off-hook-fn ()
  "Stop org-trello hook function to deinstall some org-trello setup."
  ;; remove the invisible property names
  (remove-from-invisibility-spec '(org-trello-cbx-property)) ;; for an ellipsis (...) change to '(org-trello-cbx-property . t)
  ;; removing hooks
  (remove-hook 'before-save-hook 'orgtrello-controller/prepare-buffer!)
  ;; remove org-trello overlays
  (orgtrello-buffer/remove-overlays!)
  ;; deactivate org-trello--mode-activated-p
  (setq org-trello--mode-activated-p))

(orgtrello-log/msg orgtrello-log-debug "orgtrello-controller loaded!")

(provide 'org-trello-controller)
;;; org-trello-controller.el ends here
