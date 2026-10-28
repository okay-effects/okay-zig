const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const okay = b.addModule("okay", .{
        .root_source_file = b.path("src/okay.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run the tests");
    inline for (.{"test/std_test.zig"}) |file| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(file),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "okay", .module = okay }},
        }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    const bench = b.addExecutable(.{ .name = "ticks", .root_module = b.createModule(.{
        .root_source_file = b.path("bench/ticks.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "okay", .module = okay }},
    }) });
    const run_bench = b.addRunArtifact(bench);
    b.step("bench", "Run the benchmark (with -Doptimize=ReleaseFast)").dependOn(&run_bench.step);
}
