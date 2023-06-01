⚠️ These docs are missing a lot! Please refer to the commits or the source code for more information about the DrawLisp language.

# Introduction

DrawLisp is a dialect of the [Lisp](https://en.wikipedia.org/wiki/Lisp_(programming_language)) family of programming languages. Here is an example program.

```lisp
; set the color of the background, and the color of the lines and filled areas
(let :clear-color black)
(let :stroke-color white)
(let :fill-color (color 255 50 30))

; opens a 400x400 canvas window
(create-window 400 400)

; draws a rectangle to the middle of the screen
(rect 150 150 100 100)

; draws two crossing lines
(line 150 150 250 250)
(line 150 250 250 150)
```

The expression `(f arg1 arg2 arg3 [etc.])` calls the function `f` with the given arguments.

You can exit the interactive shell by entering `;`.

# Lexical settings

Lexical settings are perhaps the most novel concept implemented in this project. They are certain variable names (currently `:fill-color`, `:stroke-color`, and `:clear-color`) are read by the evaluator to determine how to draw a given shape. Importantly, these definitions are forgotten at the end of the block of code in which they are defined. Consider the following example:

```lisp
(create-window)
(let :fill-color black)
(begin ; defines a new block of code
        (let :fill-color white)
        (rect 100 100 100 100)) ; draws a white square
(rect 300 300 100 100) ; draws a black square
```

These lexical settings replace traditional setter functions (like `fill` and `stroke` in Processing, for example). Importantly, this means that it's impossible for a function call to change any lexical settings in the current block.

# Notes for experienced programmers
These are notes for this tool which I don't want to leave undocumented but I also don't know how to explain to the uninitiated.

- In the interactive shell, you can omit the top level parens.
- DrawLisp supports `.` pair syntax. Cons pairs do not need to be well-formed lists.
- DrawLisp is early-binding with variables.
- DrawLisp is lexically scoped.
- Recursion is vaguely supported but requires using a fixed-point combinator, but is not encouraged as it will eventually cause an unrecoverable stack overflow in the evaluator.
- Whether a builtin function is a lambda or a primitive is an implementation detail, and users should not depend on this difference.

# Terminology
List - Either `()`, or a value `x` of type `cons` such that `(cdr x)` is a list.

# Builtin Values
- `true`: The truthy value.
- `false`: The falsy value.
- `white`: The color `#ffffff`.
- `black`: The color `#000000`.

# Builtin functions
An argument surrounded by square brackets (e.g. `[val]`) is optional. An Argument surrounded by parentheses (e.g. `(val1 val2 val3)`) must be a list of that many elements. An argument prepended by two periods (e.g. `..vals`) is a list of zero or more arguments (a.k.a. variadic arguments).

### quote
`(quote arg)`

Returns `arg` without evaluating it. The shorthand `'arg` is preferred.

## Console functions
### print
`(print value)`

Prints the value to the interactive shell.

## Canvas and Graphics

### color
`(color r g b)`

Returns a value of type `color` with the given red, green, and blue values, clamped to the range `[0..255]`. `r`, `g`, and `b` must be of type `int`.

### create-window
`(create-window [width height])`
Create a canvas window of a given width and height, destroying any previously created window. `width` and `height` default to `500`. `width` and `height` must be of type `int`.

### draw
`(draw)`

Manually tells the canvas to rerender to display current changes. Only useful within computationally long loops.

### clear
`(clear)`

Clears the canvas with color `:clear-color`.

### point
`(point x y)`

Draws a pixel with color `:stroke-color` at the given xy-position. `x` and `y` must be of type `int`.

### line
`(point x1 y1 x2 y2)`

Draws a line with color `:stroke-color` between the two given xy-positions. `x1`, `y1`, `x2`, and `y2` must be of type `int`.

### rect
`(rect x y w h)`

Draws a rectangle filled with color `:fill-color` and bordered with color `:stroke-color`. `x` and `y` give the xy-position of the top left corner of the rectangle, and `w` and `h` give the width and height of the rectangle. `x`, `y`, `w`, and `h` must be of type `int`.

### destroy-window
(destroy-window)

Close the current canvas window, if one exists.


### Typechecking functions
- `(atom? x)` returns `true` if `x` is not of type `cons`.
- `(nil? x)` returns `true` if `x` is the value `()`.
- `(cons? x)` returns `true` if `x` is of type `cons`.
- `(int? x)` returns `true` if `x` is of type `int`.
- `(bool? x)` returns `true` if `x` is of type `bool`.
- `(symbol? x)` returns `true` if `x` is of type `symbol`.
- `(primitive? x)` returns `true` if `x` is of type `primitive`.
- `(lambda? x)` returns `true` if `x` is of type `lambda`.
- `(function? x)` returns `true` if `x` is of type `primitive` or `lambda`.
- `(color? x)` returns `true` if `x` is of type `color`.

## Arithmetic functions
- `(+ ..elements)` returns the sum of a list of numbers.
- `(* ..elements)` returns the product of a list of numbers.
- `(- n)` returns the negative value of `n`.
- `(- n ..elements)` returns the difference between `n` and the sum of `elements`. `elements` must be non-empty.
- `(/ n ..elements)` returns the quotient between `n` and `elements`, left-associative, rounding down. `elements` must be non-empty. Division by zero is not allowed.
- `(% n ..elements)` returns the modulo between `n` and `elements`, left-associative. `elements` must be non-empty. Modulo by zero is not allowed.

## Boolean functions

### eq?
`(eq? x y)`

Checks if `x` and `y` are equal. If `x` and `y` are of type `cons`, this function instead returns `false`.

### neq?
`(neq? x y)`

Returns the negation of `(eq? x y)`.

### not
`(not b)`

Returns the negation of `b`. `b` must be of type `bool`.

### bool->int
`(bool->int b)`

Returns 1 if `b` is `true` and 0 if `b` is `false`. `b` must be of type `bool`.

### int->bool
`(int->bool n)`

Returns `false` if `n` equals 0, and `true` otherwise. `n` must be of type `int`.

### truthy?
`(truthy? x)`

Returns `false` if `x` is `()`, `false`, or `0`, and `true` otherwise.

## Program structure functions

### cond
`(cond ..(condition ..body))`

Evaluates each `condition` in order. If a `condition` yields `true`, the corresponding `body` will be evaluated and yielded. Otherwise, this function yields `()`. Each `condition` must yield a value of type `bool`, and each `body` must be non-empty.

### if
`(if condition true-body [false-body])`

If `condition` evaluates to `true`, this function evaluates and yields `true-body`. Otherwise, it evaluates and yields `false-body`. `false-body` defaults to `()`.

### begin
`(begin ..body)`

Evaluates every element of `body`. `body` defaults to `()`.

### lambda
`(lambda args ..body)`

Yields a function which will evaluate `body` when called with the given `args`. `args` must either be an identifier or a list of identifiers. `body` must be non-empty.

### let
`(let variable ..body)`

Declares a new variable `variable` with the yielded value of the evaluated `body`. If an existing variable with the same name is already defined, it will be shadowed for the duration of the new variable's scope. `variable` must be a symbol. `body` must be non-empty.

## Cons and list operations

### car
`(car x)`

Returns the first element of `x`. `x` must be of type `cons`.

### cdr
`(cdr x)`

Returns the remaining elements of `x`. `x` must be of type `cons`.

### cons
`(cons a b)`

Returns a value of type `cons` such that `(car (cons a b))` equals `a` and `(cdr (cons a b))` equals `b`.

### range
`(range [start] end [step])`

Returns a list of numbers between `start` and `end` at increments `step`, not including `end`. `start` is defaulted to `0` and `step` is defaulted to `1`. If `start > end`, they will implicitly be swapped, e.g.

- `(range n)` where `n` is positive will yield a list of numbers in the range `[0..n)`.
- `(range n)` where `n` is negative will yield a list of numbers in the range `[n..0)`.
- `(range n m)` where `n < m` will yield a list of numbers in the range `[n..m)`.
- `(range n m)` where `n > m` will yield a list of numbers in the range `[m..n)`.

`start`, `end`, and `step` must be of type `int`. `step` must not be `0` unless `start` and `end` are equal.

### map
`(map fn list)`

Returns a new list such that each element of the returned list is the value of function `fn` applied to each element of `list`, preserving order. `fn` must be a function which can accept one argument. `list` must be a list.

### filter
`(filter fn list)`

Returns a new list that only contains elements of `list` where applying `fn` to that element returns `true`, preserving order. `fn` must be a function which can accept one argument and returns a value of type `bool`. `list` must be a list.

### fold
`(fold fn init list)`

For every element `x` in `list`, sets `init` to `(fn init x)`, returning the final value of `init`. `fn` must be a function which can accept two arguments. `list` must be a list.

### reduce
`(reduce fn list)`

Like `fold`, but uses the first element of `list` as the initial value folded with the remaining elements of `list`. Equivalent to `(fold fn (car list) (cdr list))`. `fn` must be a function which can accept two arguments. `list` must be a non-empty list.
