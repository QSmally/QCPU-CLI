
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const qcpu = b.addExecutable(.{
        .name = "qcpu",
        .root_source_file = b.path("Sources/qcpu.zig"),
        .target = target,
        .optimize = optimize });
    b.installArtifact(qcpu);

    const test_options = b.addOptions();
    const option_dump = b.option(bool, "dump", "dump debug information");
    test_options.addOption(bool, "dump", option_dump orelse false);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("Sources/tests.zig"),
            .target = target,
            .optimize = optimize })
    });
    tests.root_module.addOptions("options", test_options);
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "use-case tests");
    test_step.dependOn(&run_tests.step);

    const docs = b.addInstallDirectory(.{
        .source_dir = tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs" });
    const docs_step = b.step("docs", "generate docs");
    docs_step.dependOn(&docs.step);
}
