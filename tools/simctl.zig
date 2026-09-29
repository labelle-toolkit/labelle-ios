//! `xcrun simctl`: device discovery and selection, and the argv/environment
//! of each simulator call (ported from labelle-cli `src/cli/ios.zig`
//! `ensureSimulatorBooted`/`deployToSimulator`, origin/main e2e0e85).
//!
//! The CLI scanned `simctl list` text for the first `"udid" : "` and the first
//! iPhone line. This parses `simctl list -j devices available` instead, keeps
//! iOS runtimes only (no watchOS/tvOS/visionOS device can run the app), and
//! picks deterministically: a booted iPhone first, else an iPhone of the newest
//! iOS runtime.
const std = @import("std");
const contract = @import("contract.zig");

pub const Device = struct {
    udid: []const u8,
    name: []const u8,
    /// `Booted`, `Shutdown`, `Booting`, ...
    state: []const u8,
    /// The runtime identifier, e.g. `com.apple.CoreSimulator.SimRuntime.iOS-18-2`.
    runtime: []const u8,
    /// `iOS-18-2` → 18.2.0.
    version: [3]u32,
    /// e.g. `com.apple.CoreSimulator.SimDeviceType.iPhone-16`; null when the
    /// listing omits it (Xcode 12 and older).
    device_type: ?[]const u8 = null,

    pub fn booted(d: Device) bool {
        return std.mem.eql(u8, d.state, "Booted");
    }

    /// By the device type, never the display name: a simulator can be
    /// renamed (`simctl rename`, or `simctl create "<any name>"`). Only a
    /// listing without device types falls back to the name.
    pub fn iphone(d: Device) bool {
        if (d.device_type) |t| return std.mem.startsWith(u8, t, iphone_type_prefix);
        return std.mem.startsWith(u8, d.name, "iPhone");
    }

    pub fn ipad(d: Device) bool {
        if (d.device_type) |t| return std.mem.startsWith(u8, t, ipad_type_prefix);
        return std.mem.startsWith(u8, d.name, "iPad");
    }
};

pub const iphone_type_prefix = "com.apple.CoreSimulator.SimDeviceType.iPhone-";
pub const ipad_type_prefix = "com.apple.CoreSimulator.SimDeviceType.iPad";

/// The kind of device an automatic choice looks for.
pub const Family = enum {
    iphone,
    ipad,

    /// `UIDeviceFamily` "2" is iPad-only; "1" and "1,2" run on an iPhone.
    pub fn label(f: Family) []const u8 {
        return switch (f) {
            .iphone => "iPhone",
            .ipad => "iPad",
        };
    }

    pub fn fromDeviceFamily(device_family: []const u8) Family {
        return if (std.mem.eql(u8, device_family, "2")) .ipad else .iphone;
    }
};

/// What an automatically chosen simulator must satisfy for the app to
/// install: its family and `MinimumOSVersion`.
pub const Need = struct {
    family: Family = .iphone,
    minimum: [3]u32 = .{ 0, 0, 0 },

    pub fn met(n: Need, d: Device) bool {
        const family_ok = switch (n.family) {
            .iphone => d.iphone(),
            .ipad => d.ipad(),
        };
        return family_ok and std.mem.order(u32, &d.version, &n.minimum) != .lt;
    }
};

/// `xcrun simctl list -j devices available`.
pub const list_args = [_][]const u8{ "simctl", "list", "-j", "devices", "available" };

const runtime_prefix = "com.apple.CoreSimulator.SimRuntime.iOS-";

/// The runtime version of an iOS runtime identifier, or null for any other
/// platform's runtime (or a malformed one).
pub fn iosRuntimeVersion(runtime: []const u8) ?[3]u32 {
    if (!std.mem.startsWith(u8, runtime, runtime_prefix)) return null;
    var version: [3]u32 = .{ 0, 0, 0 };
    var it = std.mem.splitScalar(u8, runtime[runtime_prefix.len..], '-');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i == version.len) return null;
        version[i] = std.fmt.parseInt(u32, part, 10) catch return null;
    }
    if (i < 2) return null;
    return version;
}

/// Every available device of an iOS runtime in `simctl list -j` output, in
/// the listed order. Strings borrow from `a`.
pub fn parseDevices(a: std.mem.Allocator, bytes: []const u8) ![]Device {
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch return error.InvalidSimctlOutput;
    if (root != .object) return error.InvalidSimctlOutput;
    const by_runtime = root.object.get("devices") orelse return error.InvalidSimctlOutput;
    if (by_runtime != .object) return error.InvalidSimctlOutput;
    var found: std.ArrayList(Device) = .empty;
    var it = by_runtime.object.iterator();
    while (it.next()) |entry| {
        const version = iosRuntimeVersion(entry.key_ptr.*) orelse continue;
        if (entry.value_ptr.* != .array) return error.InvalidSimctlOutput;
        for (entry.value_ptr.array.items) |item| {
            if (item != .object) return error.InvalidSimctlOutput;
            const o = item.object;
            if (o.get("isAvailable")) |available| {
                if (available != .bool or !available.bool) continue;
            }
            try found.append(a, .{
                .udid = try field(o, "udid"),
                .name = try field(o, "name"),
                .state = try field(o, "state"),
                .runtime = entry.key_ptr.*,
                .version = version,
                .device_type = if (o.get("deviceTypeIdentifier")) |t| switch (t) {
                    .string => |str| str,
                    else => return error.InvalidSimctlOutput,
                } else null,
            });
        }
    }
    return found.items;
}

fn field(o: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = o.get(key) orelse return error.InvalidSimctlOutput;
    if (v != .string) return error.InvalidSimctlOutput;
    return v.string;
}

fn newer(x: [3]u32, y: [3]u32) bool {
    return std.mem.order(u32, &x, &y) == .gt;
}

/// Of `candidates` that satisfy `accept`: a booted one first, else the one
/// on the newest runtime (the first listed on ties).
fn best(devices: []const Device, ctx: anytype, comptime accept: fn (@TypeOf(ctx), Device) bool) ?Device {
    var chosen: ?Device = null;
    for (devices) |d| {
        if (!accept(ctx, d)) continue;
        if (chosen) |p| {
            if (p.booted()) continue;
            if (d.booted() or newer(d.version, p.version)) chosen = d;
        } else chosen = d;
    }
    return chosen;
}

fn meets(need: Need, d: Device) bool {
    return need.met(d);
}

fn isUdid(want: []const u8, d: Device) bool {
    return std.ascii.eqlIgnoreCase(d.udid, want);
}

fn isNamed(want: []const u8, d: Device) bool {
    return std.mem.eql(u8, d.name, want);
}

/// The device to run on. `want` (a UDID, else a device name) when given,
/// taken as asked; otherwise, among the devices that meet `need` (the app's
/// family and minimum iOS), a booted one, else one of the newest runtime.
pub fn pick(devices: []const Device, want: ?[]const u8, need: Need) ?Device {
    if (want) |w| return best(devices, w, isUdid) orelse best(devices, w, isNamed);
    return best(devices, need, meets);
}

/// An installed iOS simulator runtime.
pub const Runtime = struct {
    identifier: []const u8,
    /// `iOS 18.2`.
    name: []const u8,
    version: [3]u32,
    available: bool,
};

/// `xcrun simctl list -j runtimes`.
pub const runtimes_args = [_][]const u8{ "simctl", "list", "-j", "runtimes" };

/// The iOS runtimes of `simctl list -j runtimes` output (other platforms
/// dropped), in the listed order. Strings borrow from `a`.
pub fn parseRuntimes(a: std.mem.Allocator, bytes: []const u8) ![]Runtime {
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch return error.InvalidSimctlOutput;
    if (root != .object) return error.InvalidSimctlOutput;
    const entries = root.object.get("runtimes") orelse return error.InvalidSimctlOutput;
    if (entries != .array) return error.InvalidSimctlOutput;
    var found: std.ArrayList(Runtime) = .empty;
    for (entries.array.items) |item| {
        if (item != .object) return error.InvalidSimctlOutput;
        const identifier = try field(item.object, "identifier");
        const version = iosRuntimeVersion(identifier) orelse continue;
        const available = if (item.object.get("isAvailable")) |v| v == .bool and v.bool else true;
        try found.append(a, .{
            .identifier = identifier,
            .name = if (item.object.get("name")) |n| (if (n == .string) n.string else identifier) else identifier,
            .version = version,
            .available = available,
        });
    }
    return found.items;
}

/// The newest available runtime at or above `minimum`, if any.
pub fn newestRuntime(runtimes: []const Runtime, minimum: [3]u32) ?Runtime {
    var chosen: ?Runtime = null;
    for (runtimes) |r| {
        if (!r.available or std.mem.order(u32, &r.version, &minimum) == .lt) continue;
        if (chosen == null or newer(r.version, chosen.?.version)) chosen = r;
    }
    return chosen;
}

/// What the `launch` hook takes from `labelle run ... -- <args>`: a
/// `--device=<udid|name>` (or `--device <udid|name>`) choice, and the rest,
/// forwarded to the app as its arguments.
pub const RunArgs = struct {
    device: ?[]const u8 = null,
    app_args: []const []const u8 = &.{},
};

pub fn parseRunArgs(a: std.mem.Allocator, args: []const []const u8) !RunArgs {
    var out: RunArgs = .{};
    var rest: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "--device=")) {
            out.device = arg["--device=".len..];
        } else if (std.mem.eql(u8, arg, "--device")) {
            i += 1;
            out.device = if (i < args.len) args[i] else "";
        } else {
            try rest.append(a, arg);
            continue;
        }
        if (out.device.?.len == 0) return error.DeviceNeedsValue;
    }
    out.app_args = rest.items;
    return out;
}

/// `xcrun simctl launch --console-pty --terminate-running-process <udid>
/// <bundle_id> [args...]`: blocks with the app's stdout/stderr on the
/// console until the app exits. `--terminate-running-process` replaces an
/// instance a previous run left behind, so the new install is what runs.
pub fn launchArgv(a: std.mem.Allocator, xcrun: []const u8, udid: []const u8, bundle_id: []const u8, app_args: []const []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ xcrun, "simctl", "launch", "--console-pty", "--terminate-running-process", udid, bundle_id });
    try argv.appendSlice(a, app_args);
    return argv.items;
}

/// `simctl launch` hands a `SIMCTL_CHILD_<NAME>` variable of its own
/// environment to the app as `<NAME>`: each run option becomes one.
pub fn childEnvName(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "SIMCTL_CHILD_{s}", .{name});
}

/// The launch's environment: this process's, plus one `SIMCTL_CHILD_*`
/// per run option. Stale `SIMCTL_CHILD_*` variables inherited from the
/// caller are dropped, so only this run's options reach the app.
pub fn launchEnv(a: std.mem.Allocator, parent: *const std.process.Environ.Map, run_env: []const contract.RunEnv) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(a);
    var it = parent.iterator();
    while (it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, "SIMCTL_CHILD_")) continue;
        try env.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    for (run_env) |kv| try env.put(try childEnvName(a, kv.name), kv.value);
    return env;
}

// ── Tests ─────────────────────────────────────────────────────────────────

/// Trimmed real `xcrun simctl list -j devices available` output (Xcode 16),
/// plus a watchOS runtime and an unavailable device.
const listing =
    \\{
    \\  "devices" : {
    \\    "com.apple.CoreSimulator.SimRuntime.watchOS-11-2" : [
    \\      { "udid" : "AAAAAAAA-0000-0000-0000-000000000001", "isAvailable" : true, "state" : "Booted", "name" : "Apple Watch Series 10 (46mm)" }
    \\    ],
    \\    "com.apple.CoreSimulator.SimRuntime.iOS-17-5" : [
    \\      { "lastBootedAt" : "2024-10-01T10:00:00Z", "dataPath" : "/x", "dataPathSize" : 1, "logPath" : "/y",
    \\        "udid" : "11111111-0000-0000-0000-000000000001", "isAvailable" : true,
    \\        "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-15", "state" : "Shutdown", "name" : "iPhone 15" },
    \\      { "udid" : "11111111-0000-0000-0000-00000000000A", "isAvailable" : true, "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M2", "state" : "Shutdown", "name" : "iPad Air 11-inch (M2)" }
    \\    ],
    \\    "com.apple.CoreSimulator.SimRuntime.iOS-18-2" : [
    \\      { "udid" : "22222222-0000-0000-0000-000000000001", "isAvailable" : true, "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro", "state" : "Shutdown", "name" : "iPhone 16 Pro" },
    \\      { "udid" : "22222222-0000-0000-0000-000000000002", "isAvailable" : true, "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-16", "state" : "Shutdown", "name" : "iPhone 16" },
    \\      { "udid" : "22222222-0000-0000-0000-000000000003", "isAvailable" : false, "state" : "Shutdown", "name" : "iPhone 15" }
    \\    ]
    \\  }
    \\}
;

test "parseDevices keeps available devices of iOS runtimes only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const devices = try parseDevices(arena.allocator(), listing);
    try std.testing.expectEqual(@as(usize, 4), devices.len);
    for (devices) |d| {
        try std.testing.expect(std.mem.startsWith(u8, d.runtime, "com.apple.CoreSimulator.SimRuntime.iOS-"));
        try std.testing.expect(!std.mem.eql(u8, d.udid, "22222222-0000-0000-0000-000000000003"));
    }
    try std.testing.expectEqual([3]u32{ 17, 5, 0 }, devices[0].version);
    try std.testing.expectEqualStrings("iPhone 15", devices[0].name);
}

test "parseDevices refuses output that is not a simctl device listing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "[]", "{}", "{\"devices\": []}", "{\"devices\": {\"com.apple.CoreSimulator.SimRuntime.iOS-18-2\": [{\"udid\": 1}]}}" }) |bad| {
        try std.testing.expectError(error.InvalidSimctlOutput, parseDevices(a, bad));
    }
    // No iOS runtime at all is an empty list, not an error.
    try std.testing.expectEqual(@as(usize, 0), (try parseDevices(a, "{\"devices\": {}}")).len);
}

test "iosRuntimeVersion" {
    try std.testing.expectEqual([3]u32{ 18, 2, 0 }, iosRuntimeVersion("com.apple.CoreSimulator.SimRuntime.iOS-18-2").?);
    try std.testing.expectEqual([3]u32{ 17, 0, 1 }, iosRuntimeVersion("com.apple.CoreSimulator.SimRuntime.iOS-17-0-1").?);
    for ([_][]const u8{ "com.apple.CoreSimulator.SimRuntime.tvOS-18-2", "com.apple.CoreSimulator.SimRuntime.iOS-18", "com.apple.CoreSimulator.SimRuntime.iOS-x-1", "iOS-18-2" }) |bad| {
        try std.testing.expect(iosRuntimeVersion(bad) == null);
    }
}

test "pick: newest-runtime iPhone when none is booted; a booted iPhone wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const devices = try parseDevices(arena.allocator(), listing);
    // Nothing booted: the first iPhone of iOS 18.2, never the iPad or the watch.
    try std.testing.expectEqualStrings("22222222-0000-0000-0000-000000000001", pick(devices, null, .{}).?.udid);
    // A booted iPhone on an older runtime is preferred (no boot needed).
    devices[0].state = "Booted";
    try std.testing.expectEqualStrings("11111111-0000-0000-0000-000000000001", pick(devices, null, .{}).?.udid);
    // A booted iPad does not count as an iPhone.
    devices[0].state = "Shutdown";
    devices[1].state = "Booted";
    try std.testing.expectEqualStrings("22222222-0000-0000-0000-000000000001", pick(devices, null, .{}).?.udid);
}

test "pick: an explicit UDID or name; unknown is null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const devices = try parseDevices(arena.allocator(), listing);
    try std.testing.expectEqualStrings("iPad Air 11-inch (M2)", pick(devices, "11111111-0000-0000-0000-00000000000A", .{}).?.name);
    // UDIDs compare case-insensitively.
    try std.testing.expectEqualStrings("iPad Air 11-inch (M2)", pick(devices, "11111111-0000-0000-0000-00000000000a", .{}).?.name);
    try std.testing.expectEqualStrings("22222222-0000-0000-0000-000000000002", pick(devices, "iPhone 16", .{}).?.udid);
    // A name on two runtimes: the newer one (the unavailable 18.2 copy was dropped).
    try std.testing.expectEqualStrings("11111111-0000-0000-0000-000000000001", pick(devices, "iPhone 15", .{}).?.udid);
    try std.testing.expect(pick(devices, "iPhone 99", .{}) == null);
    try std.testing.expect(pick(devices, "AAAAAAAA-0000-0000-0000-000000000001", .{}) == null); // the watch
    try std.testing.expect(pick(&.{}, null, .{}) == null);
}

test "parseRunArgs: --device in both spellings; the rest reaches the app" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parseRunArgs(a, &.{ "--level=3", "--device=ABC", "-v" });
    try std.testing.expectEqualStrings("ABC", r.device.?);
    try std.testing.expectEqual(@as(usize, 2), r.app_args.len);
    try std.testing.expectEqualStrings("--level=3", r.app_args[0]);
    try std.testing.expectEqualStrings("-v", r.app_args[1]);
    try std.testing.expectEqualStrings("iPhone 16", (try parseRunArgs(a, &.{ "--device", "iPhone 16" })).device.?);
    try std.testing.expect((try parseRunArgs(a, &.{})).device == null);
    try std.testing.expectError(error.DeviceNeedsValue, parseRunArgs(a, &.{"--device"}));
    try std.testing.expectError(error.DeviceNeedsValue, parseRunArgs(a, &.{"--device="}));
}

test "launchArgv blocks on the console and forwards app arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try launchArgv(arena.allocator(), "xcrun", "UDID", "com.a.b", &.{ "x", "y z" });
    const want = [_][]const u8{ "xcrun", "simctl", "launch", "--console-pty", "--terminate-running-process", "UDID", "com.a.b", "x", "y z" };
    try std.testing.expectEqual(want.len, argv.len);
    for (want, argv) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "launchEnv: each run option becomes SIMCTL_CHILD_*; stale ones are dropped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parent = std.process.Environ.Map.init(a);
    try parent.put("PATH", "/usr/bin");
    try parent.put("SIMCTL_CHILD_LABELLE_SCENE", "stale");
    const run_env = [_]contract.RunEnv{
        .{ .name = "LABELLE_SCENE", .value = "intro" },
        .{ .name = "LABELLE_SCREENSHOT_AFTER_SEC", .value = "2.500" },
    };
    const env = try launchEnv(a, &parent, &run_env);
    try std.testing.expectEqualStrings("/usr/bin", env.get("PATH").?);
    try std.testing.expectEqualStrings("intro", env.get("SIMCTL_CHILD_LABELLE_SCENE").?);
    try std.testing.expectEqualStrings("2.500", env.get("SIMCTL_CHILD_LABELLE_SCREENSHOT_AFTER_SEC").?);
    const none = try launchEnv(a, &parent, &.{});
    try std.testing.expect(none.get("SIMCTL_CHILD_LABELLE_SCENE") == null);
}

test "pick: an iPhone is recognised by its device type, not its name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const devices = try parseDevices(arena.allocator(),
        \\{ "devices": { "com.apple.CoreSimulator.SimRuntime.iOS-18-2": [
        \\  { "udid": "IPAD", "isAvailable": true, "state": "Shutdown", "name": "iPhone lookalike",
        \\    "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M2" },
        \\  { "udid": "RENAMED", "isAvailable": true, "state": "Shutdown", "name": "labelle-ios CI phone",
        \\    "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16" }
        \\] } }
    );
    try std.testing.expect(!devices[0].iphone());
    try std.testing.expect(devices[1].iphone());
    try std.testing.expectEqualStrings("RENAMED", pick(devices, null, .{}).?.udid);
    // A listing without device types (old Xcode) still works by name.
    const old = try parseDevices(arena.allocator(),
        \\{ "devices": { "com.apple.CoreSimulator.SimRuntime.iOS-14-5": [
        \\  { "udid": "OLD", "isAvailable": true, "state": "Shutdown", "name": "iPhone 12" } ] } }
    );
    try std.testing.expectEqualStrings("OLD", pick(old, null, .{}).?.udid);
    try std.testing.expectError(error.InvalidSimctlOutput, parseDevices(arena.allocator(),
        \\{ "devices": { "com.apple.CoreSimulator.SimRuntime.iOS-18-2": [
        \\  { "udid": "X", "state": "Shutdown", "name": "x", "deviceTypeIdentifier": 7 } ] } }
    ));
}

test "pick: the automatic choice meets the app's family and minimum iOS" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const devices = try parseDevices(arena.allocator(), listing);
    // iPad-only app: the iPad, never an iPhone.
    try std.testing.expectEqualStrings("11111111-0000-0000-0000-00000000000A", pick(devices, null, .{ .family = .ipad }).?.udid);
    // A booted iPhone on a runtime older than minimum_ios is passed over.
    devices[0].state = "Booted"; // iPhone 15, iOS 17.5
    try std.testing.expectEqualStrings("11111111-0000-0000-0000-000000000001", pick(devices, null, .{}).?.udid);
    try std.testing.expectEqualStrings("22222222-0000-0000-0000-000000000001", pick(devices, null, .{ .minimum = .{ 18, 0, 0 } }).?.udid);
    // Nothing new enough: none (the caller explains).
    try std.testing.expect(pick(devices, null, .{ .minimum = .{ 19, 0, 0 } }) == null);
    // An explicit choice is taken as asked; the caller notes the mismatch.
    try std.testing.expectEqualStrings("iPhone 15", pick(devices, "iPhone 15", .{ .minimum = .{ 19, 0, 0 } }).?.name);
    try std.testing.expectEqual(Family.ipad, Family.fromDeviceFamily("2"));
    try std.testing.expectEqual(Family.iphone, Family.fromDeviceFamily("1,2"));
    try std.testing.expectEqual(Family.iphone, Family.fromDeviceFamily("1"));
}

/// Trimmed `xcrun simctl list -j runtimes` (Xcode 16): two iOS runtimes, one
/// unavailable, and a watchOS one.
pub const runtimes_fixture =
    \\{
    \\  "runtimes" : [
    \\    { "bundlePath" : "/x", "buildversion" : "21F79", "platform" : "iOS", "runtimeRoot" : "/y",
    \\      "identifier" : "com.apple.CoreSimulator.SimRuntime.iOS-17-5", "version" : "17.5", "isInternal" : false,
    \\      "isAvailable" : true, "name" : "iOS 17.5", "supportedDeviceTypes" : [] },
    \\    { "identifier" : "com.apple.CoreSimulator.SimRuntime.iOS-18-2", "version" : "18.2", "isAvailable" : true, "name" : "iOS 18.2" },
    \\    { "identifier" : "com.apple.CoreSimulator.SimRuntime.iOS-16-4", "version" : "16.4", "isAvailable" : false, "name" : "iOS 16.4",
    \\      "availabilityError" : "runtime profile not found" },
    \\    { "identifier" : "com.apple.CoreSimulator.SimRuntime.watchOS-11-2", "version" : "11.2", "isAvailable" : true, "name" : "watchOS 11.2" }
    \\  ]
    \\}
;

test "parseRuntimes: iOS only; newestRuntime honours availability and the floor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const runtimes = try parseRuntimes(a, runtimes_fixture);
    try std.testing.expectEqual(@as(usize, 3), runtimes.len);
    try std.testing.expectEqualStrings("iOS 17.5", runtimes[0].name);
    try std.testing.expect(!runtimes[2].available);
    try std.testing.expectEqualStrings("iOS 18.2", newestRuntime(runtimes, .{ 15, 0, 0 }).?.name);
    try std.testing.expect(newestRuntime(runtimes, .{ 19, 0, 0 }) == null);
    try std.testing.expect(newestRuntime(runtimes[2..], .{ 15, 0, 0 }) == null);
    try std.testing.expectEqual(@as(usize, 0), (try parseRuntimes(a, "{\"runtimes\": []}")).len);
    for ([_][]const u8{ "", "{}", "{\"runtimes\": {}}", "{\"runtimes\": [{}]}" }) |bad| {
        try std.testing.expectError(error.InvalidSimctlOutput, parseRuntimes(a, bad));
    }
}
