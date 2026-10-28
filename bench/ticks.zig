const std = @import("std");
const ok = @import("okay");
const Counter = ok.effects.State(u32);
const Build = ok.Build;
const Eff = ok.Eff;

fn tick(b: *Build, comptime R: anytype) Eff(u32, R) {
    return b.then(Counter.get(b, R), {}, struct {
        fn f(_: void, bb: *Build, n: u32) Eff(u32, R) {
            return bb.andThen(Counter.put(bb, R, n + 1), bb.pure(u32, R, n));
        }
    }.f);
}
fn loop(b: *Build, comptime R: anytype, n: u32) Eff(u32, R) {
    if (n == 0) return Counter.get(b, R);
    return b.then(tick(b, R), n, struct {
        fn f(m: u32, bb: *Build, _: u32) Eff(u32, R) {
            return loop(bb, R, m - 1);
        }
    }.f);
}

pub fn main(init: std.process.Init) void {
    const io = init.io;
    const R = ok.Row(.{Counter});
    const n: u32 = 1_000_000;
    var best: u64 = std.math.maxInt(u64);
    var round: usize = 0;
    while (round < 5) : (round += 1) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var b = Build{ .arena = arena.allocator() };
        var cell: u32 = 0;
        const start = std.Io.Timestamp.now(io, .awake);
        const got = b.run(Counter.inCell(&b, loop(&b, R, n), &cell));
        const ns: u64 = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds - start.nanoseconds);
        if (got != n) @panic("wrong");
        best = @min(best, ns);
        const bytes = b.nodes.made * @sizeOf(ok.Node) + b.frames.made * 48;
        const ms = ns / 1_000_000;
        const fmt = "round {d}: {d} ms; nodes made {d}, frames made {d} ({d} bytes)\n";
        std.debug.print(fmt, .{ round, ms, b.nodes.made, b.frames.made, bytes });
    }
    std.debug.print("best: {d} ns per tick (get + put + binds)\n", .{best / n});

    // the same ticks through a CONTEXT: a plain loop, each operation a call on the handler
    var cell: u32 = 0;
    const cx = ok.context(.{Counter.Cell{ .s = &cell }});
    var fastest: u64 = std.math.maxInt(u64);
    round = 0;
    while (round < 5) : (round += 1) {
        cell = 0;
        const start = std.Io.Timestamp.now(io, .awake);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const v = cx.op(Counter, .get, {});
            std.mem.doNotOptimizeAway(v); // each step kept: the loop not folded into one addition
            cx.op(Counter, .put, v + 1);
        }
        std.mem.doNotOptimizeAway(cell);
        const ns: u64 = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds - start.nanoseconds);
        fastest = @min(fastest, ns);
    }
    if (cell != n) @panic("wrong");
    std.debug.print("context: {d} ps per tick\n", .{fastest * 1000 / n});
}
