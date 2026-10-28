//! okay's in-process ABI (okay's polyglot-one-wire, stage 3): a library okay loads into its own process through FFM
//! (`ForeignWorker.inProcess(path)`) — one request in, one answer out, no second process:
//!
//!   uint8_t* okay_exchange(const uint8_t* req, size_t len, size_t* out_len);  // an empty request: the hello
//!   void     okay_free(uint8_t* resp, size_t len);
//!
//! The worker's state lives here between calls; calls are one at a time (a lock).

const std = @import("std");
const ok = @import("okay");
const programs = @import("programs.zig").programs;

const gpa = std.heap.c_allocator;
var worker: ?ok.wire.Worker = null;
var lock: std.atomic.Mutex = .unlocked;

export fn okay_exchange(req: [*]const u8, len: usize, out_len: *usize) [*]u8 {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    const w = if (worker) |*w| w else blk: {
        worker = ok.wire.Worker.init(gpa, &programs);
        break :blk &worker.?;
    };
    const out = if (len == 0)
        gpa.dupe(u8, ok.wire.Worker.hello) catch @panic("out of memory")
    else
        w.serve1(req[0..len]);
    out_len.* = out.len;
    return out.ptr;
}

export fn okay_free(resp: [*]u8, len: usize) void {
    gpa.free(resp[0..len]);
}
