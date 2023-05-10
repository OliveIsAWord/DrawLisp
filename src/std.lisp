; A collection of standard library functions which can be implemented within
; the language itself.

(let not (lambda b (if b #f #t)))
(let neq? (lambda (x y) (not (eq? x y))))
(let bool->int (lambda b (if b 1 0)))
(let int->bool (lambda n (neq? n 0)))
(let truthy? (lambda v (cond
    ((nil? v) #f)
    ((cons? v) #t)
    ((int? v) (int->bool v))
    ((bool? v) v)
    (#t #t))))

; (let compose (lambda (f g) (lambda x (f (g x)))))
