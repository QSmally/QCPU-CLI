
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize });

    const qcpuv = b.addExecutable(.{
        .name = "qcpuv",
        .root_source_file = .{ .path = "Sources/qcpuv.zig" },
        .target = target,
        .optimize = optimize });
    qcpuv.addModule("clap", clap.module("clap"));
    b.installArtifact(qcpuv);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "Sources/test.zig" },
        .target = target,
        .optimize = optimize });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "use-case tests");
    test_step.dependOn(&run_unit_tests.step);
}
