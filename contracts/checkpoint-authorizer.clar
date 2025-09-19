;; Continuous Checkpoint Authorizer
;; 
;; A secure and transparent smart contract for managing continuous progress verification
;; and milestone tracking across long-term or complex projects.

;; Error Codes
(define-constant ERR-UNAUTHORIZED-ACCESS (err u100))
(define-constant ERR-INVALID-CHECKPOINT (err u101))
(define-constant ERR-CHECKPOINT-ALREADY-EXISTS (err u102))
(define-constant ERR-INSUFFICIENT-PERMISSIONS (err u103))
(define-constant ERR-CHECKPOINT-NOT-FOUND (err u104))

;; Checkpoint Status Constants
(define-constant STATUS-PENDING u1)
(define-constant STATUS-APPROVED u2)
(define-constant STATUS-REJECTED u3)

;; Configuration Constants
(define-constant MAX-DESCRIPTION-LENGTH u500)
(define-constant VERIFICATION-THRESHOLD u2)

;; Admin/Owner Management
(define-data-var contract-admin principal tx-sender)

;; Data Maps

;; Checkpoint Registry
(define-map checkpoints
  { 
    project-id: uint, 
    checkpoint-id: uint 
  }
  {
    submitter: principal,
    description: (string-utf8 MAX-DESCRIPTION-LENGTH),
    evidence-uri: (string-ascii 200),
    submitted-at: uint,
    status: uint,
    verifiers: (list 5 principal),
    verification-count: uint
  }
)

;; Project Registry
(define-map projects
  { project-id: uint }
  {
    name: (string-ascii 100),
    owner: principal,
    total-checkpoints: uint,
    created-at: uint
  }
)

;; Project Authorization
(define-map project-authorizations
  { 
    project-id: uint, 
    authorized-user: principal 
  }
  {
    can-submit-checkpoints: bool,
    can-verify-checkpoints: bool
  }
)

;; Counters
(define-data-var project-id-counter uint u0)
(define-data-var checkpoint-id-counter uint u0)

;; Private Functions

;; Increment and return next project ID
(define-private (get-next-project-id)
  (let ((next-id (+ (var-get project-id-counter) u1)))
    (var-set project-id-counter next-id)
    next-id
  )
)

;; Increment and return next checkpoint ID
(define-private (get-next-checkpoint-id)
  (let ((next-id (+ (var-get checkpoint-id-counter) u1)))
    (var-set checkpoint-id-counter next-id)
    next-id
  )
)

;; Check if user is authorized for a specific project
(define-private (is-project-authorized 
  (project-id uint) 
  (user principal) 
  (permission (string-ascii 20))
)
  (match (map-get? project-authorizations { project-id: project-id, authorized-user: user })
    auth-info (if (is-eq permission "submit")
                  (get can-submit-checkpoints auth-info)
                  (get can-verify-checkpoints auth-info))
    false
  )
)

;; Public Functions

;; Create a new project
(define-public (create-project (name (string-ascii 100)))
  (let (
    (project-id (get-next-project-id))
    (sender tx-sender)
  )
    (map-set projects 
      { project-id: project-id }
      {
        name: name,
        owner: sender,
        total-checkpoints: u0,
        created-at: block-height
      }
    )
    
    ;; Automatically authorize project owner
    (map-set project-authorizations
      { 
        project-id: project-id, 
        authorized-user: sender 
      }
      {
        can-submit-checkpoints: true,
        can-verify-checkpoints: true
      }
    )
    
    (ok project-id)
  )
)

;; Submit a checkpoint for a project
(define-public (submit-checkpoint
  (project-id uint)
  (description (string-utf8 MAX-DESCRIPTION-LENGTH))
  (evidence-uri (string-ascii 200))
)
  (let (
    (checkpoint-id (get-next-checkpoint-id))
    (sender tx-sender)
  )
    ;; Validate project exists
    (asserts! (is-some (map-get? projects { project-id: project-id })) ERR-CHECKPOINT-NOT-FOUND)
    
    ;; Validate submitter authorization
    (asserts! (is-project-authorized project-id sender "submit") ERR-UNAUTHORIZED-ACCESS)
    
    ;; Create checkpoint
    (map-set checkpoints
      { 
        project-id: project-id, 
        checkpoint-id: checkpoint-id 
      }
      {
        submitter: sender,
        description: description,
        evidence-uri: evidence-uri,
        submitted-at: block-height,
        status: STATUS-PENDING,
        verifiers: (list),
        verification-count: u0
      }
    )
    
    ;; Update project total checkpoints
    (let ((project (unwrap-panic (map-get? projects { project-id: project-id }))))
      (map-set projects
        { project-id: project-id }
        (merge project { total-checkpoints: (+ (get total-checkpoints project) u1) })
      )
    )
    
    (ok checkpoint-id)
  )
)

;; Verify a checkpoint
(define-public (verify-checkpoint 
  (project-id uint) 
  (checkpoint-id uint)
)
  (let (
    (sender tx-sender)
    (checkpoint (map-get? checkpoints { project-id: project-id, checkpoint-id: checkpoint-id }))
  )
    ;; Validate checkpoint exists
    (asserts! (is-some checkpoint) ERR-CHECKPOINT-NOT-FOUND)
    
    ;; Validate verifier authorization
    (asserts! (is-project-authorized project-id sender "verify") ERR-UNAUTHORIZED-ACCESS)
    
    ;; Prevent duplicate verification
    (asserts! 
      (is-none 
        (find (is-eq sender) 
          (get verifiers (unwrap-panic checkpoint))
        )
      ) 
      ERR-CHECKPOINT-ALREADY-EXISTS
    )
    
    ;; Update checkpoint
    (map-set checkpoints
      { project-id: project-id, checkpoint-id: checkpoint-id }
      (merge 
        (unwrap-panic checkpoint)
        {
          verifiers: (unwrap! 
            (as-max-len? 
              (append (get verifiers (unwrap-panic checkpoint)) sender) 
              u5
            ) 
            ERR-UNAUTHORIZED-ACCESS
          ),
          verification-count: (+ (get verification-count (unwrap-panic checkpoint)) u1),
          status: (if (>= (+ (get verification-count (unwrap-panic checkpoint)) u1) VERIFICATION-THRESHOLD)
                      STATUS-APPROVED
                      STATUS-PENDING)
        }
      )
    )
    
    (ok true)
  )
)