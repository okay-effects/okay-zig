# AGENTS.md — okay-zig

Read before anything else, then `specs/design.md`: a change of design is a change of the spec first.

- Algebraic effects and handlers for Zig, okay-scala's design: a program is DATA (`Node`), its type `Eff(A, R)` — its
  value and its ROW of effects, checked at compile time (`Row.place`: a missing effect is a compile error naming both).
- Two layers, one set of handlers: CONTEXTS (`src/cx.zig`: a plain function given `cx`, `cx.op`, observers) and the
  MACHINE. A handler is a struct whose methods are the operations and that says `pub const Effect = E`.
- One machine (`Build.eval`): a CEK machine, its continuation an immutable stack in an arena — `k` resumed any number
  of times. Handlers: `handle` (with `k`), `handleTail` (in place: a method an operation).
- Zig 0.17.0, pinned, in `~/.zig/zig-aarch64-macos-0.17.0` (`export PATH=~/.zig/zig-aarch64-macos-0.17.0:$PATH`). The
  language changes between versions: a newer one is a deliberate move, the whole suite run.
- `zig build test`; `zig build bench -Doptimize=ReleaseFast`. Lines at most 120 wide. Commits: plain messages, no
  attribution trailers.
- `src/wire.zig`: okay's wire (okay-py's `wire.txt`); `conformance/`: the programs okay's `WireConformance` calls, the
  stdio worker, the C ABI library (`zig build worker -Doptimize=ReleaseSafe`) and `TestZigLinks.scala` — run it in a
  CLONE of okay (`git clone --local ~/work/my/okay /tmp/okay-conf`), never in okay's own tree: its header says how.
- The erasure (`Any`, `box`, `unbox`) is the machine's alone; the typed words are the only way in, so no user code
  casts. `zig fmt` keeps the form; lines over 120 are wrapped by hand.
