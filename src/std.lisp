; A collection of standard library functions which can be implemented within
; the language itself.

(let true (eq? 0 0))
(let false (eq? 0 1))
(let not (lambda b (if b false true)))
(let neq? (lambda (x y) (not (eq? x y))))
(let bool->int (lambda b (if b 1 0)))
(let int->bool (lambda n (neq? n 0)))
(let truthy? (lambda v (cond
    ((nil? v) false)
    ((cons? v) true)
    ((int? v) (int->bool v))
    ((bool? v) v)
    (true true))))

; (let compose (lambda (f g) (lambda x (f (g x)))))
(let reduce (lambda (op list) (fold op (car list) (cdr list))))

(let white (color 255 255 255))
(let black (color 0 0 0))

(let :clear-color white)
(let :fill-color white)
(let :stroke-color black)
