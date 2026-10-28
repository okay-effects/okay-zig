const std = @import("std");
const ok = @import("okay");
const S = ok.effects;
const Build = ok.Build;
const Eff = ok.Eff;
const t = std.testing;

const Counter = S.State(u32);
const Name = S.Reader([]const u8);

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

/// a tick: the state read, one more put, the old value the program's
fn tick(b: *Build, comptime R: anytype) Eff(u32, R) {
    return b.then(Counter.get(b, R), {}, struct {
        fn f(_: void, bb: *Build, n: u32) Eff(u32, R) {
            return bb.map(Counter.put(bb, R, n + 1), n, struct {
                fn g(old: u32, _: void) u32 {
                    return old;
                }
            }.g);
        }
    }.f);
}

test "state in a cell: ticks, the old values, the state after" {
    var a = arena();
    defer a.deinit();
    var b = Build{ .arena = a.allocator() };
    const R = ok.Row(.{Counter});
    var cell: u32 = 40;
    const p = b.andThen(tick(&b, R), tick(&b, R));
    try t.expectEqual(41, b.run(Counter.inCell(&b, p, &cell)));
    try t.expectEqual(42, cell);
}

test "two effects, one row, handled in either order; a row written as R.with(E)" {
    var a = arena();
    defer a.deinit();
    var b = Build{ .arena = a.allocator() };
    const R = ok.Row(.{Name}).with(Counter); // Name + Counter
    const p = b.then(Name.ask(&b, R), {}, struct {
        fn f(_: void, bb: *Build, who: []const u8) Eff(usize, R) {
            return bb.map(tick(bb, R), who.len, struct {
                fn g(len: usize, n: u32) usize {
                    return len * 100 + n;
                }
            }.g);
        }
    }.f);
    var cell: u32 = 7;
    try t.expectEqual(307, b.run(Name.given(&b, Counter.inCell(&b, p, &cell), "Ann")));
    cell = 7;
    try t.expectEqual(307, b.run(Counter.inCell(&b, Name.given(&b, p, "Ann"), &cell)));
}

test "fail: the rest dropped, the failure the value; what was done before it stays" {
    var a = arena();
    defer a.deinit();
    var b = Build{ .arena = a.allocator() };
    const Err = S.Fail([]const u8);
    const R = ok.Row(.{ Counter, Err });
    var cell: u32 = 0;
    const p = b.andThen(tick(&b, R), b.then(Err.raise(&b, u32, R, "no"), {}, struct {
        fn f(_: void, bb: *Build, x: u32) Eff(u32, R) {
            return bb.andThen(Counter.put(bb, R, 999), bb.pure(u32, R, x));
        }
    }.f));
    const got = b.run(Counter.inCell(&b, Err.attempt(&b, p), &cell));
    try t.expectEqualStrings("no", got.failed);
    try t.expectEqual(1, cell); // the tick done, the put after the raise never
}

test "choose: the rest resumed twice — every value, in order" {
    var a = arena();
    defer a.deinit();
    var b = Build{ .arena = a.allocator() };
    const R = ok.Row(.{S.Choose});
    const p = b.then(S.Choose.flip(&b, R), {}, struct {
        fn f(_: void, bb: *Build, x: bool) Eff(u8, R) {
            return bb.map(S.Choose.flip(bb, R), x, struct {
                fn g(first: bool, second: bool) u8 {
                    return @as(u8, if (first) 2 else 0) + @as(u8, if (second) 1 else 0);
                }
            }.g);
        }
    }.f);
    try t.expectEqualSlices(u8, &.{ 3, 2, 1, 0 }, b.run(S.Choose.all(&b, p)));
}

test "choose under state: the cell is one, the choices many — handled outside or inside" {
    var a = arena();
    defer a.deinit();
    var b = Build{ .arena = a.allocator() };
    const R = ok.Row(.{ Counter, S.Choose });
    const p = b.then(S.Choose.flip(&b, R), {}, struct {
        fn f(_: void, bb: *Build, x: bool) Eff(u32, R) {
            return bb.map(tick(bb, R), x, struct {
                fn g(first: bool, n: u32) u32 {
                    return if (first) n + 100 else n;
                }
            }.g);
        }
    }.f);
    var cell: u32 = 0;
    try t.expectEqualSlices(u32, &.{ 100, 1 }, b.run(Counter.inCell(&b, S.Choose.all(&b, p), &cell)));
    try t.expectEqual(2, cell);
}

/// a loop of `n` ticks, built as it runs
fn loop(b: *Build, comptime R: anytype, n: u32) Eff(u32, R) {
    if (n == 0) return Counter.get(b, R);
    return b.then(tick(b, R), n, struct {
        fn f(m: u32, bb: *Build, _: u32) Eff(u32, R) {
            return loop(bb, R, m - 1);
        }
    }.f);
}

test "a million operations: the machine's stack its own, not the call stack" {
    var a = arena();
    defer a.deinit();
    var b = Build{ .arena = a.allocator() };
    const R = ok.Row(.{Counter});
    var cell: u32 = 0;
    try t.expectEqual(1_000_000, b.run(Counter.inCell(&b, loop(&b, R, 1_000_000), &cell)));
}

test "writer: told in order" {
    var a = arena();
    defer a.deinit();
    var b = Build{ .arena = a.allocator() };
    const Log = S.Writer([]const u8);
    const R = ok.Row(.{Log});
    var told: std.ArrayList([]const u8) = .empty;
    const p = b.andThen(Log.tell(&b, R, "one"), Log.tell(&b, R, "two"));
    b.run(b.handleTail(Log, p, Log.Collect{ .told = &told, .arena = b.arena }));
    try t.expectEqual(2, told.items.len);
    try t.expectEqualStrings("two", told.items[1]);
}
