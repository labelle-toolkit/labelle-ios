//! `bin/labelle-ios`: the labelle-cli provider executable for the `ios`
//! target (RFC labelle-cli#471 I1).
//!
//! One binary serves every hook `plugin.labelle` declares, like labelle-android's
//! `bin/labelle-android`. The CLI writes a contract context to the file named
//! by `LABELLE_CONTEXT`; this decodes it strictly (`contract.zig`), routes on
//! the invocation `(kind, id, step, phase)`, and refuses any combination the
//! manifest does not declare. Settings (`providers/ios.json`) are validated
//! before any side effect.
//!
//! Exit status: the app's for `launch` (0 when `--timeout` or a termination
//! signal stopped it), otherwise 0 on success and 1 on any failure, with a
//! `labelle-ios:` diagnostic on stderr. Reports go to stderr, so stdout stays
//! free for the CLI's JSON progress protocol.
const std = @import("std");
const contract = @import("contract.zig");
const settings_mod = @import("settings.zig");
const identity_mod = @import("project_identity.zig");
const app_mod = @import("app.zig");
const launch_mod = @import("launch.zig");
const bundle_mod = @import("bundle.zig");
const stdio = @import("stdio.zig");

/// What an invocation runs.
pub const Action = enum {
    /// `after build`: wrap the executable into `zig-out/ios/<AppName>.app`.
    app_hook,
    /// `replace run`: install that app on a simulator and run it.
    launch_hook,
    /// `replace bundle`: zip the simulator app.
    bundle_hook,
};

const Kind = @FieldType(contract.Invocation, "kind");

/// One declared entry point. Must match `plugin.labelle` exactly.
const Route = struct {
    kind: Kind,
    id: []const u8,
    step: ?contract.Step = null,
    phase: ?contract.Phase = null,
    action: Action,
};

const routes = [_]Route{
    .{ .kind = .hook, .id = "app", .step = .build, .phase = .after, .action = .app_hook },
    .{ .kind = .hook, .id = "launch", .step = .run, .phase = .replace, .action = .launch_hook },
    .{ .kind = .hook, .id = "bundle", .step = .bundle, .phase = .replace, .action = .bundle_hook },
};

/// The one target this provider's hooks serve.
pub const target = "ios";

pub const RouteError = error{ UnknownCommand, UnknownHook, InvalidInvocation, UnsupportedTarget };

/// Resolve a decoded context to its action, or refuse it.
pub fn route(ctx: contract.Context) RouteError!Action {
    const inv = ctx.invocation;
    for (routes) |r| {
        if (r.kind != inv.kind or !std.mem.eql(u8, r.id, inv.id)) continue;
        if (!sameStep(r.step, inv.step) or !samePhase(r.phase, inv.phase)) return error.InvalidInvocation;
        if (ctx.project_dir == null) return error.InvalidInvocation;
        if (!std.mem.eql(u8, ctx.target orelse "", target)) return error.UnsupportedTarget;
        return r.action;
    }
    return switch (inv.kind) {
        .command => error.UnknownCommand,
        .hook => error.UnknownHook,
    };
}

fn sameStep(a: ?contract.Step, b: ?contract.Step) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.? == b.?;
}

fn samePhase(a: ?contract.Phase, b: ?contract.Phase) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.? == b.?;
}

pub fn main(init: std.process.Init) u8 {
    var err_buf: [1024]u8 = undefined;
    // Streaming, never positional: stderr may be a file the CLI shares (cli#446).
    var stderr = stdio.stderrWriter(init.io, &err_buf);
    const out = &stderr.interface;
    const code = execute(init, out) catch |err| {
        out.print("labelle-ios: {s}\n", .{@errorName(err)}) catch {};
        out.flush() catch {};
        return 1;
    };
    out.flush() catch {};
    return code;
}

fn execute(init: std.process.Init, out: *std.Io.Writer) !u8 {
    const a = init.arena.allocator();
    const io = init.io;
    const context_path = init.environ_map.get(contract.context_env) orelse {
        try out.writeAll("labelle-ios: run me through labelle (LABELLE_CONTEXT is not set)\n");
        return error.MissingContext;
    };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, context_path, a, .limited(1024 * 1024));
    const parsed = try contract.parseContext(a, bytes, true);
    const ctx = parsed.value;
    const action = try route(ctx);
    {
        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
        defer it.deinit();
        _ = it.skip();
        if (it.next() != null) return error.UnexpectedHookArguments;
    }

    // Validate settings before any side effect.
    const settings_path = ctx.config_file orelse {
        try out.writeAll(
            \\labelle-ios: this project has no iOS settings. Add providers/ios.json
            \\  (at least {"schema_version": 1, "bundle_id": "com.studio.game"}) and declare it in project.labelle:
            \\  .provider_config = .{ .{ .package = "ios", .file = "providers/ios.json" } },
            \\
        );
        return error.MissingSettings;
    };
    const settings_bytes = try std.Io.Dir.cwd().readFileAlloc(io, settings_path, a, .limited(1024 * 1024));
    var diag: settings_mod.Diagnostic = .{};
    const settings = settings_mod.parse(a, settings_bytes, &diag) catch |err| {
        try out.print("labelle-ios: {s}: {s}\n", .{ settings_path, diag.message });
        return err;
    };
    const identity = try identity_mod.load(a, io, ctx.project_dir.?);
    try out.flush();

    // Every hook context carries its target dir (wire 1.2.0+; the manifest
    // admits 1.3.0+ only).
    const target_dir = ctx.target_dir orelse return error.MissingTargetDir;
    switch (action) {
        .app_hook => {
            const app = try app_mod.make(a, io, .{
                .project_dir = ctx.project_dir.?,
                .target_dir = target_dir,
                .settings = settings,
                .identity = identity,
                .env = init.environ_map,
            });
            std.debug.print("labelle-ios: app ready: {s}\n", .{app});
            return 0;
        },
        .launch_hook => return launch_mod.launchHook(a, io, .{
            .target_dir = target_dir,
            .settings = settings,
            .run = ctx.run orelse .{ .env = &.{}, .args = &.{}, .timeout_ms = null },
            .env = init.environ_map,
        }),
        .bundle_hook => {
            const archive = try bundle_mod.bundleHook(a, io, target_dir, ctx.output_dir, settings.bundle_id);
            std.debug.print("labelle-ios: bundle ready: {s}\n", .{archive});
            return 0;
        },
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────

fn contextFor(kind: Kind, id: []const u8, step: ?contract.Step, phase: ?contract.Phase, project: bool) contract.Context {
    const root = if (@import("builtin").os.tag == .windows) "C:/p" else "/p";
    return .{
        .contract_version = contract.version,
        .invocation = .{ .kind = kind, .id = id, .step = step, .phase = phase },
        .package_dir = root,
        .project_dir = if (project) root else null,
        .target = if (project) target else null,
        .lock_file = if (project) root else null,
        .config_file = null,
        .output_dir = root,
        .zig_executable = root,
        .optimize = .Debug,
        .progress = .human,
    };
}

/// What `route` must answer for one invocation, derived independently of
/// `route` from the declared table.
fn expected(kind: Kind, id: []const u8, step: ?contract.Step, phase: ?contract.Phase, project: bool) RouteError!Action {
    for (routes) |r| {
        if (r.kind != kind or !std.mem.eql(u8, r.id, id)) continue;
        if (!sameStep(r.step, step) or !samePhase(r.phase, phase)) return error.InvalidInvocation;
        if (!project) return error.InvalidInvocation;
        return r.action;
    }
    return if (kind == .hook) error.UnknownHook else error.UnknownCommand;
}

test "invocation matrix: only the declared (kind, id, step, phase) runs" {
    const ids = [_][]const u8{ "app", "launch", "bundle", "doctor", "run", "xcode", "bogus" };
    const steps = [_]?contract.Step{ null, .generate, .build, .bundle, .run };
    const phases = [_]?contract.Phase{ null, .before, .replace, .after };
    var accepted: usize = 0;
    for ([_]Kind{ .command, .hook }) |kind| {
        for (ids) |id| {
            for (steps) |step| {
                for (phases) |phase| {
                    for ([_]bool{ false, true }) |project| {
                        const want = expected(kind, id, step, phase, project);
                        const got = route(contextFor(kind, id, step, phase, project));
                        if (want) |action| {
                            try std.testing.expectEqual(action, try got);
                            accepted += 1;
                        } else |err| try std.testing.expectError(err, got);
                    }
                }
            }
        }
    }
    // The three hooks, each on its own (step, phase), in a project.
    try std.testing.expectEqual(@as(usize, 3), accepted);
    // Spot-check the table itself, so `expected` cannot drift with it.
    try std.testing.expectEqual(Action.app_hook, try route(contextFor(.hook, "app", .build, .after, true)));
    try std.testing.expectEqual(Action.launch_hook, try route(contextFor(.hook, "launch", .run, .replace, true)));
    try std.testing.expectEqual(Action.bundle_hook, try route(contextFor(.hook, "bundle", .bundle, .replace, true)));
    try std.testing.expectError(error.InvalidInvocation, route(contextFor(.hook, "app", .build, .before, true)));
    // No commands in v0.1: the `ios` namespace is still the CLI's.
    try std.testing.expectError(error.UnknownCommand, route(contextFor(.command, "doctor", null, null, true)));
}

test "a hook for another target is refused" {
    var ctx = contextFor(.hook, "app", .build, .after, true);
    ctx.target = "desktop";
    try std.testing.expectError(error.UnsupportedTarget, route(ctx));
}

test "routes mirror plugin.labelle" {
    const a = std.testing.allocator;
    const manifest = @embedFile("plugin.labelle");
    const tool = ".build_step = \"install-provider\", .executable = \"bin/labelle-ios\"";
    for (routes) |r| {
        const needle = try std.fmt.allocPrint(a, ".id = \"{s}\", .step = .{s}, .target = \"{s}\", .when = .{s}, {s}", .{
            r.id, @tagName(r.step.?), target, @tagName(r.phase.?), tool,
        });
        defer a.free(needle);
        try std.testing.expect(std.mem.indexOf(u8, manifest, needle) != null);
    }
    // Nothing declared that the table does not route, and no namespace or
    // commands (`ios` is reserved by the CLI until RFC #471 I5).
    const declared = manifest[std.mem.indexOf(u8, manifest, ".hooks = .{").?..];
    try std.testing.expectEqual(routes.len, std.mem.count(u8, declared, ".id = \""));
    try std.testing.expect(std.mem.indexOf(u8, manifest, "    .namespace") == null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "    .commands") == null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "    .target_defaults") == null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, ".name = \"ios\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, ".targets = .{\"ios\"},") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, ".command_contract = \">=1.3.0 <1.4.0\"") != null);
}

test "the vendored decoder is contract 1.3.0 and accepts its own fixtures" {
    try std.testing.expectEqualStrings("1.3.0", contract.version);
    const fixture = if (@import("builtin").os.tag == .windows)
        @embedFile("provider_contract/projectless-windows.json")
    else
        @embedFile("provider_contract/projectless.json");
    const parsed = try contract.parseContext(std.testing.allocator, fixture, false);
    defer parsed.deinit();
    // A projectless command: no hook of this provider accepts it.
    try std.testing.expectError(error.UnknownCommand, route(parsed.value));
}

test {
    _ = contract;
    _ = settings_mod;
    _ = identity_mod;
    _ = app_mod;
    _ = launch_mod;
    _ = bundle_mod;
    _ = stdio;
    _ = @import("plist.zig");
    _ = @import("simctl.zig");
    _ = @import("zip.zig");
    _ = @import("proc.zig");
}
