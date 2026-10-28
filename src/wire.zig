//! OKAY'S WIRE: Zig programs served to okay's hosts (okay's `ForeignWorker`, okay-py's `wire.txt` its transcript).
//!
//! A host starts a program by name; each operation the program performs goes to the host as `perform`, the rest of the
//! program kept here — a machine's `k` — under an id; the host runs it under its own handlers and `continue`s that
//! rest, the same one any number of times (multi-shot); `forget` drops a run, its memory with it (a run is an arena). A
//! program's failure is a condition by name, and the worker lives on. Also served: a `call` (a program that answers
//! without performing), a value `held` for the host and `release`d, and `configure` of the wire (JSON lines, no
//! compression — what the hello says).
//!
//! The host's operations are ONE effect, `Host`: an operation by name, its arguments and answer JSON. A typed effect is
//! sent to the host by `remote` — each operation its tag's name, its payload the arguments, its answer decoded.

const std = @import("std");
const ok = @import("okay.zig");
const Allocator = std.mem.Allocator;
const Build = ok.Build;
const Eff = ok.Eff;

pub const Value = std.json.Value;

/// the wire's version this worker speaks; okay's hosts refuse another
pub const shim_version = 9;

/// a failure by name, as the wire carries it
pub const Condition = struct { kind: []const u8, message: []const u8 };

/// THE HOST: the operations a program sends to the host — one by name, its arguments, its answer (or the host's
/// condition) — and its failure
pub const Host = struct {
    pub const Request = struct { name: []const u8, args: []const Value };
    pub const Reply = union(enum) { ok: Value, failed: Condition };
    pub const Op = union(enum) { request: Request, fail: Condition };
    pub fn Answer(comptime tag: std.meta.Tag(Op)) type {
        return switch (tag) {
            .request => Reply,
            .fail => void,
        };
    }

    /// the host's operation `name`, its answer the program's value; the host's condition the program's failure
    pub fn call(b: *Build, comptime R: anytype, name: []const u8, args: []const Value) Eff(Value, R) {
        const Steps = struct {
            fn answered(bb: *Build, r: Reply) Eff(Value, R) {
                return switch (r) {
                    .ok => |v| bb.pure(Value, R, v),
                    .failed => |c| fail(bb, Value, R, c.kind, c.message),
                };
            }
        };
        return b.next(b.perform(R, Host, .request, .{ .name = name, .args = args }), Steps.answered);
    }

    /// a program that fails with a condition by name: any value type
    pub fn fail(b: *Build, comptime A: type, comptime R: anytype, kind: []const u8, message: []const u8) Eff(A, R) {
        return ok.never(A, b.perform(R, Host, .fail, .{ .kind = kind, .message = message }));
    }
};

/// the row of a served program
pub const Remote = ok.Row(.{Host});

/// A PROGRAM THE HOST STARTS BY NAME: its arguments in (a held value in its ref's place), a program over the host's
/// operations out
pub const Program = *const fn (b: *Build, args: []const Value) Remote.Of(Value);

pub const Entry = struct { name: []const u8, program: Program };

// ------------------------------------------------------------------------------------------------ values

/// `v` copied into `a`: what a run or a held value keeps outlives the request it came in
pub fn clone(a: Allocator, v: Value) Allocator.Error!Value {
    return switch (v) {
        .null, .bool, .integer, .float => v,
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .array => |xs| blk: {
            var out = try std.json.Array.initCapacity(a, xs.items.len);
            for (xs.items) |x| out.appendAssumeCapacity(try clone(a, x));
            break :blk .{ .array = out };
        },
        .object => |o| blk: {
            var out: std.json.ObjectMap = .empty;
            var it = o.iterator();
            while (it.next()) |e| try out.put(a, try a.dupe(u8, e.key_ptr.*), try clone(a, e.value_ptr.*));
            break :blk .{ .object = out };
        },
    };
}

/// a value off the wire, copied into `a`: okay's tagged numbers plain — a whole double `{"t": "f", "v": 4.0}` a
/// float, a big integer `{"t": "int", "v": "…"}` an integer, `{"t": "nan"}` NaN
pub fn incoming(a: Allocator, v: Value) Allocator.Error!Value {
    switch (v) {
        .object => |o| {
            const t = text(o.get("t")) orelse "";
            if (std.mem.eql(u8, t, "f")) if (o.get("v")) |x| if (float(x)) |f| return .{ .float = f };
            if (std.mem.eql(u8, t, "nan")) return .{ .float = std.math.nan(f64) };
            if (std.mem.eql(u8, t, "int")) if (text(o.get("v"))) |d|
                return if (std.fmt.parseInt(i64, d, 10)) |i|
                    .{ .integer = i }
                else |_|
                    .{ .number_string = try a.dupe(u8, d) };
            var out: std.json.ObjectMap = .empty;
            var it = o.iterator();
            while (it.next()) |e| try out.put(a, try a.dupe(u8, e.key_ptr.*), try incoming(a, e.value_ptr.*));
            return .{ .object = out };
        },
        .array => |xs| {
            var out = try std.json.Array.initCapacity(a, xs.items.len);
            for (xs.items) |x| out.appendAssumeCapacity(try incoming(a, x));
            return .{ .array = out };
        },
        else => return clone(a, v),
    }
}

/// a value onto the wire, copied into `a`, as okay's hosts read it: a whole float tagged so it stays a double, an
/// integer past 2^53 tagged so it stays exact, NaN tagged
pub fn outgoing(a: Allocator, v: Value) Allocator.Error!Value {
    return switch (v) {
        .float => |f| if (std.math.isNan(f))
            object(a, .{.{ "t", Value{ .string = "nan" } }})
        else if (@floor(f) == f and @abs(f) < 1e15)
            object(a, .{ .{ "t", Value{ .string = "f" } }, .{ "v", v } })
        else
            v,
        .integer => |i| if (@abs(i) < (1 << 53)) v else object(a, .{
            .{ "t", Value{ .string = "int" } },
            .{ "v", Value{ .string = try std.fmt.allocPrint(a, "{d}", .{i}) } },
        }),
        .array => |xs| blk: {
            var out = try std.json.Array.initCapacity(a, xs.items.len);
            for (xs.items) |x| out.appendAssumeCapacity(try outgoing(a, x));
            break :blk .{ .array = out };
        },
        .object => |o| blk: {
            var out: std.json.ObjectMap = .empty;
            var it = o.iterator();
            while (it.next()) |e| try out.put(a, try a.dupe(u8, e.key_ptr.*), try outgoing(a, e.value_ptr.*));
            break :blk .{ .object = out };
        },
        else => clone(a, v),
    };
}

/// a number, as a float: an integer or a float
pub fn float(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// a number, as an integer: an integer, or a float with no fraction
pub fn int(v: Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (@floor(f) == f and @abs(f) < 9.2e18) @intFromFloat(f) else null,
        else => null,
    };
}

/// a JSON array of `xs`
pub fn array(a: Allocator, xs: []const Value) Value {
    var out = std.json.Array.initCapacity(a, xs.len) catch oom();
    out.appendSliceAssumeCapacity(xs);
    return .{ .array = out };
}

/// a JSON object of `fields`, in order
pub fn object(a: Allocator, fields: anytype) Value {
    var out: std.json.ObjectMap = .empty;
    inline for (fields) |f| out.put(a, f[0], f[1]) catch oom();
    return .{ .object = out };
}

fn field(v: Value, name: []const u8) ?Value {
    return switch (v) {
        .object => |o| o.get(name),
        else => null,
    };
}

fn text(v: ?Value) ?[]const u8 {
    return if (v) |x| switch (x) {
        .string => |s| s,
        else => null,
    } else null;
}

fn natural(v: ?Value) ?u64 {
    return if (v) |x| switch (x) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    } else null;
}

/// a table's column by name, as the host sends it — `{"t": "frame", "cols": …}`, each column `{name, values}`
/// (columnar: its absences, `na`, not marked) or `[name, cells]`
pub fn column(frame: Value, name: []const u8) ?[]const Value {
    if (!std.mem.eql(u8, text(field(frame, "t")) orelse "", "frame")) return null;
    const cols = switch (field(frame, "cols") orelse return null) {
        .array => |xs| xs.items,
        else => return null,
    };
    for (cols) |c| switch (c) {
        .object => if (std.mem.eql(u8, text(field(c, "name")) orelse "", name)) {
            return switch (field(c, "cells") orelse field(c, "values") orelse return null) {
                .array => |xs| xs.items,
                else => null,
            };
        },
        .array => |pair| if (pair.items.len == 2 and std.mem.eql(u8, text(pair.items[0]) orelse "", name)) {
            return switch (pair.items[1]) {
                .array => |xs| xs.items,
                else => null,
            };
        },
        else => {},
    };
    return null;
}

/// a table, as a far side answers one: `{"t": "frame", "cols": [[name, cells], …]}`
pub fn table(a: Allocator, cols: []const struct { []const u8, []const Value }) Value {
    var out = std.json.Array.initCapacity(a, cols.len) catch oom();
    for (cols) |c| out.appendAssumeCapacity(array(a, &.{ .{ .string = c[0] }, array(a, c[1]) }));
    return object(a, .{ .{ "t", Value{ .string = "frame" } }, .{ "cols", Value{ .array = out } } });
}

fn oom() noreturn {
    @panic("okay-zig: out of memory");
}

// ------------------------------------------------------------------------------------------------ typed effects

/// a value of `T` as the wire carries it
pub fn encode(a: Allocator, comptime T: type, v: T) Value {
    if (T == Value) return v;
    if (T == []const u8) return .{ .string = v };
    return switch (@typeInfo(T)) {
        .bool => .{ .bool = v },
        .int, .comptime_int => .{ .integer = @intCast(v) },
        .float, .comptime_float => .{ .float = v },
        .void => .null,
        .optional => if (v) |x| encode(a, @typeInfo(T).optional.child, x) else .null,
        .pointer => |p| blk: {
            if (p.size != .slice) @compileError("okay-zig: no wire form for " ++ @typeName(T));
            const xs = a.alloc(Value, v.len) catch oom();
            for (v, 0..) |x, i| xs[i] = encode(a, p.child, x);
            break :blk array(a, xs);
        },
        else => @compileError("okay-zig: no wire form for " ++ @typeName(T)),
    };
}

/// a value of `T` read from the wire: null if it is not one
pub fn decode(comptime T: type, v: Value) ?T {
    if (T == Value) return v;
    if (T == []const u8) return text(v);
    return switch (@typeInfo(T)) {
        .bool => switch (v) {
            .bool => |x| x,
            else => null,
        },
        .int => if (int(v)) |i| std.math.cast(T, i) else null,
        .float => if (float(v)) |f| @floatCast(f) else null,
        .void => {},
        else => @compileError("okay-zig: no wire form for " ++ @typeName(T)),
    };
}

/// an operation's payload as its arguments: none for `void`, a struct's fields each one, else the one
fn arguments(a: Allocator, payload: anytype) []const Value {
    const P = @TypeOf(payload);
    if (P == void) return &.{};
    if (@typeInfo(P) == .@"struct" and P != Value) {
        const info = @typeInfo(P).@"struct";
        const xs = a.alloc(Value, info.field_names.len) catch oom();
        inline for (info.field_names, 0..) |n, i| xs[i] = encode(a, @FieldType(P, n), @field(payload, n));
        return xs;
    }
    const xs = a.alloc(Value, 1) catch oom();
    xs[0] = encode(a, P, payload);
    return xs;
}

/// `p` with the TYPED effect `E` sent to the host: each operation by its tag's name, its payload the arguments, the
/// host's answer decoded as the operation's — one the host answers wrongly is the program's failure (`TypeError`).
/// `Host` must be in what is left of the row.
pub fn remote(b: *Build, comptime E: type, p: anytype) ok.Handled(@TypeOf(p), E, @TypeOf(p).Value) {
    const P = @TypeOf(p);
    const Rest = P.Effects.without(P.Effects.place(E));
    const Out = Eff(P.Value, Rest);
    const K = ok.Resume(E, Out);
    const H = struct {
        pub fn ret(_: @This(), bb: *Build, a: P.Value) Out {
            return bb.pure(P.Value, Rest, a);
        }
        pub fn op(_: @This(), bb: *Build, o: E.Op, k: K) Out {
            switch (o) {
                inline else => |payload, tag| {
                    const Back = struct {
                        fn answered(kk: K, bbb: *Build, v: Value) Out {
                            const A = E.Answer(tag);
                            if (decode(A, v)) |x| return kk.answer(bbb, tag, x);
                            return Host.fail(bbb, P.Value, Rest, "TypeError", "the host's answer to " ++
                                @tagName(tag) ++ " is not a " ++ @typeName(A));
                        }
                    };
                    const asked = Host.call(bb, Rest, @tagName(tag), arguments(bb.arena, payload));
                    return bb.then(asked, k, Back.answered);
                },
            }
        }
    };
    return b.handle(E, p, H{});
}

/// `p` with `E`'s operations decided by the GUARD `g` (`decide(op) !void`, as a context's guard) before they go on: one
/// allowed is performed past the guard — to the host, or to the next handler of `E` — and its answer given back; one
/// refused is the program's failure, a condition named by the guard's error (`OverBudget`), the operation never
/// performed. The row is kept; `Host` must be in it.
pub fn guard(b: *Build, comptime E: type, p: anytype, g: anytype) @TypeOf(p) {
    const P = @TypeOf(p);
    const Rs = P.Effects;
    const K = ok.Resume(E, P);
    const G = @TypeOf(g);
    const H = struct {
        g: G,
        pub fn ret(_: @This(), bb: *Build, a: P.Value) P {
            return bb.pure(P.Value, Rs, a);
        }
        pub fn op(self: @This(), bb: *Build, o: E.Op, k: K) P {
            self.g.decide(o) catch |e| return Host.fail(bb, P.Value, Rs, @errorName(e), "refused by a guard");
            switch (o) {
                inline else => |payload, tag| {
                    const Back = struct {
                        fn answered(kk: K, bbb: *Build, x: E.Answer(tag)) P {
                            return kk.answer(bbb, tag, x);
                        }
                    };
                    return bb.then(bb.perform(Rs, E, tag, payload), k, Back.answered);
                },
            }
        }
    };
    return b.intercept(E, p, H{ .g = g });
}

// ------------------------------------------------------------------------------------------------ the worker

/// a program stepped as far as the host must answer: its value, an operation with its rest, or its failure
const Step = union(enum) {
    done: Value,
    perform: struct { name: []const u8, args: []const Value, k: *const ok.Captured },
    failed: Condition,
};
const Stepped = Eff(Step, ok.Pure);

const Stepping = struct {
    pub fn ret(_: Stepping, b: *Build, v: Value) Stepped {
        return b.pure(Step, ok.Pure, .{ .done = v });
    }
    pub fn op(_: Stepping, b: *Build, o: Host.Op, k: ok.Resume(Host, Stepped)) Stepped {
        return switch (o) {
            .request => |r| b.pure(Step, ok.Pure, .{ .perform = .{ .name = r.name, .args = r.args, .k = k.k } }),
            .fail => |c| b.pure(Step, ok.Pure, .{ .failed = c }),
        };
    }
};

// ------------------------------------------------------------------------------------------------ direct style

/// THE HOST AS A CONTEXT'S HANDLER: for DIRECT STYLE — a plain function given a context, its `cx.op(Host, .request,
/// …)` a call that waits for the host's answer (the function on a thread of its own, parked while the host works)
pub const Caller = struct {
    pub const Effect = Host;
    park: *Parked,
    pub fn request(self: Caller, r: Host.Request) Host.Reply {
        return self.park.ask(r);
    }
};

/// the context a direct function is given: the host, and (by `cx.guard`, `cx.observe`) what it adds
pub const Direct = ok.Context(struct { Caller }, @TypeOf(.{}), @TypeOf(.{}));

/// A FUNCTION THE HOST CALLS IN DIRECT STYLE: its context, an arena for what it makes, its arguments; its value, or an
/// error — `error.Condition` the host's condition (`call`), any other a condition by the error's name
pub const DirectFn = *const fn (cx: Direct, a: Allocator, args: []const Value) anyerror!Value;

pub const DirectEntry = struct { name: []const u8, function: DirectFn };

/// the host's operation `name` from a direct function: its answer; `error.Condition` the host's condition (kept, for
/// the worker to send back); `error.Canceled` the run cancelled — the host forgot it — so the function unwinds
pub fn call(cx: anytype, name: []const u8, args: []const Value) error{ Condition, Canceled }!Value {
    const reply = cx.op(Host, .request, .{ .name = name, .args = args });
    const park = cx.of(Host).park;
    if (park.canceled) return error.Canceled;
    return switch (reply) {
        .ok => |v| v,
        .failed => |c| {
            park.failure = c;
            return error.Condition;
        },
    };
}

/// A DIRECT CALL IN FLIGHT: the function runs as a task of the worker's `Io` (`io.concurrent`) — a fiber with
/// `Io.Evented`, a thread with `Io.Threaded`: the `Io` the worker is given chooses — and takes turns with the worker,
/// one running while the other waits on its event. The host forgetting it is `Io`'s cancellation: the function's
/// waiting call is a cancellation point
pub const Parked = struct {
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    task: std.Io.Future(void) = undefined,
    /// the function's turn: the host's answer is in `reply`
    go: std.Io.Event = .unset,
    /// the worker's turn: the function's operation, value or failure is in `out`
    back: std.Io.Event = .unset,
    reply: Host.Reply = .{ .ok = .null },
    out: Step = .{ .done = .null },
    failure: ?Condition = null,
    /// cancelled: every call of the function answers at once, `error.Canceled` (`call`)
    canceled: bool = false,
    k: u64 = 0,
    finished: bool = false,

    const gone: Host.Reply = .{ .failed = .{ .kind = "Canceled", .message = "the host forgot this run" } };

    fn ask(p: *Parked, r: Host.Request) Host.Reply {
        if (p.canceled) return gone;
        p.go.reset();
        p.out = .{ .perform = .{ .name = r.name, .args = r.args, .k = undefined } };
        p.back.set(p.io);
        p.go.wait(p.io) catch {
            p.canceled = true;
            return gone;
        };
        return p.reply;
    }

    fn body(p: *Parked, f: DirectFn, args: []const Value) void {
        const cx: Direct = .{ .handlers = .{Caller{ .park = p }}, .observers = .{}, .guards = .{} };
        p.out = if (f(cx, p.arena.allocator(), args)) |v| .{ .done = v } else |e| .{ .failed = if (e ==
            error.Condition and p.failure != null) p.failure.? else .{ .kind = @errorName(e), .message = "" } };
        p.finished = true;
        p.back.set(p.io);
    }

    /// the function's next turn: what it did — an operation, its value, its failure
    fn turn(p: *Parked) Step {
        p.back.waitUncancelable(p.io);
        p.back.reset();
        if (p.finished) p.task.await(p.io);
        return p.out;
    }

    /// the function started, as a task of `io`: null if `io` runs nothing concurrently
    fn start(gpa: Allocator, io: std.Io, f: DirectFn, args: []const Value) ?*Parked {
        const p = gpa.create(Parked) catch oom();
        p.* = .{ .io = io, .arena = .init(gpa) };
        const own = p.arena.allocator().alloc(Value, args.len) catch oom();
        for (args, own) |x, *y| y.* = clone(p.arena.allocator(), x) catch oom();
        p.task = io.concurrent(body, .{ p, f, own }) catch {
            p.arena.deinit();
            gpa.destroy(p);
            return null;
        };
        return p;
    }

    fn give(p: *Parked, r: Host.Reply) Step {
        p.reply = r;
        p.go.set(p.io);
        return p.turn();
    }

    /// the run dropped: a function still waiting cancelled (`Io`'s cancellation), and awaited
    fn drop(p: *Parked, gpa: Allocator) void {
        if (!p.finished) p.task.cancel(p.io);
        p.arena.deinit();
        gpa.destroy(p);
    }
};

/// the host's answer in a `continue`: its value, or its condition — copied into `a`
fn replyOf(a: Allocator, req: Value) Host.Reply {
    if (field(req, "condition")) |c| if (c == .object) return .{ .failed = .{
        .kind = a.dupe(u8, text(field(c, "kind")) orelse "Condition") catch oom(),
        .message = a.dupe(u8, text(field(c, "message")) orelse "") catch oom(),
    } };
    return .{ .ok = incoming(a, field(req, "answer") orelse .null) catch oom() };
}

/// a run: its arena — the program, its rests, the answers it was given — dropped whole when the host forgets it
const Run = struct {
    arena: std.heap.ArenaAllocator,
    b: Build,
    rests: std.AutoHashMapUnmanaged(u64, *const ok.Captured) = .empty,
    next: u64 = 0,

    fn make(gpa: Allocator) *Run {
        const r = gpa.create(Run) catch oom();
        r.* = .{ .arena = .init(gpa), .b = undefined };
        r.b = .{ .arena = r.arena.allocator() };
        return r;
    }
    fn drop(r: *Run, gpa: Allocator) void {
        r.arena.deinit();
        gpa.destroy(r);
    }
};

const Held = struct { arena: std.heap.ArenaAllocator, value: Value };

/// A WORKER: the programs it serves, by name, and what it keeps between requests — the runs' rests and the values
/// held for the host
pub const Worker = struct {
    gpa: Allocator,
    programs: []const Entry,
    /// functions in direct style, each call on a thread of its own: `withDirect`
    direct: []const DirectEntry = &.{},
    io: ?std.Io = null,
    runs: std.AutoHashMapUnmanaged(u64, *Run) = .empty,
    parked: std.AutoHashMapUnmanaged(u64, *Parked) = .empty,
    held: std.AutoHashMapUnmanaged(u64, *Held) = .empty,
    next_ref: u64 = 0,

    pub fn init(gpa: Allocator, programs: []const Entry) Worker {
        return .{ .gpa = gpa, .programs = programs };
    }

    /// the same worker serving `direct` functions too, their threads waiting by `io`
    pub fn withDirect(w: Worker, io: std.Io, direct: []const DirectEntry) Worker {
        var out = w;
        out.io = io;
        out.direct = direct;
        return out;
    }

    pub fn deinit(w: *Worker) void {
        var parked = w.parked.valueIterator();
        while (parked.next()) |p| p.*.drop(w.gpa);
        w.parked.deinit(w.gpa);
        var runs = w.runs.valueIterator();
        while (runs.next()) |r| r.*.drop(w.gpa);
        w.runs.deinit(w.gpa);
        var held = w.held.valueIterator();
        while (held.next()) |h| {
            h.*.arena.deinit();
            w.gpa.destroy(h.*);
        }
        w.held.deinit(w.gpa);
    }

    /// the worker's first line: who it is, what it speaks
    pub const hello = "{\"shim\":9,\"python\":\"zig\",\"speaks\":{\"format\":[\"json\"],\"compress\":[],\"frames\":" ++
        "[\"columnar\"]}}";

    /// a program by its name, or by `module:name`
    pub fn find(w: *const Worker, name: []const u8) ?Program {
        const bare = if (std.mem.indexOfScalar(u8, name, ':')) |i| name[i + 1 ..] else name;
        for (w.programs) |e| if (std.mem.eql(u8, e.name, name) or std.mem.eql(u8, e.name, bare)) return e.program;
        return null;
    }

    /// a direct function by its name, or by `module:name`
    pub fn findDirect(w: *const Worker, name: []const u8) ?DirectFn {
        const bare = if (std.mem.indexOfScalar(u8, name, ':')) |i| name[i + 1 ..] else name;
        for (w.direct) |e| if (std.mem.eql(u8, e.name, name) or std.mem.eql(u8, e.name, bare)) return e.function;
        return null;
    }

    fn dropRun(w: *Worker, run: u64) void {
        if (w.runs.fetchRemove(run)) |old| old.value.drop(w.gpa);
        if (w.parked.fetchRemove(run)) |old| old.value.drop(w.gpa);
    }

    /// a direct function's step as the host reads it: its operation says `once` — a parked thread, continued once
    fn directNode(w: *Worker, a: Allocator, run: u64, p: *Parked, step: Step) Answer {
        switch (step) {
            .perform => |o| {
                p.k += 1;
                return .{ .ok = object(a, .{
                    .{ "perform", Value{ .string = a.dupe(u8, o.name) catch oom() } },
                    .{ "args", outgoing(a, array(a, o.args)) catch oom() },
                    .{ "k", Value{ .integer = @intCast(p.k) } },
                    .{ "once", Value{ .bool = true } },
                }) };
            },
            .done => |v| {
                const out = object(a, .{.{ "done", outgoing(a, v) catch oom() }});
                w.dropRun(run);
                return .{ .ok = out };
            },
            .failed => |c| {
                const out = Condition{ .kind = a.dupe(u8, c.kind) catch oom(), .message = a.dupe(u8, c.message) catch
                    oom() };
                w.dropRun(run);
                return .{ .condition = out };
            },
        }
    }

    const Answer = union(enum) { ok: Value, condition: Condition };

    fn noConcurrency() Answer {
        return refuse("RuntimeError", "this worker's Io runs nothing concurrently: no direct style");
    }

    fn refuse(kind: []const u8, message: []const u8) Answer {
        return .{ .condition = .{ .kind = kind, .message = message } };
    }

    /// ONE REQUEST, its answer: a line of JSON, owned by the caller (`w.gpa`)
    pub fn serve1(w: *Worker, line: []const u8) []u8 {
        var scratch = std.heap.ArenaAllocator.init(w.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const req = std.json.parseFromSliceLeaky(Value, a, line, .{}) catch |e| {
            return w.render(a, .null, refuse("ValueError", @errorName(e)));
        };
        const id = field(req, "id") orelse .null;
        return w.render(a, id, w.answer(a, req));
    }

    fn render(w: *Worker, a: Allocator, id: Value, said: Answer) []u8 {
        const reply = switch (said) {
            .ok => |v| object(a, .{ .{ "id", id }, .{ "ok", v } }),
            .condition => |c| object(a, .{ .{ "id", id }, .{ "condition", object(a, .{
                .{ "kind", Value{ .string = c.kind } },
                .{ "message", Value{ .string = c.message } },
            }) } }),
        };
        return std.json.Stringify.valueAlloc(w.gpa, reply, .{}) catch oom();
    }

    fn answer(w: *Worker, a: Allocator, req: Value) Answer {
        const op = text(field(req, "op")) orelse return refuse("ValueError", "not a request");
        const run = natural(field(req, "run"));
        if (std.mem.eql(u8, op, "program")) {
            const fn_ = text(field(req, "fn"));
            if (run == null or fn_ == null) return refuse("ValueError", "a program request names its run and its fn");
            w.dropRun(run.?); // a run id used again: a new run
            if (w.findDirect(fn_.?)) |f| {
                var why: Condition = undefined;
                var scratch = std.heap.ArenaAllocator.init(w.gpa);
                defer scratch.deinit();
                const args = w.argsOf(scratch.allocator(), req, &why) orelse return .{ .condition = why };
                const parked = Parked.start(w.gpa, w.io.?, f, args) orelse return noConcurrency();
                w.parked.put(w.gpa, run.?, parked) catch oom();
                return w.directNode(a, run.?, parked, parked.turn());
            }
            const p = w.find(fn_.?) orelse return refuse("LookupError", "no program by that name in this worker");
            const r = Run.make(w.gpa);
            w.runs.put(w.gpa, run.?, r) catch oom();
            var why: Condition = undefined;
            const args = w.argsOf(r.b.arena, req, &why) orelse return .{ .condition = why };
            const prog = p(&r.b, args);
            return w.node(a, r, r.b.run(r.b.handle(Host, prog, Stepping{})));
        }
        if (std.mem.eql(u8, op, "continue")) {
            const k = natural(field(req, "k"));
            if (run == null or k == null) return refuse("ValueError", "a continue names its run and its k");
            if (w.parked.get(run.?)) |parked| {
                if (k.? != parked.k) return refuse("LookupError", "a direct call's continuation is continued once");
                return w.directNode(a, run.?, parked, parked.give(replyOf(parked.arena.allocator(), req)));
            }
            const r = w.runs.get(run.?) orelse return refuse("LookupError", "no such run here (forgotten?)");
            const rest = r.rests.get(k.?) orelse
                return refuse("LookupError", "that continuation is not held here (forgotten, or another process)");
            const reply = replyOf(r.b.arena, req);
            const resumed = ok.Resume(Host, Stepped){ .k = rest };
            return w.node(a, r, r.b.run(resumed.answer(&r.b, .request, reply)));
        }
        if (std.mem.eql(u8, op, "forget")) {
            if (run == null) return refuse("ValueError", "a forget names its run");
            w.dropRun(run.?);
            return .{ .ok = .null };
        }
        if (std.mem.eql(u8, op, "call")) {
            const fn_ = text(field(req, "fn")) orelse return refuse("ValueError", "a call names its fn (by name)");
            if (w.findDirect(fn_)) |f| {
                var why: Condition = undefined;
                var scratch = std.heap.ArenaAllocator.init(w.gpa);
                defer scratch.deinit();
                const args = w.argsOf(scratch.allocator(), req, &why) orelse return .{ .condition = why };
                const parked = Parked.start(w.gpa, w.io.?, f, args) orelse return noConcurrency();
                defer parked.drop(w.gpa);
                return switch (parked.turn()) {
                    .done => |v| .{ .ok = outgoing(a, v) catch oom() },
                    .perform => refuse("ValueError", "it calls the host: a call answers a value; run it as a program"),
                    .failed => |c| .{ .condition = .{
                        .kind = a.dupe(u8, c.kind) catch oom(),
                        .message = a.dupe(u8, c.message) catch oom(),
                    } },
                };
            }
            const p = w.find(fn_) orelse return refuse("LookupError", "no program by that name in this worker");
            const r = Run.make(w.gpa);
            defer r.drop(w.gpa);
            var why: Condition = undefined;
            const args = w.argsOf(r.b.arena, req, &why) orelse return .{ .condition = why };
            const step = r.b.run(r.b.handle(Host, p(&r.b, args), Stepping{}));
            return switch (step) {
                .done => |v| if (field(req, "held")) |h| switch (h) {
                    .bool => |yes| if (yes) w.hold(a, v) else .{ .ok = outgoing(a, v) catch oom() },
                    else => .{ .ok = outgoing(a, v) catch oom() },
                } else .{ .ok = outgoing(a, v) catch oom() },
                .perform => refuse("ValueError", "it performs: a call answers a value; run it as a program"),
                .failed => |c| .{ .condition = .{
                    .kind = a.dupe(u8, c.kind) catch oom(),
                    .message = a.dupe(u8, c.message) catch oom(),
                } },
            };
        }
        if (std.mem.eql(u8, op, "configure")) {
            const format = text(field(req, "format"));
            const compress = text(field(req, "compress"));
            if (format == null or compress == null)
                return refuse("ValueError", "a configure names its format and compression");
            if (std.mem.eql(u8, format.?, "json") and std.mem.eql(u8, compress.?, "none"))
                return .{ .ok = object(a, .{
                    .{ "format", Value{ .string = "json" } },
                    .{ "compress", Value{ .string = "none" } },
                }) };
            return refuse("ValueError", "this Zig worker speaks json with no compression");
        }
        if (std.mem.eql(u8, op, "release")) {
            if (natural(field(req, "ref"))) |i| if (w.held.fetchRemove(i)) |h| {
                h.value.arena.deinit();
                w.gpa.destroy(h.value);
            };
            return .{ .ok = .null };
        }
        return refuse("ValueError", "this Zig worker serves programs and calls, not that op");
    }

    /// a value kept for the host: its ref
    fn hold(w: *Worker, a: Allocator, v: Value) Answer {
        const h = w.gpa.create(Held) catch oom();
        h.* = .{ .arena = .init(w.gpa), .value = undefined };
        h.value = clone(h.arena.allocator(), v) catch oom();
        w.next_ref += 1;
        w.held.put(w.gpa, w.next_ref, h) catch oom();
        return .{ .ok = object(a, .{
            .{ "t", Value{ .string = "ref" } },
            .{ "id", Value{ .integer = @intCast(w.next_ref) } },
            .{ "type", Value{ .string = "value" } },
        }) };
    }

    /// a request's arguments, copied into the run, each ref's held value in its place
    fn argsOf(w: *Worker, a: Allocator, req: Value, why: *Condition) ?[]const Value {
        const xs = switch (field(req, "args") orelse return &.{}) {
            .array => |xs| xs.items,
            else => return &.{},
        };
        const out = a.alloc(Value, xs.len) catch oom();
        for (xs, 0..) |x, i| {
            if (std.mem.eql(u8, text(field(x, "t")) orelse "", "ref")) {
                const gone = "that ref is not held by this worker (released, or held by a process that is gone)";
                const h = w.held.get(natural(field(x, "id")) orelse 0) orelse {
                    why.* = .{ .kind = "LookupError", .message = gone };
                    return null;
                };
                out[i] = clone(a, h.value) catch oom();
            } else out[i] = incoming(a, x) catch oom();
        }
        return out;
    }

    /// a stepped program as the host reads it: its value, or its operation with the id of its rest, kept here
    fn node(w: *Worker, a: Allocator, r: *Run, step: Step) Answer {
        _ = w;
        return switch (step) {
            .done => |v| .{ .ok = object(a, .{.{ "done", outgoing(a, v) catch oom() }}) },
            .perform => |p| blk: {
                r.next += 1;
                r.rests.put(r.b.arena, r.next, p.k) catch oom();
                break :blk .{ .ok = object(a, .{
                    .{ "perform", Value{ .string = a.dupe(u8, p.name) catch oom() } },
                    .{ "args", outgoing(a, array(a, p.args)) catch oom() },
                    .{ "k", Value{ .integer = @intCast(r.next) } },
                }) };
            },
            .failed => |c| .{ .condition = .{
                .kind = a.dupe(u8, c.kind) catch oom(),
                .message = a.dupe(u8, c.message) catch oom(),
            } },
        };
    }

    /// the worker on a reader and a writer: its hello first, then one line in, one line out, until the input ends
    pub fn serve(w: *Worker, in: *std.Io.Reader, out: *std.Io.Writer) !void {
        try out.writeAll(hello ++ "\n");
        try out.flush();
        while (try in.takeDelimiter('\n')) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) continue;
            const reply = w.serve1(line);
            defer w.gpa.free(reply);
            try out.writeAll(reply);
            try out.writeAll("\n");
            try out.flush();
        }
    }
};
