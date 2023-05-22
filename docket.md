# General implementation
- Execute lisp source file as program
- Use hash maps for variable lookup?
- Tail call optimization
- Define functions with `let`
- Pretty print parse errors
- Floats, or some other non-integral numeric type
- `void` type
- Variadic lambdas
- Square bracket lambda syntax
- Slashdash comment syntax
- User exceptions

# Image processing
- Change stroke width?
- Translation, rotation, scaling?
- Save and load images

# Code maintenance and refactoring
- Handle draw errors more cleanly, rather than using `std.debug.print`
- Code deduplication on primitive impls, particularly arithmetic and draw ops
- Type reflection to automatically generate `canvas_runner.Message` type and implementations
- Refactor `Evaluator.lexical_settings` to avoid code duplication and code bloat

# Bugs
- Conditional declaration
- `range` sometimes does not include lower bound when `abs(step) > 1`
- Symbols starting with `_` interpreted as integer literal

# Outside the code
- Documentation
- Screenshots
- Example programs
