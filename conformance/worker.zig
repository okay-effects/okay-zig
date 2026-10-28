//! The conformance worker on stdin/stdout: `zig build worker`, then `zig-out/bin/zig-worker`.

const std = @import("std");
const ok = @import("okay");
const programs = @import("programs.zig").programs;

pub fn main(init: std.process.Init) !void {
    var w = ok.wire.Worker.init(init.gpa, &programs);
    defer w.deinit();
    var in_buf: [1 << 20]u8 = undefined;
    var out_buf: [1 << 16]u8 = undefined;
    var in = std.Io.File.stdin().readerStreaming(init.io, &in_buf);
    var out = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    try w.serve(&in.interface, &out.interface);
}
