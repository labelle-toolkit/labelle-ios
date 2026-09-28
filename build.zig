//! labelle-ios: the `ios` target provider for labelle-cli (RFC labelle-cli#471
//! I1), plus the (for now empty) `labelle_ios` module the assembler wires into
//! a project that pins it.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // The assembler hands every plugin `ios_sdk_path` on an iOS generate
    // (`build_files/build_zig.zig`); an undeclared option would fail the
    // dependency. Nothing here compiles C, so it is accepted and unused.
    _ = b.option([]const u8, "ios_sdk_path", "iOS SDK path (passed by the assembler; unused)");

    _ = b.addModule("labelle_ios", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run every labelle-ios test (module + provider tool)");
    const module_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(module_tests).step);

    // ── Provider host tool ────────────────────────────────────────────────
    // `bin/labelle-ios`, the one executable every hook in `plugin.labelle`
    // names. The CLI builds it with `zig build --system <cache>
    // install-provider`, which disables dependency fetching, so it stays
    // std-only. Always built for the host, whatever `-Dtarget` says. libc:
    // `waitpid`/`kill` for the simulator launch's supervision.
    const provider_module = b.createModule(.{
        .root_source_file = b.path("tools/main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    // `tools/main.zig`'s test checks its routing table against the manifest.
    provider_module.addAnonymousImport("plugin.labelle", .{ .root_source_file = b.path("plugin.labelle") });
    const provider = b.addExecutable(.{ .name = "labelle-ios", .root_module = provider_module });
    b.step("install-provider", "Install the labelle-cli provider tool (bin/labelle-ios)")
        .dependOn(&b.addInstallArtifact(provider, .{}).step);
    const provider_tests = b.addRunArtifact(b.addTest(.{ .root_module = provider_module }));
    b.step("test-provider", "Run the provider host-tool tests (wire contract, settings, plist, simctl, zip)")
        .dependOn(&provider_tests.step);
    test_step.dependOn(&provider_tests.step);
}
