;; OracleSure - Oracle-backed parametric insurance (Fixed)

(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-CONTRACT-PAUSED (err u101))
(define-constant ERR-PRODUCT-NOT-FOUND (err u102))
(define-constant ERR-INACTIVE-PRODUCT (err u103))
(define-constant ERR-INSUFFICIENT-FUNDS (err u104))
(define-constant ERR-POLICY-NOT-FOUND (err u105))
(define-constant ERR-CLAIM-NOT-FOUND (err u106))
(define-constant ERR-ALREADY-CLAIMED (err u107))
(define-constant ERR-NOT-CLAIMANT (err u108))
(define-constant ERR-CHALLENGE-TOO-LATE (err u109))
(define-constant ERR-INVALID-ORACLE (err u110))
(define-constant ERR-ALREADY-PAID (err u111))

;; Admin & operational principals
(define-data-var admin principal tx-sender)
(define-data-var oracle principal tx-sender)
(define-data-var paused bool false)

;; Counters
(define-data-var next-product-id uint u1)
(define-data-var next-policy-id uint u1)
(define-data-var next-claim-id uint u1)

;; Product struct
(define-map products
  {pid: uint}
  {premium: uint,
   payout: uint,
   coverage: uint,
   max-payout: uint,
   oracle-id: (buff 32),
   active: bool})

;; Policies
(define-map policies
  {policy-id: uint}
  {owner: principal, product-id: uint, start-block: uint, expiry-block: uint, payouted: bool})

;; Product reserving
(define-map product-reserve
  {pid: uint}
  {reserved: uint})

;; Oracle reports
(define-map oracle-reports {pid: uint} {happened: bool, reported-block: uint})

;; Claims
(define-map claims
  {claim-id: uint}
  {policy-id: uint, claimant: principal, state: uint, requested-at: uint, challenger: principal, challenge-stake: uint})

;; Claim states
(define-constant ST-CLAIM-PENDING u1)
(define-constant ST-CLAIM-CHALLENGED u2)
(define-constant ST-CLAIM-RESOLVED u3)
(define-constant ST-CLAIM-REJECTED u4)

;; Config
(define-data-var CHALLENGE_WINDOW_BLOCKS uint u720) 

;; Event emitter helper
(define-private (emit (m (tuple (event (string-ascii 32))))) (print m))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Admin functions
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-public (set-oracle (p principal))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) ERR-UNAUTHORIZED)
    (var-set oracle p)
    (emit {event: "oracle-set"})
    (ok true)))

(define-public (pause)
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) ERR-UNAUTHORIZED)
    (var-set paused true)
    (emit {event: "paused"})
    (ok true)))

(define-public (resume)
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) ERR-UNAUTHORIZED)
    (var-set paused false)
    (emit {event: "resumed"})
    (ok true)))

(define-public (create-product (premium uint) (payout uint) (coverage uint) (max-payout uint) (oracle-id (buff 32)))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) ERR-UNAUTHORIZED)
    (let ((pid (var-get next-product-id)))
      (map-set products {pid: pid} {premium: premium, payout: payout, coverage: coverage, max-payout: max-payout, oracle-id: oracle-id, active: true})
      (map-set product-reserve {pid: pid} {reserved: u0})
      (var-set next-product-id (+ pid u1))
      (emit {event: "product-created"})
      (ok pid))))

(define-public (deactivate-product (pid uint))
  (let ((p (unwrap! (map-get? products {pid: pid}) ERR-PRODUCT-NOT-FOUND)))
    (asserts! (is-eq tx-sender (var-get admin)) ERR-UNAUTHORIZED)
    (begin
      (map-set products {pid: pid} (merge p {active: false}))
      (emit {event: "product-deactivated"})
      (ok true))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Buyer: purchase policy
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-public (buy-policy (pid uint))
  (let (
    (p (unwrap! (map-get? products {pid: pid}) ERR-PRODUCT-NOT-FOUND))
    (reserve-data (unwrap! (map-get? product-reserve {pid: pid}) ERR-PRODUCT-NOT-FOUND))
  )
    (asserts! (not (var-get paused)) ERR-CONTRACT-PAUSED)
    (asserts! (get active p) ERR-INACTIVE-PRODUCT)
    (asserts! (<= (+ (get reserved reserve-data) (get payout p)) (get max-payout p)) ERR-INSUFFICIENT-FUNDS)
    
    (try! (stx-transfer? (get premium p) tx-sender (as-contract tx-sender)))
    
    (let (
      (polid (var-get next-policy-id)) 
      (start stacks-block-height) 
      (expiry (+ stacks-block-height (get coverage p)))
    )
      (map-set product-reserve {pid: pid} {reserved: (+ (get reserved reserve-data) (get payout p))})
      (map-set policies {policy-id: polid} {owner: tx-sender, product-id: pid, start-block: start, expiry-block: expiry, payouted: false})
      (var-set next-policy-id (+ polid u1))
      (ok polid))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Oracle: report event
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-public (report-event (pid uint) (oracle-id (buff 32)) (happened bool))
  (let ((p (unwrap! (map-get? products {pid: pid}) ERR-PRODUCT-NOT-FOUND)))
    (asserts! (is-eq tx-sender (var-get oracle)) ERR-INVALID-ORACLE)
    (asserts! (is-eq oracle-id (get oracle-id p)) ERR-INVALID-ORACLE)
    (map-set oracle-reports {pid: pid} {happened: happened, reported-block: stacks-block-height})
    (ok true)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Claim: request payout
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-public (request-payout (policy-id uint))
  (let (
    (policy (unwrap! (map-get? policies {policy-id: policy-id}) ERR-POLICY-NOT-FOUND))
    (report (unwrap! (map-get? oracle-reports {pid: (get product-id policy)}) ERR-CLAIM-NOT-FOUND))
  )
    (asserts! (not (var-get paused)) ERR-CONTRACT-PAUSED)
    (asserts! (is-eq (get owner policy) tx-sender) ERR-UNAUTHORIZED)
    (asserts! (not (get payouted policy)) ERR-ALREADY-PAID)
    (asserts! (get happened report) ERR-CLAIM-NOT-FOUND)
    
    (let ((cid (var-get next-claim-id)))
      (map-set claims {claim-id: cid} {policy-id: policy-id, claimant: tx-sender, state: ST-CLAIM-PENDING, requested-at: stacks-block-height, challenger: (as-contract tx-sender), challenge-stake: u0})
      (var-set next-claim-id (+ cid u1))
      (ok cid))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Challenge: stake to challenge
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-public (challenge-claim (claim-id uint) (stake uint))
  (let ((c (unwrap! (map-get? claims {claim-id: claim-id}) ERR-CLAIM-NOT-FOUND)))
    (asserts! (> stake u0) ERR-INVALID-ORACLE)
    (asserts! (is-eq (get state c) ST-CLAIM-PENDING) ERR-CLAIM-NOT-FOUND)
    (asserts! (<= stacks-block-height (+ (get requested-at c) (var-get CHALLENGE_WINDOW_BLOCKS))) ERR-CHALLENGE-TOO-LATE)
    
    (try! (stx-transfer? stake tx-sender (as-contract tx-sender)))
    (map-set claims {claim-id: claim-id} (merge c {state: ST-CLAIM-CHALLENGED, challenger: tx-sender, challenge-stake: stake}))
    (ok true)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Resolve claim
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-public (resolve-claim (claim-id uint) (approve bool))
  (let (
    (c (unwrap! (map-get? claims {claim-id: claim-id}) ERR-CLAIM-NOT-FOUND))
    (pol (unwrap! (map-get? policies {policy-id: (get policy-id c)}) ERR-POLICY-NOT-FOUND))
    (prod (unwrap! (map-get? products {pid: (get product-id pol)}) ERR-PRODUCT-NOT-FOUND))
  )
    (asserts! (is-eq tx-sender (var-get oracle)) ERR-INVALID-ORACLE)
    (asserts! (>= stacks-block-height (+ (get requested-at c) (var-get CHALLENGE_WINDOW_BLOCKS))) ERR-CHALLENGE-TOO-LATE)
    
    (if approve
      (begin
        (map-set policies {policy-id: (get policy-id c)} (merge pol {payouted: true}))
        (let ((res (unwrap-panic (map-get? product-reserve {pid: (get product-id pol)}))))
          (map-set product-reserve {pid: (get product-id pol)} {reserved: (- (get reserved res) (get payout prod))}))
        (if (> (get challenge-stake c) u0)
          (try! (as-contract (stx-transfer? (get challenge-stake c) tx-sender (get claimant c))))
          false)
        (try! (as-contract (stx-transfer? (get payout prod) tx-sender (get claimant c))))
        (map-set claims {claim-id: claim-id} (merge c {state: ST-CLAIM-RESOLVED}))
        (ok true))
      (begin
        (if (> (get challenge-stake c) u0)
          (begin
            (try! (as-contract (stx-transfer? (get challenge-stake c) tx-sender (get challenger c))))
            u0)
          u0)
        (map-set claims {claim-id: claim-id} (merge c {state: ST-CLAIM-REJECTED}))
        (ok true)))))