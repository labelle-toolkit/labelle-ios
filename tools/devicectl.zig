//! `xcrun devicectl` (Xcode 15+): physical iOS devices. Discovery parses
//! `devicectl list devices --json-output <file>`; install and launch are
//! `devicectl device install app` and `devicectl device process launch
//! --console`, which streams the app's output and returns when it exits.
const std = @import("std");
const contract = @import("contract.zig");
const proc = @import("proc.zig");

pub const Device = struct {
    /// CoreDevice identifier (a UUID): what `--device` takes.
    identifier: []const u8,
    /// The hardware UDID (`00008130-...`), also accepted by `--device`.
    udid: ?[]const u8 = null,
    name: []const u8,
    /// `marketingName` (`iPhone 15 Pro`), else `productType`.
    model: ?[]const u8 = null,
    os_version: ?[]const u8 = null,
    /// `wired`, `localNetwork`; null when not connected.
    transport: ?[]const u8 = null,
    /// `paired`, `unpaired`, ...
    pairing: ?[]const u8 = null,
    /// `enabled` / `disabled` (iOS 16+ Developer Mode).
    developer_mode: ?[]const u8 = null,

    /// Reachable now: paired and on a transport.
    pub fn connected(d: Device) bool {
        return d.transport != null and std.mem.eql(u8, d.pairing orelse "", "paired");
    }

    pub fn state(d: Device) []const u8 {
        if (!std.mem.eql(u8, d.pairing orelse "", "paired")) return "unpaired";
        return d.transport orelse "unavailable";
    }
};

/// `xcrun devicectl list devices --json-output <file>` (argv after xcrun).
pub fn listArgv(a: std.mem.Allocator, xcrun: []const u8, json_out: []const u8) ![]const []const u8 {
    return a.dupe([]const u8, &.{ xcrun, "devicectl", "list", "devices", "--json-output", json_out });
}

/// Every iOS device (iPhone, iPad) in a `devicectl list devices` JSON
/// document, in the listed order. Strings borrow from `a`.
pub fn parseDevices(a: std.mem.Allocator, bytes: []const u8) ![]Device {
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch return error.InvalidDevicectlOutput;
    if (root != .object) return error.InvalidDevicectlOutput;
    const result = root.object.get("result") orelse return error.InvalidDevicectlOutput;
    if (result != .object) return error.InvalidDevicectlOutput;
    const entries = result.object.get("devices") orelse return error.InvalidDevicectlOutput;
    if (entries != .array) return error.InvalidDevicectlOutput;
    var found: std.ArrayList(Device) = .empty;
    for (entries.array.items) |item| {
        if (item != .object) return error.InvalidDevicectlOutput;
        const o = item.object;
        const hardware = sub(o, "hardwareProperties");
        const props = sub(o, "deviceProperties");
        const conn = sub(o, "connectionProperties");
        // iPadOS reports "iOS" too; watchOS, tvOS, visionOS and Macs cannot
        // run the app.
        if (!std.mem.eql(u8, str(hardware, "platform") orelse "", "iOS")) continue;
        try found.append(a, .{
            .identifier = str(o, "identifier") orelse return error.InvalidDevicectlOutput,
            .udid = str(hardware, "udid"),
            .name = str(props, "name") orelse str(hardware, "marketingName") orelse "iOS device",
            .model = str(hardware, "marketingName") orelse str(hardware, "productType"),
            .os_version = str(props, "osVersionNumber"),
            .transport = str(conn, "transportType"),
            .pairing = str(conn, "pairingState"),
            .developer_mode = str(props, "developerModeStatus"),
        });
    }
    return found.items;
}

fn sub(o: ?std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const map = o orelse return null;
    const v = map.get(key) orelse return null;
    return if (v == .object) v.object else null;
}

fn str(o: ?std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const map = o orelse return null;
    const v = map.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

pub const PickError = error{ NoDevice, SeveralDevices, NoSuchDevice };

/// The device to run on: `want` (an identifier, a UDID or a name) when
/// given; otherwise the one connected device. Several connected devices
/// need a choice.
pub fn pick(devices: []const Device, want: ?[]const u8) PickError!Device {
    if (want) |w| {
        for (devices) |d| if (std.ascii.eqlIgnoreCase(d.identifier, w)) return d;
        for (devices) |d| if (d.udid) |u| if (std.ascii.eqlIgnoreCase(u, w)) return d;
        for (devices) |d| if (std.mem.eql(u8, d.name, w)) return d;
        return error.NoSuchDevice;
    }
    var chosen: ?Device = null;
    for (devices) |d| {
        if (!d.connected()) continue;
        if (chosen != null) return error.SeveralDevices;
        chosen = d;
    }
    return chosen orelse error.NoDevice;
}

/// `xcrun devicectl device install app --device <id> <App>.app`.
pub fn installArgv(a: std.mem.Allocator, xcrun: []const u8, device: []const u8, app: []const u8) ![]const []const u8 {
    return a.dupe([]const u8, &.{ xcrun, "devicectl", "device", "install", "app", "--device", device, app });
}

/// `xcrun devicectl device process launch --device <id> --terminate-existing
/// --console [--environment-variables <json>] <bundle_id> [args...]`: the
/// run options reach the app as its environment (the device counterpart of
/// `SIMCTL_CHILD_*`).
pub fn launchArgv(a: std.mem.Allocator, xcrun: []const u8, device: []const u8, bundle_id: []const u8, env: []const contract.RunEnv, app_args: []const []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ xcrun, "devicectl", "device", "process", "launch", "--device", device, "--terminate-existing", "--console" });
    if (env.len > 0) {
        var out: std.Io.Writer.Allocating = .init(a);
        var jws: std.json.Stringify = .{ .writer = &out.writer };
        try jws.beginObject();
        for (env) |kv| {
            try jws.objectField(kv.name);
            try jws.write(kv.value);
        }
        try jws.endObject();
        try argv.appendSlice(a, &.{ "--environment-variables", out.written() });
    }
    try argv.append(a, bundle_id);
    try argv.appendSlice(a, app_args);
    return argv.items;
}

/// Whether this Xcode has devicectl (Xcode 15+): `xcrun --find devicectl`.
pub fn available(a: std.mem.Allocator, io: std.Io, xcrun: []const u8) bool {
    const r = proc.run(a, io, &.{ xcrun, "--find", "devicectl" }, .{}) catch return false;
    return proc.succeeded(r.term);
}

/// List the physical iOS devices: `devicectl list devices` writes its JSON
/// to `json_out` (removed afterwards), which is parsed.
pub fn list(a: std.mem.Allocator, io: std.Io, xcrun: []const u8, json_out: []const u8) ![]Device {
    defer std.Io.Dir.cwd().deleteFile(io, json_out) catch {};
    const r = proc.run(a, io, try listArgv(a, xcrun, json_out), .{}) catch |err| {
        std.debug.print("labelle-ios: could not list devices: xcrun did not start ({s})\n", .{@errorName(err)});
        return error.DevicectlFailed;
    };
    if (!proc.succeeded(r.term)) {
        std.debug.print("labelle-ios: `xcrun devicectl list devices` exited {d}:\n{s}{s}\n", .{ proc.status(r.term), r.stdout, r.stderr });
        return error.DevicectlFailed;
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, json_out, a, .limited(16 * 1024 * 1024));
    return parseDevices(a, bytes);
}

// ── Tests ─────────────────────────────────────────────────────────────────

/// Trimmed `xcrun devicectl list devices --json-output` (Xcode 16): a wired
/// iPhone, an unpaired iPad over the network, an offline iPhone and a watch.
pub const fixture =
    \\{
    \\  "info" : { "commandType" : "devicectl.list.devices", "outcome" : "success", "version" : "397.21" },
    \\  "result" : {
    \\    "devices" : [
    \\      { "identifier" : "5B4C4E0B-0000-4000-8000-00000000A001",
    \\        "connectionProperties" : { "pairingState" : "paired", "transportType" : "wired", "tunnelState" : "connected" },
    \\        "deviceProperties" : { "name" : "Jo's iPhone", "osVersionNumber" : "18.1", "developerModeStatus" : "enabled" },
    \\        "hardwareProperties" : { "platform" : "iOS", "deviceType" : "iPhone", "marketingName" : "iPhone 15 Pro", "productType" : "iPhone16,1", "udid" : "00008130-001234560E12001C" } },
    \\      { "identifier" : "5B4C4E0B-0000-4000-8000-00000000A002",
    \\        "connectionProperties" : { "pairingState" : "unpaired", "transportType" : "localNetwork" },
    \\        "deviceProperties" : { "name" : "Studio iPad", "osVersionNumber" : "17.6" },
    \\        "hardwareProperties" : { "platform" : "iOS", "deviceType" : "iPad", "productType" : "iPad13,1" } },
    \\      { "identifier" : "5B4C4E0B-0000-4000-8000-00000000A003",
    \\        "connectionProperties" : { "pairingState" : "paired", "tunnelState" : "unavailable" },
    \\        "deviceProperties" : { "name" : "Old iPhone" },
    \\        "hardwareProperties" : { "platform" : "iOS", "deviceType" : "iPhone" } },
    \\      { "identifier" : "5B4C4E0B-0000-4000-8000-00000000A004",
    \\        "connectionProperties" : { "pairingState" : "paired", "transportType" : "wired" },
    \\        "deviceProperties" : { "name" : "Watch" },
    \\        "hardwareProperties" : { "platform" : "watchOS" } }
    \\    ]
    \\  }
    \\}
;

test "parseDevices: iOS devices only, with their connection state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const devices = try parseDevices(arena.allocator(), fixture);
    try std.testing.expectEqual(@as(usize, 3), devices.len);
    try std.testing.expectEqualStrings("Jo's iPhone", devices[0].name);
    try std.testing.expectEqualStrings("iPhone 15 Pro", devices[0].model.?);
    try std.testing.expectEqualStrings("00008130-001234560E12001C", devices[0].udid.?);
    try std.testing.expect(devices[0].connected());
    try std.testing.expectEqualStrings("wired", devices[0].state());
    try std.testing.expectEqualStrings("iPad13,1", devices[1].model.?);
    try std.testing.expect(!devices[1].connected());
    try std.testing.expectEqualStrings("unpaired", devices[1].state());
    try std.testing.expectEqualStrings("unavailable", devices[2].state());
}

test "parseDevices refuses a document that is not a device listing; none is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "[]", "{}", "{\"result\": []}", "{\"result\": {\"devices\": [1]}}", "{\"result\": {\"devices\": [{\"hardwareProperties\": {\"platform\": \"iOS\"}}]}}" }) |bad| {
        try std.testing.expectError(error.InvalidDevicectlOutput, parseDevices(a, bad));
    }
    try std.testing.expectEqual(@as(usize, 0), (try parseDevices(a, "{\"result\": {\"devices\": []}}")).len);
}

test "pick: the one connected device; an identifier, UDID or name when asked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const devices = try parseDevices(arena.allocator(), fixture);
    try std.testing.expectEqualStrings("5B4C4E0B-0000-4000-8000-00000000A001", (try pick(devices, null)).identifier);
    try std.testing.expectEqualStrings("Studio iPad", (try pick(devices, "5b4c4e0b-0000-4000-8000-00000000a002")).name);
    try std.testing.expectEqualStrings("Jo's iPhone", (try pick(devices, "00008130-001234560E12001C")).name);
    try std.testing.expectEqualStrings("Old iPhone", (try pick(devices, "Old iPhone")).name);
    try std.testing.expectError(error.NoSuchDevice, pick(devices, "nope"));
    try std.testing.expectError(error.NoDevice, pick(devices[1..], null));
    var two = [_]Device{ devices[0], devices[0] };
    two[1].identifier = "other";
    try std.testing.expectError(error.SeveralDevices, pick(&two, null));
}

test "launchArgv: console launch, run options as the app's environment, app arguments last" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try launchArgv(a, "xcrun", "ID", "com.a.b", &.{ .{ .name = "LABELLE_SCENE", .value = "intro" }, .{ .name = "Q", .value = "a\"b" } }, &.{"--level=3"});
    const want = [_][]const u8{ "xcrun", "devicectl", "device", "process", "launch", "--device", "ID", "--terminate-existing", "--console", "--environment-variables", "{\"LABELLE_SCENE\":\"intro\",\"Q\":\"a\\\"b\"}", "com.a.b", "--level=3" };
    try std.testing.expectEqual(want.len, argv.len);
    for (want, argv) |w, g| try std.testing.expectEqualStrings(w, g);
    const bare = try launchArgv(a, "xcrun", "ID", "com.a.b", &.{}, &.{});
    try std.testing.expectEqualStrings("com.a.b", bare[bare.len - 1]);
    try std.testing.expect(std.mem.indexOf(u8, try std.mem.join(a, " ", bare), "--environment-variables") == null);
    const install = try installArgv(a, "xcrun", "ID", "/x/G.app");
    try std.testing.expectEqualStrings("/x/G.app", install[install.len - 1]);
}
