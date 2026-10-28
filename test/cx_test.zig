const std = @import("std");
const ok = @import("okay");
const S = ok.effects;
const t = std.testing;

const Counter = S.State(u32);
const Name = S.Reader([]const u8);

/// a program as a plain function: its effects the context's, each operation a call
fn greet(cx: anytype) usize {
    ok.needs(@TypeOf(cx), .{ Name, Counter });
    const who = cx.op(Name, .ask, {});
    const n = cx.op(Counter, .get, {});
    cx.op(Counter, .put, n + 1);
    return who.len * 100 + n;
}

test "a plain function, its effects a context's handlers — the machine's own handlers" {
    var cell: u32 = 7;
    const cx = ok.context(.{ Counter.Cell{ .s = &cell }, Name.Given{ .env = "Ann" } });
    try t.expectEqual(307, greet(cx));
    try t.expectEqual(308, greet(cx));
    try t.expectEqual(9, cell);
}

/// an observer of Counter: the audit, every operation seen before it is answered
const Seen = struct {
    pub const Effect = Counter;
    ops: *std.ArrayList(Counter.Op),
    gpa: std.mem.Allocator,
    pub fn seen(self: Seen, op: Counter.Op) void {
        self.ops.append(self.gpa, op) catch @panic("out of memory");
    }
};

test "observed: each operation of the effect seen, in order, before its answer; a direct call is not" {
    var cell: u32 = 0;
    var ops: std.ArrayList(Counter.Op) = .empty;
    defer ops.deinit(t.allocator);
    const cx = ok.context(.{ Name.Given{ .env = "Bo" }, Counter.Cell{ .s = &cell } })
        .observe(Seen{ .ops = &ops, .gpa = t.allocator });
    _ = greet(cx);
    try t.expectEqual(2, ops.items.len);
    try t.expectEqual(Counter.Op.get, std.meta.activeTag(ops.items[0]));
    try t.expectEqual(@as(u32, 1), ops.items[1].put);
    cx.of(Counter).put(42); // the handler itself: not observed
    try t.expectEqual(2, ops.items.len);
    try t.expectEqual(42, cell);
}

test "one handler, both layers: the context's Cell is the machine's handleTail" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    var b = ok.Build{ .arena = a.allocator() };
    const R = ok.Row(.{Counter});
    var cell: u32 = 10;
    const handler = Counter.Cell{ .s = &cell };
    _ = b.run(b.handleTail(Counter, Counter.put(&b, R, 11), handler));
    const cx = ok.context(.{handler});
    try t.expectEqual(11, cx.op(Counter, .get, {}));
}
