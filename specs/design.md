# okay-zig — design (spec, 2026-10-28)

Status: the data layer built — rows, typed places, the machine, `handle` and `handleTail`, State, Reader, Writer, Fail,
Choose; 7 tests (a million operations, `k` resumed twice). Next: the contexts layer; memory; okay's wire.

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

## Measured (ReleaseFast, one machine)

A tick (`get`, `put`, three binds), a million of them: 77 ns a tick. The arena holds 544 MB at the end: every node,
frame and value is allocated and kept until the run ends.

## Next

1. MEMORY: frames no `k` captured popped back to a free list; small values (≤ a word) kept in the node, not boxed;
   a long loop's nodes in a region freed as the loop goes.
2. THE CONTEXTS LAYER: an effect as an interface passed in — as Zig's own `Allocator` and `Io` are (since 0.16 `main`
   is given `Io`); a handler a struct implementing it; a call a call, inlined. For the effects answered in place; the
   machine for the rest (abort, choice, resuming twice, durable steps, interceptors as data).
3. okay's WIRE, so a Zig program runs under another language's handlers (the JVM's by its C ABI, as okay-lean and
   okay-rust do); the family's TCK of scenarios.
