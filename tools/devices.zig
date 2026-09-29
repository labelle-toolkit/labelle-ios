//! `labelle ios devices`: the iOS simulators (`simctl list -j devices
//! available`) and, with Xcode 15+, the physical devices (`devicectl list
//! devices`) an app can run on, with the id `--device=` takes.
const std = @import("std");
const builtin = @import("builtin");
const simctl = @import("simctl.zig");
const devicectl = @import("devicectl.zig");
const proc = @import("proc.zig");

/// Newest runtime first, then by name.
fn simulatorOrder(_: void, x: simctl.Device, y: simctl.Device) bool {
    return switch (std.mem.order(u32, &x.version, &y.version)) {
        .gt => true,
        .lt => false,
        .eq => std.mem.lessThan(u8, x.name, y.name),
    };
}

/// The listing. `physical` is null when devicectl is unavailable (with the
/// reason in `physical_note`).
pub fn writeListing(simulators: []simctl.Device, physical: ?[]const devicectl.Device, physical_note: ?[]const u8, out: *std.Io.Writer) !void {
    std.mem.sort(simctl.Device, simulators, {}, simulatorOrder);
    try out.writeAll("iOS simulators\n");
    if (simulators.len == 0) try out.writeAll("  (none: install a runtime in Xcode > Settings > Components)\n");
    for (simulators) |d| {
        try out.print("  {s}  {s} (iOS {d}.{d}{s})\n", .{ d.udid, d.name, d.version[0], d.version[1], if (d.booted()) ", booted" else "" });
    }
    try out.writeAll("\niOS devices\n");
    if (physical) |list| {
        if (list.len == 0) try out.writeAll("  (none: connect a device and trust this Mac)\n");
        for (list) |d| {
            try out.print("  {s}  {s} ({s}, iOS {s}, {s}", .{ d.identifier, d.name, d.model orelse "?", d.os_version orelse "?", d.state() });
            if (d.developer_mode) |mode| if (!std.mem.eql(u8, mode, "enabled")) try out.writeAll(", Developer Mode off");
            try out.writeAll(")\n");
        }
    } else try out.print("  ({s})\n", .{physical_note orelse "unavailable"});
    try out.writeAll("\nRun on one with: labelle ios run --device=<id>  (or labelle run --platform=ios -- --device=<id>)\n");
    try out.flush();
}

/// Where `devicectl` writes its JSON: the temp directory, unique per process.
fn scratchFile(a: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    const dir = env.get("TMPDIR") orelse "/tmp";
    return std.fs.path.join(a, &.{ dir, try std.fmt.allocPrint(a, "labelle-ios-devices-{d}.json", .{proc.pid()}) });
}

pub fn devicesCommand(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, out: *std.Io.Writer) !void {
    if (builtin.os.tag != .macos) {
        std.debug.print("labelle-ios: listing iOS simulators and devices needs macOS with Xcode\n", .{});
        return error.NeedsMacos;
    }
    const xcrun = (try proc.findOnPath(a, io, env, "xcrun")) orelse {
        std.debug.print("labelle-ios: xcrun not found on PATH (install Xcode; `labelle ios doctor` checks the setup)\n", .{});
        return error.XcrunNotFound;
    };
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, xcrun);
    try argv.appendSlice(a, &simctl.list_args);
    const r = try proc.run(a, io, argv.items, .{});
    if (!proc.succeeded(r.term)) {
        std.debug.print("labelle-ios: `xcrun simctl list` exited {d} (`labelle ios doctor` checks the Xcode setup):\n{s}\n", .{ proc.status(r.term), r.stderr });
        return error.SimctlFailed;
    }
    const simulators = simctl.parseDevices(a, r.stdout) catch {
        std.debug.print("labelle-ios: `xcrun simctl list -j devices available` printed something that is not a device list\n", .{});
        return error.InvalidSimctlOutput;
    };
    var physical: ?[]const devicectl.Device = null;
    var note: ?[]const u8 = null;
    if (devicectl.available(a, io, xcrun)) {
        physical = devicectl.list(a, io, xcrun, try scratchFile(a, env)) catch |err| blk: {
            note = try std.fmt.allocPrint(a, "devicectl failed: {s}", .{@errorName(err)});
            break :blk null;
        };
    } else note = "devicectl needs Xcode 15 or newer";
    try writeListing(simulators, physical, note, out);
}

// ── Tests ─────────────────────────────────────────────────────────────────

const sim_fixture =
    \\{ "devices" : {
    \\  "com.apple.CoreSimulator.SimRuntime.iOS-17-5" : [
    \\    { "udid" : "11111111-0000-0000-0000-000000000001", "isAvailable" : true, "state" : "Shutdown", "name" : "iPhone 15",
    \\      "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-15" } ],
    \\  "com.apple.CoreSimulator.SimRuntime.iOS-18-2" : [
    \\    { "udid" : "22222222-0000-0000-0000-000000000002", "isAvailable" : true, "state" : "Booted", "name" : "iPhone 16",
    \\      "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-16" },
    \\    { "udid" : "22222222-0000-0000-0000-000000000001", "isAvailable" : true, "state" : "Shutdown", "name" : "iPad Air 11-inch (M2)" } ]
    \\} }
;

test "writeListing: simulators newest first, devices with their state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sims = try simctl.parseDevices(a, sim_fixture);
    const phys = try devicectl.parseDevices(a, devicectl.fixture);
    var out: std.Io.Writer.Allocating = .init(a);
    try writeListing(sims, phys, null, &out.writer);
    try std.testing.expectEqualStrings(
        \\iOS simulators
        \\  22222222-0000-0000-0000-000000000001  iPad Air 11-inch (M2) (iOS 18.2)
        \\  22222222-0000-0000-0000-000000000002  iPhone 16 (iOS 18.2, booted)
        \\  11111111-0000-0000-0000-000000000001  iPhone 15 (iOS 17.5)
        \\
        \\iOS devices
        \\  5B4C4E0B-0000-4000-8000-00000000A001  Jo's iPhone (iPhone 15 Pro, iOS 18.1, wired)
        \\  5B4C4E0B-0000-4000-8000-00000000A002  Studio iPad (iPad13,1, iOS 17.6, unpaired)
        \\  5B4C4E0B-0000-4000-8000-00000000A003  Old iPhone (?, iOS ?, unavailable)
        \\
        \\Run on one with: labelle ios run --device=<id>  (or labelle run --platform=ios -- --device=<id>)
        \\
    , out.written());
}

test "writeListing: nothing installed, and no devicectl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    try writeListing(&.{}, null, "devicectl needs Xcode 15 or newer", &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "(none: install a runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "(devicectl needs Xcode 15 or newer)") != null);
}
