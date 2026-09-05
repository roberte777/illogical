const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ghostty_vt = ghosttyVtModule(b, target, optimize);

    // ---------------------------------------------------------------
    // illogical-core: everything both the daemon and the CLI need.
    // ---------------------------------------------------------------
    const core = b.addModule("illogical", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (ghostty_vt) |m| core.addImport("ghostty-vt", m);

    // ---------------------------------------------------------------
    // illogicald: the session server.
    // ---------------------------------------------------------------
    const daemon_mod = b.createModule(.{
        .root_source_file = b.path("src/daemon/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    daemon_mod.addImport("illogical", core);
    if (ghostty_vt) |m| daemon_mod.addImport("ghostty-vt", m);

    const daemon = b.addExecutable(.{
        .name = "illogicald",
        .root_module = daemon_mod,
    });
    b.installArtifact(daemon);

    // ---------------------------------------------------------------
    // illogical: the control CLI (list/new/attach/kill).
    // ---------------------------------------------------------------
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_mod.addImport("illogical", core);
    if (ghostty_vt) |m| cli_mod.addImport("ghostty-vt", m);

    const cli = b.addExecutable(.{
        .name = "illogical",
        .root_module = cli_mod,
    });
    b.installArtifact(cli);

    // ---------------------------------------------------------------
    // Steps
    // ---------------------------------------------------------------
    const run_step = b.step("run", "Run illogicald in the foreground");
    const run_cmd = b.addRunArtifact(daemon);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run all unit tests");
    for ([_]*std.Build.Module{ core, daemon_mod, cli_mod }) |mod| {
        const t = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}

/// Resolve the `ghostty-vt` module from the vendored ghostty checkout.
///
/// Returns null when the submodule has not been initialized yet, so that
/// `zig build --help` and friends still work on a fresh clone.
fn ghosttyVtModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ?*std.Build.Module {
    const dep = b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    }) orelse return null;
    return dep.module("ghostty-vt");
}
