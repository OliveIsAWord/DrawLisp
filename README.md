<a href="https://oliveisaword.itch.io/drawlisp?secret=YvWD7OeAYr5Go241rtOMFrdbRG8">
    <img src="https://static.itch.io/images/badge-color.svg" alt="Available on itch.io" width=200/>
</a>

<img src="icon_large_transparent.png" alt="DrawLisp logo" align="right" width="256"/>

# DrawLisp
A programming language and environment focused on drawing to a digital canvas, similar to [Processing](https://processing.org/) and [p5.js](https://p5js.org/). Users primarily interact with DrawLisp through an interactive shell (a.k.a. a REPL). The language is a Lisp dialect inspired by Scheme.

```lisp
(let :clear-color (color 200 150 255))
(create-window 600 400)
(let :fill-color black)
(let :stroke-color (color 150 150 150))
(begin ; defines a new block of code
        (let :fill-color white)
        (rect 50 60 200 200)) ; draws a white square
(rect 350 140 200 200) ; draws a black square
```

## Building from source

Provide a filepath to SDL in a file `sdl_filepath.txt`.
```
zig build run
```

To generate a release build:
```
zig build run -Drelease-safe=true
```

You can try `release-fast` and `release-small` at your own peril; I do not trust that this code has no undefined behavior!

This works for building on Windows, to Windows. I can't imagine it would be so hard to support Mac or Linux, but my knowledge of build systems and Zig build scripts is very limited. PRs greatly appreciated!
