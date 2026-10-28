//! THE STANDARD EFFECTS: State, Reader, Writer, Fail, Choose — each its operations (`Op`, a tagged union), the type
//! of each one's answer (`Answer`), its words, and its handlers.

const std = @import("std");
const ok = @import("okay.zig");
const Build = ok.Build;
const Eff = ok.Eff;

/// a state `S`: `get`, `put`
pub fn State(comptime S: type) type {
    return struct {
        const Self = @This();
        pub const Op = union(enum) { get: void, put: S };
        pub fn Answer(comptime tag: std.meta.Tag(Op)) type {
            return switch (tag) {
                .get => S,
                .put => void,
            };
        }
        pub fn get(b: *Build, comptime R: anytype) Eff(S, R) {
            return b.perform(R, Self, .get, {});
        }
        pub fn put(b: *Build, comptime R: anytype, s: S) Eff(void, R) {
            return b.perform(R, Self, .put, s);
        }
        /// in place: the state in a cell the caller holds
        pub const Cell = struct {
            pub const Effect = Self;
            s: *S,
            pub fn get(self: Cell) S {
                return self.s.*;
            }
            pub fn put(self: Cell, v: S) void {
                self.s.* = v;
            }
        };
        /// `p` with its state in `cell`: what is left of the row
        pub fn inCell(b: *Build, p: anytype, cell: *S) @TypeOf(b.handleTail(Self, p, Cell{ .s = cell })) {
            return b.handleTail(Self, p, Cell{ .s = cell });
        }
    };
}

/// an environment `E` read: `ask`
pub fn Reader(comptime E: type) type {
    return struct {
        const Self = @This();
        pub const Op = union(enum) { ask: void };
        pub fn Answer(comptime tag: std.meta.Tag(Op)) type {
            return switch (tag) {
                .ask => E,
            };
        }
        pub fn ask(b: *Build, comptime R: anytype) Eff(E, R) {
            return b.perform(R, Self, .ask, {});
        }
        pub const Given = struct {
            pub const Effect = Self;
            env: E,
            pub fn ask(self: Given) E {
                return self.env;
            }
        };
        pub fn given(b: *Build, p: anytype, env: E) @TypeOf(b.handleTail(Self, p, Given{ .env = env })) {
            return b.handleTail(Self, p, Given{ .env = env });
        }
    };
}

/// things told, `W`: `tell`
pub fn Writer(comptime W: type) type {
    return struct {
        const Self = @This();
        pub const Op = union(enum) { tell: W };
        pub fn Answer(comptime tag: std.meta.Tag(Op)) type {
            return switch (tag) {
                .tell => void,
            };
        }
        pub fn tell(b: *Build, comptime R: anytype, w: W) Eff(void, R) {
            return b.perform(R, Self, .tell, w);
        }
        /// in place: what is told appended to a list in the build's arena
        pub const Collect = struct {
            pub const Effect = Self;
            told: *std.ArrayList(W),
            arena: std.mem.Allocator,
            pub fn tell(self: Collect, w: W) void {
                // room left: a store, inlined where it is told; growing, a call
                if (self.told.items.len < self.told.capacity) return self.told.appendAssumeCapacity(w);
                self.told.append(self.arena, w) catch @panic("okay-zig: out of memory");
            }
        };
    };
}

/// a failure `E`: `raise` — the rest of the program dropped
pub fn Fail(comptime E: type) type {
    return struct {
        const Self = @This();
        pub const Op = union(enum) { raise: E };
        pub fn Answer(comptime tag: std.meta.Tag(Op)) type {
            return switch (tag) {
                .raise => void,
            };
        }
        /// a program of any value that never gives it: `e` raised
        pub fn raise(b: *Build, comptime A: type, comptime R: anytype, e: E) Eff(A, R) {
            return ok.never(A, b.perform(R, Self, .raise, e));
        }
        pub fn Result(comptime A: type) type {
            return union(enum) { value: A, failed: E };
        }
        /// `p`'s value, or what it raised: the rest of the program never resumed
        pub fn attempt(b: *Build, p: anytype) ok.Handled(@TypeOf(p), Self, Result(@TypeOf(p).Value)) {
            const P = @TypeOf(p);
            const Rest = P.Effects.without(P.Effects.place(Self));
            const Out = Eff(Result(P.Value), Rest);
            const H = struct {
                pub fn ret(_: @This(), bb: *Build, a: P.Value) Out {
                    return bb.pure(Result(P.Value), Rest, .{ .value = a });
                }
                pub fn op(_: @This(), bb: *Build, o: Op, _: ok.Resume(Self, Out)) Out {
                    return switch (o) {
                        .raise => |e| bb.pure(Result(P.Value), Rest, .{ .failed = e }),
                    };
                }
            };
            return b.handle(Self, p, H{});
        }
    };
}

/// a choice of two: `flip` — a handler may answer it both ways
pub const Choose = struct {
    const Self = @This();
    pub const Op = union(enum) { flip: void };
    pub fn Answer(comptime tag: std.meta.Tag(Op)) type {
        return switch (tag) {
            .flip => bool,
        };
    }
    pub fn flip(b: *Build, comptime R: anytype) Eff(bool, R) {
        return b.perform(R, Self, .flip, {});
    }
    /// EVERY value the program can give: each flip answered true, then the same rest answered false — `k` resumed
    /// twice
    pub fn all(b: *Build, p: anytype) ok.Handled(@TypeOf(p), Self, []const @TypeOf(p).Value) {
        const P = @TypeOf(p);
        const A = P.Value;
        const Rest = P.Effects.without(P.Effects.place(Self));
        const Out = Eff([]const A, Rest);
        const H = struct {
            pub fn ret(_: @This(), bb: *Build, a: A) Out {
                const one = bb.arena.alloc(A, 1) catch @panic("okay-zig: out of memory");
                one[0] = a;
                return bb.pure([]const A, Rest, one);
            }
            pub fn op(_: @This(), bb: *Build, o: Op, k: ok.Resume(Self, Out)) Out {
                switch (o) {
                    .flip => {
                        return bb.then(k.answer(bb, .flip, true), k, struct {
                            fn f(kk: ok.Resume(Self, Out), b2: *Build, xs: []const A) Out {
                                return b2.map(kk.answer(b2, .flip, false), .{ .xs = xs, .arena = b2.arena }, struct {
                                    fn g(c: anytype, ys: []const A) []const A {
                                        return std.mem.concat(c.arena, A, &.{ c.xs, ys }) catch
                                            @panic("okay-zig: out of memory");
                                    }
                                }.g);
                            }
                        }.f);
                    },
                }
            }
        };
        return b.handle(Self, p, H{});
    }
};
