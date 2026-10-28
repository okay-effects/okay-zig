//! Multi-shot continuations, measured as okay-goose's and okay-rust's lanes (n = 1000, µs per run, a second of
//! warm-up, then five rounds of a second; mean ± sd): RESUMABLE programs (`RS:`, the rest a union copied) and the
//! CEK MACHINE (`M:`, the rest captured frames). Each answer passed through `opaque`, so a run is not folded into a
//! formula. `zig build lanes -Doptimize=ReleaseFast`.

const std = @import("std");
const ok = @import("okay");
const rs = ok.resumable;
const Build = ok.Build;

const N: i64 = 1000;

/// a value the optimizer cannot see through (Rust's `black_box`)
fn opaque_(x: anytype) @TypeOf(x) {
    var y = x;
    std.mem.doNotOptimizeAway(&y);
    return y;
}

// ------------------------------------------------------------------------------------------------ resumable

/// one choice among n, then i + 1
const Pick = union(enum) {
    chosen,
    pub const Op = union(enum) { among: usize };
    pub const Answer = usize;
    pub const Out = usize;
    fn start(n: usize) rs.Step(Pick) {
        return rs.perform(Pick, .{ .among = n }, .chosen);
    }
    pub fn step(_: Pick, i: usize) rs.Step(Pick) {
        return rs.done(Pick, i + 1);
    }
};

const CountAll = struct {
    count: *i64,
    pub fn answers(_: CountAll, op: Pick.Op) Opaque {
        return .{ .inner = .{ .n = op.among } };
    }
    pub fn found(self: CountAll, _: usize) void {
        self.count.* += 1;
    }
    /// 0 ..< n, each through `opaque`
    const Opaque = struct {
        inner: rs.Among,
        pub fn next(self: *Opaque) ?usize {
            return if (self.inner.next()) |i| opaque_(i) else null;
        }
    };
};

/// a loop of n stops, each answered; the parity of the count its value
const Ticks = union(enum) {
    at: struct { i: i64, n: i64, even: bool },
    pub const Op = union(enum) { tick: i64 };
    pub const Answer = i64;
    pub const Out = bool;
    fn start(n: i64) rs.Step(Ticks) {
        if (n <= 0) return rs.done(Ticks, true);
        return rs.perform(Ticks, .{ .tick = 0 }, .{ .at = .{ .i = 0, .n = n, .even = true } });
    }
    pub fn step(self: Ticks, v: i64) rs.Step(Ticks) {
        var s = self.at;
        std.mem.doNotOptimizeAway(v);
        s.even = !s.even;
        s.i += 1;
        return if (s.i < s.n) rs.perform(Ticks, .{ .tick = s.i }, .{ .at = s }) else rs.done(Ticks, s.even);
    }
};

const Echo = struct {
    pub fn answer(_: Echo, op: Ticks.Op) i64 {
        return opaque_(op.tick);
    }
};

/// a generator of 0 ..< n
const Numbers = union(enum) {
    at: struct { i: i64, n: i64 },
    pub const Op = union(enum) { emit: i64 };
    pub const Answer = void;
    pub const Out = void;
    fn start(n: i64) rs.Step(Numbers) {
        if (n <= 0) return rs.done(Numbers, {});
        return rs.perform(Numbers, .{ .emit = 0 }, .{ .at = .{ .i = 0, .n = n } });
    }
    pub fn step(self: Numbers, _: void) rs.Step(Numbers) {
        var s = self.at;
        s.i += 1;
        return if (s.i < s.n) rs.perform(Numbers, .{ .emit = s.i }, .{ .at = s }) else rs.done(Numbers, {});
    }
};

fn sum(first: rs.Step(Numbers)) i64 {
    var total: i64 = 0;
    var step = first;
    while (true) switch (step) {
        .done => return total,
        .perform => |p| {
            total += opaque_(p.op.emit);
            step = p.k.step({});
        },
    };
}

fn rsChoose() i64 {
    var found: i64 = 0;
    rs.everyPath(Pick, Pick.start(opaque_(@as(usize, N))), CountAll{ .count = &found });
    return found;
}
fn rsGeneral() i64 {
    return @intFromBool(rs.run(Ticks, Ticks.start(opaque_(N)), Echo{}));
}
fn rsGenerate() i64 {
    return sum(Numbers.start(opaque_(N)));
}

// ------------------------------------------------------------------------------------------------ the machine

const Among = struct {
    pub const Op = union(enum) { among: usize };
    pub fn Answer(comptime _: std.meta.Tag(Op)) type {
        return usize;
    }
};
const Tick = struct {
    pub const Op = union(enum) { tick: i64 };
    pub fn Answer(comptime _: std.meta.Tag(Op)) type {
        return i64;
    }
};
const Yield = struct {
    pub const Op = union(enum) { emit: i64 };
    pub fn Answer(comptime _: std.meta.Tag(Op)) type {
        return void;
    }
};

var arena_state: std.heap.ArenaAllocator = undefined;

fn fresh() Build {
    _ = arena_state.reset(.retain_capacity);
    return .{ .arena = arena_state.allocator() };
}

/// every path of a choice among n: the rest resumed n times, the paths counted
fn mChoose() i64 {
    var b = fresh();
    const R = ok.Row(.{Among});
    const P = ok.Pure;
    const K = ok.Resume(Among, P.Of(i64));
    const prog = b.map(b.perform(R, Among, .among, opaque_(@as(usize, N))), {}, struct {
        fn f(_: void, i: usize) usize {
            return i + 1;
        }
    }.f);
    const H = struct {
        const At = struct { k: K, i: usize, n: usize };
        fn from(bb: *Build, at: At) P.Of(i64) {
            if (at.i == at.n) return bb.pure(i64, P, 0);
            return bb.then(at.k.answer(bb, .among, opaque_(at.i)), at, struct {
                fn g(c: At, b2: *Build, x: i64) P.Of(i64) {
                    return b2.map(from(b2, .{ .k = c.k, .i = c.i + 1, .n = c.n }), x, struct {
                        fn add(y: i64, z: i64) i64 {
                            return y + z;
                        }
                    }.add);
                }
            }.g);
        }
        pub fn ret(_: @This(), bb: *Build, _: usize) P.Of(i64) {
            return bb.pure(i64, P, 1);
        }
        pub fn op(_: @This(), bb: *Build, o: Among.Op, k: K) P.Of(i64) {
            return from(bb, .{ .k = k, .i = 0, .n = o.among });
        }
    };
    return b.run(b.handle(Among, prog, H{}));
}

/// a deep handler taking the rest at each of n steps, resumed once
fn mGeneral() i64 {
    var b = fresh();
    const R = ok.Row(.{Tick});
    const P = ok.Pure;
    const Loop = struct {
        const At = struct { i: i64, n: i64, even: bool };
        fn from(bb: *Build, at: At) R.Of(bool) {
            if (at.i == at.n) return bb.pure(bool, R, at.even);
            return bb.then(bb.perform(R, Tick, .tick, at.i), at, struct {
                fn g(c: At, b2: *Build, v: i64) R.Of(bool) {
                    std.mem.doNotOptimizeAway(v);
                    return from(b2, .{ .i = c.i + 1, .n = c.n, .even = !c.even });
                }
            }.g);
        }
    };
    const H = struct {
        pub fn ret(_: @This(), bb: *Build, e: bool) P.Of(bool) {
            return bb.pure(bool, P, e);
        }
        pub fn op(_: @This(), bb: *Build, o: Tick.Op, k: ok.Resume(Tick, P.Of(bool))) P.Of(bool) {
            return k.answer(bb, .tick, opaque_(o.tick));
        }
    };
    return @intFromBool(b.run(b.handle(Tick, Loop.from(&b, .{ .i = 0, .n = opaque_(N), .even = true }), H{})));
}

/// a generator of n values, summed by its handler
fn mGenerate() i64 {
    var b = fresh();
    const R = ok.Row(.{Yield});
    const P = ok.Pure;
    const Loop = struct {
        const At = struct { i: i64, n: i64 };
        fn from(bb: *Build, at: At) R.Of(void) {
            if (at.i == at.n) return bb.pure(void, R, {});
            return bb.then(bb.perform(R, Yield, .emit, at.i), at, struct {
                fn g(c: At, b2: *Build, _: void) R.Of(void) {
                    return from(b2, .{ .i = c.i + 1, .n = c.n });
                }
            }.g);
        }
    };
    const H = struct {
        pub fn ret(_: @This(), bb: *Build, _: void) P.Of(i64) {
            return bb.pure(i64, P, 0);
        }
        pub fn op(_: @This(), bb: *Build, o: Yield.Op, k: ok.Resume(Yield, P.Of(i64))) P.Of(i64) {
            return bb.map(k.answer(bb, .emit, {}), opaque_(o.emit), struct {
                fn add(v: i64, rest: i64) i64 {
                    return v + rest;
                }
            }.add);
        }
    };
    return b.run(b.handle(Yield, Loop.from(&b, .{ .i = 0, .n = opaque_(N) }), H{}));
}

// ------------------------------------------------------------------------------------------------ a context

const Told = ok.effects.Writer(i64);

/// 1000 values told through a context, kept in a list, summed (okay-goose's G:writer, okay-rust's T:writer)
fn cxWriter() i64 {
    _ = arena_state.reset(.retain_capacity);
    var told: std.ArrayList(i64) = .empty;
    const cx = ok.context(.{Told.Collect{ .told = &told, .arena = arena_state.allocator() }});
    const n = opaque_(N);
    var i: i64 = 0;
    while (i < n) : (i += 1) cx.op(Told, .tell, opaque_(i));
    var s: i64 = 0;
    for (told.items) |x| s += x;
    return s;
}

/// 1000 values told by a program as data, answered in place by the same `Writer.Collect` (Scala's `writer`, okay-rust's
/// machine `writer`)
fn mWriter() i64 {
    var b = fresh();
    const R = ok.Row(.{Told});
    var told: std.ArrayList(i64) = .empty;
    const Loop = struct {
        const At = struct { i: i64, n: i64 };
        fn from(bb: *Build, at: At) R.Of(void) {
            if (at.i == at.n) return bb.pure(void, R, {});
            return bb.then(Told.tell(bb, R, opaque_(at.i)), at, struct {
                fn g(c: At, b2: *Build, _: void) R.Of(void) {
                    return from(b2, .{ .i = c.i + 1, .n = c.n });
                }
            }.g);
        }
    };
    const p = Loop.from(&b, .{ .i = 0, .n = opaque_(N) });
    b.run(b.handleTail(Told, p, Told.Collect{ .told = &told, .arena = b.arena }));
    var total: i64 = 0;
    for (told.items) |x| total += x;
    return total;
}

// ------------------------------------------------------------------------------------------------ timing

fn lane(io: std.Io, name: []const u8, f: *const fn () i64) void {
    const second: i96 = 1_000_000_000;
    const now = struct {
        fn at(i: std.Io) i96 {
            return std.Io.Timestamp.now(i, .awake).nanoseconds;
        }
    }.at;
    var t = now(io);
    while (now(io) - t < second) std.mem.doNotOptimizeAway(f());
    var rounds: [5]f64 = undefined;
    for (&rounds) |*r| {
        t = now(io);
        var n: u64 = 0;
        while (now(io) - t < second) : (n += 1) std.mem.doNotOptimizeAway(f());
        r.* = @as(f64, @floatFromInt(now(io) - t)) / 1000.0 / @as(f64, @floatFromInt(n));
    }
    var mean: f64 = 0;
    for (rounds) |r| mean += r / 5.0;
    var v: f64 = 0;
    for (rounds) |r| v += (r - mean) * (r - mean) / 4.0;
    std.debug.print("{s:14} {d:10.3} ± {d:7.3} us/op\n", .{ name, mean, @sqrt(v) });
}

pub fn main(init: std.process.Init) void {
    arena_state = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    // the answers, checked
    const want = [_]i64{ N, 1, N * (N - 1) / 2 };
    if (cxWriter() != N * (N - 1) / 2) @panic("writer");
    if (mWriter() != N * (N - 1) / 2) @panic("machine writer");
    const rs_got = [_]i64{ rsChoose(), rsGeneral(), rsGenerate() };
    const m_got = [_]i64{ mChoose(), mGeneral(), mGenerate() };
    if (!std.mem.eql(i64, &want, &rs_got) or !std.mem.eql(i64, &want, &m_got)) {
        std.debug.print("wrong: want {any}, resumable {any}, machine {any}\n", .{ want, rs_got, m_got });
        return;
    }
    lane(init.io, "RS:choose", rsChoose);
    lane(init.io, "RS:general", rsGeneral);
    lane(init.io, "RS:generate", rsGenerate);
    lane(init.io, "M:choose", mChoose);
    lane(init.io, "M:general", mGeneral);
    lane(init.io, "M:generate", mGenerate);
    lane(init.io, "CX:writer", cxWriter);
    lane(init.io, "M:writer", mWriter);
}
