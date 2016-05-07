#lang racket

(require db)

(provide
 (contract-out [make-table (->* ((listof symbol?)
                                 (sequence/c (sequence/c any/c)))
                                (#:permanent string?)
                               table?)]
               [find-table (-> string? table?)]
               [in-table-column (-> table?
                                    symbol?
                                    (sequence/c any/c))]
               [table-ref (-> table? symbol? symbol? any/c
                              (sequence/c any/c))]
               [table-ref1 (->* (table? symbol? symbol? any/c)
                                (any/c)
                                any/c)]
               [table-select (->* (table? (listof colspec?))
                                  (#:where any/c
                                   #:group-by (listof symbol?))
                                  (sequence/c (vectorof any/c)))]
               [natural-join (->* (table? table?)
                                  (#:permanent string?)
                                  table?)]
               [back-door/rows (-> string? boolean? any/c)])
 table?)

(define table? string?)
(define colspec? (or/c symbol? (list/c 'count)))

(define file-conn (sqlite3-connect #:database "/tmp/student-data.sqlite"
                                   #:mode 'create))
(define conn (sqlite3-connect #:database 'memory))


;; don't start at zero any more!
(define table-title-box (box 0))
(define (fresh-table-name!)
  (define idx (unbox table-title-box))
  (set-box! table-title-box (add1 (unbox table-title-box)))
  (string-append "temp_" (number->string idx)))


;(: make-table ((Listof Symbol) (Sequenceof (Sequenceof Any)) -> Table))
;(: make-table ((Listof Symbol) (Sequenceof (Sequenceof Any)) -> Table))
(define (make-table names dataseq #:permanent [maybe-table-name #f]) 
  (define name-count (length names))
  ;(: data (Listof (Vectorof Any)))
  (define data
    (for/list ([row dataseq])
      (define vec (sequence->vector row))
      (unless (= (vector-length vec) name-count)
        (error 'make-table
               "expected all rows to be of length equal to \
# of names (~v), got row: ~e"
               name-count vec))
      vec))
  (define col-name-str (col-names->col-name-str names))
  (match-define (list table-name the-conn) (name-and-connection
                                            maybe-table-name))
  (when (member table-name (list-tables the-conn))
    (raise-argument-error 'make-table
                          "table that doesn't already exist"
                          2 names dataseq maybe-table-name))
  (query-exec
   the-conn
   (format "CREATE TABLE ~a ~a;" table-name col-name-str))
  (define insert-stmt
    (string-append
     (format "INSERT INTO ~a VALUES " table-name)
     (parens (strs->commasep
              (for/list ([i (in-range (length names))]) "?")))
     ";"))
  (for ([row dataseq])
    (apply query-exec
           the-conn
           insert-stmt
           (sequence->list row)))
  table-name)

;; given a maybe-table-name, return the table name and connection to use
(define (name-and-connection maybe-table-name)
  (define permanent? maybe-table-name)
  (when (and permanent?
             (temp-table? maybe-table-name))
    (error 'make-table
           "can't create table with name ~e\n" maybe-table-name))
  (define table-name
    (cond [permanent? maybe-table-name]
          [else (fresh-table-name!)]))
  (define the-conn (if permanent? file-conn conn))
  (list table-name the-conn))


;; given a name, return a table (actually just the same string)
;; if the table exists
(define (find-table str)
  (define the-conn (if (temp-table? str) conn file-conn))
  (cond [(member str (list-tables the-conn)) str]
        [else (error 'find-table
                     "table not found: ~e\n"
                     str)]))

;; construct a view as the join of two tables (or views)
(define (natural-join t1 t2 #:permanent [maybe-table-name #f])
  
  (match-define (list view-name the-conn)
    (name-and-connection maybe-table-name))
  (cond [(and (temp-table? t1) (temp-table? t2) (temp-table? view-name))
         'okay]
        [(and (not (temp-table? t1))
              (not (temp-table? t2))
              (not (temp-table? view-name)))
         'okay]
        [else (error natural-join
                     (string-append
                      "input and output tables must all be permanent or "
                      "all be temporary"))])
  (query-exec
   the-conn
   (format "CREATE VIEW ~a AS SELECT * FROM ~a NATURAL JOIN ~a;"
           view-name t1 t2))
  view-name)

;; convert a list of symbols to a parenthesized, quoted list
;; of strings. Check that they're legal names with no duplicates
(define (col-names->col-name-str names)
  (when (check-duplicates names)
    (raise-argument-error 'col-names->col-name-str
                          "unique names" 0 names))
  (define col-name-strings
    (map col-name->sql names))
  (parens (strs->commasep col-name-strings)))

;; return the set of values (no dupes) in a column of a table
(define (in-table-column table column)
  (define the-conn (if (temp-table? table) conn file-conn))
  (define col-str (col-name->sql column))
  (query-list
   the-conn
   (format "SELECT ~a FROM ~a GROUP BY ~a;"
           column table column)))

;; given a table and two columns (from and to) and a value
;; in the 'from' column, return all values in the 'to' column
;; that match. no deduplication.
(define (table-ref table from to val)
  (define the-conn (if (temp-table? table) conn file-conn))
  (define from-str (col-name->sql from))
  (define to-str (col-name->sql to))
  (query-list
   the-conn
   (format "SELECT ~a from ~a WHERE ~a = ?"
           to-str table from-str)
   val))

;; same as table-ref, but returns exactly one
;; value, signalling error if more than one result.
(define (table-ref1 table from to val [fail-result
                                       ref-fail])
  (match (table-ref table from to val)
    [(list result) result]
    [(list) (cond [(procedure? fail-result) (fail-result)]
                  [else fail-result])]
    [other (error 'table-ref1
                  "expected one value from query, got: ~e"
                  other)]))

(define (ref-fail)
  (error 'table-ref1 "no matching value"))

;; given a table and a list of columns or (count), and optional
;; #:where and #:group-by clauses, return the rows that result.
(define (table-select table cols #:where [where-clauses #f]
                      #:group-by [group-by #f])
  (define the-conn (if (temp-table? table) conn file-conn))
  (when (empty? cols)
    (raise-argument-error 'table-select "nonempty list of columns"
                          1 table cols where-clauses group-by))
  (define col-name-strs (map col-name->sql/count cols))
  (define cols-name-str (strs->commasep col-name-strs))
  (define maybe-where
    (match where-clauses
      [#f ""]
      [other (parse-where-clauses where-clauses)]))
  (define maybe-group-by
    (match group-by
      [#f ""]
      [(list (? symbol? syms) ...)
       (~a " GROUP BY "(strs->commasep (map col-name->sql syms))" ")]))
  (query-rows
   the-conn
   (~a "SELECT "cols-name-str" FROM "table" "
       maybe-where maybe-group-by
       ";")))

;; given a list of where clauses, return a SQL WHERE string
;; currently only handles equality
(define (parse-where-clauses clauses)
  (string-append " WHERE "
                 (apply string-append
                        (add-between (map parse-where-clause clauses)
                                     " AND "))
                 " "))

;; given a single WHERE clause, return the corresponding SQL string
(define (parse-where-clause clause)
  (match clause
    [(list '= a b)
     (string-append (parse-sql-expr a) " = "
                    (parse-sql-expr b))]
    [(list '< a b)
     (string-append (parse-sql-expr a) " < "
                    (parse-sql-expr b))]
    [other
     (error 'parse-where-clause "unimplemented 56fef1ed")]))




;; given a single sql element (symbol, string, number), produce
;; the corresponding sql string
(define (parse-sql-expr e)
  (match e
    [(? symbol? e) (col-name->sql e)]
    [(and (? string? e)
          ;; not clear what kind of strings sqlite accepts.
          ;; being conservative for now (no internet connection to
          ;; check...)
          (regexp #px"^[-a-zA-Z0-9 .,!@#$%^&*()_]*$"))
     (string-append "'" e "'")]
    ;; again, I'm sure some decimals will work fine...
    [(? integer? i) (number->string i)]))




;; take a list of strings, add commas between them, and append them
(define (strs->commasep strs)
  (apply string-append (add-between strs ",")))

;; wrap parens around a string
(define (parens str)
  (string-append "(" str ")"))

;; is this a temporary table?
(define (temp-table? table)
  (not (not (regexp-match #px"^temp_[0-9]+$" table))))

;; map a column name symbol to a quoted string:
(define (col-name->sql name)
  (define name-str (symbol->string name))
  (unless (regexp-match #px"^[a-zA-Z0-9_]+$" name-str)
    (error
     'col-name->quoted-str
     "expected column names consisting only of a-zA-Z0-9_, got: ~v"
     name))
  (string-append "\"" name-str "\""))

;; map (count) to COUNT(*), other symbols to quoted identifiers
(define (col-name->sql/count name)
  (match name
    [(list 'count) "COUNT(*)"]
    [(? symbol? s) (col-name->sql s)]
    [other (raise-argument-error 'col-name->sql/count
                                 "symbol or '(count)"
                                 0 name)]))


;; convert a sequence to a vector
;(: sequence->vector (All (T) ((Sequenceof T) -> (Vectorof T))))
(define (sequence->vector s)
  (list->vector (sequence->list s)))

;; back door--use sqlite interface directly
(define (back-door/rows str temp-conn?)
  (define the-conn (if temp-conn? conn file-conn))
  (query-rows the-conn str))

(module+ test
  (require rackunit)


  (check-equal? (name-and-connection #f)
              (list "temp_4" conn))
(check-equal? (name-and-connection "zoobah")
              (list "zoobah" file-conn))
(check-exn #px"can't create table with name"
           (λ () (name-and-connection "temp_3")))
  
  (check-equal? (temp-table? "temp_0") #t)
  (check-equal? (temp-table? "zquoh") #f)
  
(check-equal? (parse-where-clauses '((= zagbar 2)))
              " WHERE \"zagbar\" = 2 ")
(check-equal? (parse-where-clauses '((= zagbar 2)
                                     (= "abc" def)))
              " WHERE \"zagbar\" = 2 AND 'abc' = \"def\" ")

(check-equal? (parse-where-clause '(= zagbar 2))
              "\"zagbar\" = 2")
(check-equal? (parse-where-clause '(= "abc" def))
              "'abc' = \"def\"")

(check-equal? (parse-sql-expr 13) "13")
(check-equal? (parse-sql-expr "abc") "'abc'")
(check-equal? (parse-sql-expr 'abc) "\"abc\"")


(check-equal? (col-name->sql 'ooth) "\"ooth\"")
(check-equal? (col-names->col-name-str '(a b c))
              "(\"a\",\"b\",\"c\")")
(check-equal? (col-names->col-name-str '(aaa b c))
              "(\"aaa\",\"b\",\"c\")")
(check-exn #px"expected column names"
           (λ () (col-names->col-name-str '(a_-3 b c))))
(check-exn #px"unique names"
           (λ () (col-names->col-name-str '(abc abc c))))
(check-exn #px"all rows to be of length"
           (λ () (make-table '(a b c) '((1 2 3) (2 3 4 5)))))
(define t1
  (make-table '(a b zagbar quux)
              (list (list 3 4 5 "p")
                    (list 8 87 2 "q")
                    (list 1 88 2 "q")
                    (list 1 87 2 "q"))))

  (check-equal? (table-select t1 '(b) #:where '((< 2 a)))
                '(#(4)
                  #(87)))

(check-equal? (table-select t1 '(b a)
                            #:where '((= zagbar 2)))
              '(#(87 8)
                #(88 1)
                #(87 1)))

(check-equal? (list->set
               (sequence->list (in-table-column t1 'quux)))
              (set "q" "p"))
(check-equal? (list->set (table-ref t1 'quux 'b "q"))
              (set 88 87))
(check-exn #px"expected one value"
           (λ () (table-ref1 t1 'quux 'b "q")))
  (check-exn #px"no match"
             (λ () (table-ref1 t1 'quux 'b "cronjob")))
  (check-equal? (table-ref1 t1 'quux 'b "cronjob" 124)
                124)
(check-equal? (table-ref1 t1 'quux 'b "p")
              4)

(define t2
  (make-table '(b trogdor)
              '((1 1234)
                (87 2242))))

(check-equal?
 (table-select t1 '(b quux (count)) #:group-by '(b quux))
 '(#(4 "p" 1)
   #(87 "q" 2)
   #(88 "q" 1)))

(define t3 (natural-join t1 t2))


(check-equal?
 (table-select t3 '(a b zagbar quux trogdor))
 '(#(8 87 2 "q" 2242)
   #(1 87 2 "q" 2242)))

  (check-equal?
   (list->set (table-select
    (natural-join
     (make-table '(student score1) '(#("bob" 3) #("annie" 4) #("bob" 6)))
     (make-table '(student score2) '(#("bob" 5) #("annie" 13) #("annie" 9))))
    '(student score1 score2)))
   (list->set
    '(#("bob" 3 5) #("bob" 6 5) #("annie" 4 13) #("annie" 4 9))))

  (check-equal? (find-table t3) t3)
  (check-exn #px"table not found"
             (λ () (find-table "squazle")))

  
)



;(check-equal? (table-select t1 '(a quux) '((= ))))
