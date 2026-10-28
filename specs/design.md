# okay-zig — design (spec, 2026-10-28)

Status: the data layer built — rows, typed places, the machine, `handle` and `handleTail`, State, Reader, Writer, Fail,
Choose; memory a loop's turn, not its length; 8 tests (a million operations, `k` resumed twice, sharing), in Debug and
ReleaseSafe. Next: the contexts layer; okay's wire.

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

## Next

1. THE CONTEXTS LAYER: an effect as an interface passed in — as Zig's own `Allocator` and `Io` are (since 0.16 `main`
   is given `Io`); a handler a struct implementing it; a call a call, inlined. For the effects answered in place; the
   machine for the rest (abort, choice, resuming twice, durable steps, interceptors as data).
2. okay's WIRE, so a Zig program runs under another language's handlers (the JVM's by its C ABI, as okay-lean and
   okay-rust do); the family's TCK of scenarios.
