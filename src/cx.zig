//! THE CONTEXTS LAYER (specs/design.md): a program a plain Zig function; its effects the handlers of a CONTEXT it is
//! given, as Zig gives `Allocator` and `Io`. An operation is a call (`cx.op(E, .tag, payload)`), its answer typed by
//! the effect's `Answer`; a handler is the same struct the machine's `handleTail` takes — a method an operation — and
//! says its effect (`pub const Effect = E`). An effect the context lacks is a compile error naming both. OBSERVERS see
//! each operation of their effect before it is answered — the audit, at the one place every operation goes through.
//! GUARDS decide: each operation of their effect allowed, or refused by an ERROR of the guard's own (`decide(op)
//! !void`) — so with a guard, the effect's operations answer an error union (`try cx.op(…)`), its errors the guards';
//! an effect with no guard answers plainly: the types say which operations may be refused. No continuation here: what
//! needs `k` (abort, choice, resuming twice) is the machine's.

const std = @import("std");

/// A CONTEXT: its handlers, its observers, its guards (each a tuple)
pub fn Context(comptime Handlers: type, comptime Observers: type, comptime Guards: type) type {
    return struct {
        handlers: Handlers,
        observers: Observers,
        guards: Guards,
        const Self = @This();

        fn indexOf(comptime E: type) usize {
            inline for (@typeInfo(Handlers).@"struct".field_types, 0..) |T, i| {
                if (T.Effect == E) return i;
            }
            @compileError("the effect " ++ @typeName(E) ++ " is not in the context " ++ effectNames());
        }
        fn effectNames() []const u8 {
            comptime var names: []const u8 = "{";
            inline for (@typeInfo(Handlers).@"struct".field_types, 0..) |T, i| {
                names = names ++ (if (i == 0) " " else ", ") ++ @typeName(T.Effect);
            }
            return names ++ " }";
        }

        /// whether `E` is answered here
        pub fn has(comptime E: type) bool {
            inline for (@typeInfo(Handlers).@"struct".field_types) |T| if (T.Effect == E) return true;
            return false;
        }

        /// whether `E` has a guard here: its operations may be refused
        pub fn guarded(comptime E: type) bool {
            inline for (@typeInfo(Guards).@"struct".field_types) |T| if (T.Effect == E) return true;
            return false;
        }

        /// the errors `E`'s operations may be refused with: its guards' own
        pub fn Refusal(comptime E: type) type {
            comptime var errors = error{};
            inline for (@typeInfo(Guards).@"struct".field_types) |T| {
                if (T.Effect == E) errors = errors || @typeInfo(@typeInfo(@TypeOf(T.decide)).@"fn".return_type.?)
                    .error_union.error_set;
            }
            return errors;
        }

        /// what an operation answers here: its answer, or — its effect guarded — its answer or a refusal
        pub fn Answered(comptime E: type, comptime tag: std.meta.Tag(E.Op)) type {
            return if (guarded(E)) Refusal(E)!E.Answer(tag) else E.Answer(tag);
        }

        /// an operation of `E`: each observer of `E` told, each guard of `E` asked — the first to refuse refuses it,
        /// unanswered — then its handler's method answers
        pub fn op(
            self: Self,
            comptime E: type,
            comptime tag: std.meta.Tag(E.Op),
            payload: @FieldType(E.Op, @tagName(tag)),
        ) Answered(E, tag) {
            const h = self.handlers[comptime indexOf(E)];
            const o = @unionInit(E.Op, @tagName(tag), payload);
            inline for (@typeInfo(Observers).@"struct".field_types, 0..) |T, i| {
                if (comptime T.Effect == E) self.observers[i].seen(o);
            }
            inline for (@typeInfo(Guards).@"struct".field_types, 0..) |T, i| {
                if (comptime T.Effect == E) try self.guards[i].decide(o);
            }
            const method = @field(@TypeOf(h), @tagName(tag));
            return if (@TypeOf(payload) == void) method(h) else method(h, payload);
        }

        /// the handler of `E` itself: calls on it are not observed
        pub fn of(self: Self, comptime E: type) @typeInfo(Handlers).@"struct".field_types[indexOf(E)] {
            return self.handlers[comptime indexOf(E)];
        }

        /// the same context, `o` observing its effect (`o.seen(op)` before each operation of it is decided)
        pub fn observe(self: Self, o: anytype) Context(Handlers, @TypeOf(self.observers ++ .{o}), Guards) {
            comptime if (!has(@TypeOf(o).Effect))
                @compileError("an observer of " ++ @typeName(@TypeOf(o).Effect) ++ ", not in the context " ++
                    effectNames());
            return .{ .handlers = self.handlers, .observers = self.observers ++ .{o}, .guards = self.guards };
        }

        /// the same context, `g` guarding its effect: `g.decide(op)` before each operation of it is answered — an
        /// error of `g`'s refuses it
        pub fn guard(self: Self, g: anytype) Context(Handlers, Observers, @TypeOf(self.guards ++ .{g})) {
            comptime if (!has(@TypeOf(g).Effect))
                @compileError("a guard of " ++ @typeName(@TypeOf(g).Effect) ++ ", not in the context " ++
                    effectNames());
            return .{ .handlers = self.handlers, .observers = self.observers, .guards = self.guards ++ .{g} };
        }
    };
}

/// a context of these handlers: `context(.{ cell, given })`
pub fn context(handlers: anytype) Context(@TypeOf(handlers), @TypeOf(.{}), @TypeOf(.{})) {
    return .{ .handlers = handlers, .observers = .{}, .guards = .{} };
}

/// a function's requirement, said where it starts: each effect of `effects` in the context `Cx`, or a compile error
pub fn needs(comptime Cx: type, comptime effects: anytype) void {
    inline for (effects) |E| {
        if (comptime !Cx.has(E)) @compileError("needs " ++ @typeName(E) ++ "; the context has " ++ Cx.effectNames());
    }
}
