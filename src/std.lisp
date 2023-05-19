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

; Is this alignment in the source code good? I frequently find the answer to be "no".
(let black   #000000)
(let red     #ff0000)
(let green   #00ff00)
(let blue    #0000ff)
(let cyan    #00ffff)
(let magenta #ff00ff)
(let yellow  #ffff00)
(let white   #ffffff)

(let :clear-color white)
(let :fill-color white)
(let :stroke-color black)
