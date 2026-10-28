const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const okay = b.addModule("okay", .{
        .root_source_file = b.path("src/okay.zig"),
        .target = target,
        .optimize = optimize,
    });

    // okay's conformance programs, served on okay's wire
    const conformance = b.createModule(.{
        .root_source_file = b.path("conformance/programs.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "okay", .module = okay }},
    });
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "okay", .module = okay },
        .{ .name = "conformance", .module = conformance },
    };

    const test_step = b.step("test", "Run the tests");
    inline for (.{ "test/std_test.zig", "test/cx_test.zig", "test/wire_test.zig" }) |file| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(file),
            .target = target,
            .optimize = optimize,
            .imports = imports,
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

    // the conformance worker: on stdin/stdout, and as a library of okay's C ABI (FFM)
    const worker = b.addExecutable(.{ .name = "zig-worker", .root_module = b.createModule(.{
        .root_source_file = b.path("conformance/worker.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) });
    const library = b.addLibrary(.{ .name = "okay-zig-worker", .linkage = .dynamic, .root_module = b.createModule(.{
        .root_source_file = b.path("conformance/ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    }) });
    const workers = b.step("worker", "Build the conformance worker: zig-out/bin/zig-worker, zig-out/lib's library");
    workers.dependOn(&b.addInstallArtifact(worker, .{}).step);
    workers.dependOn(&b.addInstallArtifact(library, .{}).step);
}
