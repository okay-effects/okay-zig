//! okay-zig: algebraic effects and handlers for Zig, okay-scala's design (specs/design.md).
//!
//! A program is DATA — a value, an operation, a bind, a handler around a program, a resumption — and its type
//! `Eff(A, R)` says its value `A` and its effects, the ROW `R`, at compile time. An effect is in a row at a PLACE the
//! compiler computes (`Row.place`); one missing is a compile error naming both. A handler takes its effect out of the
//! row: `handle` (the rest of the program `k` given, resumed once, twice, or never) and `handleTail` (the answer given
//! in place, no `k` taken). One machine runs them, a CEK machine whose continuation is an immutable stack in an arena:
//! `k` is the segment up to its handler, so it is resumed any number of times.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ------------------------------------------------------------------------------------------------ rows

/// A ROW of effects: their types, in order. `Row(.{ State(u32), Log })`; `R.with(E)` is `R + E`.
pub fn Row(comptime members: anytype) type {
    return struct {
        pub const list = members;
        pub const len = list.len;

        /// `R + E`
        pub fn with(comptime E: type) type {
            return Row(members ++ .{E});
        }

        /// `E`'s place in the row: a compile error naming both if it is not there
        pub fn place(comptime E: type) usize {
            inline for (list, 0..) |X, i| if (X == E) return i;
            @compileError("the effect " ++ @typeName(E) ++ " is not in the row " ++ @typeName(@This()));
        }

        /// the row without the effect at `i`: what is left when its handler has taken it out
        pub fn without(comptime i: usize) type {
            return rowWithout(list, i, 0, .{});
        }

        /// a program of this row, its value `A`: `R.Of(u32)` is `u32 ! R`
        pub fn Of(comptime A: type) type {
            return Eff(A, @This());
        }

        /// whether `E` is in the row
        pub fn has(comptime E: type) bool {
            inline for (list) |X| if (X == E) return true;
            return false;
        }
    };
}

fn rowWithout(comptime xs: anytype, comptime i: usize, comptime j: usize, comptime acc: anytype) type {
    if (j == xs.len) return Row(acc);
    return if (j == i) rowWithout(xs, i, j + 1, acc) else rowWithout(xs, i, j + 1, acc ++ .{xs[j]});
}

/// the row of no effect
pub const Pure = Row(.{});

fn rowOf(comptime R: anytype) type {
    return if (@TypeOf(R) == type) R else Row(R);
}

// ------------------------------------------------------------------------------------------------ the machine

const builtin = @import("builtin");

fn oom() noreturn {
    @panic("okay-zig: out of memory");
}

/// A VALUE, as the machine carries it: kept IN the value when it is small (16 bytes, a slice's size, or less), else
/// in the arena and its address kept. The typed words put and take it by the types the compiler knows.
pub const Val = struct {
    w: [2]u64 = .{ 0, 0 },

    fn inline_(comptime T: type) bool {
        return @sizeOf(T) <= 16 and @alignOf(T) <= 8;
    }
    fn put(a: Allocator, comptime T: type, v: T) Val {
        var out = Val{};
        if (comptime inline_(T)) {
            const p: *T = @ptrCast(@alignCast(&out.w));
            p.* = v;
        } else {
            const p = a.create(T) catch oom();
            p.* = v;
            out.w[0] = @intFromPtr(p);
        }
        return out;
    }
    fn take(comptime T: type, v: Val) T {
        if (comptime inline_(T)) {
            const p: *const T = @ptrCast(@alignCast(&v.w));
            return p.*;
        }
        const p: *const T = @ptrFromInt(@as(usize, @intCast(v.w[0])));
        return p.*;
    }
};

/// the rest of a bind: a function and what it holds — a closure, made by hand
pub const Cont = struct {
    ctx: Val,
    call: *const fn (ctx: Val, b: *Build, value: Val) *Node,
};

/// a handler, erased: its return clause and its operation clause, or (`answer`) its answer in place
pub const Handling = struct {
    ctx: Val,
    ret: *const fn (ctx: Val, b: *Build, value: Val) *Node,
    op: ?*const fn (ctx: Val, b: *Build, op: Val, k: *const Captured) *Node,
    answer: ?*const fn (ctx: Val, b: *Build, op: Val) Val,
    /// an INTERCEPTOR: it takes its effect's operations and keeps the row — a place past it is not renumbered
    keeps: bool = false,
};

/// A PROGRAM AS DATA. A run CONSUMES it — each node freed as soon as the machine has read it — unless it is
/// `shared` (`Build.share`): then it, and what it holds, is kept for another run.
pub const Node = struct {
    shared: bool = false,
    kind: Kind,

    pub const Kind = union(enum) {
        value: Val,
        /// an operation of the effect at `place` in the program's row
        perform: struct { place: usize, op: Val },
        bind: struct { prog: *Node, k: Cont },
        /// `first`, its value dropped, then `then`
        seq: struct { first: *Node, then: *Node },
        /// `prog` with the effect at `place` handled by `h`
        handle: struct { prog: *Node, place: usize, h: *const Handling },
        /// the rest of a program given back its operation's answer
        resume_: struct { k: *const Captured, value: Val },
        /// a node a run has freed (Debug builds keep it so): run again, it says so
        dead,
    };
};

const Frame = struct {
    next: ?*Frame,
    /// in a captured `k`: its template, never freed — `k` may be resumed again
    pinned: bool = false,
    /// a copy of a template's frame: what it holds is the template's, kept
    shared: bool = false,
    kind: union(enum) {
        bind: Cont,
        seq: *Node,
        handle: struct { place: usize, h: *const Handling },
    },
};

/// `k`: the frames from the operation up to its handler, the handler's frame the last — pinned, so a handler
/// resumes it once, twice, or not at all
pub const Captured = struct { top: *Frame, handler: *Frame };

/// a free list of `T`s: what a run frees, the next allocation takes again — memory a loop's size, not its length
fn Pool(comptime T: type) type {
    return struct {
        free: ?*Slot = null,
        /// how many were taken from memory, not from the free list: what a run's memory is made of
        made: usize = 0,
        const Slot = struct { next: ?*Slot };
        comptime {
            if (@sizeOf(T) < @sizeOf(Slot) or @alignOf(T) < @alignOf(Slot))
                @compileError("a pool's item holds a pointer");
        }
        fn get(self: *@This(), a: Allocator) *T {
            if (self.free) |s| {
                self.free = s.next;
                return @ptrCast(@alignCast(s));
            }
            self.made += 1;
            return a.create(T) catch oom();
        }
        fn put(self: *@This(), p: *T) void {
            const s: *Slot = @ptrCast(@alignCast(p));
            s.* = .{ .next = self.free };
            self.free = s;
        }
    };
}

/// what programs are made with and run by: an arena — what lasts the run — and the free lists of nodes and frames
pub const Build = struct {
    arena: Allocator,
    nodes: Pool(Node) = .{},
    frames: Pool(Frame) = .{},

    pub fn node(b: *Build, kind: Node.Kind) *Node {
        const p = b.nodes.get(b.arena);
        p.* = .{ .kind = kind };
        return p;
    }

    fn bindNode(b: *Build, prog: *Node, ctx: Val, call: *const fn (Val, *Build, Val) *Node) *Node {
        return b.node(.{ .bind = .{ .prog = prog, .k = .{ .ctx = ctx, .call = call } } });
    }

    fn valueNode(b: *Build, v: Val) *Node {
        return b.node(.{ .value = v });
    }

    fn release(b: *Build, n: *Node) void {
        if (builtin.mode == .debug) {
            n.kind = .dead; // kept, poisoned: a program run twice is caught, not read freed
        } else b.nodes.put(n);
    }

    fn push(b: *Build, below: ?*Frame, kind: @FieldType(Frame, "kind"), shared: bool) *Frame {
        const f = b.frames.get(b.arena);
        f.* = .{ .next = below, .shared = shared, .kind = kind };
        return f;
    }

    /// THE MACHINE: a program of no effect left, run to its value. `ret` the value being returned to the stack;
    /// `keep` whether the node at hand is kept (shared, or in a shared one)
    fn eval(b: *Build, start: *Node) Val {
        var cur: *Node = start;
        var keep = start.shared;
        var stack: ?*Frame = null;
        var ret: Val = .{};
        var returning = false;
        while (true) {
            if (returning) {
                const f = stack orelse return ret;
                stack = f.next;
                returning = false;
                switch (f.kind) {
                    .bind => |k| {
                        cur = k.call(k.ctx, b, ret);
                        keep = cur.shared;
                    },
                    .seq => |second| {
                        cur = second;
                        keep = f.shared or second.shared;
                    },
                    .handle => |h| {
                        cur = h.h.ret(h.h.ctx, b, ret);
                        keep = cur.shared;
                    },
                }
                b.frames.put(f); // a live frame is never pinned: a template is off the stack
                continue;
            }
            const n = cur;
            const kept = keep or n.shared;
            switch (n.kind) {
                .dead => @panic("okay-zig: a program run a second time — `b.share(p)` keeps one for another run"),
                .value => |v| {
                    ret = v;
                    returning = true;
                },
                .bind => |x| {
                    stack = b.push(stack, .{ .bind = x.k }, kept);
                    cur = x.prog;
                    keep = kept;
                },
                .seq => |x| {
                    stack = b.push(stack, .{ .seq = x.then }, kept);
                    cur = x.first;
                    keep = kept;
                },
                .handle => |x| {
                    stack = b.push(stack, .{ .handle = .{ .place = x.place, .h = x.h } }, kept);
                    cur = x.prog;
                    keep = kept;
                },
                .perform => |p| {
                    // up the stack to the operation's handler, its place renumbered past each other handler
                    var place = p.place;
                    var f = stack;
                    const found: *Frame = while (f) |fr| : (f = fr.next) {
                        switch (fr.kind) {
                            .handle => |h| {
                                if (h.place == place) break fr;
                                if (!h.h.keeps and place > h.place) place -= 1;
                            },
                            else => {},
                        }
                    } else @panic("okay-zig: an operation no handler takes (the types should have said so)");
                    const h = found.kind.handle.h;
                    if (h.answer) |answer| {
                        ret = answer(h.ctx, b, p.op); // in place: the stack as it is
                        returning = true;
                    } else {
                        // the segment up to the handler pinned: a template for every resumption
                        var g: *Frame = stack.?;
                        while (true) : (g = g.next.?) {
                            g.pinned = true;
                            if (g == found) break;
                        }
                        const k = b.arena.create(Captured) catch oom();
                        k.* = .{ .top = stack.?, .handler = found };
                        stack = found.next;
                        cur = h.op.?(h.ctx, b, p.op, k);
                        keep = cur.shared;
                    }
                },
                .resume_ => |r| {
                    stack = b.reinstate(r.k, stack);
                    ret = r.value;
                    returning = true;
                },
            }
            if (!kept) b.release(n);
        }
    }

    /// `k`'s frames on `base`: copied, marked shared — the template stays for the next resumption
    fn reinstate(b: *Build, k: *const Captured, base: ?*Frame) *Frame {
        var t: *Frame = k.top;
        const first = b.push(null, t.kind, true);
        var last = first;
        while (t != k.handler) {
            t = t.next.?;
            const c = b.push(null, t.kind, true);
            last.next = c;
            last = c;
        }
        last.next = base;
        return first;
    }

    /// `p` kept by its runs: run again, or used twice in one program
    pub fn share(_: *Build, p: anytype) @TypeOf(p) {
        p.node.shared = true;
        return p;
    }

    // -------------------------------------------------------------------------------------------- the words

    /// `a`, a program of row `R` with no operation
    pub fn pure(b: *Build, comptime A: type, comptime R: anytype, a: A) Eff(A, R) {
        return .{ .node = b.valueNode(Val.put(b.arena, A, a)) };
    }

    /// an operation of `E`, its answer the program's value: `E` must be in `R`
    pub fn perform(
        b: *Build,
        comptime R: anytype,
        comptime E: type,
        comptime tag: std.meta.Tag(E.Op),
        payload: @FieldType(E.Op, @tagName(tag)),
    ) Eff(E.Answer(tag), R) {
        const place = comptime rowOf(R).place(E);
        const op = @unionInit(E.Op, @tagName(tag), payload);
        return .{ .node = b.node(.{ .perform = .{ .place = place, .op = Val.put(b.arena, E.Op, op) } }) };
    }

    /// `p`, then `f(ctx, b, its value)`: `ctx` is what `f` holds, `f` a function with no capture
    pub fn then(b: *Build, p: anytype, ctx: anytype, comptime f: anytype) ReturnOf(f) {
        const P = @TypeOf(p);
        const Ctx = @TypeOf(ctx);
        const Q = ReturnOf(f);
        comptime if (P.Effects != Q.Effects)
            @compileError("then: " ++ @typeName(P.Effects) ++ " and " ++ @typeName(Q.Effects) ++ " are not one row");
        const W = struct {
            fn call(c: Val, bb: *Build, v: Val) *Node {
                return f(Val.take(Ctx, c), bb, Val.take(P.Value, v)).node;
            }
        };
        return .{ .node = b.bindNode(p.node, Val.put(b.arena, Ctx, ctx), W.call) };
    }

    /// `p`'s value through `f(ctx, it)`
    pub fn map(b: *Build, p: anytype, ctx: anytype, comptime f: anytype) Eff(ReturnOfPlain(f), @TypeOf(p).Effects) {
        const P = @TypeOf(p);
        const Ctx = @TypeOf(ctx);
        const B = ReturnOfPlain(f);
        const W = struct {
            fn call(c: Val, bb: *Build, v: Val) *Node {
                return bb.valueNode(Val.put(bb.arena, B, f(Val.take(Ctx, c), Val.take(P.Value, v))));
            }
        };
        return .{ .node = b.bindNode(p.node, Val.put(b.arena, Ctx, ctx), W.call) };
    }

    /// `p`, then `q`, its value dropped
    pub fn andThen(b: *Build, p: anytype, q: anytype) @TypeOf(q) {
        return .{ .node = b.node(.{ .seq = .{ .first = p.node, .then = q.node } }) };
    }

    /// `p`, then the STEP `f(b, its value)` — a step a function that holds nothing, declared once and named
    pub fn next(b: *Build, p: anytype, comptime f: anytype) ReturnOf(f) {
        const P = @TypeOf(p);
        comptime if (P.Effects != ReturnOf(f).Effects)
            @compileError("next: " ++ @typeName(P.Effects) ++ " and " ++ @typeName(ReturnOf(f).Effects) ++
                " are not one row");
        const W = struct {
            fn call(_: Val, bb: *Build, v: Val) *Node {
                return f(bb, Val.take(P.Value, v)).node;
            }
        };
        return .{ .node = b.bindNode(p.node, .{}, W.call) };
    }

    /// programs one after another, each value but the last dropped: `b.seq(.{ p, q, r })`
    pub fn seq(b: *Build, ps: anytype) @TypeOf(ps[ps.len - 1]) {
        return b.seqFrom(ps, 0);
    }
    fn seqFrom(b: *Build, ps: anytype, comptime i: usize) @TypeOf(ps[ps.len - 1]) {
        if (i == ps.len - 1) return ps[i];
        return b.andThen(ps[i], b.seqFrom(ps, i + 1));
    }

    /// `p` through STEPS, each given the value before: `b.chain(p, .{ double, save })`, each a function
    /// `fn (*Build, A) R.Of(B)` — its types the steps' own, checked where they meet
    pub fn chain(b: *Build, p: anytype, comptime steps: anytype) ReturnOf(steps[steps.len - 1]) {
        return b.chainFrom(p, steps, 0);
    }
    fn chainFrom(b: *Build, p: anytype, comptime steps: anytype, comptime i: usize) ReturnOf(steps[steps.len - 1]) {
        if (i == steps.len - 1) return b.next(p, steps[i]);
        return b.chainFrom(b.next(p, steps[i]), steps, i + 1);
    }

    /// `p` with `E` handled by `h`: `h.ret(b, a)` its return, `h.op(b, op, k)` each operation with the rest of the
    /// program `k` (`k.answer(b, tag, value)` resumes it — once, twice, or never). The program's row without `E`.
    pub fn handle(b: *Build, comptime E: type, p: anytype, h: anytype) HandledBy(@TypeOf(h)) {
        const P = @TypeOf(p);
        const Out = HandledBy(@TypeOf(h));
        const place = comptime P.Effects.place(E);
        comptime if (Out.Effects != P.Effects.without(place))
            @compileError("handle: the handler's row is " ++ @typeName(Out.Effects) ++ ", the program's without " ++
                @typeName(E) ++ " is " ++ @typeName(P.Effects.without(place)));
        return b.install(E, p, h, false);
    }

    /// `p` with `E`'s operations taken by `h` — as `handle` — and the ROW KEPT: an operation of `E` inside goes to
    /// `h`, one outside it to the next handler of `E`. A handler anywhere in a program, its row one type (the TCK's
    /// handlers nested in any order)
    pub fn intercept(b: *Build, comptime E: type, p: anytype, h: anytype) HandledBy(@TypeOf(h)) {
        const P = @TypeOf(p);
        const Out = HandledBy(@TypeOf(h));
        comptime if (Out.Effects != P.Effects)
            @compileError("intercept: the handler's row is " ++ @typeName(Out.Effects) ++ ", the program's " ++
                @typeName(P.Effects));
        return b.install(E, p, h, true);
    }

    fn install(b: *Build, comptime E: type, p: anytype, h: anytype, keeps: bool) HandledBy(@TypeOf(h)) {
        const P = @TypeOf(p);
        const H = @TypeOf(h);
        const Out = HandledBy(H);
        const place = comptime P.Effects.place(E);
        const W = struct {
            fn ret(c: Val, bb: *Build, v: Val) *Node {
                return Val.take(H, c).ret(bb, Val.take(P.Value, v)).node;
            }
            fn op(c: Val, bb: *Build, o: Val, k: *const Captured) *Node {
                return Val.take(H, c).op(bb, Val.take(E.Op, o), Resume(E, Out){ .k = k }).node;
            }
        };
        const handling = b.arena.create(Handling) catch oom();
        handling.* = .{ .ctx = Val.put(b.arena, H, h), .ret = W.ret, .op = W.op, .answer = null, .keeps = keeps };
        return .{ .node = b.node(.{ .handle = .{ .prog = p.node, .place = place, .h = handling } }) };
    }

    /// `p` with `E` answered IN PLACE by `h`: a method of `h` an operation, by its name, its answer the operation's
    /// (`State`: `get(self) S`, `put(self, s) void`) — no `k` taken, the cheapest handler
    pub fn handleTail(b: *Build, comptime E: type, p: anytype, h: anytype) Handled(@TypeOf(p), E, @TypeOf(p).Value) {
        return .{ .node = b.installTail(E, p, h, false) };
    }

    /// `p` with `E` answered in place by `h` — as `handleTail` — and the row kept, as `intercept`
    pub fn interceptTail(b: *Build, comptime E: type, p: anytype, h: anytype) @TypeOf(p) {
        return .{ .node = b.installTail(E, p, h, true) };
    }

    fn installTail(b: *Build, comptime E: type, p: anytype, h: anytype, keeps: bool) *Node {
        const P = @TypeOf(p);
        const H = @TypeOf(h);
        const place = comptime P.Effects.place(E);
        const W = struct {
            fn ret(_: Val, bb: *Build, v: Val) *Node {
                return bb.valueNode(v);
            }
            fn answer(c: Val, bb: *Build, o: Val) Val {
                const self = Val.take(H, c);
                switch (Val.take(E.Op, o)) {
                    inline else => |payload, tag| {
                        const method = @field(H, @tagName(tag));
                        const a = if (@TypeOf(payload) == void) method(self) else method(self, payload);
                        return Val.put(bb.arena, E.Answer(tag), a);
                    },
                }
            }
        };
        const handling = b.arena.create(Handling) catch oom();
        handling.* = .{ .ctx = Val.put(b.arena, H, h), .ret = W.ret, .op = null, .answer = W.answer, .keeps = keeps };
        return b.node(.{ .handle = .{ .prog = p.node, .place = place, .h = handling } });
    }

    /// a program of no effect, run: its value
    pub fn run(b: *Build, p: anytype) @TypeOf(p).Value {
        const P = @TypeOf(p);
        comptime if (P.Effects.len != 0) @compileError("run: effects left unhandled: " ++ @typeName(P.Effects));
        return Val.take(P.Value, b.eval(p.node));
    }
};

/// A PROGRAM: its value `A`, its effects the row `R` (a `Row`, or a tuple of effects) — `A ! R`
pub fn Eff(comptime A: type, comptime R: anytype) type {
    return EffOf(A, rowOf(R)); // `.{ F, G }` and `Row(.{ F, G })`: one type
}
fn EffOf(comptime A: type, comptime R: type) type {
    return struct {
        node: *Node,
        pub const Value = A;
        pub const Effects = R;
    };
}

/// what a program `P` is with `E` handled, its value `B`: its row without `E`
pub fn Handled(comptime P: type, comptime E: type, comptime B: type) type {
    return Eff(B, P.Effects.without(P.Effects.place(E)));
}

/// the rest of a program, given to a handler's operation clause: resumed with the operation's answer
pub fn Resume(comptime E: type, comptime Out: type) type {
    return struct {
        k: *const Captured,
        /// the rest of the program, given `value` as the answer to its operation `tag`: a program of the handler's
        pub fn answer(self: @This(), b: *Build, comptime tag: std.meta.Tag(E.Op), value: E.Answer(tag)) Out {
            const v = Val.put(b.arena, E.Answer(tag), value);
            return .{ .node = b.node(.{ .resume_ = .{ .k = self.k, .value = v } }) };
        }
    };
}

fn ReturnOf(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?;
}
fn ReturnOfPlain(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?;
}

/// a program whose value never comes (its operation is never answered): any value type
pub fn never(comptime A: type, p: anytype) Eff(A, @TypeOf(p).Effects) {
    return .{ .node = p.node };
}
fn HandledBy(comptime H: type) type {
    return @typeInfo(@TypeOf(H.ret)).@"fn".return_type.?;
}

/// the standard effects
pub const effects = @import("std.zig");

/// the contexts layer: a program a plain function, its effects the handlers it is given
pub const Context = @import("cx.zig").Context;
pub const context = @import("cx.zig").context;
pub const needs = @import("cx.zig").needs;

/// okay's wire: Zig programs served to okay's hosts, run under their handlers
pub const wire = @import("wire.zig");

/// resumable programs: the rest of a program a value — a state machine copied to resume it again
pub const resumable = @import("resumable.zig");
