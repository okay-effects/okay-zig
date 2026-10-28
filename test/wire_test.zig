//! okay's wire, as a transcript (okay-py's `wire.txt`): each request's answer compared as JSON, a string "*" matching
//! any value — the conformance programs served.

const std = @import("std");
const ok = @import("okay");
const programs = @import("conformance").programs;
const Value = ok.wire.Value;

fn same(want: Value, got: Value) bool {
    if (want == .string and std.mem.eql(u8, want.string, "*")) return true;
    if (ok.wire.float(want)) |x| return if (ok.wire.float(got)) |y| x == y else false;
    return switch (want) {
        .null => got == .null,
        .bool => |b| got == .bool and got.bool == b,
        .string => |s| got == .string and std.mem.eql(u8, s, got.string),
        .array => |xs| got == .array and xs.items.len == got.array.items.len and
            for (xs.items, got.array.items) |x, y| {
                if (!same(x, y)) break false;
            } else true,
        .object => |o| got == .object and o.count() == got.object.count() and blk: {
            var it = o.iterator();
            while (it.next()) |e| if (!same(e.value_ptr.*, got.object.get(e.key_ptr.*) orelse break :blk false))
                break :blk false;
            break :blk true;
        },
        else => false,
    };
}

/// `>` lines sent, `<` lines expected
fn transcript(lines: []const []const u8) !void {
    const gpa = std.testing.allocator;
    var w = ok.wire.Worker.init(gpa, &programs);
    defer w.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var i: usize = 0;
    while (i < lines.len) : (i += 2) {
        const got_text = w.serve1(lines[i]);
        defer gpa.free(got_text);
        const want = try std.json.parseFromSliceLeaky(Value, a, lines[i + 1], .{});
        const got = try std.json.parseFromSliceLeaky(Value, a, got_text, .{});
        if (!same(want, got)) {
            std.debug.print("\n> {s}\n< want {s}\n< got  {s}\n", .{ lines[i], lines[i + 1], got_text });
            return error.TestUnexpectedResult;
        }
    }
}

test "the hello: shim 9, a Zig worker, JSON lines" {
    const gpa = std.testing.allocator;
    const h = try std.json.parseFromSlice(Value, gpa, ok.wire.Worker.hello, .{});
    defer h.deinit();
    try std.testing.expectEqual(@as(i64, 9), h.value.object.get("shim").?.integer);
    try std.testing.expectEqualStrings("zig", h.value.object.get("python").?.string);
}

test "a call by name (module:name too); a failure is a condition by name; the worker lives on" {
    try transcript(&.{
        \\{"id": 1, "op": "call", "fn": "t:describe", "args": [2, 3]}
        ,
        \\{"id": 1, "ok": 5}
        ,
        \\{"id": 2, "op": "call", "fn": "boom", "args": []}
        ,
        \\{"id": 2, "condition": {"kind": "ZigError", "message": "zig says no"}}
        ,
        \\{"id": 3, "op": "call", "fn": "nothing", "args": []}
        ,
        \\{"id": 3, "condition": {"kind": "LookupError", "message": "*"}}
        ,
        \\{"id": 4, "op": "call", "fn": "pairs", "args": []}
        ,
        \\{"id": 4, "condition": {"kind": "ValueError", "message": "*"}}
        ,
        \\{"id": 5, "op": "teleport"}
        ,
        \\{"id": 5, "condition": {"kind": "ValueError", "message": "*"}}
        ,
        \\not json
        ,
        \\{"id": null, "condition": {"kind": "ValueError", "message": "*"}}
    });
}

test "a held value: kept, used twice by its ref, released, then refused by name" {
    try transcript(&.{
        \\{"id": 1, "op": "call", "fn": "counter", "args": [10], "held": true}
        ,
        \\{"id": 1, "ok": {"t": "ref", "id": 1, "type": "value"}}
        ,
        \\{"id": 2, "op": "call", "fn": "describe", "args": [{"t": "ref", "id": 1}, 2]}
        ,
        \\{"id": 2, "ok": 12}
        ,
        \\{"id": 3, "op": "call", "fn": "describe", "args": [{"t": "ref", "id": 1}, 5]}
        ,
        \\{"id": 3, "ok": 15}
        ,
        \\{"id": 4, "op": "release", "ref": 1}
        ,
        \\{"id": 4, "ok": null}
        ,
        \\{"id": 5, "op": "call", "fn": "describe", "args": [{"t": "ref", "id": 1}, 1]}
        ,
        \\{"id": 5, "condition": {"kind": "LookupError", "message": "*"}}
    });
}

test "a table call: a frame in (columnar, or pairs), a frame out" {
    try transcript(&.{
        \\{"id": 5, "op": "call", "fn": "t:scale", "table": true, "args": [
        \\  {"t": "frame", "v": 2, "cols": [{"name": "x", "type": "i", "values": [1, 2], "na": []}]}, 3]}
        ,
        \\{"id": 5, "ok": {"t": "frame", "cols": [["x", [3, 6]]]}}
        ,
        \\{"id": 6, "op": "call", "fn": "scale", "args": [{"t": "frame", "cols": [["x", [5]]]}, 2]}
        ,
        \\{"id": 6, "ok": {"t": "frame", "cols": [["x", [10]]]}}
    });
}

test "MULTI-SHOT across the wire: one k continued twice, each branch's own second choice" {
    try transcript(&.{
        \\{"id": 6, "op": "program", "run": 1, "fn": "pairs", "args": [], "callbacks": ["choose"]}
        ,
        \\{"id": 6, "ok": {"perform": "choose", "args": [[1, 2]], "k": 1}}
        ,
        \\{"id": 7, "op": "continue", "run": 1, "k": 1, "answer": 1}
        ,
        \\{"id": 7, "ok": {"perform": "choose", "args": [[10, 20]], "k": 2}}
        ,
        \\{"id": 8, "op": "continue", "run": 1, "k": 2, "answer": 10}
        ,
        \\{"id": 8, "ok": {"done": 11}}
        ,
        \\{"id": 9, "op": "continue", "run": 1, "k": 2, "answer": 20}
        ,
        \\{"id": 9, "ok": {"done": 21}}
        ,
        \\{"id": 10, "op": "continue", "run": 1, "k": 1, "answer": 2}
        ,
        \\{"id": 10, "ok": {"perform": "choose", "args": [[10, 20]], "k": 3}}
        ,
        \\{"id": 11, "op": "continue", "run": 1, "k": 3, "answer": 20}
        ,
        \\{"id": 11, "ok": {"done": 22}}
        ,
        \\{"id": 12, "op": "continue", "run": 1, "k": 2, "answer": 10}
        ,
        \\{"id": 12, "ok": {"done": 11}}
        ,
        \\{"id": 13, "op": "forget", "run": 1}
        ,
        \\{"id": 13, "ok": null}
        ,
        \\{"id": 14, "op": "continue", "run": 1, "k": 1, "answer": 1}
        ,
        \\{"id": 14, "condition": {"kind": "LookupError", "message": "*"}}
    });
}

test "a typed effect sent to the host: operations by name, answers decoded (tagged doubles too), conditions failures" {
    try transcript(&.{
        \\{"id": 1, "op": "program", "run": 7, "fn": "total", "args": ["tea", 3], "callbacks": ["price_of", "discount"]}
        ,
        \\{"id": 1, "ok": {"perform": "price_of", "args": ["tea"], "k": 1}}
        ,
        \\{"id": 2, "op": "continue", "run": 7, "k": 1, "answer": {"t": "f", "v": 4.0}}
        ,
        \\{"id": 2, "ok": {"perform": "discount", "args": [{"t": "f", "v": 12}], "k": 2}}
        ,
        \\{"id": 3, "op": "continue", "run": 7, "k": 2, "answer": 6.5}
        ,
        \\{"id": 3, "ok": {"done": 6.5}}
        ,
        \\{"id": 31, "op": "continue", "run": 7, "k": 1, "answer": 4}
        ,
        \\{"id": 31, "ok": {"perform": "discount", "args": [{"t": "f", "v": 12}], "k": 3}}
        ,
        \\{"id": 32, "op": "continue", "run": 7, "k": 3, "answer": {"t": "f", "v": 6}}
        ,
        \\{"id": 32, "ok": {"done": {"t": "f", "v": 6}}}
        ,
        \\{"id": 4, "op": "continue", "run": 7, "k": 1, "condition": {"kind": "KeyError", "message": "no tea"}}
        ,
        \\{"id": 4, "condition": {"kind": "KeyError", "message": "no tea"}}
        ,
        \\{"id": 5, "op": "continue", "run": 7, "k": 1, "answer": "cheap"}
        ,
        \\{"id": 5, "condition": {"kind": "TypeError", "message": "*"}}
        ,
        \\{"id": 6, "op": "configure", "format": "json", "compress": "none"}
        ,
        \\{"id": 6, "ok": {"format": "json", "compress": "none"}}
        ,
        \\{"id": 7, "op": "configure", "format": "cbor", "compress": "deflate"}
        ,
        \\{"id": 7, "condition": {"kind": "ValueError", "message": "*"}}
    });
}

/// a guard of the host's operations: a discount past a limit refused, by an error of its own
const Limit = struct {
    max: f64,
    pub fn decide(self: Limit, op: ok.wire.Host.Op) error{OverBudget}!void {
        switch (op) {
            .request => |r| if (std.mem.eql(u8, r.name, "discount") and
                (ok.wire.float(r.args[0]) orelse 0) > self.max) return error.OverBudget,
            .fail => {},
        }
    }
};

const R = ok.wire.Remote;
fn guardedTotal(b: *ok.Build, args: []const Value) R.Of(Value) {
    const price = ok.wire.Host.call(b, R, "price_of", args[0..1]);
    const S = struct {
        fn priced(qty: Value, bb: *ok.Build, p: Value) R.Of(Value) {
            const amount = (ok.wire.float(p) orelse 0) * (ok.wire.float(qty) orelse 0);
            const xs = bb.arena.dupe(Value, &.{.{ .float = amount }}) catch unreachable;
            return ok.wire.Host.call(bb, R, "discount", xs);
        }
    };
    return ok.wire.guard(b, ok.wire.Host, b.then(price, args[1], S.priced), Limit{ .max = 20 });
}

test "a guard on the wire: an allowed operation goes to the host; a refused one is a condition by the guard's error" {
    const gpa = std.testing.allocator;
    var w = ok.wire.Worker.init(gpa, &.{.{ .name = "guarded", .program = guardedTotal }});
    defer w.deinit();
    const lines = [_][2][]const u8{
        .{
            \\{"id": 1, "op": "program", "run": 1, "fn": "guarded", "args": ["tea", 3]}
            ,
            \\{"id":1,"ok":{"perform":"price_of","args":["tea"],"k":1}}
        },
        .{
            \\{"id": 2, "op": "continue", "run": 1, "k": 1, "answer": 4.5}
            ,
            \\{"id":2,"ok":{"perform":"discount","args":[13.5],"k":2}}
        },
        .{
            \\{"id": 3, "op": "continue", "run": 1, "k": 1, "answer": 9}
            ,
            \\{"id":3,"condition":{"kind":"OverBudget","message":"refused by a guard"}}
        },
    };
    for (lines) |l| {
        const got = w.serve1(l[0]);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(l[1], got);
    }
}
