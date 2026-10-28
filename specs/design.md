# okay-zig — design (spec, 2026-10-28)

Status 2026-10-28: both layers built. The machine — rows, typed places, `handle` and `handleTail`, State, Reader,
Writer, Fail, Choose; memory a loop's turn, not its length; steps (`next`, `chain`, `seq`). Contexts — `context`, `op`,
`needs`, `observe`. 12 tests, in Debug and ReleaseSafe. Next: okay's wire, the family's TCK.

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

## Next

1. okay's WIRE, so a Zig program runs under another language's handlers (the JVM's by its C ABI, as okay-lean and
   okay-rust do); the family's TCK of scenarios.
2. Interceptors that decide (a guard refusing an operation): Zig's errors — an operation's answer an error union.
