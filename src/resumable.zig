//! RESUMABLE PROGRAMS: the rest of a program as a VALUE. A resumable program is an explicit state machine — a
//! `union(enum)` of its stops, each holding the variables alive there — that stops at each operation and gives back a
//! STEP: its value, or the operation and the rest `k`. Zig copies a union by value, so `k` is resumed as many times as
//! a handler wants: each resumption a copy, from the same point, the program's variables as they were. No machine, no
//! allocation, no replay: a step is a `switch` to the next stop.
//!
//! A resumable type `K` says its operations (`Op`), the answer it is resumed with (`Answer`), its value (`Out`), and
//! `step(self, answer) Step(K)`. Zig's comptime cannot rewrite a function's body, so the states are written by hand —
//! the shape `#[resumable]` writes in Rust and okgc in Goose. A handler is a plain function over the steps.

const std = @import("std");

/// A STEP of the resumable program `K`: its value, or an operation and the rest
pub fn Step(comptime K: type) type {
    return union(enum) {
        done: K.Out,
        perform: Performed,
        pub const Performed = struct { op: K.Op, k: K };
    };
}

/// `K` checked: a resumable program's declarations, said at compile time where one is missing
pub fn check(comptime K: type) void {
    inline for (.{ "Op", "Answer", "Out" }) |name| {
        if (!@hasDecl(K, name)) @compileError(@typeName(K) ++ " is not resumable: it declares no `" ++ name ++ "`");
    }
    if (!@hasDecl(K, "step")) @compileError(@typeName(K) ++ " is not resumable: it has no `step`");
    if (@TypeOf(K.step) != fn (K, K.Answer) Step(K))
        @compileError(@typeName(K) ++ ".step must be `fn (" ++ @typeName(K) ++ ", Answer) Step(" ++
            @typeName(K) ++ ")`");
}

/// a step that performs `op`, its rest `k`
pub fn perform(comptime K: type, op: K.Op, k: K) Step(K) {
    return .{ .perform = .{ .op = op, .k = k } };
}

/// a step that is the program's value
pub fn done(comptime K: type, a: K.Out) Step(K) {
    return .{ .done = a };
}

// ------------------------------------------------------------------------------------------------ handlers

/// a handler that answers IN PLACE, each operation once (`h.answer(op) K.Answer`): the program run to its value — a
/// loop, the rest resumed where it stands, never copied
pub fn run(comptime K: type, first: Step(K), h: anytype) K.Out {
    comptime check(K);
    var step = first;
    while (true) switch (step) {
        .done => |a| return a,
        .perform => |p| step = p.k.step(h.answer(p.op)),
    };
}

/// EVERY PATH: each operation answered with every answer `h.answers(op)` gives — the rest copied for each — and
/// `h.found(value)` told of each value the program reaches
pub fn everyPath(comptime K: type, step: Step(K), h: anytype) void {
    comptime check(K);
    switch (step) {
        .done => |a| h.found(a),
        .perform => |p| {
            var it = h.answers(p.op);
            // a value reached at once is told here: a call made only for a rest that stops again
            while (it.next()) |answer| switch (p.k.step(answer)) {
                .done => |a| h.found(a),
                .perform => |next| everyPath(K, .{ .perform = next }, h),
            };
        },
    }
}

/// the answers `0 ..< n`: what a choice among `n` is answered with, one after another
pub const Among = struct {
    i: usize = 0,
    n: usize,
    pub fn next(self: *Among) ?usize {
        if (self.i == self.n) return null;
        defer self.i += 1;
        return self.i;
    }
};
