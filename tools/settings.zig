//! `providers/ios.json`, schema v1: the iOS settings a project gives this
//! provider through `.provider_config` (RFC labelle-cli#471 I1). It replaces
//! the CLI's `project.labelle .ios` block.
//!
//! The parse is strict: unknown keys, duplicate keys and wrong types are
//! errors, nested blocks included. Validation runs before any side effect, so
//! a bad file stops the hook before anything is written or launched.
const std = @import("std");

pub const schema_version = 1;

/// `UILaunchScreen` (the storyboard-free launch screen) needs iOS 14.
pub const minimum_ios_floor = 14;

pub const Orientation = enum {
    portrait,
    /// Landscape, either direction (iOS has no single-direction lock in
    /// `UISupportedInterfaceOrientations` that games want).
    landscape,
    /// Same plist as `landscape` on iOS; accepted so one orientation value
    /// can be shared with `providers/android.json`.
    sensor_landscape,
    all,
};

pub const Destination = enum { simulator, device };

pub const Simulator = struct {
    /// A simulator UDID or device name (`"iPhone 16"`); null picks one.
    device: ?[]const u8 = null,
};

pub const Settings = struct {
    schema_version: u32,
    bundle_id: []const u8,
    /// Defaults to the project's `.title`.
    app_name: ?[]const u8 = null,
    /// Apple Developer Team ID: validated now, used by device signing (v0.2).
    team_id: ?[]const u8 = null,
    minimum_ios: []const u8 = "15.0",
    orientation: Orientation = .all,
    /// `UIDeviceFamily`: `"1"` iPhone, `"2"` iPad, `"1,2"` both.
    device_family: []const u8 = "1,2",
    simulator: Simulator = .{},
    destination: Destination = .simulator,
};

pub const Error = error{
    InvalidSettings,
    OutOfMemory,
};

/// Why a settings file was refused, for the user.
pub const Diagnostic = struct {
    message: []const u8 = "",
};

/// Parse and validate a settings document. `diag.message` explains a
/// refusal (allocated in `a`). The result borrows from `a`.
pub fn parse(a: std.mem.Allocator, bytes: []const u8, diag: *Diagnostic) Error!Settings {
    // Name the keys a typed decode would only report as `UnknownField`.
    const raw = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch |err| return fail(a, diag, "not a valid JSON document ({s})", .{@errorName(err)});
    const object = switch (raw) {
        .object => |object| object,
        else => return fail(a, diag, "the top level must be a JSON object", .{}),
    };
    for (object.keys()) |key| {
        if (!isField(Settings, key)) return fail(a, diag, "unknown key '{s}'", .{key});
    }
    if (object.get("schema_version")) |version| {
        if (version != .integer or version.integer != schema_version)
            return fail(a, diag, "schema_version must be {d}", .{schema_version});
    } else return fail(a, diag, "missing required key 'schema_version'", .{});
    if (object.get("simulator")) |sim| {
        if (sim == .object) for (sim.object.keys()) |key| {
            if (!isField(Simulator, key)) return fail(a, diag, "unknown key 'simulator.{s}'", .{key});
        };
    }
    // Answered before the typed decode, so the v0.2 value gets its own
    // message rather than a generic schema error.
    if (object.get("destination")) |dest| {
        if (dest == .string and std.mem.eql(u8, dest.string, "device"))
            return fail(a, diag, "destination \"device\" is not supported yet: device builds arrive in v0.2 (use \"simulator\")", .{});
    }

    const settings = std.json.parseFromSliceLeaky(Settings, a, bytes, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    }) catch |err| return fail(a, diag, "does not match schema v1: {s} (a required key is missing, a key has the wrong type, or a value is out of range)", .{@errorName(err)});
    try validate(a, settings, diag);
    return settings;
}

/// Every rule a typed decode cannot express.
pub fn validate(a: std.mem.Allocator, s: Settings, diag: *Diagnostic) Error!void {
    if (s.schema_version != schema_version) return fail(a, diag, "schema_version must be {d}", .{schema_version});
    if (!bundleId(s.bundle_id))
        return fail(a, diag, "bundle_id '{s}' is not a valid bundle identifier (reverse-DNS: letters, digits, '-' and '.', e.g. com.studio.game)", .{s.bundle_id});
    if (s.app_name) |name| {
        if (!displayText(name)) return fail(a, diag, "app_name must be non-empty text without control characters", .{});
    }
    if (s.team_id) |team| {
        if (!teamId(team)) return fail(a, diag, "team_id '{s}' must be a 10-character Apple Team ID (A-Z, 0-9)", .{team});
    }
    const ios = osVersion(s.minimum_ios) orelse
        return fail(a, diag, "minimum_ios '{s}' must be a version like \"15.0\"", .{s.minimum_ios});
    if (ios < minimum_ios_floor)
        return fail(a, diag, "minimum_ios must be at least {d}.0 (the storyboard-free launch screen needs it)", .{minimum_ios_floor});
    if (!deviceFamily(s.device_family))
        return fail(a, diag, "device_family must be \"1\" (iPhone), \"2\" (iPad) or \"1,2\"", .{});
    if (s.simulator.device) |device| {
        if (!displayText(device)) return fail(a, diag, "simulator.device must be a simulator UDID or name", .{});
    }
    if (s.destination == .device)
        return fail(a, diag, "destination \"device\" is not supported yet: device builds arrive in v0.2 (use \"simulator\")", .{});
}

/// The name the home screen shows: `app_name`, else the project's title.
pub fn appName(s: Settings, project_title: []const u8) []const u8 {
    return s.app_name orelse project_title;
}

fn fail(a: std.mem.Allocator, diag: *Diagnostic, comptime fmt: []const u8, args: anytype) Error {
    diag.message = try std.fmt.allocPrint(a, fmt, args);
    return error.InvalidSettings;
}

fn isField(comptime T: type, key: []const u8) bool {
    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, key)) return true;
    }
    return false;
}

/// A `CFBundleIdentifier`: at least two dot-separated segments of
/// `[A-Za-z0-9-]`, the first starting with a letter.
pub fn bundleId(value: []const u8) bool {
    if (value.len == 0 or value.len > 155) return false;
    var segments: usize = 0;
    var it = std.mem.splitScalar(u8, value, '.');
    while (it.next()) |segment| {
        if (segment.len == 0) return false;
        if (segments == 0 and !std.ascii.isAlphabetic(segment[0])) return false;
        for (segment) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '-')) return false;
        }
        segments += 1;
    }
    return segments >= 2;
}

/// Ten uppercase letters or digits.
pub fn teamId(value: []const u8) bool {
    if (value.len != 10) return false;
    for (value) |c| {
        if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c))) return false;
    }
    return true;
}

/// The major version of `N.N[.N]`, or null when malformed.
pub fn osVersion(value: []const u8) ?u32 {
    var parts: usize = 0;
    var major: u32 = 0;
    var it = std.mem.splitScalar(u8, value, '.');
    while (it.next()) |part| {
        if (part.len == 0 or part.len > 3) return null;
        const n = std.fmt.parseInt(u32, part, 10) catch return null;
        if (!std.ascii.isDigit(part[0])) return null;
        if (parts == 0) major = n;
        parts += 1;
    }
    if (parts < 2 or parts > 3) return null;
    return major;
}

fn deviceFamily(value: []const u8) bool {
    for ([_][]const u8{ "1", "2", "1,2" }) |ok| {
        if (std.mem.eql(u8, value, ok)) return true;
    }
    return false;
}

pub fn displayText(value: []const u8) bool {
    if (std.mem.trim(u8, value, " \t").len == 0) return false;
    for (value) |c| {
        if (std.ascii.isControl(c)) return false;
    }
    return true;
}

// ── Tests ─────────────────────────────────────────────────────────────────

const full =
    \\{
    \\  "schema_version": 1,
    \\  "app_name": "Flying Platform",
    \\  "bundle_id": "com.labelle.flying-platform",
    \\  "team_id": "ABCDE12345",
    \\  "minimum_ios": "16.4",
    \\  "orientation": "landscape",
    \\  "device_family": "2",
    \\  "simulator": { "device": "iPhone 16" },
    \\  "destination": "simulator"
    \\}
;

test "the full schema parses into typed settings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const s = try parse(arena.allocator(), full, &diag);
    try std.testing.expectEqualStrings("com.labelle.flying-platform", s.bundle_id);
    try std.testing.expectEqualStrings("Flying Platform", appName(s, "Title"));
    try std.testing.expectEqualStrings("ABCDE12345", s.team_id.?);
    try std.testing.expectEqualStrings("16.4", s.minimum_ios);
    try std.testing.expectEqual(Orientation.landscape, s.orientation);
    try std.testing.expectEqualStrings("2", s.device_family);
    try std.testing.expectEqualStrings("iPhone 16", s.simulator.device.?);
    try std.testing.expectEqual(Destination.simulator, s.destination);
}

test "a minimal file gets the v1 defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const s = try parse(arena.allocator(), "{\"schema_version\": 1, \"bundle_id\": \"com.studio.game\"}", &diag);
    try std.testing.expectEqualStrings("15.0", s.minimum_ios);
    try std.testing.expectEqual(Orientation.all, s.orientation);
    try std.testing.expectEqualStrings("1,2", s.device_family);
    try std.testing.expect(s.simulator.device == null and s.team_id == null and s.app_name == null);
    try std.testing.expectEqual(Destination.simulator, s.destination);
    try std.testing.expectEqualStrings("Project Title", appName(s, "Project Title"));
    // An explicit null device is the default.
    const n = try parse(arena.allocator(), "{\"schema_version\": 1, \"bundle_id\": \"com.a\", \"simulator\": {\"device\": null}}", &diag);
    try std.testing.expect(n.simulator.device == null);
}

test "every rejection names its reason" {
    const Case = struct { json: []const u8, reason: []const u8 };
    const cases = [_]Case{
        // Structure.
        .{ .json = "[]", .reason = "top level" },
        .{ .json = "{", .reason = "not a valid JSON" },
        .{ .json = "{\"bundle_id\": \"com.a.b\"}", .reason = "missing required key 'schema_version'" },
        .{ .json = "{\"schema_version\": 2, \"bundle_id\": \"com.a.b\"}", .reason = "schema_version must be 1" },
        .{ .json = "{\"schema_version\": \"1\", \"bundle_id\": \"com.a.b\"}", .reason = "schema_version must be 1" },
        .{ .json = "{\"schema_version\": 1}", .reason = "MissingField" },
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"com.a.b\", \"typo\": 1}", .reason = "unknown key 'typo'" },
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"com.a.b\", \"package_name\": \"com.a.b\"}", .reason = "unknown key 'package_name'" },
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"com.a.b\", \"bundle_id\": \"com.a.c\"}", .reason = "DuplicateField" },
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"com.a.b\", \"orientation\": \"sideways\"}", .reason = "InvalidEnumTag" },
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": 7}", .reason = "UnexpectedToken" },
        // Nested blocks are strict too.
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"com.a.b\", \"simulator\": {\"udid\": \"x\"}}", .reason = "unknown key 'simulator.udid'" },
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"com.a.b\", \"simulator\": \"iPhone\"}", .reason = "does not match schema v1" },
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"com.a.b\", \"simulator\": {\"device\": \" \"}}", .reason = "simulator.device" },
        // Destination: simulator only in v0.1.
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"com.a.b\", \"destination\": \"device\"}", .reason = "device builds arrive in v0.2" },
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"com.a.b\", \"destination\": \"cloud\"}", .reason = "InvalidEnumTag" },
        // Bundle identifier.
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"game\"}", .reason = "bundle_id 'game'" },
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"\"}", .reason = "bundle_id" },
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"com..b\"}", .reason = "bundle_id" },
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"com.a_b\"}", .reason = "bundle_id" },
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"1com.a\"}", .reason = "bundle_id" },
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"com.a.\"}", .reason = "bundle_id" },
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"com.a b\"}", .reason = "bundle_id" },
        // Text and ids.
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"com.a.b\", \"app_name\": \" \"}", .reason = "app_name" },
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"com.a.b\", \"app_name\": \"a\\nb\"}", .reason = "app_name" },
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"com.a.b\", \"team_id\": \"abcde12345\"}", .reason = "team_id 'abcde12345'" },
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"com.a.b\", \"team_id\": \"ABC\"}", .reason = "team_id" },
        // Versions and families.
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"com.a.b\", \"minimum_ios\": \"15\"}", .reason = "minimum_ios '15'" },
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"com.a.b\", \"minimum_ios\": \"v15.0\"}", .reason = "minimum_ios" },
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"com.a.b\", \"minimum_ios\": \"13.0\"}", .reason = "at least 14.0" },
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"com.a.b\", \"device_family\": \"3\"}", .reason = "device_family" },
        .{ .json = "{\"schema_version\": 1, \"bundle_id\": \"com.a.b\", \"device_family\": \"2,1\"}", .reason = "device_family" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var diag: Diagnostic = .{};
        const result = parse(arena.allocator(), case.json, &diag);
        if (result) |_| {
            std.debug.print("accepted: {s}\n", .{case.json});
            return error.TestUnexpectedResult;
        } else |err| try std.testing.expectEqual(error.InvalidSettings, err);
        if (std.mem.indexOf(u8, diag.message, case.reason) == null) {
            std.debug.print("case {s}\n  expected reason containing '{s}', got '{s}'\n", .{ case.json, case.reason, diag.message });
            return error.TestUnexpectedResult;
        }
    }
}

test "bundleId follows the CFBundleIdentifier rule" {
    for ([_][]const u8{ "com.a", "com.labelle.flying-platform", "io.Studio.Game2", "a.b.c.d", "com.1up" }) |ok| try std.testing.expect(bundleId(ok));
    for ([_][]const u8{ "", "com", "com.", ".com", "com..a", "com.a_b", "com.a b", "1.a", "-a.b", "com.a/b" }) |bad| try std.testing.expect(!bundleId(bad));
}

test "osVersion reads N.N and N.N.N majors" {
    try std.testing.expectEqual(@as(?u32, 15), osVersion("15.0"));
    try std.testing.expectEqual(@as(?u32, 17), osVersion("17.2.1"));
    for ([_][]const u8{ "", "15", "15.", ".0", "15.0.0.0", "a.b", "+1.0", "1234.0" }) |bad| try std.testing.expect(osVersion(bad) == null);
}
