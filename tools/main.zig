//! `bin/labelle-ios`: the labelle-cli provider executable for the `ios`
//! target and the `ios` command namespace (RFC labelle-cli#471 I1, I6).
//!
//! One binary serves every command and hook `plugin.labelle` declares, like
//! labelle-android's `bin/labelle-android`. The CLI writes a contract context
//! to the file named by `LABELLE_CONTEXT`; this decodes it strictly
//! (`contract.zig`), routes on the invocation `(kind, id, step, phase)`, and
//! refuses any combination the manifest does not declare. Settings
//! (`providers/ios.json`) are validated before any side effect.
//!
//! Exit status: the app's for `launch` and `labelle ios run` (0 when
//! `--timeout` or a termination signal stopped it), otherwise 0 on success
//! and 1 on any failure (doctor: a required item missing), with a
//! `labelle-ios:` diagnostic on stderr. Reports go to stderr, so stdout stays
//! free for the CLI's JSON progress protocol; the exceptions are `doctor
//! --json`, whose capability object is the command's stdout (the CLI captures
//! it for `labelle doctor --json`), and `devices`, whose listing is.
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("contract.zig");
const settings_mod = @import("settings.zig");
const identity_mod = @import("project_identity.zig");
const app_mod = @import("app.zig");
const launch_mod = @import("launch.zig");
const bundle_mod = @import("bundle.zig");
const build_options = @import("build_options.zig");
const doctor = @import("doctor.zig");
const devices_mod = @import("devices.zig");
const xcode = @import("xcode.zig");
const simctl = @import("simctl.zig");
const signing = @import("signing.zig");
const stdio = @import("stdio.zig");

/// What an invocation runs.
pub const Action = enum {
    /// `labelle ios doctor [--json] [--fix]`.
    doctor,
    /// `labelle ios devices`: simulators and connected devices.
    devices,
    /// `labelle ios xcode`: an Xcode project around the built app.
    xcode_command,
    /// `labelle ios run`: install and run the built app.
    run_command,
    /// `before build`: `-Ddevice=true` for a device build (build_options).
    device_hook,
    /// `after build`: wrap the executable into `zig-out/ios/<AppName>.app`.
    app_hook,
    /// `replace run`: install that app on a simulator or device and run it.
    launch_hook,
    /// `replace bundle`: the simulator zip or the device `.ipa`.
    bundle_hook,
};

const Kind = @FieldType(contract.Invocation, "kind");

/// One declared entry point. Must match `plugin.labelle` exactly: a command
/// has no step/phase; a hook has both.
const Route = struct {
    kind: Kind,
    id: []const u8,
    step: ?contract.Step = null,
    phase: ?contract.Phase = null,
    action: Action,
    needs_project: bool,
};

const routes = [_]Route{
    .{ .kind = .command, .id = "doctor", .action = .doctor, .needs_project = false },
    .{ .kind = .command, .id = "devices", .action = .devices, .needs_project = false },
    .{ .kind = .command, .id = "xcode", .action = .xcode_command, .needs_project = true },
    .{ .kind = .command, .id = "run", .action = .run_command, .needs_project = true },
    .{ .kind = .hook, .id = "device", .step = .build, .phase = .before, .action = .device_hook, .needs_project = true },
    .{ .kind = .hook, .id = "app", .step = .build, .phase = .after, .action = .app_hook, .needs_project = true },
    .{ .kind = .hook, .id = "launch", .step = .run, .phase = .replace, .action = .launch_hook, .needs_project = true },
    .{ .kind = .hook, .id = "bundle", .step = .bundle, .phase = .replace, .action = .bundle_hook, .needs_project = true },
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
        if (r.needs_project and ctx.project_dir == null) return error.InvalidInvocation;
        if (r.kind == .hook and !std.mem.eql(u8, ctx.target orelse "", target)) return error.UnsupportedTarget;
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

pub const DoctorArgs = struct { json: bool = false, fix: bool = false };

/// Every provider doctor accepts `--json` and `--fix` (contract §1).
pub fn parseDoctorArgs(args: []const []const u8) !DoctorArgs {
    var o: DoctorArgs = .{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            o.json = true;
        } else if (std.mem.eql(u8, arg, "--fix")) {
            o.fix = true;
        } else {
            std.debug.print("labelle-ios: unknown argument '{s}' (usage: labelle ios doctor [--json] [--fix])\n", .{arg});
            return error.UnknownArgument;
        }
    }
    return o;
}

const missing_settings =
    \\labelle-ios: this project has no iOS settings. Add providers/ios.json
    \\  (at least {"schema_version": 1, "bundle_id": "com.studio.game"}) and declare it in project.labelle:
    \\  .provider_config = .{ .{ .package = "ios", .file = "providers/ios.json" } },
    \\
;

fn execute(init: std.process.Init, out: *std.Io.Writer) !u8 {
    const a = init.arena.allocator();
    const io = init.io;
    const context_path = init.environ_map.get(contract.context_env) orelse {
        try out.writeAll("labelle-ios: run me through labelle (LABELLE_CONTEXT is not set)\n");
        return error.MissingContext;
    };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, context_path, a, .limited(1024 * 1024));
    // Every route's own `needs_project` is enforced by `route`.
    const parsed = try contract.parseContext(a, bytes, false);
    const ctx = parsed.value;
    const action = try route(ctx);

    var args: std.ArrayList([]const u8) = .empty;
    {
        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
        defer it.deinit();
        _ = it.skip();
        while (it.next()) |arg| {
            if (ctx.invocation.kind == .hook) return error.UnexpectedHookArguments;
            try args.append(a, try a.dupe(u8, arg));
        }
    }
    const doctor_args: DoctorArgs = if (action == .doctor) try parseDoctorArgs(args.items) else .{};
    if (action == .devices and args.items.len > 0) {
        try out.print("labelle-ios: unknown argument '{s}' (usage: labelle ios devices)\n", .{args.items[0]});
        return error.UnknownArgument;
    }

    // Validate settings before any side effect.
    var settings: ?settings_mod.Settings = null;
    var settings_bytes: []const u8 = "";
    if (ctx.config_file) |path| {
        settings_bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
        var diag: settings_mod.Diagnostic = .{};
        settings = settings_mod.parse(a, settings_bytes, &diag) catch |err| {
            try out.print("labelle-ios: {s}: {s}\n", .{ path, diag.message });
            return err;
        };
    }
    try out.flush();

    switch (action) {
        .doctor => return runDoctor(a, io, init.environ_map, ctx, settings, doctor_args, out),
        .devices => {
            var buf: [4096]u8 = undefined;
            var stdout = stdio.stdoutWriter(io, &buf);
            try devices_mod.devicesCommand(a, io, init.environ_map, &stdout.interface);
            return 0;
        },
        else => {},
    }

    // Everything else builds, packages or runs, so it needs the settings.
    const s = settings orelse {
        try out.writeAll(missing_settings);
        return error.MissingSettings;
    };
    const project_dir = ctx.project_dir.?;
    if (action == .device_hook) {
        _ = try build_options.hook(io, s, ctx);
        return 0;
    }
    const identity = try identity_mod.load(a, io, project_dir);
    const target_dir = switch (action) {
        // A command's context carries no target dir: act on the one iOS
        // build this project has.
        .xcode_command, .run_command => try app_mod.singleBuiltTarget(try app_mod.builtTargets(a, io, project_dir)),
        // Every hook context carries it (wire 1.2.0+; the manifest admits
        // 1.3.0+ only).
        else => ctx.target_dir orelse return error.MissingTargetDir,
    };
    const app_inputs: app_mod.Inputs = .{
        .project_dir = project_dir,
        .target_dir = target_dir,
        .settings = s,
        .settings_bytes = settings_bytes,
        .identity = identity,
        // Only a `bundle` hook's context carries it (contract 1.1.0+).
        .build_number = ctx.build_number,
        .env = init.environ_map,
    };
    switch (action) {
        .doctor, .devices, .device_hook => unreachable,
        .app_hook => {
            const app = try app_mod.make(a, io, app_inputs);
            std.debug.print("labelle-ios: app ready: {s}\n", .{app.path});
            return 0;
        },
        .launch_hook => return launch_mod.launchHook(a, io, .{
            .app = app_inputs,
            .run = ctx.run orelse .{ .env = &.{}, .args = &.{}, .timeout_ms = null },
        }),
        .bundle_hook => {
            const archive = try bundle_mod.bundleHook(a, io, app_inputs, ctx.output_dir);
            std.debug.print("labelle-ios: bundle ready: {s}\n", .{archive});
            return 0;
        },
        .run_command => {
            const run_args = simctl.parseRunArgs(a, args.items) catch {
                std.debug.print("labelle-ios: --device needs a simulator or device UDID or name\nusage: labelle ios run [--device=<udid|name>] [app arguments...]\n", .{});
                return error.InvalidRunArguments;
            };
            const result = try launch_mod.launchApp(a, io, .{ .app = app_inputs, .device = run_args.device, .app_args = run_args.app_args });
            return result.status;
        },
        .xcode_command => {
            const xargs = try xcode.parseArgs(args.items);
            const built = try app_mod.built(a, io, app_inputs);
            var project: xcode.Project = .{
                .name = built.record.app[0 .. built.record.app.len - ".app".len],
                .bundle_id = s.bundle_id,
                .minimum_ios = s.minimum_ios,
                .device_family = s.device_family,
                .team_id = s.team_id,
                .executable = built.record.executable,
                .destination = built.record.destination,
                .version = built.record.version,
            };
            project.resources = try xcode.resourcesOf(a, io, built.path, project);
            const out_dir = if (xargs.output) |o|
                (if (std.fs.path.isAbsolute(o)) o else try std.fs.path.join(a, &.{ project_dir, o }))
            else
                try std.fs.path.join(a, &.{ project_dir, "ios-xcode" });
            const proj = try xcode.write(a, io, .{ .app = built.path, .out_dir = out_dir, .project = project });
            std.debug.print("labelle-ios: Xcode project ready: {s}\n", .{proj});
            if (built.record.destination == .simulator)
                std.debug.print("  note: it wraps a simulator build, so it runs on simulators only; set \"destination\": \"device\" and rebuild for devices\n", .{});
            std.debug.print("  next: open it, pick your team under Signing & Capabilities{s}, then Run\n", .{if (s.team_id != null) " (team_id is preset)" else ""});
            return 0;
        },
    }
}

fn runDoctor(
    a: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    ctx: contract.Context,
    settings: ?settings_mod.Settings,
    args: DoctorArgs,
    out: *std.Io.Writer,
) !u8 {
    var opts: doctor.Options = .{ .host_macos = builtin.os.tag == .macos };
    if (settings) |s| {
        opts.minimum_ios = s.minimum_ios;
        opts.destination = s.destination;
        opts.identity = s.signing.identity;
        if (s.signing.profile) |rel| if (ctx.project_dir) |project| {
            const path = try signing.profilePath(a, project, rel);
            opts.profile = path;
            opts.profile_exists = if (std.Io.Dir.cwd().access(io, path, .{})) |_| true else |_| false;
        };
    }
    if (ctx.project_dir) |project| {
        opts.in_project = true;
        const source = std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ project, "project.labelle" }), a, .limited(4 * 1024 * 1024)) catch "";
        opts.backend = identity_mod.backend(source);
    }
    var sys: doctor.SystemExec = .{ .io = io, .env = env };
    const checks = try doctor.detect(a, sys.exec(), opts);
    if (args.json) {
        var buf: [4096]u8 = undefined;
        var stdout = stdio.stdoutWriter(io, &buf);
        try doctor.writeJson(a, checks, &stdout.interface);
        // `--fix` with `--json`: the commands go to stderr, the object stays clean.
        if (args.fix) try doctor.writeFixes(checks, out);
    } else {
        if (settings) |s| {
            try out.print("\n  bundle id: {s}  destination: {s}  minimum iOS: {s}\n", .{ s.bundle_id, @tagName(s.destination), s.minimum_ios });
        } else if (ctx.project_dir != null) {
            try out.writeAll("\n  note: no providers/ios.json for this project (`.provider_config`); using defaults\n");
        }
        try doctor.writeReport(checks, args.fix, out);
    }
    try out.flush();
    return if (doctor.summarize(checks).failures == 0) 0 else 1;
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
        if (r.needs_project and !project) return error.InvalidInvocation;
        return r.action;
    }
    return if (kind == .hook) error.UnknownHook else error.UnknownCommand;
}

test "invocation matrix: only the declared (kind, id, step, phase) runs" {
    const ids = [_][]const u8{ "app", "launch", "bundle", "device", "doctor", "devices", "run", "xcode", "bogus" };
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
    // Four hooks and two project commands in a project; doctor and devices
    // in and out of one.
    try std.testing.expectEqual(@as(usize, 4 + 2 + 2 * 2), accepted);
    // Spot-check the table itself, so `expected` cannot drift with it.
    try std.testing.expectEqual(Action.device_hook, try route(contextFor(.hook, "device", .build, .before, true)));
    try std.testing.expectEqual(Action.app_hook, try route(contextFor(.hook, "app", .build, .after, true)));
    try std.testing.expectEqual(Action.launch_hook, try route(contextFor(.hook, "launch", .run, .replace, true)));
    try std.testing.expectEqual(Action.bundle_hook, try route(contextFor(.hook, "bundle", .bundle, .replace, true)));
    try std.testing.expectEqual(Action.doctor, try route(contextFor(.command, "doctor", null, null, false)));
    try std.testing.expectEqual(Action.devices, try route(contextFor(.command, "devices", null, null, false)));
    try std.testing.expectEqual(Action.run_command, try route(contextFor(.command, "run", null, null, true)));
    try std.testing.expectEqual(Action.xcode_command, try route(contextFor(.command, "xcode", null, null, true)));
    try std.testing.expectError(error.InvalidInvocation, route(contextFor(.command, "xcode", null, null, false)));
    try std.testing.expectError(error.InvalidInvocation, route(contextFor(.hook, "app", .build, .before, true)));
}

test "a hook for another target is refused; a command runs whatever the target" {
    var ctx = contextFor(.hook, "app", .build, .after, true);
    ctx.target = "desktop";
    try std.testing.expectError(error.UnsupportedTarget, route(ctx));
    var cmd = contextFor(.command, "run", null, null, true);
    cmd.target = "desktop";
    try std.testing.expectEqual(Action.run_command, try route(cmd));
}

test "doctor accepts --json and --fix, nothing else" {
    try std.testing.expectEqual(DoctorArgs{}, try parseDoctorArgs(&.{}));
    try std.testing.expectEqual(DoctorArgs{ .json = true, .fix = true }, try parseDoctorArgs(&.{ "--json", "--fix" }));
    try std.testing.expectEqual(DoctorArgs{ .fix = true }, try parseDoctorArgs(&.{"--fix"}));
    try std.testing.expectError(error.UnknownArgument, parseDoctorArgs(&.{"--verbose"}));
}

test "routes mirror plugin.labelle" {
    const a = std.testing.allocator;
    const manifest = @embedFile("plugin.labelle");
    const tool = ".build_step = \"install-provider\", .executable = \"bin/labelle-ios\"";
    for (routes) |r| {
        const needle = switch (r.kind) {
            .hook => try std.fmt.allocPrint(a, ".id = \"{s}\", .step = .{s}, .target = \"{s}\", .when = .{s}, {s}", .{
                r.id, @tagName(r.step.?), target, @tagName(r.phase.?), tool,
            }),
            .command => try std.fmt.allocPrint(a, ".name = \"{s}\", {s}", .{ r.id, tool }),
        };
        defer a.free(needle);
        if (std.mem.indexOf(u8, manifest, needle) == null) {
            std.debug.print("plugin.labelle lacks: {s}\n", .{needle});
            return error.TestUnexpectedResult;
        }
        if (r.kind == .command) {
            const line_start = std.mem.indexOf(u8, manifest, needle).?;
            const line = manifest[line_start .. std.mem.indexOfScalarPos(u8, manifest, line_start, '\n') orelse manifest.len];
            const want = if (r.needs_project) ".needs_project = true" else ".needs_project = false";
            try std.testing.expect(std.mem.indexOf(u8, line, want) != null);
        }
    }
    // Nothing declared that the table does not route.
    const hooks = manifest[std.mem.indexOf(u8, manifest, ".hooks = .{").?..];
    const commands = manifest[std.mem.indexOf(u8, manifest, ".commands = .{").?..std.mem.indexOf(u8, manifest, ".hooks = .{").?];
    var hook_count: usize = 0;
    var command_count: usize = 0;
    for (routes) |r| switch (r.kind) {
        .hook => hook_count += 1,
        .command => command_count += 1,
    };
    try std.testing.expectEqual(hook_count, std.mem.count(u8, hooks, ".id = \""));
    try std.testing.expectEqual(command_count, std.mem.count(u8, commands, ".name = \""));
    try std.testing.expect(std.mem.indexOf(u8, manifest, ".namespace = \"ios\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "    .target_defaults") == null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, ".name = \"ios\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, ".targets = .{\"ios\"},") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, ".command_contract = \">=1.3.0 <1.7.0\"") != null);
}

test "the vendored decoder is contract 1.6.0, admits the manifest's range, and accepts its own fixtures" {
    try std.testing.expectEqualStrings("1.6.0", contract.version);
    for ([_][]const u8{ "1.3.0", "1.4.0", "1.5.0", "1.6.0" }) |wire| {
        var found = false;
        for (contract.supported_versions) |v| found = found or std.mem.eql(u8, v, wire);
        try std.testing.expect(found);
    }
    const fixture = if (@import("builtin").os.tag == .windows)
        @embedFile("provider_contract/projectless-windows.json")
    else
        @embedFile("provider_contract/projectless.json");
    const parsed = try contract.parseContext(std.testing.allocator, fixture, false);
    defer parsed.deinit();
    // The fixture is a projectless `doctor` command.
    try std.testing.expectEqualStrings("doctor", parsed.value.invocation.id);
    try std.testing.expectEqual(Action.doctor, try route(parsed.value));
}

test {
    _ = contract;
    _ = settings_mod;
    _ = identity_mod;
    _ = app_mod;
    _ = launch_mod;
    _ = bundle_mod;
    _ = build_options;
    _ = doctor;
    _ = devices_mod;
    _ = xcode;
    _ = signing;
    _ = stdio;
    _ = @import("plist.zig");
    _ = @import("simctl.zig");
    _ = @import("devicectl.zig");
    _ = @import("zip.zig");
    _ = @import("assets.zig");
    _ = @import("proc.zig");
}
