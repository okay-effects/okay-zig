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

/// a value, erased: the machine's own; the typed words below put and take them, by the types the compiler knows
pub const Any = *const anyopaque;

fn oom() noreturn {
    @panic("okay-zig: out of memory");
}

fn box(a: Allocator, comptime T: type, v: T) Any {
    const p = a.create(T) catch oom();
    p.* = v;
    return @ptrCast(p);
}

fn unbox(comptime T: type, p: Any) T {
    const q: *const T = @ptrCast(@alignCast(p));
    return q.*;
}

/// the rest of a bind: a function and what it holds — a closure, made by hand
pub const Cont = struct {
    ctx: Any,
    call: *const fn (ctx: Any, b: *Build, value: Any) *const Node,
};

/// a handler, erased: its return clause and its operation clause, or (`answer`) its answer in place
pub const Handling = struct {
    ctx: Any,
    ret: *const fn (ctx: Any, b: *Build, value: Any) *const Node,
    op: ?*const fn (ctx: Any, b: *Build, op: Any, k: *const Captured) *const Node,
    answer: ?*const fn (ctx: Any, b: *Build, op: Any) Any,
};

/// A PROGRAM AS DATA
pub const Node = union(enum) {
    value: Any,
    /// an operation of the effect at `place` in the program's row
    perform: struct { place: usize, op: Any },
    bind: struct { prog: *const Node, k: Cont },
    /// `prog` with the effect at `place` handled by `h`
    handle: struct { prog: *const Node, place: usize, h: *const Handling },
    /// the rest of a program given back its operation's answer
    resume_: struct { k: *const Captured, value: Any },
};

const Frame = struct {
    next: ?*const Frame,
    kind: union(enum) {
        bind: Cont,
        handle: struct { place: usize, h: *const Handling },
    },
};

/// `k`: the frames from the operation up to its handler, the handler's frame the last — kept, never changed, so a
/// handler resumes it once, twice, or not at all
pub const Captured = struct { top: *const Frame, handler: *const Frame };

/// what programs are made with and run by: an arena, everything a run makes in it, freed with it
pub const Build = struct {
    arena: Allocator,

    pub fn node(b: *Build, n: Node) *const Node {
        const p = b.arena.create(Node) catch oom();
        p.* = n;
        return p;
    }

    fn bindNode(b: *Build, prog: *const Node, ctx: Any, call: *const fn (Any, *Build, Any) *const Node) *const Node {
        return b.node(.{ .bind = .{ .prog = prog, .k = .{ .ctx = ctx, .call = call } } });
    }

    fn valueNode(b: *Build, v: Any) *const Node {
        return b.node(.{ .value = v });
    }

    /// the machine: a program of no effect left, run to its value
    fn eval(b: *Build, start: *const Node) Any {
        var cur = start;
        var stack: ?*const Frame = null;
        while (true) {
            switch (cur.*) {
                .bind => |n| {
                    stack = b.frame(.{ .next = stack, .kind = .{ .bind = n.k } });
                    cur = n.prog;
                },
                .handle => |n| {
                    stack = b.frame(.{ .next = stack, .kind = .{ .handle = .{ .place = n.place, .h = n.h } } });
                    cur = n.prog;
                },
                .value => |v| {
                    const f = stack orelse return v;
                    stack = f.next;
                    cur = switch (f.kind) {
                        .bind => |k| k.call(k.ctx, b, v),
                        .handle => |h| h.h.ret(h.h.ctx, b, v),
                    };
                },
                .perform => |p| {
                    // up the stack to the operation's handler, its place renumbered past each other handler
                    var place = p.place;
                    var f = stack;
                    const found: *const Frame = while (f) |fr| : (f = fr.next) {
                        switch (fr.kind) {
                            .handle => |h| {
                                if (h.place == place) break fr;
                                if (place > h.place) place -= 1;
                            },
                            .bind => {},
                        }
                    } else @panic("okay-zig: an operation no handler takes (the types should have said so)");
                    const h = found.kind.handle.h;
                    if (h.answer) |answer| {
                        cur = b.valueNode(answer(h.ctx, b, p.op)); // in place: the stack as it is
                    } else {
                        const k = b.arena.create(Captured) catch oom();
                        k.* = .{ .top = stack.?, .handler = found };
                        stack = found.next;
                        cur = h.op.?(h.ctx, b, p.op, k);
                    }
                },
                .resume_ => |r| {
                    stack = b.reinstate(r.k, stack);
                    cur = b.valueNode(r.value);
                },
            }
        }
    }

    fn frame(b: *Build, f: Frame) *const Frame {
        const p = b.arena.create(Frame) catch oom();
        p.* = f;
        return p;
    }

    /// `k`'s frames on `base`: copied, so the same `k` is reinstated again elsewhere
    fn reinstate(b: *Build, k: *const Captured, base: ?*const Frame) *const Frame {
        var segment: std.ArrayList(*const Frame) = .empty;
        var f: *const Frame = k.top;
        while (true) : (f = f.next.?) {
            segment.append(b.arena, f) catch oom();
            if (f == k.handler) break;
        }
        var below: ?*const Frame = base;
        var i = segment.items.len;
        while (i > 0) {
            i -= 1;
            below = b.frame(.{ .next = below, .kind = segment.items[i].kind });
        }
        return below.?;
    }

    // -------------------------------------------------------------------------------------------- the words

    /// `a`, a program of row `R` with no operation
    pub fn pure(b: *Build, comptime A: type, comptime R: anytype, a: A) Eff(A, R) {
        return .{ .node = b.valueNode(box(b.arena, A, a)) };
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
        return .{ .node = b.node(.{ .perform = .{ .place = place, .op = box(b.arena, E.Op, op) } }) };
    }

    /// `p`, then `f(ctx, b, its value)`: `ctx` is what `f` holds, `f` a function with no capture
    pub fn then(b: *Build, p: anytype, ctx: anytype, comptime f: anytype) ReturnOf(f) {
        const P = @TypeOf(p);
        const Ctx = @TypeOf(ctx);
        const Q = ReturnOf(f);
        comptime if (P.Effects != Q.Effects)
            @compileError("then: " ++ @typeName(P.Effects) ++ " and " ++ @typeName(Q.Effects) ++ " are not one row");
        const W = struct {
            fn call(c: Any, bb: *Build, v: Any) *const Node {
                return f(unbox(Ctx, c), bb, unbox(P.Value, v)).node;
            }
        };
        return .{ .node = b.bindNode(p.node, box(b.arena, Ctx, ctx), W.call) };
    }

    /// `p`'s value through `f(ctx, it)`
    pub fn map(b: *Build, p: anytype, ctx: anytype, comptime f: anytype) Eff(ReturnOfPlain(f), @TypeOf(p).Effects) {
        const P = @TypeOf(p);
        const Ctx = @TypeOf(ctx);
        const B = ReturnOfPlain(f);
        const W = struct {
            fn call(c: Any, bb: *Build, v: Any) *const Node {
                return bb.valueNode(box(bb.arena, B, f(unbox(Ctx, c), unbox(P.Value, v))));
            }
        };
        return .{ .node = b.bindNode(p.node, box(b.arena, Ctx, ctx), W.call) };
    }

    /// `p`, then `q`, its value dropped
    pub fn andThen(b: *Build, p: anytype, q: anytype) @TypeOf(q) {
        const Q = @TypeOf(q);
        const W = struct {
            fn call(c: Any, _: *Build, _: Any) *const Node {
                return unbox(*const Node, c);
            }
        };
        _ = Q;
        return .{ .node = b.bindNode(p.node, box(b.arena, *const Node, q.node), W.call) };
    }

    /// `p` with `E` handled by `h`: `h.ret(b, a)` its return, `h.op(b, op, k)` each operation with the rest of the
    /// program `k` (`k.answer(b, tag, value)` resumes it — once, twice, or never). The program's row without `E`.
    pub fn handle(b: *Build, comptime E: type, p: anytype, h: anytype) HandledBy(@TypeOf(h)) {
        const P = @TypeOf(p);
        const H = @TypeOf(h);
        const Out = HandledBy(H);
        const place = comptime P.Effects.place(E);
        comptime if (Out.Effects != P.Effects.without(place))
            @compileError("handle: the handler's row is " ++ @typeName(Out.Effects) ++ ", the program's without " ++
                @typeName(E) ++ " is " ++ @typeName(P.Effects.without(place)));
        const W = struct {
            fn ret(c: Any, bb: *Build, v: Any) *const Node {
                return unbox(H, c).ret(bb, unbox(P.Value, v)).node;
            }
            fn op(c: Any, bb: *Build, o: Any, k: *const Captured) *const Node {
                return unbox(H, c).op(bb, unbox(E.Op, o), Resume(E, Out){ .k = k }).node;
            }
        };
        const handling = b.arena.create(Handling) catch oom();
        handling.* = .{ .ctx = box(b.arena, H, h), .ret = W.ret, .op = W.op, .answer = null };
        return .{ .node = b.node(.{ .handle = .{ .prog = p.node, .place = place, .h = handling } }) };
    }

    /// `p` with `E` answered IN PLACE by `h`: a method of `h` an operation, by its name, its answer the operation's
    /// (`State`: `get(self) S`, `put(self, s) void`) — no `k` taken, the cheapest handler
    pub fn handleTail(b: *Build, comptime E: type, p: anytype, h: anytype) Handled(@TypeOf(p), E, @TypeOf(p).Value) {
        const P = @TypeOf(p);
        const H = @TypeOf(h);
        const place = comptime P.Effects.place(E);
        const W = struct {
            fn ret(_: Any, bb: *Build, v: Any) *const Node {
                return bb.valueNode(v);
            }
            fn answer(c: Any, bb: *Build, o: Any) Any {
                const self = unbox(H, c);
                switch (unbox(E.Op, o)) {
                    inline else => |payload, tag| {
                        const method = @field(H, @tagName(tag));
                        const a = if (@TypeOf(payload) == void) method(self) else method(self, payload);
                        return box(bb.arena, E.Answer(tag), a);
                    },
                }
            }
        };
        const handling = b.arena.create(Handling) catch oom();
        handling.* = .{ .ctx = box(b.arena, H, h), .ret = W.ret, .op = null, .answer = W.answer };
        return .{ .node = b.node(.{ .handle = .{ .prog = p.node, .place = place, .h = handling } }) };
    }

    /// a program of no effect, run: its value
    pub fn run(b: *Build, p: anytype) @TypeOf(p).Value {
        const P = @TypeOf(p);
        comptime if (P.Effects.len != 0) @compileError("run: effects left unhandled: " ++ @typeName(P.Effects));
        return unbox(P.Value, b.eval(p.node));
    }
};

/// A PROGRAM: its value `A`, its effects the row `R` (a `Row`, or a tuple of effects) — `A ! R`
pub fn Eff(comptime A: type, comptime R: anytype) type {
    return struct {
        node: *const Node,
        pub const Value = A;
        pub const Effects = rowOf(R);
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
            return .{ .node = b.node(.{ .resume_ = .{ .k = self.k, .value = box(b.arena, E.Answer(tag), value) } }) };
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
