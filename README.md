# okay-zig

Algebraic effects and handlers for Zig, as [okay-scala](https://github.com/okay-effects/okay-scala) has them: a
program is data, its type says its value and its effects, a handler takes an effect out of the program's row — and may
resume the rest of the program once, twice, or never.

```zig
const ok = @import("okay");
const Counter = ok.effects.State(u32);

/// a tick: the state read, one more put, the old value the program's — in ANY row that has Counter
fn tick(b: *ok.Build, comptime R: anytype) ok.Eff(u32, R) {
    return b.then(Counter.get(b, R), {}, struct {
        fn f(_: void, bb: *ok.Build, n: u32) ok.Eff(u32, R) {
            return bb.andThen(Counter.put(bb, R, n + 1), bb.pure(u32, R, n));
        }
    }.f);
}

const R = ok.Row(.{ ok.effects.Reader([]const u8), Counter });   // u32 ! Reader % String + State % u32
var cell: u32 = 40;
const v = b.run(Counter.inCell(&b, Reader.given(&b, tick(&b, R), "Ann"), &cell));
```

- A ROW is a tuple of effect types: `Row(.{ F, G })`, `R.with(E)` (`R + E`); `Eff(A, R)` is `A ! R`.
- An effect is a type with its operations (`Op`, a tagged union) and the type of each one's answer (`Answer`).
- `b.perform(R, E, .tag, payload)` is an operation; `E` not in `R` is a compile error:
  `the effect Reader(u8) is not in the row Row(.{State(u32)})`.
- `b.handle(E, p, h)`: `h.ret` and `h.op(b, op, k)`, `k.answer(b, .tag, value)` resuming the rest — any number of
  times (`Choose.all` answers every choice both ways). `b.handleTail(E, p, h)`: each operation a method of `h`, its
  answer in place.
- Standard effects: `State`, `Reader`, `Writer`, `Fail`, `Choose`.

Zig 0.17.0. `zig build test`, `zig build bench -Doptimize=ReleaseFast`. One of the
[okay-effects](https://github.com/okay-effects) family. The design: [specs/design.md](specs/design.md).
