# okay-zig — design (spec, 2026-10-28)

Status 2026-10-28: both layers built. The machine — rows, typed places, `handle` and `handleTail`, State, Reader,
Writer, Fail, Choose; memory a loop's turn, not its length; steps (`next`, `chain`, `seq`). Contexts — `context`, `op`,
`needs`, `observe`, `guard`. okay's wire: a worker on pipes and on okay's C ABI, okay's `WireConformance` passed.
20 tests, in Debug and ReleaseSafe.

## Why it fits Zig

Zig has no closures, no garbage collector and no custom operators — and has `comptime`, where types are values. So:

- A ROW is a tuple of types, `Row(.{ F, G })`; `R.with(E)` is `R + E`; `Eff(A, R)` is `A ! R`. There is no infix
  type: the notation is a call evaluated by the compiler.
- `In[E, R]` is `R.place(E)`, computed at compile time: the place an index, its check a `@compileError` naming the
  effect and the row. A handler's row is `R.without(place)`.
- A closure is written by hand: a function with no capture and the value it holds (`then(p, ctx, f)`); the machine
  keeps the pair (`Cont`).
- Memory is an ARENA a run makes everything in, freed with it — Zig's own way.

## The machine

`Node`: a value, an operation (its place, the operation), a bind (a program and its `Cont`), a handler around a
program, a resumption (a captured `k` and an answer). `Build.eval` runs a CEK machine: the continuation a stack of
frames — binds and handlers — immutable, in the arena. An operation walks up to its handler, its place renumbered past
each other handler (`place > h.place` → one less: the row without the handled effect). A tail handler answers in place,
the stack as it is. A general handler is given `k`: the frames from the operation up to and including its own; `k`
resumed is that segment copied onto the stack where it is resumed — so `k` is resumed again, and the handler is
reinstated (deep handlers). The erasure — `Any`, `box`, `unbox` — is the machine's; the typed words are the only way
to make a node, so a user never casts.

## Memory (2026-10-28)

- A VALUE is carried in a `Val` of 16 bytes: kept in it when it fits (a slice, a number, a small union, `void`), else
  in the arena and its address kept. No allocation for the values a loop passes.
- The machine RETURNS a value in a register: no node made for it.
- A RUN CONSUMES ITS PROGRAM: each node is freed — to a free list — as soon as the machine has read it; each frame
  when it is popped. A node `shared` (`b.share(p)`) is kept, and so is everything in it while the machine is inside
  it: a program run again, or used in two places. A continuation's call returns a FRESH program (the rule a closure
  keeps: a program it holds and returns is a program used twice — share it).
- `k` captured PINS its frames: the segment up to the handler is a template; each resumption copies it, the copies
  marked shared, so what they hold is never freed and `k` is resumed again. A `k` never resumed keeps its template until
  the arena goes; so do `Handling`s, `Captured`s and the values bigger than 16 bytes — what a handler's installation
  makes, not what a loop turns.
- Debug builds never reuse a node: a freed one is poisoned (`dead`), and running it again is a panic that says to
  share it. Tests run in Debug and ReleaseSafe (`zig build test -Doptimize=ReleaseSafe`: the free lists at work).

Measured (ReleaseFast, `zig build bench`): a tick (`get`, `put`, three binds), a million of them: 17–18 ns a tick
(77 before); taken from memory in all, 4 nodes and 3 frames — 336 bytes, for a million ticks or for ten.

## Steps: the machine without closures written

A continuation in Zig is a function with no capture and the value it holds. Most continuations hold nothing but the
row: they are STEPS, functions `fn (*Build, A) R.Of(B)` declared once (generic over the row by a function returning a
struct of them) and named — `b.next(p, step)`, `b.chain(p, .{ step1, step2 })` (the types checked where two steps
meet: one's value the next one's argument), `b.seq(.{ p, q, r })` (values dropped but the last). `b.then(p, ctx, f)`
stays for the step that must hold a value.

## The contexts layer (2026-10-28)

Two ways to write a program, one set of handlers — the choice is what the program needs:

- a CONTEXT (`src/cx.zig`): the program is a plain function given `cx`; `cx.op(E, .tag, payload)` calls the handler's
  method of that name, its answer typed by `E.Answer(tag)`. The context is a tuple of handlers, each saying its effect
  (`pub const Effect = E`); an effect it lacks is a compile error naming the context's (`needs` says it where a function
  starts). As Zig itself passes `Allocator` and, since 0.16, `Io`.
- OBSERVERS (`cx.observe(o)`): each operation of `o`'s effect shown to `o.seen(op)` before its answer — the audit, at
  the one place every operation goes through. `cx.of(E)` is the handler itself: what is called on it is not observed.
- No continuation in a context: abort, choice, resuming twice, a durable step are the machine's. The handler struct is
  one: the context's `Counter.Cell` is the machine's `handleTail` handler.

Measured (ReleaseFast): a tick through a context, each step kept from folding (`doNotOptimizeAway`), 0.25 ns — the
cost of the variable; left alone, the compiler folds a million ticks into one addition. Through the machine, 20 ns.

## Guards: interceptors that decide (2026-10-28)

- A GUARD is a struct that says its effect (`pub const Effect = E`) and decides each operation of it:
  `decide(self, op) !void` — returning is allowing; an error of the guard's own refuses it, by name.
- `cx.guard(g)`: with a guard, `E`'s operations answer an ERROR UNION, `Refusal(E)!E.Answer(tag)` — the program says
  `try cx.op(…)`, and a refusal leaves the function as Zig's errors do. An effect with no guard answers plainly: the
  types say which operations may be refused (`Cx.Answered(E, tag)`), and a refusal unhandled is a compile error.
- Several guards of one effect: each asked in order, the first error refuses; their errors one set (`Cx.Refusal(E)`).
- Order: observers see the operation, then guards decide, then the handler answers — the audit sees the refused ones
  too; a refused operation is never answered.
- Contexts only: a guard in the machine is a handler around the effect that answers or fails (`Fail`) — written
  with `handle` already.

## okay's wire (2026-10-28)

`src/wire.zig`: Zig programs served to okay's hosts (okay's `ForeignWorker`; okay-py's `wire.txt` the protocol), as
okay-lean serves Lean's.

- The host's operations are ONE effect, `Host`: `request` (a name, JSON arguments; its answer the host's value or its
  condition) and `fail` (a condition by name). `Host.call(b, R, name, args)` and `Host.fail`. A program the host
  starts is `fn (*Build, []const Value) Remote.Of(Value)`, served by name or `module:name`.
- A TYPED effect goes to the host by `remote(b, E, p)`: each operation by its tag's name, its payload the arguments
  (a struct's fields each one), its answer decoded as the operation's (`TypeError` if the host's is not one).
- The worker runs a program under a handler of `Host` that does not resume: an operation stops the run with its `k`,
  kept by (run, k) id; `continue` resumes that `k` — any number of times, the machine's templates — so the host's
  handler may be multi-shot (okay's `runChoice`). A RUN IS AN ARENA: its program, rests and answers; `forget` frees it.
- Values are `std.json.Value`; okay's tagged numbers are plain inside (`{"t": "f"}` a float, `{"t": "int"}`, NaN) and
  tagged going out (a whole float stays a double). Held values (`call … held`) live in their own arenas until
  `release`; a released ref is a `LookupError`.
- The worker on stdin/stdout (`Worker.serve`, `conformance/worker.zig`) and in the host's process through FFM
  (`conformance/ffi.zig`: `okay_exchange`, `okay_free`). JSON lines, no compression. Not served: direct style and
  streams (a muxed worker's), as for Lean and Haskell.
- Checked: `test/wire_test.zig` replays transcripts; okay's own `WireConformance` (`conformance/TestZigLinks.scala`,
  run in a clone of okay): 12 passed over pipes and FFM — multi-shot across the link, a typed effect under the host's
  `Reader`, tables, held values, failures by name.

## Next

1. The family's TCK of scenarios beyond the wire's (okay-rust's open item too): one set run by every language.
2. A guard on the wire: a host's policy deciding a Zig program's operations (okay-guard's `Action`), or a Zig guard
  over the host's.
