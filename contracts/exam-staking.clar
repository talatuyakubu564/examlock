;; Title: Exam Staking Contract
;; Version: 1.0
;; Summary: Manages exam registration and collateral staking to prevent cheating
;; Description: Core staking system that handles exam creation, registration, and penalty management

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u401))
(define-constant ERR-EXAM-NOT-FOUND (err u404))
(define-constant ERR-EXAM-FULL (err u405))
(define-constant ERR-INSUFFICIENT-STAKE (err u400))
(define-constant ERR-ALREADY-REGISTERED (err u409))
(define-constant ERR-EXAM-NOT-ACTIVE (err u410))
(define-constant ERR-STAKE-LOCKED (err u423))
(define-constant ERR-INVALID-PARAMETERS (err u422))
(define-constant ERR-TRANSFER-FAILED (err u500))

;; Contract constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant MIN-STAKE-AMOUNT u1000000) ;; 1 STX minimum
(define-constant MAX-EXAM-DURATION u14400) ;; 4 hours in blocks
(define-constant PENALTY-RATE u50) ;; 50% penalty for cheating
(define-constant ADMIN-FEE-RATE u10) ;; 10% admin fee from penalties

;; Data variables
(define-data-var next-exam-id uint u1)
(define-data-var total-exams-created uint u0)
(define-data-var total-stakes-held uint u0)
(define-data-var contract-paused bool false)

;; Exam information storage
(define-map exams
  { exam-id: uint }
  {
    creator: principal,
    title: (string-ascii 128),
    stake-amount: uint,
    max-participants: uint,
    duration: uint,
    start-time: uint,
    end-time: uint,
    status: (string-ascii 32),
    total-stakes: uint,
    participants-count: uint
  }
)

;; Participant registration and stakes
(define-map exam-participants
  { exam-id: uint, participant: principal }
  {
    stake-amount: uint,
    registration-time: uint,
    status: (string-ascii 32),
    completion-time: (optional uint),
    penalty-applied: bool
  }
)

;; Exam results and validation
(define-map exam-results
  { exam-id: uint, participant: principal }
  {
    score: uint,
    completion-time: uint,
    behavior-flags: uint,
    validated: bool,
    evidence-hash: (optional (buff 32))
  }
)

;; Admin permissions
(define-map authorized-admins
  { admin: principal }
  { permissions: uint, active: bool }
)

;; Penalty distributions
(define-map penalty-pool
  { exam-id: uint }
  { total-penalties: uint, distributed: uint, remaining: uint }
)

;; Public function to create a new exam
(define-public (create-exam 
    (title (string-ascii 128))
    (stake-amount uint)
    (max-participants uint)
    (duration uint)
    (start-time uint))
  (let (
    (exam-id (var-get next-exam-id))
    (end-time (+ start-time duration))
  )
    (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)
    (asserts! (>= stake-amount MIN-STAKE-AMOUNT) ERR-INSUFFICIENT-STAKE)
    (asserts! (<= duration MAX-EXAM-DURATION) ERR-INVALID-PARAMETERS)
    (asserts! (> max-participants u0) ERR-INVALID-PARAMETERS)
    (asserts! (> start-time stacks-block-height) ERR-INVALID-PARAMETERS)
    
    ;; Store exam information
    (map-set exams
      { exam-id: exam-id }
      {
        creator: tx-sender,
        title: title,
        stake-amount: stake-amount,
        max-participants: max-participants,
        duration: duration,
        start-time: start-time,
        end-time: end-time,
        status: "active",
        total-stakes: u0,
        participants-count: u0
      }
    )
    
    ;; Initialize penalty pool
    (map-set penalty-pool
      { exam-id: exam-id }
      { total-penalties: u0, distributed: u0, remaining: u0 }
    )
    
    ;; Update counters
    (var-set next-exam-id (+ exam-id u1))
    (var-set total-exams-created (+ (var-get total-exams-created) u1))
    
    (ok exam-id)
  )
)

;; Public function to register for an exam
(define-public (register-for-exam (exam-id uint))
  (let (
    (exam-info (unwrap! (map-get? exams { exam-id: exam-id }) ERR-EXAM-NOT-FOUND))
    (stake-amount (get stake-amount exam-info))
    (current-time stacks-block-height)
  )
    (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status exam-info) "active") ERR-EXAM-NOT-ACTIVE)
    (asserts! (< current-time (get start-time exam-info)) ERR-EXAM-NOT-ACTIVE)
    (asserts! (< (get participants-count exam-info) (get max-participants exam-info)) ERR-EXAM-FULL)
    (asserts! (is-none (map-get? exam-participants { exam-id: exam-id, participant: tx-sender })) ERR-ALREADY-REGISTERED)
    
    ;; Transfer stake from participant
    (try! (stx-transfer? stake-amount tx-sender (as-contract tx-sender)))
    
    ;; Register participant
    (map-set exam-participants
      { exam-id: exam-id, participant: tx-sender }
      {
        stake-amount: stake-amount,
        registration-time: current-time,
        status: "registered",
        completion-time: none,
        penalty-applied: false
      }
    )
    
    ;; Update exam statistics
    (map-set exams
      { exam-id: exam-id }
      (merge exam-info {
        total-stakes: (+ (get total-stakes exam-info) stake-amount),
        participants-count: (+ (get participants-count exam-info) u1)
      })
    )
    
    ;; Update global counter
    (var-set total-stakes-held (+ (var-get total-stakes-held) stake-amount))
    
    (ok true)
  )
)

;; Public function to submit exam results
(define-public (submit-result 
    (exam-id uint)
    (score uint)
    (behavior-flags uint)
    (evidence-hash (optional (buff 32))))
  (let (
    (exam-info (unwrap! (map-get? exams { exam-id: exam-id }) ERR-EXAM-NOT-FOUND))
    (participant-info (unwrap! (map-get? exam-participants { exam-id: exam-id, participant: tx-sender }) ERR-NOT-AUTHORIZED))
    (current-time stacks-block-height)
  )
    (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)
    (asserts! (and (>= current-time (get start-time exam-info)) (<= current-time (get end-time exam-info))) ERR-EXAM-NOT-ACTIVE)
    (asserts! (is-eq (get status participant-info) "registered") ERR-NOT-AUTHORIZED)
    
    ;; Store results
    (map-set exam-results
      { exam-id: exam-id, participant: tx-sender }
      {
        score: score,
        completion-time: current-time,
        behavior-flags: behavior-flags,
        validated: false,
        evidence-hash: evidence-hash
      }
    )
    
    ;; Update participant status
    (map-set exam-participants
      { exam-id: exam-id, participant: tx-sender }
      (merge participant-info {
        status: "completed",
        completion-time: (some current-time)
      })
    )
    
    (ok true)
  )
)

;; Admin function to apply penalty for cheating
(define-public (apply-penalty (exam-id uint) (participant principal))
  (let (
    (exam-info (unwrap! (map-get? exams { exam-id: exam-id }) ERR-EXAM-NOT-FOUND))
    (participant-info (unwrap! (map-get? exam-participants { exam-id: exam-id, participant: participant }) ERR-NOT-AUTHORIZED))
    (stake-amount (get stake-amount participant-info))
    (penalty-amount (/ (* stake-amount PENALTY-RATE) u100))
    (admin-fee (/ (* penalty-amount ADMIN-FEE-RATE) u100))
    (pool-amount (- penalty-amount admin-fee))
    (current-pool (default-to { total-penalties: u0, distributed: u0, remaining: u0 } 
                              (map-get? penalty-pool { exam-id: exam-id })))
  )
    (asserts! (is-authorized-admin tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (not (get penalty-applied participant-info)) ERR-INVALID-PARAMETERS)
    (asserts! (> stacks-block-height (get end-time exam-info)) ERR-EXAM-NOT-ACTIVE)
    
    ;; Transfer admin fee to contract owner
    (try! (as-contract (stx-transfer? admin-fee tx-sender CONTRACT-OWNER)))
    
    ;; Update penalty pool
    (map-set penalty-pool
      { exam-id: exam-id }
      {
        total-penalties: (+ (get total-penalties current-pool) pool-amount),
        distributed: (get distributed current-pool),
        remaining: (+ (get remaining current-pool) pool-amount)
      }
    )
    
    ;; Mark participant as penalized
    (map-set exam-participants
      { exam-id: exam-id, participant: participant }
      (merge participant-info {
        status: "penalized",
        penalty-applied: true
      })
    )
    
    (ok penalty-amount)
  )
)

;; Public function to claim stake refund (for honest participants)
(define-public (claim-refund (exam-id uint))
  (let (
    (exam-info (unwrap! (map-get? exams { exam-id: exam-id }) ERR-EXAM-NOT-FOUND))
    (participant-info (unwrap! (map-get? exam-participants { exam-id: exam-id, participant: tx-sender }) ERR-NOT-AUTHORIZED))
    (stake-amount (get stake-amount participant-info))
  )
    (asserts! (> stacks-block-height (get end-time exam-info)) ERR-STAKE-LOCKED)
    (asserts! (is-eq (get status participant-info) "completed") ERR-NOT-AUTHORIZED)
    (asserts! (not (get penalty-applied participant-info)) ERR-NOT-AUTHORIZED)
    
    ;; Return full stake to honest participant
    (try! (as-contract (stx-transfer? stake-amount tx-sender tx-sender)))
    
    ;; Update participant status
    (map-set exam-participants
      { exam-id: exam-id, participant: tx-sender }
      (merge participant-info { status: "refunded" })
    )
    
    ;; Update global counter
    (var-set total-stakes-held (- (var-get total-stakes-held) stake-amount))
    
    (ok stake-amount)
  )
)

;; Admin function to add authorized admin
(define-public (add-admin (admin principal) (permissions uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (map-set authorized-admins
      { admin: admin }
      { permissions: permissions, active: true }
    )
    (ok true)
  )
)

;; Admin function to pause/unpause contract
(define-public (toggle-pause)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (var-set contract-paused (not (var-get contract-paused)))
    (ok (var-get contract-paused))
  )
)

;; Read-only function to get exam details
(define-read-only (get-exam-info (exam-id uint))
  (map-get? exams { exam-id: exam-id })
)

;; Read-only function to get participant info
(define-read-only (get-participant-info (exam-id uint) (participant principal))
  (map-get? exam-participants { exam-id: exam-id, participant: participant })
)

;; Read-only function to get exam results
(define-read-only (get-exam-results (exam-id uint) (participant principal))
  (map-get? exam-results { exam-id: exam-id, participant: participant })
)

;; Read-only function to get contract statistics
(define-read-only (get-contract-stats)
  {
    total-exams: (var-get total-exams-created),
    next-exam-id: (var-get next-exam-id),
    total-stakes-held: (var-get total-stakes-held),
    contract-paused: (var-get contract-paused)
  }
)

;; Private function to check admin authorization
(define-private (is-authorized-admin (user principal))
  (match (map-get? authorized-admins { admin: user })
    admin-info (and (get active admin-info) (> (get permissions admin-info) u0))
    false
  )
)

