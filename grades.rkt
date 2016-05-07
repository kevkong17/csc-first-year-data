#lang typed/racket

(provide grade-ordering
         class-ordering
         success-grades
         qtrs-in-range
         vref)

;; shared knowledge about grades.
;; and classes.
;; and a nice abstraction (uh oh).

;; grades that allow you to take the next class in the first year:
(: success-grades (Listof String))
(define success-grades '("A" "A-" "B+" "B" "B-" "C+" "C" "C-"))

;; grade ordering, best to worst
(: grade-ordering (Listof String))
(define grade-ordering
  (reverse
  '("W" "WU" "AU" "U" "NC" "I" "F" "D-" "D" "D+" "C-" "C" "C+" "B-" "B" "B+" "A-" "A")))

;; class ordering, first to last
(: class-ordering (Listof String))
(define class-ordering
  '("CPE 123" "CPE 101" "CPE 102" "CPE 103"))


;; all of the quarters in a given range (inclusive)
(: qtrs-in-range (Natural Natural -> (Listof Natural)))
(define (qtrs-in-range earliest-qtr latest-qtr)
  (for/list ([qtr : Natural
                  (ann (in-range earliest-qtr
                                 (add1 latest-qtr)
                                 2)
                       (Sequenceof Natural))]
             #:when (member (modulo qtr 10) '(2 4 6 8)))
    qtr))

(: vref (All (T) (Integer -> ((Vectorof T) -> T))))
(define (vref idx)
  (λ ([v : (Vectorof T)]) (vector-ref v idx)))