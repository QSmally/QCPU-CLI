
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exec = b.addExecutable(.{
        .name = "qcpuv",
        .root_source_file = .{ .path = "Sources/qcpuv.zig" },
        .target = target,
        .optimize = optimize });
    b.installArtifact(exec);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "Sources/test.zig" },
        .target = target,
        .optimize = optimize });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "use-case tests");
    test_step.dependOn(&run_unit_tests.step);
}
