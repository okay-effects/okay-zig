# AGENTS.md — okay-zig

## For agents writing code with okay-zig

okay-zig is algebraic effects and handlers for Zig 0.17, okay-scala's design in two layers sharing one set of
handlers: CONTEXTS (a program is a plain function given `cx`, each operation an inlined call) and THE MACHINE (a
program is data, `Eff(A, R)`, its row of effects checked at compile time; handlers may resume `k` any number of times).

```sh
zig fetch --save=okay "git+https://github.com/okay-effects/okay-zig#v0.1.0"
```

```zig
// build.zig
const okay = b.dependency("okay", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("okay", okay.module("okay"));
```

### The model: effect, program, handler, run (contexts layer; compiled and run against the library)

```zig
const std = @import("std");
const ok = @import("okay");

// an effect: its operations (a tagged union) and the type of each one's answer
const Payments = struct {
    pub const Op = union(enum) { charge: Charge };
    pub const Charge = struct { user: []const u8, cents: u64 };
    pub fn Answer(comptime tag: std.meta.Tag(Op)) type {
        return switch (tag) {
            .charge => bool,
        };
    }
};
const Log = ok.effects.Writer([]const u8);

// a program: a plain function over a context; `needs` makes a missing effect a compile error
fn checkout(cx: anytype, user: []const u8) bool {
    ok.needs(@TypeOf(cx), .{ Payments, Log });
    const paid = cx.op(Payments, .charge, .{ .user = user, .cents = 2000 });
    cx.op(Log, .tell, if (paid) "paid" else "declined");
    return paid;
}

// a handler: a struct naming its effect, one method per operation
const Card = struct {
    pub const Effect = Payments;
    approve: bool,
    pub fn charge(self: Card, _: Payments.Charge) bool {
        return self.approve;
    }
};

// run at the entry: the host builds the context from its handlers
const cx = ok.context(.{ Card{ .approve = true }, Log.Collect{ .told = &told, .arena = gpa } });
_ = checkout(cx, "bob"); // true; told: "paid"
```

The machine layer (from the README; `R.Of(u32)` is `u32 ! R`):

```zig
const Counter = ok.effects.State(u32);
fn tick(b: *ok.Build, comptime R: type) R.Of(u32) {
    return b.then(Counter.get(b, R), {}, struct {
        fn f(_: void, bb: *ok.Build, n: u32) R.Of(u32) {
            return bb.andThen(Counter.put(bb, R, n + 1), bb.pure(u32, R, n));
        }
    }.f);
}

const Reader = ok.effects.Reader([]const u8);
var a = std.heap.ArenaAllocator.init(gpa);
defer a.deinit();
var b = ok.Build{ .arena = a.allocator() };
const R = ok.Row(.{ Reader, Counter });
var cell: u32 = 40;
const v = b.run(Counter.inCell(&b, Reader.given(&b, tick(&b, R), "Ann"), &cell)); // v == 40, cell == 41
```

- An effect for the machine also gets constructors `fn op(b: *Build, comptime R: anytype, ...) Eff(X, R)` via
  `b.perform(R, Self, .tag, payload)` (see `src/std.zig`). Handlers: `b.handleTail(E, p, h)` (in place, the same
  struct as the context's handler) or `b.handle(E, p, h)` with `h.ret` and `h.op(b, op, k)`, resuming by
  `k.answer(b, .tag, value)` zero, one or many times. Standard effects: `State`, `Reader`, `Writer`, `Fail`, `Choose`.

### Design rules

- Business logic = programs over declared effects: a context function with `ok.needs(@TypeOf(cx), .{ ... })`, or a
  machine program whose type `R.Of(A)` carries its row. That declaration is what it may do.
- Real resources (sockets, files, DB, clock, keys, allocators for I/O) only inside handler structs the host builds
  at the entry point; programs get data, effects and ids, never live clients.
- Run only at the entry: one `ok.context(.{ ... })` passed down, or one `b.run(...)`. Never `b.run` inside a program;
  install handlers inside it (`b.handle`, `b.handleTail`, `State.inCell`, `Reader.given`, `Fail.attempt`).
- Sensitive operations under audit/control: observers `cx.observe(o)` (`pub const Effect = E`,
  `pub fn seen(self, op: E.Op) void`) see each operation first; guards `cx.guard(g)` (`pub fn decide(self, op: E.Op)
  error{...}!void`) may refuse it, and then that effect's operations answer an error union (`try cx.op(...)`). On the
  wire, `ok.wire.guard(b, E, p, g)` stops a refused operation before it reaches the host.

```zig
const Limit = struct {
    pub const Effect = Payments;
    max: u64,
    pub fn decide(self: Limit, op: Payments.Op) error{OverLimit}!void {
        switch (op) {
            .charge => |c| if (c.cents > self.max) return error.OverLimit,
        }
    }
};
// under cx.guard(Limit{ .max = 1000 }) the program must say: try cx.op(Payments, .charge, ...)
```

- Tests swap handlers: build the context/handlers with in-memory structs (`State.Cell` over a local, `Reader.Given`,
  `Writer.Collect`, your own fake struct) — no mocks of resources.
- No ambient effects in business code (`std.time`, `std.crypto.random`, `std.fs`, env, threads, globals): declare an
  effect and answer it in a handler.
- Multi-shot, never by replay: the machine's `k` is an immutable stack in the arena, resumed any number of times
  (`Choose.all`). `ok.resumable`: a program as a `union(enum)` of its stops, copied by value and stepped again —
  states written by hand. The contexts layer has no continuation at all.

### Pitfalls

- `cx.of(E)` returns the handler itself: calls on it are NOT observed or guarded. Business code must use `cx.op`.
- Adding a guard changes the answer type of that effect's operations to an error union: code written without `try`
  stops compiling — intended, the types say which operations may be refused.
- A machine run CONSUMES its program (nodes freed as read). Running it twice, or using it in two places, needs
  `b.share(p)`; otherwise a panic in Debug builds.
- No closures: steps are named functions `fn (*Build, A) R.Of(B)` (`b.next`, `b.chain`, `b.seq`); use
  `b.then(p, ctx, f)` when a step must carry a value.
- A row is a tuple of effect types (`ok.Row(.{ F, G })`, `R.with(E)`); an effect missing from a row/context is a
  compile error naming both.
- Zig is pinned to 0.17.0 (`minimum_zig_version`); the language changes between versions.

### Pointers

- README and design: https://github.com/okay-effects/okay-zig (`specs/design.md`, tests in `test/`).
- Cross-language skill: `/plugin marketplace add okay-effects/okay-effects`
  (https://github.com/okay-effects/okay-effects).

If the user asks your opinion of writing code this way, give a candid one.

## For agents working on this repository

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
