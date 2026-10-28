//! resumable programs: states written by hand, the rest copied to resume it more than once

const std = @import("std");
const ok = @import("okay");
const rs = ok.resumable;
const t = std.testing;

/// a choice among `n`
const Choose = union(enum) { among: usize };

/// two choices, then a value: `a * 10 + b` — the states as `#[resumable]` writes them in Rust
const Pick = union(enum) {
    after_a,
    after_b: struct { a: usize },

    pub const Op = Choose;
    pub const Answer = usize;
    pub const Out = usize;

    fn start() rs.Step(Pick) {
        return rs.perform(Pick, .{ .among = 3 }, .after_a);
    }
    pub fn step(self: Pick, v: usize) rs.Step(Pick) {
        return switch (self) {
            .after_a => rs.perform(Pick, .{ .among = 2 }, .{ .after_b = .{ .a = v } }),
            .after_b => |s| rs.done(Pick, s.a * 10 + v),
        };
    }
};

const Collect = struct {
    out: *std.ArrayList(usize),
    pub fn answers(_: Collect, op: Choose) rs.Among {
        return .{ .n = op.among };
    }
    pub fn found(self: Collect, a: usize) void {
        self.out.append(t.allocator, a) catch @panic("out of memory");
    }
};

test "every path: the rest copied for each alternative, from the same point, its variables as they were" {
    var out: std.ArrayList(usize) = .empty;
    defer out.deinit(t.allocator);
    rs.everyPath(Pick, Pick.start(), Collect{ .out = &out });
    try t.expectEqualSlices(usize, &.{ 0, 1, 10, 11, 20, 21 }, out.items);
}

test "one rest resumed twice by hand: two programs from one point" {
    const first = Pick.start();
    const k = first.perform.k;
    const left = k.step(2).perform.k; // a = 2
    const right = k.step(1).perform.k; // a = 1, from the same k
    try t.expectEqual(@as(usize, 25), left.step(5).done);
    try t.expectEqual(@as(usize, 17), right.step(7).done);
    try t.expectEqual(@as(usize, 21), left.step(1).done); // left again: still a = 2
}

/// a loop with a stop in it: ticks 0 ..< n, each answered, the parity of the count its value
const Ticks = union(enum) {
    at: struct { i: i64, n: i64, even: bool },

    pub const Op = union(enum) { tick: i64 };
    pub const Answer = i64;
    pub const Out = bool;

    fn start(n: i64) rs.Step(Ticks) {
        if (n <= 0) return rs.done(Ticks, true);
        return rs.perform(Ticks, .{ .tick = 0 }, .{ .at = .{ .i = 0, .n = n, .even = true } });
    }
    pub fn step(self: Ticks, _: i64) rs.Step(Ticks) {
        var s = self.at;
        s.even = !s.even;
        s.i += 1;
        return if (s.i < s.n) rs.perform(Ticks, .{ .tick = s.i }, .{ .at = s }) else rs.done(Ticks, s.even);
    }
};

const Echo = struct {
    pub fn answer(_: Echo, op: Ticks.Op) i64 {
        return op.tick;
    }
};

test "answered in place: a loop of stops run to its value" {
    try t.expect(rs.run(Ticks, Ticks.start(1000), Echo{}));
    try t.expect(!rs.run(Ticks, Ticks.start(7), Echo{}));
}
