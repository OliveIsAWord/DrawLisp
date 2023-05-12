# General implementation
- Execute lisp source file as program
- Use hash maps for variable lookup?
- Tail call optimization
- Recursion limit
- Typeof
- Pretty print parse errors
- Floats, or some other non-integral numeric type

# Image Processing
- Change Draw Color
- Resize window
- Change window position

# Code maintenance and refactoring
- Handle draw errors more cleanly, rather than using `std.debug.print`
- (Easy) Remove "invalid boolean literal" lexer error
- Pass `?*Value.Cons` to primitive impls (fixes todos like `getArgsNoEval`)
- Code deduplication on primitive impls, particularly arithmetic and draw ops
- Type reflection to automatically generate `canvas_runner.Message` type and implementations
