const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ghostty_vt = ghosttyVtModule(b, target, optimize);

    // ---------------------------------------------------------------
    // Version, stamped in rather than written down.
    //
    // `illogical.version` was the literal "0.0.0-dev", which made `--version`
    // and the `server` field of every `welcome` frame the same string for
    // every build ever made. The Mac client compares the daemon it is talking
    // to against the daemon it shipped with, and a constant cannot answer
    // that question.
    //
    // The ghostty pin is part of the version rather than a footnote: it is
    // what actually decides whether two builds agree about a snapshot. Format
    // v1 carries no compatibility guarantee across pins (README, "The ghostty
    // pin"), so two builds differing only in pin must compare unequal.
    // ---------------------------------------------------------------
    const version = b.option(
        []const u8,
        "version",
        "Version string to stamp into the binaries (default: 0.0.0-dev)",
    ) orelse "0.0.0-dev";
    // A default rather than a `git` call from build.zig: `zig build` has to
    // work from a source tarball with no .git and no submodule, and the repo's
    // own answer belongs in the justfile where it can fail loudly.
    const ghostty_pin = b.option(
        []const u8,
        "ghostty-pin",
        "vendor/ghostty revision to stamp into the version (default: unknown)",
    ) orelse "unknown";
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    build_options.addOption([]const u8, "ghostty_pin", ghostty_pin);

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
    // On the core module alone. Both executables read the version through
    // `illogical.version`, so there is one copy of the string and one place
    // that decides its shape.
    core.addImport("build_options", build_options.createModule());

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
