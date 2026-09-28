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
const simctl = @import("simctl.zig");
const app_mod = @import("app.zig");
const proc = @import("proc.zig");

pub const Inputs = struct {
    /// What the `app` hook made the app from; `app_mod.built` checks it.
    app: app_mod.Inputs,
    run: contract.RunContext,
};

pub const not_macos_message = "the iOS simulator requires macOS (Xcode's simctl); this host cannot run it";

/// Returns the exit status `labelle run` should end with.
pub fn launchHook(a: std.mem.Allocator, io: std.Io, in: Inputs) !u8 {
    if (builtin.os.tag == .windows) {
        std.debug.print("labelle-ios: {s}\n", .{not_macos_message});
        return error.SimulatorNeedsMacos;
    }
    const built = try app_mod.built(a, io, in.app);
    const settings = in.app.settings;
    const env_map = in.app.env;
    const args = simctl.parseRunArgs(a, in.run.args) catch {
        std.debug.print("labelle-ios: --device needs a simulator UDID or name (labelle run --platform=ios -- --device=<udid>)\n", .{});
        return error.InvalidRunArguments;
    };
    const xcrun = (try proc.findOnPath(a, io, env_map, "xcrun")) orelse {
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
    const want = args.device orelse settings.simulator.device;
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

    var env = try simctl.launchEnv(a, env_map, in.run.env);
    for (in.run.env) |kv| std.debug.print("labelle-ios: launch environment {s}={s}\n", .{ kv.name, kv.value });
    const argv = try simctl.launchArgv(a, xcrun, device.udid, settings.bundle_id, args.app_args);
    std.debug.print("labelle-ios: launching {s} (the app's output follows)\n", .{settings.bundle_id});
    const result = try supervise(a, io, .{
        .argv = argv,
        .env = &env,
        .timeout_ms = in.run.timeout_ms,
        .terminate_argv = &.{ xcrun, "simctl", "terminate", device.udid, settings.bundle_id },
    });
    switch (result.outcome) {
        .exited => std.debug.print("labelle-ios: the app exited (status {d})\n", .{result.status}),
        .timed_out => std.debug.print("labelle-ios: stopped the app after --timeout\n", .{}),
        .interrupted => std.debug.print("labelle-ios: stopped the app on a termination signal\n", .{}),
        .stop_failed => {},
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

pub const Outcome = enum {
    /// The app ended on its own: its status is the result.
    exited,
    /// `--timeout` passed and the app was stopped: 0.
    timed_out,
    /// A termination signal asked the hook to stop and the app ended: 0,
    /// whatever `simctl launch` reported for it (Ctrl-C reaches `simctl`
    /// too, which passes it on to the app and exits 130).
    interrupted,
    /// The app had to be stopped but `simctl terminate` failed twice and the
    /// launch did not end: it may still be running on the simulator. 1.
    stop_failed,
};

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

/// How one supervision ended, from what the loop saw: the launch's
/// termination (null while it still runs) and whether a termination signal
/// had reached this process by then. A signal wins over the launch's own
/// status: Ctrl-C is delivered to the whole foreground group, so `simctl`
/// exits 130 at about the moment the handler runs, and whichever the loop
/// notices first, the stop was the user's.
pub fn classify(term: ?std.process.Child.Term, signalled: bool) ?Result {
    if (signalled) return if (term != null) .{ .status = 0, .outcome = .interrupted } else null;
    const t = term orelse return null;
    return .{ .status = proc.status(t), .outcome = .exited };
}

fn supervisePosix(a: std.mem.Allocator, io: std.Io, s: Supervise) !Result {
    // A signal from before this launch is not a request to stop it.
    stop_signal.store(0, .release);
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
    // The flag is read AFTER the launch is polled. A terminal's Ctrl-C posts
    // SIGINT to the whole foreground group at once, and a pending signal is
    // handled before `waitpid` returns to us, so a launch seen ending from
    // that Ctrl-C is always seen with the flag set (`classify`).
    const outcome: Outcome = while (true) {
        const term = pollTerm(pid);
        const signalled = stop_signal.load(.acquire) != 0;
        if (classify(term, signalled)) |done| return done;
        if (signalled) break .interrupted;
        if (s.timeout_ms) |t| if (nowMs(io) -| start >= t) break .timed_out;
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    };
    return stop(a, io, pid, s, outcome);
}

/// Stop the app on the simulator (`simctl terminate`, retried once), then
/// wait the launch out. `simctl launch --console-pty` returns only once the
/// app has exited, so a launch that ended proves the app is gone even when
/// `terminate` failed (the app ended on its own meanwhile). A failed
/// terminate with the launch still running is reported, not hidden: the app
/// may still run, so the result is `stop_failed` (status 1).
fn stop(a: std.mem.Allocator, io: std.Io, pid: std.posix.pid_t, s: Supervise, outcome: Outcome) !Result {
    var attempt: usize = 0;
    const terminated = while (attempt < 2) : (attempt += 1) {
        if (attempt > 0) {
            // Ended on its own since the first attempt: nothing left to stop.
            if (pollUntil(io, pid, 1_000) != null) return .{ .status = 0, .outcome = outcome };
            std.debug.print("labelle-ios: retrying `{s}`\n", .{try std.mem.join(a, " ", s.terminate_argv[1..])});
        }
        if (proc.run(a, io, s.terminate_argv, .{})) |r| {
            if (proc.succeeded(r.term)) break true;
            std.debug.print("labelle-ios: `{s}` exited {d}: {s}{s}", .{ try std.mem.join(a, " ", s.terminate_argv[1..]), proc.status(r.term), r.stdout, r.stderr });
        } else |err| std.debug.print("labelle-ios: could not run {s}: {s}\n", .{ s.terminate_argv[0], @errorName(err) });
    } else false;
    if (pollUntil(io, pid, if (terminated) s.grace_ms else 1_000) != null) return .{ .status = 0, .outcome = outcome };
    // The local `simctl launch` client is still there: end it.
    std.posix.kill(pid, .TERM) catch {};
    if (pollUntil(io, pid, 3_000) == null) {
        std.posix.kill(pid, .KILL) catch {};
        var status: c_int = 0;
        _ = std.c.waitpid(pid, &status, 0);
    }
    if (terminated) return .{ .status = 0, .outcome = outcome };
    std.debug.print("labelle-ios: could not stop the app on the simulator: `simctl terminate` failed twice; it may still be running (stop it from the simulator, or `xcrun {s}`)\n", .{try std.mem.join(a, " ", s.terminate_argv[1..])});
    return .{ .status = 1, .outcome = .stop_failed };
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

test "classify: a signal makes any end of the launch a clean stop" {
    // The injected orderings of the Ctrl-C race: simctl already exited 130
    // (or was killed by SIGINT) when the loop looks, with the handler's flag
    // set, is the user's stop; the same statuses without a signal are the
    // app's own.
    const ended = [_]std.process.Child.Term{ .{ .exited = 130 }, .{ .exited = 0 }, .{ .exited = 3 } };
    for (ended) |t| {
        const r = classify(t, true).?;
        try std.testing.expectEqual(Outcome.interrupted, r.outcome);
        try std.testing.expectEqual(@as(u8, 0), r.status);
    }
    if (builtin.os.tag != .windows) {
        try std.testing.expectEqual(Outcome.interrupted, classify(.{ .signal = .INT }, true).?.outcome);
        try std.testing.expectEqual(@as(u8, 130), classify(.{ .signal = .INT }, false).?.status);
    }
    const own = classify(.{ .exited = 130 }, false).?;
    try std.testing.expectEqual(Outcome.exited, own.outcome);
    try std.testing.expectEqual(@as(u8, 130), own.status);
    // Still running: no verdict yet (with a signal, the caller stops it).
    try std.testing.expect(classify(null, false) == null);
    try std.testing.expect(classify(null, true) == null);
}

test "supervise: Ctrl-C racing the launch's own exit 130 is a clean stop" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // What a terminal Ctrl-C does: the signal reaches this process AND the
    // launch, which passes it on and exits 130.
    const r = try supervise(arena.allocator(), std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "kill -INT $PPID; exit 130" },
        .terminate_argv = &.{"/usr/bin/true"},
        .grace_ms = 2_000,
    });
    try std.testing.expectEqual(Outcome.interrupted, r.outcome);
    try std.testing.expectEqual(@as(u8, 0), r.status);
}

test "supervise: terminate failing twice with the launch still running is stop_failed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const start = nowMs(std.testing.io);
    const r = try supervise(arena.allocator(), std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .timeout_ms = 100,
        .terminate_argv = &.{"/usr/bin/false"},
    });
    try std.testing.expectEqual(Outcome.stop_failed, r.outcome);
    try std.testing.expectEqual(@as(u8, 1), r.status);
    try std.testing.expect(nowMs(std.testing.io) - start < 15_000);
}

test "supervise: terminate failing while the app ends on its own is still a clean stop" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `simctl terminate` finds nothing to stop because the app is exiting;
    // the launch's end proves the app is gone.
    const r = try supervise(arena.allocator(), std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 0.4" },
        .timeout_ms = 100,
        .terminate_argv = &.{"/usr/bin/false"},
    });
    try std.testing.expectEqual(Outcome.timed_out, r.outcome);
    try std.testing.expectEqual(@as(u8, 0), r.status);
}
