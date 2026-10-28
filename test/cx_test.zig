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

/// a guard of Counter: a put past the budget refused, by an error of its own
const Budget = struct {
    pub const Effect = Counter;
    max: u32,
    pub fn decide(self: Budget, op: Counter.Op) error{OverBudget}!void {
        switch (op) {
            .put => |n| if (n > self.max) return error.OverBudget,
            .get => {},
        }
    }
};

/// a second guard of Counter, its own error
const NoZero = struct {
    pub const Effect = Counter;
    pub fn decide(_: NoZero, op: Counter.Op) error{Zero}!void {
        if (op == .put and op.put == 0) return error.Zero;
    }
};

/// a function over a guarded Counter: its operations error unions, `try` the way out; Name unguarded, plain
fn bump(cx: anytype, by: u32) !usize {
    ok.needs(@TypeOf(cx), .{ Name, Counter });
    const who = cx.op(Name, .ask, {});
    const n = try cx.op(Counter, .get, {});
    try cx.op(Counter, .put, n + by);
    return who.len + n + by;
}

test "guarded: an operation refused by the guard's own error, unanswered; the others pass" {
    var cell: u32 = 1;
    var ops: std.ArrayList(Counter.Op) = .empty;
    defer ops.deinit(t.allocator);
    const cx = ok.context(.{ Name.Given{ .env = "Cy" }, Counter.Cell{ .s = &cell } })
        .observe(Seen{ .ops = &ops, .gpa = t.allocator })
        .guard(Budget{ .max = 10 });
    try t.expectEqual(2 + 1 + 4, try bump(cx, 4));
    try t.expectEqual(5, cell);
    try t.expectError(error.OverBudget, bump(cx, 6));
    try t.expectEqual(5, cell); // refused: never answered
    try t.expectEqual(4, ops.items.len); // the audit saw the refused put too
    // the types say it: Counter's answers are error unions of the guard's errors, Name's plain
    const Cx = @TypeOf(cx);
    try t.expect(@typeInfo(Cx.Answered(Counter, .put)) == .error_union);
    try t.expectEqual([]const u8, Cx.Answered(Name, .ask));
}

test "two guards of one effect: each asked, the first to refuse refuses; their errors one set" {
    var cell: u32 = 3;
    const cx = ok.context(.{ Name.Given{ .env = "" }, Counter.Cell{ .s = &cell } })
        .guard(Budget{ .max = 10 })
        .guard(NoZero{});
    try t.expectError(error.Zero, cx.op(Counter, .put, 0));
    try t.expectError(error.OverBudget, cx.op(Counter, .put, 11));
    try cx.op(Counter, .put, 9);
    try t.expectEqual(9, cell);
    const E = @TypeOf(cx).Refusal(Counter);
    try t.expect(@typeInfo(E).error_set.error_names.?.len == 2);
}
