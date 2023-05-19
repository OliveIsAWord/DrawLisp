# General implementation
- Execute lisp source file as program
- Use hash maps for variable lookup?
- Tail call optimization
- Define functions with `let`
- Pretty print parse errors
- Floats, or some other non-integral numeric type
- Random number generation
- `void` type
- variadic lambdas
- square bracket lambda syntax

# Image processing
- Transparency
- Change stroke width?
- Translation, rotation, scaling?
- Save and load images
- Resize window
- Change window position

# Code maintenance and refactoring
- Handle draw errors more cleanly, rather than using `std.debug.print`
- Code deduplication on primitive impls, particularly arithmetic and draw ops
- Type reflection to automatically generate `canvas_runner.Message` type and implementations
- Refactor `Evaluator.lexical_settings` to avoid code duplication and code bloat

# Outside the code
- Documentation
- Screenshots
- Example programs
