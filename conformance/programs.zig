//! The conformance programs (okay's `WireConformance`), in Zig: `pairs` two choices; `total` a TYPED effect sent to
//! the host (`Shop`, by `remote`); `boom` a failure by name; `scale` a table call; `counter` a value held by the host,
//! `describe` reading it.

const std = @import("std");
const ok = @import("okay");
const wire = ok.wire;
const Build = ok.Build;
const Value = wire.Value;
const Host = wire.Host;
const R = wire.Remote;

/// two choices: okay's handler continues each rest twice
fn pairs(b: *Build, _: []const Value) R.Of(Value) {
    const S = struct {
        fn first(bb: *Build, x: Value) R.Of(Value) {
            return bb.then(choose(bb, &.{ 10, 20 }), wire.int(x) orelse 0, second);
        }
        fn second(x: i64, bb: *Build, y: Value) R.Of(Value) {
            return bb.pure(Value, R, .{ .integer = x + (wire.int(y) orelse 0) });
        }
    };
    return b.next(choose(b, &.{ 1, 2 }), S.first);
}

fn choose(b: *Build, xs: []const i64) R.Of(Value) {
    const args = b.arena.dupe(Value, &.{wire.encode(b.arena, []const i64, xs)}) catch unreachable;
    return Host.call(b, R, "choose", args);
}

/// a typed effect, its operations the host's callbacks: `price_of(sku)`, `discount(amount)`
const Shop = struct {
    pub const Op = union(enum) { price_of: []const u8, discount: f64 };
    pub fn Answer(comptime _: std.meta.Tag(Op)) type {
        return f64;
    }
};

/// `price_of(sku)`, then `discount(price * qty)`: typed here, sent by `remote`
fn totalOf(b: *Build, sku: []const u8, qty: f64) ok.Eff(f64, .{ Shop, Host }) {
    const Rs = ok.Row(.{ Shop, Host });
    const S = struct {
        fn priced(q: f64, bb: *Build, price: f64) Rs.Of(f64) {
            return bb.perform(Rs, Shop, .discount, price * q);
        }
    };
    return b.then(b.perform(Rs, Shop, .price_of, sku), qty, S.priced);
}

fn total(b: *Build, args: []const Value) R.Of(Value) {
    if (args.len != 2 or args[0] != .string or wire.float(args[1]) == null)
        return Host.fail(b, Value, R, "ValueError", "total takes a sku and a quantity");
    const S = struct {
        fn asValue(_: void, x: f64) Value {
            return .{ .float = x };
        }
    };
    return b.map(wire.remote(b, Shop, totalOf(b, args[0].string, wire.float(args[1]).?)), {}, S.asValue);
}

fn boom(b: *Build, _: []const Value) R.Of(Value) {
    return Host.fail(b, Value, R, "ZigError", "zig says no");
}

/// a TABLE call: a program that answers without performing is a function
fn scale(b: *Build, args: []const Value) R.Of(Value) {
    if (args.len != 2) return Host.fail(b, Value, R, "ValueError", "scale takes a frame and a factor");
    const xs = wire.column(args[0], "x") orelse
        return Host.fail(b, Value, R, "ValueError", "scale takes a frame with a column x");
    const k = wire.int(args[1]) orelse 0;
    const out = b.arena.alloc(Value, xs.len) catch unreachable;
    for (xs, 0..) |x, i| out[i] = .{ .integer = (wire.int(x) orelse 0) * k };
    return b.pure(Value, R, wire.table(b.arena, &.{.{ "x", out }}));
}

/// a HELD value (the number itself), and a function reading it
fn counter(b: *Build, args: []const Value) R.Of(Value) {
    if (args.len != 1) return Host.fail(b, Value, R, "ValueError", "counter takes a number");
    return b.pure(Value, R, args[0]);
}

fn describe(b: *Build, args: []const Value) R.Of(Value) {
    if (args.len != 2) return Host.fail(b, Value, R, "ValueError", "describe takes a held value and a number");
    return b.pure(Value, R, .{ .integer = (wire.int(args[0]) orelse 0) + (wire.int(args[1]) orelse 0) });
}

pub const programs = [_]wire.Entry{
    .{ .name = "pairs", .program = pairs },
    .{ .name = "total", .program = total },
    .{ .name = "boom", .program = boom },
    .{ .name = "scale", .program = scale },
    .{ .name = "counter", .program = counter },
    .{ .name = "describe", .program = describe },
};

/// DIRECT STYLE: `quote(sku, qty)`, as `total` — ordinary code, each call to the host waiting for its answer
fn quote(cx: wire.Direct, a: std.mem.Allocator, args: []const Value) !Value {
    if (args.len != 2 or args[0] != .string) return error.ValueError;
    const price = wire.float(try wire.call(cx, "price_of", args[0..1])) orelse return error.TypeError;
    const amount = price * (wire.float(args[1]) orelse return error.ValueError);
    return try wire.call(cx, "discount", try a.dupe(Value, &.{.{ .float = amount }}));
}

// ---- on a multiplexed wire: requests in flight together, streams both ways

/// gates by name: `await_open(name)` answers once `open(name)` has been called — on one worker, the second request
/// taken while the first still waits
var gates: std.StringHashMapUnmanaged(*std.Io.Event) = .empty;
var gates_mu: std.Io.Mutex = .init;
const global = std.heap.smp_allocator;

fn gate(io: std.Io, name: []const u8) *std.Io.Event {
    gates_mu.lockUncancelable(io);
    defer gates_mu.unlock(io);
    if (gates.get(name)) |g| return g;
    const g = global.create(std.Io.Event) catch unreachable;
    g.* = .unset;
    gates.put(global, global.dupe(u8, name) catch unreachable, g) catch unreachable;
    return g;
}

fn awaitOpen(cx: wire.Direct, _: std.mem.Allocator, args: []const Value) !Value {
    if (args.len != 1 or args[0] != .string) return error.ValueError;
    try gate(wire.ioOf(cx), args[0].string).wait(wire.ioOf(cx));
    return args[0];
}

fn open(cx: wire.Direct, _: std.mem.Allocator, args: []const Value) !Value {
    if (args.len != 1 or args[0] != .string) return error.ValueError;
    gate(wire.ioOf(cx), args[0].string).set(wire.ioOf(cx));
    return args[0];
}

/// how many chunks each tagged stream has sent, and whether its function has returned: counted on the far side
var counts: std.StringHashMapUnmanaged(*Count) = .empty;
var counts_mu: std.Io.Mutex = .init;
const Count = struct { emitted: std.atomic.Value(i64) = .init(0), stopped: std.atomic.Value(bool) = .init(false) };

fn countOf(io: std.Io, tag: []const u8) *Count {
    counts_mu.lockUncancelable(io);
    defer counts_mu.unlock(io);
    if (counts.get(tag)) |c| return c;
    const c = global.create(Count) catch unreachable;
    c.* = .{};
    counts.put(global, global.dupe(u8, tag) catch unreachable, c) catch unreachable;
    return c;
}

/// a STREAM the worker drives: `0 until n` in chunks of `size`, each chunk counted as it goes out
fn numbers(cx: wire.Direct, a: std.mem.Allocator, args: []const Value) !Value {
    if (args.len != 3 or args[2] != .string) return error.ValueError;
    const n = wire.int(args[0]) orelse return error.ValueError;
    const size = wire.int(args[1]) orelse return error.ValueError;
    const count = countOf(wire.ioOf(cx), args[2].string);
    defer count.stopped.store(true, .release);
    var i: i64 = 0;
    while (i < n) : (i += size) {
        const len: usize = @intCast(@min(size, n - i));
        const chunk = try a.alloc(Value, len);
        for (chunk, 0..) |*x, j| x.* = .{ .integer = i + @as(i64, @intCast(j)) };
        wire.emit(cx, wire.array(a, chunk)) catch return .null; // cancelled: stop producing
        _ = count.emitted.fetchAdd(1, .release);
    }
    return .null;
}

fn emittedOf(cx: wire.Direct, _: std.mem.Allocator, args: []const Value) !Value {
    if (args.len != 1 or args[0] != .string) return error.ValueError;
    return .{ .integer = countOf(wire.ioOf(cx), args[0].string).emitted.load(.acquire) };
}

fn stoppedOf(cx: wire.Direct, _: std.mem.Allocator, args: []const Value) !Value {
    if (args.len != 1 or args[0] != .string) return error.ValueError;
    return .{ .bool = countOf(wire.ioOf(cx), args[0].string).stopped.load(.acquire) };
}

/// the HOST's stream into a call, summed once its gate opens: the host feeds no further ahead than its credit
fn sumAfter(cx: wire.Direct, a: std.mem.Allocator, args: []const Value) !Value {
    if (args.len != 1 or args[0] != .string) return error.ValueError;
    try gate(wire.ioOf(cx), args[0].string).wait(wire.ioOf(cx));
    var sum: i64 = 0;
    while (wire.next(cx)) |chunk| {
        if (chunk != .array) return error.ValueError;
        for (chunk.array.items) |x| sum += wire.int(x) orelse 0;
    }
    try wire.emit(cx, wire.array(a, try a.dupe(Value, &.{.{ .integer = sum }})));
    return .null;
}

/// a DUPLEX transform: each chunk in answered by what it had not seen before
fn dedup(cx: wire.Direct, a: std.mem.Allocator, _: []const Value) !Value {
    var seen: std.AutoHashMapUnmanaged(i64, void) = .empty;
    while (wire.next(cx)) |chunk| {
        if (chunk != .array) return error.ValueError;
        var fresh: std.ArrayList(Value) = .empty;
        for (chunk.array.items) |x| {
            const n = wire.int(x) orelse continue;
            if ((try seen.getOrPut(a, n)).found_existing) continue;
            try fresh.append(a, .{ .integer = n });
        }
        if (fresh.items.len > 0) wire.emit(cx, wire.array(a, fresh.items)) catch return .null;
    }
    return .null;
}

pub const direct = [_]wire.DirectEntry{
    .{ .name = "quote", .function = quote },
    .{ .name = "await_open", .function = awaitOpen },
    .{ .name = "open", .function = open },
    .{ .name = "numbers", .function = numbers },
    .{ .name = "emitted_of", .function = emittedOf },
    .{ .name = "stopped_of", .function = stoppedOf },
    .{ .name = "sum_after", .function = sumAfter },
    .{ .name = "dedup", .function = dedup },
};
