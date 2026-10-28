# okay-zig

Algebraic effects and handlers for Zig, as [okay-scala](https://github.com/okay-effects/okay-scala) has them, in two
layers with one set of handlers:

- CONTEXTS: a program a plain Zig function, its effects the handlers of a context it is given — as Zig gives
  `Allocator` and `Io`. An operation is a call, inlined: a tick of a counter is a quarter of a nanosecond.
- THE MACHINE: a program as data, its type its value and its row of effects; a handler takes an effect out of the row
  and may resume the rest of the program once, twice, or never — for what needs it (abort, choice, resuming twice).

```zig
/// a plain function: its effects the context's, each operation a call — an effect missing, a compile error
fn greet(cx: anytype) usize {
    ok.needs(@TypeOf(cx), .{ Name, Counter });
    const who = cx.op(Name, .ask, {});
    const n = cx.op(Counter, .get, {});
    cx.op(Counter, .put, n + 1);
    return who.len * 100 + n;
}

var cell: u32 = 7;
const cx = ok.context(.{ Counter.Cell{ .s = &cell }, Name.Given{ .env = "Ann" } });
_ = greet(cx);                                              // 307
_ = greet(cx.observe(Audit{ … }));                          // each Counter operation seen first
```

GUARDS decide: `cx.guard(g)`, `g.decide(op)` returning an error of its own to refuse — and then that effect's
operations answer an error union, so the program says `try cx.op(Counter, .put, n)` and a refusal leaves it as Zig's
errors do. An effect with no guard answers plainly: the types say which operations may be refused.

A handler is a struct whose methods are the operations (`Counter.Cell`: `get`, `put`) and that says its effect
(`pub const Effect = Counter`); the same struct answers the machine's `handleTail`. Observers (`cx.observe(o)`) see
each operation of their effect before it is answered — the audit, at the one call every operation goes through.

## The machine

```zig
const ok = @import("okay");
const Counter = ok.effects.State(u32);

/// a tick: the state read, one more put, the old value the program's — in ANY row that has Counter;
/// `R.Of(u32)` is `u32 ! R`
fn tick(b: *ok.Build, comptime R: type) R.Of(u32) {
    return b.then(Counter.get(b, R), {}, struct {
        fn f(_: void, bb: *ok.Build, n: u32) R.Of(u32) {
            return bb.andThen(Counter.put(bb, R, n + 1), bb.pure(u32, R, n));
        }
    }.f);
}

const R = ok.Row(.{ ok.effects.Reader([]const u8), Counter });   // u32 ! Reader % String + State % u32
var cell: u32 = 40;
const v = b.run(Counter.inCell(&b, Reader.given(&b, tick(&b, R), "Ann"), &cell));
```

- A ROW is a tuple of effect types: `Row(.{ F, G })`, `R.with(E)` (`R + E`); `R.Of(A)` — or `Eff(A, .{ F, G })` —
  is `A ! R`. Zig has no infix types: a type is a call the compiler evaluates.
- An effect is a type with its operations (`Op`, a tagged union) and the type of each one's answer (`Answer`).
- `b.perform(R, E, .tag, payload)` is an operation; `E` not in `R` is a compile error:
  `the effect Reader(u8) is not in the row Row(.{State(u32)})`.
- `b.handle(E, p, h)`: `h.ret` and `h.op(b, op, k)`, `k.answer(b, .tag, value)` resuming the rest — any number of
  times (`Choose.all` answers every choice both ways). `b.handleTail(E, p, h)`: each operation a method of `h`, its
  answer in place.
- STEPS instead of closures: `b.next(p, f)`, `b.chain(p, .{ double, save })`, `b.seq(.{ p, q, r })` — each step a
  function `fn (*Build, A) R.Of(B)` declared once and named; `b.then(p, ctx, f)` when a step must hold a value.
- Standard effects: `State`, `Reader`, `Writer`, `Fail`, `Choose`.
- MEMORY: a run consumes its program — each node freed as soon as it is read, frames reused — so a loop runs in the
  memory of one turn (a million operations: 4 nodes, 3 frames). `b.share(p)` keeps a program for another run or for
  a second place; a program run twice unshared is a panic in Debug builds, saying so.

## okay's wire

Zig programs run under another language's handlers: `ok.wire` serves them to okay's hosts on [okay's
wire](https://github.com/okay-effects) — on a child's pipes (`zig build worker`: `zig-out/bin/zig-worker`) or in the
host's own process through its C ABI (`zig-out/lib/libokay-zig-worker`). A program performs `Host` operations
(`Host.call(b, R, "price_of", args)`) or a typed effect sent by `remote`; each goes to the host, which resumes the rest
any number of times. In DIRECT STYLE a plain function given a context calls the host and waits for the answer (`try
wire.call(cx, "price_of", args)`) — a task of the worker's `Io`, a thread or a fiber as that `Io` decides. The program
as data stays the main path: its `k` is resumed any number of times. `wire.guard(b, E, p, g)` puts a guard before them:
a refused operation never reaches the host, and the program fails with a condition named by the guard's error. On pipes
the worker is multiplexed: requests in flight together, and streams both ways under credit (`wire.emit`, `wire.next`).
okay's `WireConformance` passes in full over pipes (multi-shot across the link, typed callbacks under the host's
`Reader`, tables, held values, failures by name, direct style, mux, streams, a duplex dedup):
`conformance/TestZigLinks.scala`.

## Resumable programs

For the effects whose rest is taken many times (choice, backtracking), `ok.resumable` keeps the rest as a VALUE with
no machine: a program is a `union(enum)` of its stops, each holding its live variables, and `step(self, answer)`
goes to the next stop. Zig copies a union by value, so a handler resumes the rest as often as it wants — every path of
a choice among 1000 in 0.38 µs, against 29 µs through the machine (`zig build lanes -Doptimize=ReleaseFast`). The
states are written by hand: the shape Rust's `#[resumable]` and Goose's okgc generate.

## The family's TCK

okay-kernel's thousand random programs — handlers nested in any order (`b.intercept`: a handler that keeps the row),
each effect twice — give okay-kernel's digest here as on the reference machine, okay-java and okay-rust
(`test/tck_test.zig`).

## Using it

```sh
zig fetch --save=okay "git+https://github.com/okay-effects/okay-zig#v0.1.0"
```

```zig
// build.zig
const okay = b.dependency("okay", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("okay", okay.module("okay"));
```

Then `const ok = @import("okay");` — `ok.context`, `ok.Build`, `ok.effects`, `ok.wire`.

Zig 0.17.0. `zig build test`, `zig build bench -Doptimize=ReleaseFast`. One of the
[okay-effects](https://github.com/okay-effects) family. The design: [specs/design.md](specs/design.md).
