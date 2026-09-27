const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const executable = b.addExecutable(.{
        .name = "long-horizon-agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(executable);
    const run_command = b.addRunArtifact(executable);
    if (b.args) |args| run_command.addArgs(args);
    const run_step = b.step("run", "Run the agent");
    run_step.dependOn(&run_command.step);
    const test_step = b.step("test", "Run all tests");
    const test_files = [_][]const u8{
        "tests/state_tests.zig",
        "tests/context_tests.zig",
        "tests/dag_tests.zig",
        "tests/security_tests.zig",
        "tests/document_tests.zig",
        "tests/eval_tests.zig",
    };
    for (test_files) |path| {
        const test_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        test_module.addImport("long_horizon_agent", b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }));
        const tests = b.addTest(.{ .root_module = test_module });
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }
}
