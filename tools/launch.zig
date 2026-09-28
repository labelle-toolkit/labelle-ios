//! The `launch` hook (replaces `run`): install the `.app` the `app` hook made
//! on an iOS simulator and run it in the foreground (ported from labelle-cli
//! `src/cli/ios.zig` `deployToSimulator`, origin/main e2e0e85).
//!
//! Unlike the CLI's detached `simctl launch`, this blocks: `simctl launch
//! --console-pty` streams the app's stdout/stderr and returns when the app
//! exits, so `labelle run` ends with the app and its after-run hooks see a
//! real end. The hook exits with `simctl launch`'s status.
//!
//! `--timeout` (the contract's `run.timeout_ms`) and SIGTERM/SIGINT/SIGHUP
//! stop the app the same way: `simctl terminate`, then the launch is waited
//! out (killed after a grace period), and the hook exits 0, as the CLI does
//! when its own watchdog stops a desktop game (cli#390).
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("contract.zig");
const settings_mod = @import("settings.zig");
const simctl = @import("simctl.zig");
const app_mod = @import("app.zig");
const proc = @import("proc.zig");

pub const Inputs = struct {
    target_dir: []const u8,
    settings: settings_mod.Settings,
    run: contract.RunContext,
    env: *const std.process.Environ.Map,
};

pub const not_macos_message = "the iOS simulator requires macOS (Xcode's simctl); this host cannot run it";

/// Returns the exit status `labelle run` should end with.
pub fn launchHook(a: std.mem.Allocator, io: std.Io, in: Inputs) !u8 {
    if (builtin.os.tag == .windows) {
        std.debug.print("labelle-ios: {s}\n", .{not_macos_message});
        return error.SimulatorNeedsMacos;
    }
    const built = try app_mod.built(a, io, in.target_dir, in.settings.bundle_id);
    const args = simctl.parseRunArgs(a, in.run.args) catch {
        std.debug.print("labelle-ios: --device needs a simulator UDID or name (labelle run --platform=ios -- --device=<udid>)\n", .{});
        return error.InvalidRunArguments;
    };
    const xcrun = (try proc.findOnPath(a, io, in.env, "xcrun")) orelse {
        std.debug.print("labelle-ios: xcrun not found on PATH: {s}\n", .{not_macos_message});
        return error.XcrunNotFound;
    };

    // Which simulator.
    var list_argv: std.ArrayList([]const u8) = .empty;
    try list_argv.append(a, xcrun);
    try list_argv.appendSlice(a, &simctl.list_args);
    const listed = try runChecked(a, io, list_argv.items, "list the simulators");
    const devices = simctl.parseDevices(a, listed) catch {
        std.debug.print("labelle-ios: `xcrun simctl list -j devices available` printed something that is not a device list:\n{s}\n", .{listed});
        return error.InvalidSimctlOutput;
    };
    // `-- --device=` beats the settings' `simulator.device`: the one-off
    // choice on the command line overrides the project's default.
    const want = args.device orelse in.settings.simulator.device;
    const device = simctl.pick(devices, want) orelse {
        if (want) |w| {
            std.debug.print("labelle-ios: no available iOS simulator matches '{s}'. Available:\n", .{w});
        } else {
            std.debug.print("labelle-ios: no iPhone simulator available: install an iOS simulator runtime (Xcode > Settings > Components, or `xcodebuild -downloadPlatform iOS`). Available iOS devices:\n", .{});
        }
        for (devices) |d| std.debug.print("  {s}  {s} (iOS {d}.{d}, {s})\n", .{ d.udid, d.name, d.version[0], d.version[1], d.state });
        if (devices.len == 0) std.debug.print("  (none)\n", .{});
        return error.NoSimulator;
    };
    std.debug.print("labelle-ios: simulator {s} ({s}, iOS {d}.{d}, {s})\n", .{ device.name, device.udid, device.version[0], device.version[1], device.state });

    if (!device.booted()) {
        std.debug.print("labelle-ios: booting {s}...\n", .{device.name});
        _ = try runChecked(a, io, &.{ xcrun, "simctl", "bootstatus", device.udid, "-b" }, "boot the simulator");
    }
    std.debug.print("labelle-ios: installing {s}...\n", .{std.fs.path.basename(built.path)});
    _ = try runChecked(a, io, &.{ xcrun, "simctl", "install", device.udid, built.path }, "install the app");

    var env = try simctl.launchEnv(a, in.env, in.run.env);
    for (in.run.env) |kv| std.debug.print("labelle-ios: launch environment {s}={s}\n", .{ kv.name, kv.value });
    const argv = try simctl.launchArgv(a, xcrun, device.udid, in.settings.bundle_id, args.app_args);
    std.debug.print("labelle-ios: launching {s} (the app's output follows)\n", .{in.settings.bundle_id});
    const result = try supervise(a, io, .{
        .argv = argv,
        .env = &env,
        .timeout_ms = in.run.timeout_ms,
        .terminate_argv = &.{ xcrun, "simctl", "terminate", device.udid, in.settings.bundle_id },
    });
    switch (result.outcome) {
        .exited => std.debug.print("labelle-ios: the app exited (status {d})\n", .{result.status}),
        .timed_out => std.debug.print("labelle-ios: stopped the app after --timeout\n", .{}),
        .interrupted => std.debug.print("labelle-ios: stopped the app on a termination signal\n", .{}),
    }
    return result.status;
}

/// Run a simctl step to completion; its stdout on success, else the step's
/// output and a named error.
fn runChecked(a: std.mem.Allocator, io: std.Io, argv: []const []const u8, what: []const u8) ![]const u8 {
    const result = proc.run(a, io, argv, .{}) catch |err| {
        std.debug.print("labelle-ios: could not {s}: {s} did not start ({s})\n", .{ what, argv[0], @errorName(err) });
        return error.SimctlFailed;
    };
    if (!proc.succeeded(result.term)) {
        std.debug.print("labelle-ios: could not {s} (`{s}` exited {d}):\n{s}{s}\n", .{ what, try std.mem.join(a, " ", argv[1..]), proc.status(result.term), result.stdout, result.stderr });
        return error.SimctlFailed;
    }
    return result.stdout;
}

// ── Supervision ───────────────────────────────────────────────────────────

pub const Supervise = struct {
    argv: []const []const u8,
    env: ?*const std.process.Environ.Map = null,
    timeout_ms: ?u64 = null,
    /// Asks the app to stop (`simctl terminate`); the launch then returns.
    terminate_argv: []const []const u8,
    /// How long the launch may take to return after `terminate_argv`.
    grace_ms: u64 = 15_000,
};

pub const Outcome = enum { exited, timed_out, interrupted };

pub const Result = struct { status: u8, outcome: Outcome };

/// The signal that asked the hook to stop, 0 while none has.
var stop_signal: std.atomic.Value(u32) = .init(0);

fn onSignal(sig: std.posix.SIG) callconv(.c) void {
    stop_signal.store(@intFromEnum(sig), .release);
}

fn installSignalHandlers() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for ([_]std.posix.SIG{ .TERM, .INT, .HUP }) |sig| std.posix.sigaction(sig, &act, null);
}

fn nowMs(io: std.Io) u64 {
    const ns = std.Io.Timestamp.now(io, .awake).nanoseconds;
    return @intCast(@divTrunc(@max(ns, 0), std.time.ns_per_ms));
}

/// Run `argv` in the foreground (its stdout onto this process's stderr, so
/// the CLI's stdout stays free for its progress protocol) until it exits, the
/// timeout passes or a termination signal arrives. POSIX only.
pub fn supervise(a: std.mem.Allocator, io: std.Io, s: Supervise) !Result {
    // Comptime-known: the POSIX half is never analyzed on Windows.
    return if (builtin.os.tag == .windows) error.SimulatorNeedsMacos else supervisePosix(a, io, s);
}

fn supervisePosix(a: std.mem.Allocator, io: std.Io, s: Supervise) !Result {
    installSignalHandlers();
    var child = try std.process.spawn(io, .{
        .argv = s.argv,
        .environ_map = s.env,
        .stdin = .inherit,
        .stdout = .{ .file = std.Io.File.stderr() },
        .stderr = .inherit,
    });
    const pid = child.id.?;
    // Reaped here with waitpid, never through `child.wait`.
    child.id = null;
    const start = nowMs(io);
    const outcome: Outcome = while (true) {
        if (pollTerm(pid)) |term| return .{ .status = proc.status(term), .outcome = .exited };
        if (stop_signal.load(.acquire) != 0) break .interrupted;
        if (s.timeout_ms) |t| if (nowMs(io) -| start >= t) break .timed_out;
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    };
    // Ask the app to stop; `simctl launch` returns once it has.
    if (proc.run(a, io, s.terminate_argv, .{})) |r| {
        if (!proc.succeeded(r.term)) std.debug.print("labelle-ios: note: `{s}` exited {d}: {s}", .{ try std.mem.join(a, " ", s.terminate_argv[1..]), proc.status(r.term), r.stderr });
    } else |err| std.debug.print("labelle-ios: note: could not run {s}: {s}\n", .{ s.terminate_argv[0], @errorName(err) });
    if (pollUntil(io, pid, s.grace_ms) == null) {
        std.posix.kill(pid, .TERM) catch {};
        if (pollUntil(io, pid, 3_000) == null) {
            std.posix.kill(pid, .KILL) catch {};
            var status: c_int = 0;
            _ = std.c.waitpid(pid, &status, 0);
        }
    }
    return .{ .status = 0, .outcome = outcome };
}

/// The child's termination when it has ended (reaped), null while it runs.
fn pollTerm(pid: std.posix.pid_t) ?std.process.Child.Term {
    var status: c_int = 0;
    const rc = std.c.waitpid(pid, &status, std.c.W.NOHANG);
    if (rc == 0) return null;
    if (rc < 0) return .{ .unknown = 0 };
    const s: u32 = @bitCast(status);
    const W = std.c.W;
    if (W.IFEXITED(s)) return .{ .exited = W.EXITSTATUS(s) };
    if (W.IFSIGNALED(s)) return .{ .signal = W.TERMSIG(s) };
    if (W.IFSTOPPED(s)) return .{ .stopped = W.STOPSIG(s) };
    return .{ .unknown = s };
}

fn pollUntil(io: std.Io, pid: std.posix.pid_t, budget_ms: u64) ?std.process.Child.Term {
    const deadline = nowMs(io) +| budget_ms;
    while (true) {
        if (pollTerm(pid)) |term| return term;
        if (nowMs(io) >= deadline) return null;
        io.sleep(.fromMilliseconds(20), .awake) catch {};
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "supervise: the child's own exit status is the result" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try supervise(arena.allocator(), std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "exit 3" },
        .terminate_argv = &.{"/usr/bin/true"},
    });
    try std.testing.expectEqual(Outcome.exited, r.outcome);
    try std.testing.expectEqual(@as(u8, 3), r.status);
}

test "supervise: a timeout terminates, waits the launch out and reports 0" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const marker = try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(std.testing.io, ".", a), "terminated" });
    // The "launch" returns as soon as the "terminate" step has run, as
    // `simctl launch` does once `simctl terminate` stops the app.
    const loop = try std.fmt.allocPrint(a, "while [ ! -f '{s}' ]; do sleep 0.05; done; exit 0", .{marker});
    const start = nowMs(std.testing.io);
    const r = try supervise(a, std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", loop },
        .timeout_ms = 200,
        .terminate_argv = &.{ "/usr/bin/touch", marker },
        .grace_ms = 10_000,
    });
    const elapsed = nowMs(std.testing.io) - start;
    try std.testing.expectEqual(Outcome.timed_out, r.outcome);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expect(elapsed >= 200 and elapsed < 5_000);
}

test "supervise: a launch that ignores terminate is killed after the grace period" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const start = nowMs(std.testing.io);
    const r = try supervise(arena.allocator(), std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .timeout_ms = 100,
        .terminate_argv = &.{"/usr/bin/true"},
        .grace_ms = 200,
    });
    try std.testing.expectEqual(Outcome.timed_out, r.outcome);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expect(nowMs(std.testing.io) - start < 10_000);
}
