//! okay-kernel's TCK digest: its thousand random programs — handlers of logs, states, failures and choices nested in
//! any order, each effect twice (two identities), their operations, binds — run here; the digest of their outcomes
//! must be the reference machine's, okay-java's and okay-rust's: the same programs, the same seed
//! (okay-kernel tck/src/main/scala/okay/kernel/tck/Tck.scala; okay-rust machine/tests/tck.rs). A program's values are
//! Java's `int`s (wrapping); an effect's two identities two types (`State(i64)` and `State(i32)`). A handler in a
//! program keeps its row (`intercept`). The TCK's state is a CELL, made when its handler is built, one for every
//! resumption of a rest taken past it.

const std = @import("std");
const ok = @import("okay");
const S = ok.effects;
const Build = ok.Build;

/// java.util.Random, under scala.util.Random
const JRandom = struct {
    seed: u64,
    fn init(seed: i64) JRandom {
        return .{ .seed = (@as(u64, @bitCast(seed)) ^ 0x5DEECE66D) & ((1 << 48) - 1) };
    }
    fn next(r: *JRandom, comptime bits: u6) i32 {
        r.seed = (r.seed *% 0x5DEECE66D +% 0xB) & ((1 << 48) - 1);
        return @truncate(@as(i64, @bitCast(r.seed >> (48 - bits))));
    }
    fn nextInt(r: *JRandom, bound: i32) i32 {
        if (bound & -bound == bound) return @intCast((@as(i64, bound) * r.next(31)) >> 31);
        while (true) {
            const bits = r.next(31);
            const val = @mod(bits, bound);
            if (bits -% val +% (bound - 1) >= 0) return val;
        }
    }
};

const T = union(enum) {
    pure: i32,
    tell: [2]i32,
    get: i32,
    put: [2]i32,
    among: []const i32,
    raise: [2]i32,
    seq: [2]*const T,
    add: [2]*const T,
    writer: struct { e: i32, body: *const T },
    state: struct { e: i32, s0: i32, body: *const T },
    throws: struct { e: i32, body: *const T },
    choose: *const T,
};

fn mk(a: std.mem.Allocator, t: T) *const T {
    const p = a.create(T) catch @panic("out of memory");
    p.* = t;
    return p;
}

fn random(a: std.mem.Allocator, r: *JRandom, depth: i32) *const T {
    if (depth <= 0 or r.nextInt(4) == 0) return mk(a, switch (r.nextInt(6)) {
        0 => .{ .pure = r.nextInt(10) },
        1 => blk: {
            const e = r.nextInt(2);
            break :blk .{ .tell = .{ e, r.nextInt(10) } };
        },
        2 => .{ .get = r.nextInt(2) },
        3 => blk: {
            const e = r.nextInt(2);
            break :blk .{ .put = .{ e, r.nextInt(10) } };
        },
        4 => blk: {
            const n: usize = @intCast(1 + r.nextInt(2));
            const ns = a.alloc(i32, n) catch @panic("out of memory");
            for (ns) |*x| x.* = r.nextInt(10);
            break :blk .{ .among = ns };
        },
        else => blk: {
            const e = r.nextInt(2);
            break :blk .{ .raise = .{ e, r.nextInt(10) } };
        },
    });
    return mk(a, switch (r.nextInt(6)) {
        0 => blk: {
            const x = random(a, r, depth - 1);
            break :blk .{ .seq = .{ x, random(a, r, depth - 1) } };
        },
        1 => blk: {
            const x = random(a, r, depth - 1);
            break :blk .{ .add = .{ x, random(a, r, depth - 1) } };
        },
        2 => blk: {
            const e = r.nextInt(2);
            break :blk .{ .writer = .{ .e = e, .body = random(a, r, depth - 1) } };
        },
        3 => blk: {
            const e = r.nextInt(2);
            const s0 = r.nextInt(10);
            break :blk .{ .state = .{ .e = e, .s0 = s0, .body = random(a, r, depth - 1) } };
        },
        4 => blk: {
            const e = r.nextInt(2);
            break :blk .{ .throws = .{ .e = e, .body = random(a, r, depth - 1) } };
        },
        else => .{ .choose = random(a, r, depth - 1) },
    });
}

/// one row with every effect, each twice
const R = ok.Row(.{ S.Choose, S.Fail(i64), S.Fail(i32), S.State(i64), S.State(i32), S.Writer(i64), S.Writer(i32) });
const P = R.Of(i32);

fn wide(comptime X: type, n: i32) X {
    return @intCast(n);
}
fn narrow(x: anytype) i32 {
    return @truncate(@as(i64, x));
}

fn build(b: *Build, t: *const T) P {
    return switch (t.*) {
        .pure => |n| b.pure(i32, R, n),
        .tell => |x| if (x[0] == 0) told(b, i64, x[1]) else told(b, i32, x[1]),
        .get => |e| if (e == 0) got(b, i64) else got(b, i32),
        .put => |x| if (x[0] == 0) putting(b, i64, x[1]) else putting(b, i32, x[1]),
        .among => |ns| if (ns.len == 1) b.pure(i32, R, ns[0]) else b.then(S.Choose.flip(b, R), ns, struct {
            fn pick(xs: []const i32, bb: *Build, first: bool) P {
                return bb.pure(i32, R, if (first) xs[0] else xs[1]);
            }
        }.pick),
        .raise => |x| if (x[0] == 0) S.Fail(i64).raise(b, i32, R, x[1]) else S.Fail(i32).raise(b, i32, R, x[1]),
        .seq => |x| b.then(build(b, x[0]), x[1], struct {
            fn f(rest: *const T, bb: *Build, _: i32) P {
                return build(bb, rest);
            }
        }.f),
        .add => |x| b.then(build(b, x[0]), x[1], struct {
            fn f(rest: *const T, bb: *Build, i: i32) P {
                return bb.then(build(bb, rest), i, struct {
                    fn g(ii: i32, b2: *Build, j: i32) P {
                        return b2.pure(i32, R, ii +% j);
                    }
                }.g);
            }
        }.f),
        .writer => |w| if (w.e == 0) collect(b, i64, build(b, w.body)) else collect(b, i32, build(b, w.body)),
        .state => |s| if (s.e == 0) cell(b, i64, s.s0, build(b, s.body)) else cell(b, i32, s.s0, build(b, s.body)),
        .throws => |x| if (x.e == 0) either(b, i64, build(b, x.body)) else either(b, i32, build(b, x.body)),
        .choose => |body| all(b, build(b, body)),
    };
}

fn told(b: *Build, comptime W: type, n: i32) P {
    return b.andThen(S.Writer(W).tell(b, R, wide(W, n)), b.pure(i32, R, n));
}
fn got(b: *Build, comptime X: type) P {
    return b.map(S.State(X).get(b, R), {}, struct {
        fn f(_: void, s: X) i32 {
            return narrow(s);
        }
    }.f);
}
fn putting(b: *Build, comptime X: type, n: i32) P {
    return b.andThen(S.State(X).put(b, R, wide(X, n)), b.pure(i32, R, n));
}

/// the log's sum and the value: what the TCK keeps of a writer (`v * 100 + sum`)
const Told = struct { sum: i32, v: i32 };

fn collect(b: *Build, comptime W: type, body: P) P {
    const E = S.Writer(W);
    const Out = R.Of(Told);
    const H = struct {
        pub fn ret(_: @This(), bb: *Build, v: i32) Out {
            return bb.pure(Told, R, .{ .sum = 0, .v = v });
        }
        pub fn op(_: @This(), bb: *Build, o: E.Op, k: ok.Resume(E, Out)) Out {
            return bb.map(k.answer(bb, .tell, {}), narrow(o.tell), struct {
                fn f(w: i32, t: Told) Told {
                    return .{ .sum = w +% t.sum, .v = t.v };
                }
            }.f);
        }
    };
    return b.map(b.intercept(E, body, H{}), {}, struct {
        fn f(_: void, t: Told) i32 {
            return t.v *% 100 +% t.sum;
        }
    }.f);
}

fn cell(b: *Build, comptime X: type, s0: i32, body: P) P {
    const s = b.arena.create(X) catch @panic("out of memory");
    s.* = wide(X, s0);
    return b.map(b.interceptTail(S.State(X), body, S.State(X).Cell{ .s = s }), s, struct {
        fn f(at_end: *X, v: i32) i32 {
            return v *% 10 +% narrow(at_end.*);
        }
    }.f);
}

fn either(b: *Build, comptime X: type, body: P) P {
    const E = S.Fail(X);
    const H = struct {
        pub fn ret(_: @This(), bb: *Build, v: i32) P {
            return bb.pure(i32, R, v);
        }
        pub fn op(_: @This(), bb: *Build, o: E.Op, _: ok.Resume(E, P)) P {
            return bb.pure(i32, R, -1 -% narrow(o.raise));
        }
    };
    return b.intercept(E, body, H{});
}

/// every branch, their values summed
fn all(b: *Build, body: P) P {
    const E = S.Choose;
    const K = ok.Resume(E, P);
    const H = struct {
        pub fn ret(_: @This(), bb: *Build, v: i32) P {
            return bb.pure(i32, R, v);
        }
        pub fn op(_: @This(), bb: *Build, _: E.Op, k: K) P {
            return bb.then(k.answer(bb, .flip, true), k, struct {
                fn f(kk: K, b2: *Build, x: i32) P {
                    return b2.map(kk.answer(b2, .flip, false), x, struct {
                        fn g(xx: i32, y: i32) i32 {
                            return xx +% y;
                        }
                    }.g);
                }
            }.f);
        }
    };
    return b.intercept(E, body, H{});
}

/// the row closed: its effects' handlers outside, never reached (every operation is the program's own handlers')
fn closed(b: *Build, p: P) i32 {
    const No = struct {
        fn reached() noreturn {
            @panic("TCK: an operation past the program's own handlers");
        }
    };
    const Tell = struct {
        pub fn tell(_: @This(), _: anytype) void {
            No.reached();
        }
    };
    const Cell = struct {
        pub fn get(_: @This()) i64 {
            No.reached();
        }
        pub fn put(_: @This(), _: anytype) void {
            No.reached();
        }
    };
    const Cell32 = struct {
        pub fn get(_: @This()) i32 {
            No.reached();
        }
        pub fn put(_: @This(), _: anytype) void {
            No.reached();
        }
    };
    const Raise = struct {
        pub fn raise(_: @This(), _: anytype) void {
            No.reached();
        }
    };
    const Flip = struct {
        pub fn flip(_: @This()) bool {
            No.reached();
        }
    };
    const p1 = b.handleTail(S.Writer(i32), p, Tell{});
    const p2 = b.handleTail(S.Writer(i64), p1, Tell{});
    const p3 = b.handleTail(S.State(i32), p2, Cell32{});
    const p4 = b.handleTail(S.State(i64), p3, Cell{});
    const p5 = b.handleTail(S.Fail(i32), p4, Raise{});
    const p6 = b.handleTail(S.Fail(i64), p5, Raise{});
    return b.run(b.handleTail(S.Choose, p6, Flip{}));
}

/// okay-kernel's Tck.Digest
const digest: i64 = -8623788747993822161;

test "a thousand random programs: the reference machine's digest" {
    var r = JRandom.init(20261010);
    var d: i64 = 0;
    for (0..1000) |_| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        // a handler of each kind around: ChooseH(ThrowsH(0, ThrowsH(1, StateH(0, 0, StateH(1, 0, WriterH(0,
        // WriterH(1, gen)))))))
        var t = random(a, &r, 6);
        t = mk(a, .{ .writer = .{ .e = 1, .body = t } });
        t = mk(a, .{ .writer = .{ .e = 0, .body = t } });
        t = mk(a, .{ .state = .{ .e = 1, .s0 = 0, .body = t } });
        t = mk(a, .{ .state = .{ .e = 0, .s0 = 0, .body = t } });
        t = mk(a, .{ .throws = .{ .e = 1, .body = t } });
        t = mk(a, .{ .throws = .{ .e = 0, .body = t } });
        t = mk(a, .{ .choose = t });
        var b = Build{ .arena = a };
        const v = closed(&b, build(&b, t));
        d = d *% 31 +% v;
    }
    try std.testing.expectEqual(digest, d);
}

test "the generator as Java's: java.util.Random(20261010), nextInt of these bounds, as Java printed them" {
    var r = JRandom.init(20261010);
    const bounds = [_]i32{ 4, 6, 10, 2, 6, 10 };
    var got_: [18]i32 = undefined;
    for (&got_, 0..) |*x, i| x.* = r.nextInt(bounds[i % 6]);
    try std.testing.expectEqualSlices(i32, &.{ 2, 4, 9, 1, 0, 8, 0, 4, 4, 0, 2, 7, 0, 3, 6, 1, 1, 1 }, &got_);
}
