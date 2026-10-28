# okay-zig — design (spec, 2026-10-28)

Status 2026-10-28: both layers built. The machine — rows, typed places, `handle` and `handleTail`, State, Reader,
Writer, Fail, Choose; memory a loop's turn, not its length; steps (`next`, `chain`, `seq`). Contexts — `context`, `op`,
`needs`, `observe`, `guard`. okay's wire: a worker on pipes and on okay's C ABI, okay's `WireConformance` passed; a
guard on the wire; direct style, mux and streams on the wire (okay's conformance: all over pipes). okay-kernel's TCK
digest: the family's. 25 tests, in Debug and ReleaseSafe.

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

## Interceptors: handlers that keep the row (2026-10-28)

`b.intercept(E, p, h)` and `b.interceptTail(E, p, h)`: `handle` and `handleTail` that KEEP the row — an operation of
`E` inside goes to `h`, one outside it past `h` to the next handler of `E` (`Handling.keeps`: a place past it is not
renumbered). So a handler sits anywhere in a program of one row, and its operation clause may perform `E` again, past
itself: forwarding.

## The family's TCK (2026-10-28)

`test/tck_test.zig`: okay-kernel's thousand random programs — handlers of logs, states, failures and choices nested
in any order by `intercept`, each effect twice (two identities, two types), Java's wrapping `int`s, the state a cell —
generated by `java.util.Random(20261010)` ported, their outcomes folded into one digest: `-8623788747993822161`, the
reference machine's, okay-java's and okay-rust's. Passed, in Debug and ReleaseSafe.

## A guard on the wire (2026-10-28)

`wire.guard(b, E, p, g)`: the context's guard (`decide(op) !void`) in the machine — an interceptor of `E` that asks
`g`; allowed, the operation is performed past it (to the host) and its answer given back; refused, the program fails
with a condition named by the guard's error (`{"kind": "OverBudget"}`), the operation never sent. `E` may be `Host`
itself: the far side's own policy over what it asks of the host.

## Direct style on the wire (2026-10-28)

The contexts layer, served: a DIRECT function is `fn (cx: wire.Direct, a: Allocator, args) !Value` — a plain function,
its host a context's handler (`Caller`), `wire.call(cx, "price_of", args)` a call that WAITS for the host's answer. Each
run is a TASK OF THE WORKER'S `Io` (`io.concurrent`): the `Io` the worker is given decides — a thread with
`Io.Threaded`, a fiber with `Io.Evented` — and the task takes turns with the worker by two `Io.Event`s: the function
runs until it calls the host, then the worker sends `perform` with `"once": true`, and `continue` gives the answer back
— once (a stack cannot be copied: a second `continue` of a `k` is a `LookupError`). A host's condition is
`error.Condition` in the function (the condition kept, sent back if it escapes); any other error a condition by its
name. `forget` of a waiting run is `Io`'s CANCELLATION (`Future.cancel`): the function's waiting call is a cancellation
point, `wire.call` answers `error.Canceled` (and every later call too), so it unwinds; the task is awaited. An `Io` that
runs nothing concurrently refuses direct calls (`RuntimeError`). Fibers are not checked yet: in Zig 0.17.0 the evented
`Io`s of macOS (`Io.Dispatch`, `Io.Kqueue`) do not compile against `Io.VTable`. `cx.guard` and `cx.observe` work in it
as in any context. `Worker.withDirect(io, entries)`; the stdio worker uses `init.io`, the library its own `Io.Threaded`.
okay's `WireConformance` DIRECT STYLE passes over pipes and FFM: 14 passed, only streams and mux skipped.

## Mux and streams on the wire (2026-10-28)

On pipes, a worker with an `Io` is MULTIPLEXED: its hello says `"mux": true`; each request is a task of an
`Io.Group`, answered when it finishes (a call waiting for another is answered once the other arrives); what requests
share is under one `Io.Mutex`, let go while a direct function runs; replies and a stream's messages are written one at a
time.

- A call with `"stream": s` is a STREAM the far side drives: answered at once, its function a task feeding it by
  `wire.emit(cx, chunk)` — waiting while the host has granted no credit, `error.Canceled` once the host cancelled —
  each chunk `{"stream": s, "chunk": …}`; its return `{"stream": s, "end": true}`, its failure the stream's condition.
  The host's `credit` grants more.
- With `"input": {"id": -s}` the HOST feeds the call: its `chunk`s and `end` queued, `wire.next(cx)` the next one
  (null at the end), each taken granting the host one more (`{"stream": -s, "credit": 1}`). Both at once: a full-duplex
  transform. `cancel` ends both.
- At the input's end the worker stops every stream (cancelled, inputs ended) and cancels the group.
- okay's `WireConformance` over pipes: every test passed — mux, a stream under a credit of two, the far side counted
  never more than its credit ahead, an early stop cancelling it, the host feeding no further than its credit, a dedup
  of 20 000 rows both ways. In process (FFM) the link is not duplex: those six skipped, as for Go's WebAssembly worker.

## Next

1. A host's policy over a Zig program: okay-guard's `Action` for each `perform` the worker sends (service = the
   worker, operation = the name, arguments) — on the host's side, okay-guard's; nothing here to change.
2. Fibers: the same suite on `Io.Evented` once Zig's evented `Io` compiles on macOS (or on Linux, `Io.Uring`).
