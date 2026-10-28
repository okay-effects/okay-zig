//! The conformance worker on stdin/stdout: `zig build worker`, then `zig-out/bin/zig-worker`.

const std = @import("std");
const ok = @import("okay");
const programs = @import("programs.zig");

pub fn main(init: std.process.Init) !void {
    var w = ok.wire.Worker.init(std.heap.smp_allocator, &programs.programs).withDirect(init.io, &programs.direct)
        .withResumable(&programs.resumables);
    var in_buf: [1 << 20]u8 = undefined;
    var out_buf: [1 << 16]u8 = undefined;
    var in = std.Io.File.stdin().readerStreaming(init.io, &in_buf);
    var out = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    // the input ended with a call still waiting for another: the host is gone, the process ends with its tasks
    w.serve(&in.interface, &out.interface) catch |e| if (e == error.LeftWaiting) std.process.exit(0) else return e;
    w.deinit();
}
