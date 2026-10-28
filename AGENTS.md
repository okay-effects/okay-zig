# AGENTS.md — okay-zig

Read before anything else, then `specs/design.md`: a change of design is a change of the spec first.

- Algebraic effects and handlers for Zig, okay-scala's design: a program is DATA (`Node`), its type `Eff(A, R)` — its
  value and its ROW of effects, checked at compile time (`Row.place`: a missing effect is a compile error naming both).
- One machine (`Build.eval`): a CEK machine, its continuation an immutable stack in an arena — `k` resumed any number
  of times. Handlers: `handle` (with `k`), `handleTail` (in place: a method an operation).
- Zig 0.17.0, pinned, in `~/.zig/zig-aarch64-macos-0.17.0` (`export PATH=~/.zig/zig-aarch64-macos-0.17.0:$PATH`). The
  language changes between versions: a newer one is a deliberate move, the whole suite run.
- `zig build test`; `zig build bench -Doptimize=ReleaseFast`. Lines at most 120 wide. Commits: plain messages, no
  attribution trailers.
- The erasure (`Any`, `box`, `unbox`) is the machine's alone; the typed words are the only way in, so no user code
  casts. `zig fmt` keeps the form; lines over 120 are wrapped by hand.
