;; Title: Cheat Prevention Contract
;; Version: 1.0
;; Summary: Monitors and detects suspicious examination behavior
;; Description: Advanced behavioral analysis system for detecting and preventing exam cheating

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u401))
(define-constant ERR-SESSION-NOT-FOUND (err u404))
(define-constant ERR-INVALID-DATA (err u400))
(define-constant ERR-ALREADY-FLAGGED (err u409))
(define-constant ERR-INSUFFICIENT-EVIDENCE (err u412))
(define-constant ERR-APPEAL-EXPIRED (err u410))
(define-constant ERR-INVALID-THRESHOLD (err u422))
(define-constant ERR-MONITORING-DISABLED (err u423))

;; Contract constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant MAX-BEHAVIOR-SCORE u100)
(define-constant CHEATING-THRESHOLD u70)
(define-constant SUSPICIOUS-THRESHOLD u50)
(define-constant APPEAL-WINDOW u1440) ;; 24 hours in blocks
(define-constant MAX-EVIDENCE-SIZE u512)

;; Behavior flag constants
(define-constant FLAG-SUSPICIOUS-KEYSTROKE u1)
(define-constant FLAG-ABNORMAL-MOUSE u2)
(define-constant FLAG-FOCUS-LOSS u4)
(define-constant FLAG-NETWORK-ACTIVITY u8)
(define-constant FLAG-MULTIPLE-TABS u16)
(define-constant FLAG-COPY-PASTE u32)
(define-constant FLAG-PATTERN-ANOMALY u64)

;; Data variables
(define-data-var monitoring-enabled bool true)
(define-data-var total-sessions-monitored uint u0)
(define-data-var total-flags-issued uint u0)
(define-data-var cheating-threshold uint CHEATING-THRESHOLD)

;; Monitoring sessions for active exams
(define-map monitoring-sessions
  { session-id: (buff 32) }
  {
    exam-id: uint,
    participant: principal,
    start-time: uint,
    end-time: (optional uint),
    behavior-score: uint,
    total-flags: uint,
    status: (string-ascii 32)
  }
)

;; Behavior monitoring data
(define-map behavior-data
  { session-id: (buff 32), timestamp: uint }
  {
    keystroke-pattern: uint,
    mouse-movement: uint,
    focus-events: uint,
    network-requests: uint,
    clipboard-events: uint,
    anomaly-score: uint
  }
)

;; Evidence storage for detected violations
(define-map violation-evidence
  { session-id: (buff 32), evidence-id: uint }
  {
    violation-type: uint,
    evidence-hash: (buff 32),
    timestamp: uint,
    severity-score: uint,
    verified: bool
  }
)

;; Appeals for disputed violations
(define-map violation-appeals
  { session-id: (buff 32) }
  {
    appellant: principal,
    appeal-time: uint,
    reason: (string-ascii 256),
    evidence-provided: (optional (buff 32)),
    status: (string-ascii 32),
    reviewed-by: (optional principal)
  }
)

;; Monitor permissions and configuration
(define-map authorized-monitors
  { monitor: principal }
  {
    permissions: uint,
    active: bool,
    sessions-monitored: uint
  }
)

;; Detection algorithm parameters
(define-map detection-config
  { param-name: (string-ascii 64) }
  { value: uint, enabled: bool }
)

;; Public function to start monitoring session
(define-public (start-monitoring 
    (session-id (buff 32))
    (exam-id uint)
    (participant principal))
  (let (
    (current-time stacks-block-height)
  )
    (asserts! (var-get monitoring-enabled) ERR-MONITORING-DISABLED)
    (asserts! (is-authorized-monitor tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-none (map-get? monitoring-sessions { session-id: session-id })) ERR-ALREADY-FLAGGED)
    
    ;; Initialize monitoring session
    (map-set monitoring-sessions
      { session-id: session-id }
      {
        exam-id: exam-id,
        participant: participant,
        start-time: current-time,
        end-time: none,
        behavior-score: u0,
        total-flags: u0,
        status: "monitoring"
      }
    )
    
    ;; Update monitor statistics
    (let (
      (monitor-info (default-to { permissions: u0, active: false, sessions-monitored: u0 }
                                (map-get? authorized-monitors { monitor: tx-sender })))
    )
      (map-set authorized-monitors
        { monitor: tx-sender }
        (merge monitor-info { sessions-monitored: (+ (get sessions-monitored monitor-info) u1) })
      )
    )
    
    ;; Update global counter
    (var-set total-sessions-monitored (+ (var-get total-sessions-monitored) u1))
    
    (ok true)
  )
)

;; Public function to record behavior data
(define-public (record-behavior 
    (session-id (buff 32))
    (keystroke-pattern uint)
    (mouse-movement uint)
    (focus-events uint)
    (network-requests uint)
    (clipboard-events uint))
  (let (
    (session-info (unwrap! (map-get? monitoring-sessions { session-id: session-id }) ERR-SESSION-NOT-FOUND))
    (current-time stacks-block-height)
    (anomaly-score (calculate-anomaly-score keystroke-pattern mouse-movement focus-events network-requests clipboard-events))
  )
    (asserts! (is-authorized-monitor tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status session-info) "monitoring") ERR-INVALID-DATA)
    
    ;; Store behavior data
    (map-set behavior-data
      { session-id: session-id, timestamp: current-time }
      {
        keystroke-pattern: keystroke-pattern,
        mouse-movement: mouse-movement,
        focus-events: focus-events,
        network-requests: network-requests,
        clipboard-events: clipboard-events,
        anomaly-score: anomaly-score
      }
    )
    
    ;; Update session behavior score
    (let (
      (new-behavior-score (if (< (+ (get behavior-score session-info) anomaly-score) MAX-BEHAVIOR-SCORE)
                             (+ (get behavior-score session-info) anomaly-score)
                             MAX-BEHAVIOR-SCORE))
      (new-flags (count-behavior-flags keystroke-pattern mouse-movement focus-events network-requests clipboard-events))
    )
      (map-set monitoring-sessions
        { session-id: session-id }
        (merge session-info {
          behavior-score: new-behavior-score,
          total-flags: (+ (get total-flags session-info) new-flags)
        })
      )
      
      ;; Check if cheating threshold exceeded
      (if (>= new-behavior-score (var-get cheating-threshold))
        (begin 
          (unwrap-panic (flag-violation session-id FLAG-PATTERN-ANOMALY current-time new-behavior-score))
          u0
        )
        u0
      )
    )
    
    (ok anomaly-score)
  )
)

;; Public function to flag a violation
(define-public (flag-violation 
    (session-id (buff 32))
    (violation-type uint)
    (timestamp uint)
    (severity-score uint))
  (let (
    (session-info (unwrap! (map-get? monitoring-sessions { session-id: session-id }) ERR-SESSION-NOT-FOUND))
    (evidence-id (get total-flags session-info))
    (evidence-hash (sha256 session-id))
  )
    (asserts! (is-authorized-monitor tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (<= severity-score MAX-BEHAVIOR-SCORE) ERR-INVALID-DATA)
    
    ;; Store violation evidence
    (map-set violation-evidence
      { session-id: session-id, evidence-id: evidence-id }
      {
        violation-type: violation-type,
        evidence-hash: evidence-hash,
        timestamp: timestamp,
        severity-score: severity-score,
        verified: false
      }
    )
    
    ;; Update session status if severe violation
    (if (>= severity-score (var-get cheating-threshold))
      (map-set monitoring-sessions
        { session-id: session-id }
        (merge session-info {
          status: "violation-detected",
          end-time: (some stacks-block-height)
        })
      )
      true
    )
    
    ;; Update global counter
    (var-set total-flags-issued (+ (var-get total-flags-issued) u1))
    
    (ok evidence-id)
  )
)

;; Public function to submit appeal
(define-public (submit-appeal 
    (session-id (buff 32))
    (reason (string-ascii 256))
    (evidence-provided (optional (buff 32))))
  (let (
    (session-info (unwrap! (map-get? monitoring-sessions { session-id: session-id }) ERR-SESSION-NOT-FOUND))
    (current-time stacks-block-height)
  )
    (asserts! (is-eq tx-sender (get participant session-info)) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status session-info) "violation-detected") ERR-INVALID-DATA)
    (asserts! (is-none (map-get? violation-appeals { session-id: session-id })) ERR-ALREADY-FLAGGED)
    
    ;; Check appeal window
    (let (
      (end-time-value (unwrap! (get end-time session-info) ERR-INVALID-DATA))
    )
      (asserts! (< (- current-time end-time-value) APPEAL-WINDOW) ERR-APPEAL-EXPIRED)
    )
    
    ;; Store appeal
    (map-set violation-appeals
      { session-id: session-id }
      {
        appellant: tx-sender,
        appeal-time: current-time,
        reason: reason,
        evidence-provided: evidence-provided,
        status: "pending",
        reviewed-by: none
      }
    )
    
    ;; Update session status
    (map-set monitoring-sessions
      { session-id: session-id }
      (merge session-info { status: "under-appeal" })
    )
    
    (ok true)
  )
)

;; Admin function to review appeal
(define-public (review-appeal 
    (session-id (buff 32))
    (approve bool)
    (review-notes (optional (string-ascii 256))))
  (let (
    (appeal-info (unwrap! (map-get? violation-appeals { session-id: session-id }) ERR-SESSION-NOT-FOUND))
    (session-info (unwrap! (map-get? monitoring-sessions { session-id: session-id }) ERR-SESSION-NOT-FOUND))
  )
    (asserts! (is-authorized-monitor tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status appeal-info) "pending") ERR-INVALID-DATA)
    
    ;; Update appeal status
    (map-set violation-appeals
      { session-id: session-id }
      (merge appeal-info {
        status: (if approve "approved" "rejected"),
        reviewed-by: (some tx-sender)
      })
    )
    
    ;; Update session status based on appeal result
    (map-set monitoring-sessions
      { session-id: session-id }
      (merge session-info {
        status: (if approve "appeal-approved" "violation-confirmed")
      })
    )
    
    (ok approve)
  )
)

;; Admin function to add authorized monitor
(define-public (add-monitor (monitor principal) (permissions uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (map-set authorized-monitors
      { monitor: monitor }
      {
        permissions: permissions,
        active: true,
        sessions-monitored: u0
      }
    )
    (ok true)
  )
)

;; Admin function to update cheating threshold
(define-public (update-threshold (new-threshold uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (<= new-threshold MAX-BEHAVIOR-SCORE) ERR-INVALID-THRESHOLD)
    (var-set cheating-threshold new-threshold)
    (ok new-threshold)
  )
)

;; Admin function to toggle monitoring
(define-public (toggle-monitoring)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (var-set monitoring-enabled (not (var-get monitoring-enabled)))
    (ok (var-get monitoring-enabled))
  )
)

;; Read-only function to get session info
(define-read-only (get-session-info (session-id (buff 32)))
  (map-get? monitoring-sessions { session-id: session-id })
)

;; Read-only function to get behavior data
(define-read-only (get-behavior-data (session-id (buff 32)) (timestamp uint))
  (map-get? behavior-data { session-id: session-id, timestamp: timestamp })
)

;; Read-only function to get violation evidence
(define-read-only (get-violation-evidence (session-id (buff 32)) (evidence-id uint))
  (map-get? violation-evidence { session-id: session-id, evidence-id: evidence-id })
)

;; Read-only function to get contract statistics
(define-read-only (get-monitoring-stats)
  {
    monitoring-enabled: (var-get monitoring-enabled),
    total-sessions: (var-get total-sessions-monitored),
    total-flags: (var-get total-flags-issued),
    cheating-threshold: (var-get cheating-threshold)
  }
)

;; Private function to check monitor authorization
(define-private (is-authorized-monitor (user principal))
  (match (map-get? authorized-monitors { monitor: user })
    monitor-info (and (get active monitor-info) (> (get permissions monitor-info) u0))
    false
  )
)

;; Private function to calculate anomaly score
(define-private (calculate-anomaly-score 
    (keystroke uint) (mouse uint) (focus uint) (network uint) (clipboard uint))
  (let (
    (keystroke-score (if (> keystroke u80) u20 u0))
    (mouse-score (if (> mouse u90) u15 u0))
    (focus-score (if (> focus u5) u25 u0))
    (network-score (if (> network u3) u30 u0))
    (clipboard-score (if (> clipboard u2) u40 u0))
  )
    (if (< (+ keystroke-score mouse-score focus-score network-score clipboard-score) MAX-BEHAVIOR-SCORE)
      (+ keystroke-score mouse-score focus-score network-score clipboard-score)
      MAX-BEHAVIOR-SCORE)
  )
)

;; Private function to count behavior flags
(define-private (count-behavior-flags 
    (keystroke uint) (mouse uint) (focus uint) (network uint) (clipboard uint))
  (+ 
    (if (> keystroke u80) u1 u0)
    (if (> mouse u90) u1 u0)
    (if (> focus u5) u1 u0)
    (if (> network u3) u1 u0)
    (if (> clipboard u2) u1 u0)
  )
)

