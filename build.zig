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
    // Release tarballs only. An unstripped static musl `illogicald` is 15 MB
    // of which most is debug_info; `strip` is asked for through zig rather
    // than run afterwards because a release is cross-compiled from a Mac and
    // the host's `strip` cannot touch an ELF.
    const strip = b.option(bool, "strip", "Leave out debug information (default: no)");

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
        .strip = strip,
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
        .strip = strip,
    });
    daemon_mod.addImport("illogical", core);
    if (ghostty_vt) |m| daemon_mod.addImport("ghostty-vt", m);

    const daemon = b.addExecutable(.{
        .name = "illogicald",
        .root_module = daemon_mod,
    });
    appleSdkPaths(b, daemon);
    b.installArtifact(daemon);

    // ---------------------------------------------------------------
    // illogical: the control CLI (list/new/attach/kill).
    // ---------------------------------------------------------------
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    cli_mod.addImport("illogical", core);
    if (ghostty_vt) |m| cli_mod.addImport("ghostty-vt", m);

    const cli = b.addExecutable(.{
        .name = "illogical",
        .root_module = cli_mod,
    });
    appleSdkPaths(b, cli);
    b.installArtifact(cli);

    // ---------------------------------------------------------------
    // The terminfo database that makes `TERM=xterm-ghostty` a name a child
    // can look up. See `src/core/pty.zig`.
    // ---------------------------------------------------------------
    terminfoDatabase(b, target, optimize);

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

/// Point a Darwin build at the real macOS SDK, for any Apple target.
///
/// Only `-Dtarget=<other arch>-macos` needs this, and it is the difference
/// between a universal daemon and none. Zig resolves the SDK headers through
/// `xcrun` for the *native* target only; for another Darwin arch it falls back
/// to its bundled Darwin libc headers, which have no `util.h` -- so
/// `src/core/pty.zig`'s `@cImport` of `openpty` fails and `illogicald` does not
/// compile. (`illogical` does, because its path never reaches `openpty`; it is
/// given the same treatment anyway so the two cannot drift.)
///
/// `--sysroot "$SDKROOT"` looks like the answer and is not: inside the devshell
/// zig double-appends the nix SDK path -- ".../MacOSX.sdk/nix/store/.../usr/lib"
/// -- and highway and simdutf then fail to link. This is ghostty's own helper,
/// out of the same submodule, and is what builds its universal XCFramework: it
/// runs `LibCInstallation.findNative` through `xcrun` and hands the compile
/// step a `--libc` file plus the SDK's include, framework and library
/// directories.
///
/// A no-op for every non-Darwin target, so the Linux release path never sees
/// it.
fn appleSdkPaths(b: *std.Build, exe: *std.Build.Step.Compile) void {
    if (!exe.rootModuleTarget().os.tag.isDarwin()) return;
    @import("apple_sdk").addPaths(b, exe) catch |err| {
        std.debug.panic("could not resolve the macOS SDK: {t}", .{err});
    };
}

/// Compile ghostty's terminfo entry and install it as `share/terminfo`.
///
/// The daemon tells every child `TERM=xterm-ghostty` and points its `TERMINFO`
/// here, which is the only way that name means anything: the entry is not part
/// of ncurses, so a machine that has never had ghostty on it cannot look it up,
/// and a child with no terminfo at all cannot so much as move its own cursor.
/// This is ghostty's own build step (`src/build/GhosttyResources.zig`) over
/// ghostty's own source, so what we ship describes the pin we build against.
///
/// `cp -R` rather than an install-directory step because `tic` writes the
/// entry's aliases as links, which Zig's own step does not preserve. A no-op
/// when the submodule is not checked out, like everything else here.
fn terminfoDatabase(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const dep = b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    }) orelse return;

    // Built for the host: it runs here, at build time, whatever we are
    // cross-compiling the daemon for.
    const generator = b.addExecutable(.{
        .name = "terminfo-gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/terminfo.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    generator.root_module.addAnonymousImport("ghostty-terminfo", .{
        .root_source_file = dep.path("src/terminfo/ghostty.zig"),
    });

    const emit = b.addRunArtifact(generator);
    const source = emit.captureStdOut(.{});

    const tic = std.Build.Step.Run.create(b, "tic");
    tic.addArgs(&.{ "tic", "-x", "-o" });
    const database = tic.addOutputDirectoryArg("terminfo");
    tic.addFileArg(source);
    // tic reports what it compiled on stderr, which is not news.
    _ = tic.captureStdErr(.{});

    // So that the copy below lands *in* `share/terminfo` rather than creating
    // a file by that name.
    const mkdir = std.Build.Step.Run.create(b, "make share/terminfo");
    mkdir.addArgs(&.{ "mkdir", "-p", b.fmt("{s}/share/terminfo", .{b.install_path}) });

    const copy = std.Build.Step.Run.create(b, "install terminfo");
    copy.addArgs(&.{ "cp", "-R" });
    copy.addFileArg(database);
    copy.addArg(b.fmt("{s}/share/", .{b.install_path}));
    copy.step.dependOn(&mkdir.step);

    b.getInstallStep().dependOn(&copy.step);
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
