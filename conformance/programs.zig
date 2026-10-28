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

pub const direct = [_]wire.DirectEntry{
    .{ .name = "quote", .function = quote },
};
