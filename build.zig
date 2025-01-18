
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // const clap = b.dependency("clap", .{
    //     .target = target,
    //     .optimize = optimize });

    // const qcpuv = b.addExecutable(.{
    //     .name = "qcpuv",
    //     .root_source_file = .{ .path = "Sources/qcpuv.zig" },
    //     .target = target,
    //     .optimize = optimize });
    // qcpuv.addModule("clap", clap.module("clap"));
    // b.installArtifact(qcpuv);

    const test_options = b.addOptions();
    const option_dump = b.option(bool, "dump", "dump debug information");
    test_options.addOption(bool, "dump", option_dump orelse false);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .cwd_relative = "Sources/test.zig" },
        .target = target,
        .optimize = optimize });
    unit_tests.root_module.addOptions("options", test_options);
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "use-case tests");
    test_step.dependOn(&run_unit_tests.step);
}
