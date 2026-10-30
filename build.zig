
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("Sources/qcpu.zig"),
        .target = target,
        .optimize = optimize });

    const exec = b.addExecutable(.{
        .name = "qcpu",
        .root_module = root_module });
    b.installArtifact(exec);

    const test_module = b.createModule(.{
        .root_source_file = b.path("Sources/tests.zig"),
        .target = target,
        .optimize = optimize });

    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "application tests");
    test_step.dependOn(&run_tests.step);

    const docs = b.addInstallDirectory(.{
        .source_dir = tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs" });
    const docs_step = b.step("docs", "generate docs");
    docs_step.dependOn(&docs.step);
}
