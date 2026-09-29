//! Device signing (`destination: "device"`): the `.app` the `app` hook
//! stages is signed with the project's identity and provisioning profile,
//! the way Xcode signs a development build:
//!
//!   1. `security cms -D -i <profile>` decodes the profile to a plist;
//!   2. `PlistBuddy` reads its `Entitlements:application-identifier`, which
//!      must cover `bundle_id` (and its team `team_id`, when set), and
//!      writes its `Entitlements` dictionary to a file;
//!   3. the profile is embedded as `<App>.app/embedded.mobileprovision`;
//!   4. `codesign --force --sign <identity> --entitlements <file>` signs it.
//!
//! The decoded profile and the entitlements live beside the bundle, never in
//! it (the signature seals the bundle). Every tool is looked up on PATH
//! (`PlistBuddy` falls back to `/usr/libexec/PlistBuddy`), which is also how
//! the tests put fakes in their place.
const std = @import("std");
const builtin = @import("builtin");
const settings_mod = @import("settings.zig");
const proc = @import("proc.zig");

pub const plist_buddy_fallback = "/usr/libexec/PlistBuddy";
pub const embedded_profile = "embedded.mobileprovision";

pub const Inputs = struct {
    /// The staged `<App>.app`.
    app: []const u8,
    /// A scratch directory outside the bundle, for the decoded profile and
    /// the entitlements.
    scratch: []const u8,
    project_dir: []const u8,
    settings: settings_mod.Settings,
    env: *const std.process.Environ.Map,
};

/// The profile's path: `signing.profile` relative to the project, or as
/// given when absolute.
pub fn profilePath(a: std.mem.Allocator, project_dir: []const u8, profile: []const u8) ![]const u8 {
    return if (std.fs.path.isAbsolute(profile)) a.dupe(u8, profile) else std.fs.path.join(a, &.{ project_dir, profile });
}

/// The team part of an `application-identifier` (`ABCDE12345.com.a.b`).
pub fn teamOf(app_id: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, app_id, '.') orelse return app_id;
    return app_id[0..dot];
}

/// Whether a profile's `application-identifier` covers `bundle_id`: exactly
/// (`TEAM.com.a.b`), or a wildcard (`TEAM.*`, `TEAM.com.a.*`).
pub fn appIdMatches(app_id: []const u8, bundle_id: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, app_id, '.') orelse return false;
    const pattern = app_id[dot + 1 ..];
    if (std.mem.eql(u8, pattern, "*")) return true;
    if (std.mem.endsWith(u8, pattern, ".*")) {
        const prefix = pattern[0 .. pattern.len - 1]; // keeps the dot
        return std.mem.startsWith(u8, bundle_id, prefix) and bundle_id.len > prefix.len;
    }
    return std.mem.eql(u8, pattern, bundle_id);
}

/// `codesign` for a device build: the identity, the profile's entitlements,
/// no secure timestamp (a development build; offline-friendly) and the DER
/// entitlements iOS 15+ requires.
pub fn codesignArgv(a: std.mem.Allocator, codesign: []const u8, identity: []const u8, entitlements: []const u8, app: []const u8) ![]const []const u8 {
    return a.dupe([]const u8, &.{ codesign, "--force", "--sign", identity, "--entitlements", entitlements, "--timestamp=none", "--generate-entitlement-der", app });
}

fn tool(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, name: []const u8) ![]const u8 {
    return (try proc.findOnPath(a, io, env, name)) orelse {
        std.debug.print("labelle-ios: {s} not found on PATH: device signing needs macOS with Xcode\n", .{name});
        return error.SigningToolNotFound;
    };
}

fn plistBuddy(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ![]const u8 {
    if (try proc.findOnPath(a, io, env, "PlistBuddy")) |path| return path;
    std.Io.Dir.cwd().access(io, plist_buddy_fallback, .{}) catch {
        std.debug.print("labelle-ios: PlistBuddy not found ({s}): device signing needs macOS\n", .{plist_buddy_fallback});
        return error.SigningToolNotFound;
    };
    return plist_buddy_fallback;
}

/// Run one signing step; its stdout, or a diagnostic naming the step.
fn step(a: std.mem.Allocator, io: std.Io, argv: []const []const u8, what: []const u8) ![]const u8 {
    const result = proc.run(a, io, argv, .{}) catch |err| {
        std.debug.print("labelle-ios: could not {s}: {s} did not start ({s})\n", .{ what, argv[0], @errorName(err) });
        return error.SigningFailed;
    };
    if (!proc.succeeded(result.term)) {
        std.debug.print("labelle-ios: could not {s} (`{s}` exited {d}):\n{s}{s}\n", .{ what, std.fs.path.basename(argv[0]), proc.status(result.term), result.stdout, result.stderr });
        return error.SigningFailed;
    }
    return result.stdout;
}

/// Sign the staged device app. Settings were validated: a device build has
/// both `signing.identity` and `signing.profile`.
pub fn signDevice(a: std.mem.Allocator, io: std.Io, in: Inputs) !void {
    const identity = in.settings.signing.identity orelse return error.MissingSigningIdentity;
    const profile = try profilePath(a, in.project_dir, in.settings.signing.profile orelse return error.MissingSigningProfile);
    const cwd = std.Io.Dir.cwd();
    cwd.access(io, profile, .{}) catch {
        std.debug.print("labelle-ios: signing.profile '{s}' does not exist (download it from developer.apple.com or Xcode > Settings > Accounts)\n", .{profile});
        return error.MissingSigningProfile;
    };
    const security = try tool(a, io, in.env, "security");
    const buddy = try plistBuddy(a, io, in.env);
    const codesign = try tool(a, io, in.env, "codesign");

    try cwd.createDirPath(io, in.scratch);
    const decoded = try step(a, io, &.{ security, "cms", "-D", "-i", profile }, "decode the provisioning profile");
    const profile_plist = try std.fs.path.join(a, &.{ in.scratch, "profile.plist" });
    try cwd.writeFile(io, .{ .sub_path = profile_plist, .data = decoded });

    const app_id_raw = try step(a, io, &.{ buddy, "-c", "Print :Entitlements:application-identifier", profile_plist }, "read the profile's application-identifier");
    const app_id = std.mem.trim(u8, app_id_raw, " \t\r\n");
    if (!appIdMatches(app_id, in.settings.bundle_id)) {
        std.debug.print("labelle-ios: the provisioning profile is for '{s}', which does not cover bundle_id '{s}'\n", .{ app_id, in.settings.bundle_id });
        return error.ProfileMismatch;
    }
    if (in.settings.team_id) |team| {
        if (!std.mem.eql(u8, teamOf(app_id), team)) {
            std.debug.print("labelle-ios: the provisioning profile belongs to team {s}, but team_id is {s}\n", .{ teamOf(app_id), team });
            return error.ProfileMismatch;
        }
    }
    const entitlements_xml = try step(a, io, &.{ buddy, "-x", "-c", "Print :Entitlements", profile_plist }, "extract the profile's entitlements");
    const entitlements = try std.fs.path.join(a, &.{ in.scratch, "entitlements.plist" });
    try cwd.writeFile(io, .{ .sub_path = entitlements, .data = entitlements_xml });

    try cwd.copyFile(profile, cwd, try std.fs.path.join(a, &.{ in.app, embedded_profile }), io, .{});
    _ = try step(a, io, try codesignArgv(a, codesign, identity, entitlements, in.app), "sign the app for a device");
    std.debug.print("labelle-ios: signed for devices as '{s}' ({s})\n", .{ identity, app_id });
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "appIdMatches: exact, full wildcard and prefix wildcard" {
    try std.testing.expect(appIdMatches("ABCDE12345.com.a.game", "com.a.game"));
    try std.testing.expect(appIdMatches("ABCDE12345.*", "com.a.game"));
    try std.testing.expect(appIdMatches("ABCDE12345.com.a.*", "com.a.game"));
    try std.testing.expect(!appIdMatches("ABCDE12345.com.a.*", "com.a."));
    try std.testing.expect(!appIdMatches("ABCDE12345.com.a.*", "com.ab.game"));
    try std.testing.expect(!appIdMatches("ABCDE12345.com.a.other", "com.a.game"));
    try std.testing.expect(!appIdMatches("nodot", "com.a.game"));
    try std.testing.expectEqualStrings("ABCDE12345", teamOf("ABCDE12345.com.a.game"));
}

test "codesignArgv signs with the identity and the profile's entitlements" {
    const argv = try codesignArgv(std.testing.allocator, "codesign", "Apple Development: Jo", "/s/e.plist", "/s/G.app");
    defer std.testing.allocator.free(argv);
    try std.testing.expectEqualStrings("--sign", argv[2]);
    try std.testing.expectEqualStrings("Apple Development: Jo", argv[3]);
    try std.testing.expectEqualStrings("/s/e.plist", argv[5]);
    try std.testing.expectEqualStrings("/s/G.app", argv[argv.len - 1]);
}

/// Fake `security`, `PlistBuddy` and `codesign` on a PATH of their own, each
/// logging its argv to `<root>/log`. POSIX shell scripts.
pub const FakeTools = struct {
    root: []const u8,
    env: std.process.Environ.Map,

    pub fn init(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, app_id: []const u8) !FakeTools {
        const root = try dir.realPathFileAlloc(io, ".", a);
        try dir.createDirPath(io, "fakebin");
        const scripts = [_]struct { name: []const u8, body: []const u8 }{
            .{ .name = "security", .body = "printf '<plist>decoded</plist>'\n" },
            .{ .name = "PlistBuddy", .body = try std.fmt.allocPrint(a,
                \\case "$*" in
                \\  *"Print :Entitlements:application-identifier"*) echo "{s}" ;;
                \\  *"-x -c Print :Entitlements"*) printf '<plist><dict/></plist>' ;;
                \\  *) exit 3 ;;
                \\esac
                \\
            , .{app_id}) },
            .{ .name = "codesign", .body = "exit 0\n" },
        };
        for (scripts) |s| {
            const body = try std.fmt.allocPrint(a, "#!/bin/sh\necho \"{s} $*\" >> \"{s}/log\"\n{s}", .{ s.name, root, s.body });
            try dir.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ "fakebin", s.name }), .data = body, .flags = .{ .permissions = .executable_file } });
        }
        var env = std.process.Environ.Map.init(a);
        try env.put("PATH", try std.fs.path.join(a, &.{ root, "fakebin" }));
        return .{ .root = root, .env = env };
    }

    pub fn log(f: FakeTools, a: std.mem.Allocator, io: std.Io) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ f.root, "log" }), a, .limited(1 << 16)) catch "";
    }
};

fn deviceSettings(a: std.mem.Allocator, extra: []const u8) !settings_mod.Settings {
    var diag: settings_mod.Diagnostic = .{};
    const json = try std.fmt.allocPrint(a,
        \\{{"schema_version": 1, "bundle_id": "com.a.game", "destination": "device"{s},
        \\ "signing": {{"identity": "Apple Development: Jo", "profile": "dev.mobileprovision"}}}}
    , .{extra});
    return settings_mod.parse(a, json, &diag);
}

test "signDevice: decode, check, embed, sign (fake tools)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fake = try FakeTools.init(a, io, tmp.dir, "ABCDE12345.com.a.*");
    try tmp.dir.createDirPath(io, "G.app");
    try tmp.dir.writeFile(io, .{ .sub_path = "dev.mobileprovision", .data = "PROFILE" });
    const in: Inputs = .{
        .app = try std.fs.path.join(a, &.{ fake.root, "G.app" }),
        .scratch = try std.fs.path.join(a, &.{ fake.root, "scratch" }),
        .project_dir = fake.root,
        .settings = try deviceSettings(a, ", \"team_id\": \"ABCDE12345\""),
        .env = &fake.env,
    };
    try signDevice(a, io, in);
    try std.testing.expectEqualStrings("PROFILE", try tmp.dir.readFileAlloc(io, "G.app/embedded.mobileprovision", a, .limited(64)));
    try std.testing.expectEqualStrings("<plist><dict/></plist>", try tmp.dir.readFileAlloc(io, "scratch/entitlements.plist", a, .limited(64)));
    const log = try fake.log(a, io);
    try std.testing.expect(std.mem.indexOf(u8, log, "security cms -D -i ") != null);
    const sign_line = try std.fmt.allocPrint(a, "codesign --force --sign Apple Development: Jo --entitlements {s}/scratch/entitlements.plist --timestamp=none --generate-entitlement-der {s}/G.app", .{ fake.root, fake.root });
    try std.testing.expect(std.mem.indexOf(u8, log, sign_line) != null);
}

test "signDevice: a profile for another app or team, or a missing profile, is refused before signing" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { app_id: []const u8, extra: []const u8, profile: bool, want: anyerror }{
        .{ .app_id = "ABCDE12345.com.other.game", .extra = "", .profile = true, .want = error.ProfileMismatch },
        .{ .app_id = "ZZZZZ99999.*", .extra = ", \"team_id\": \"ABCDE12345\"", .profile = true, .want = error.ProfileMismatch },
        .{ .app_id = "ABCDE12345.*", .extra = "", .profile = false, .want = error.MissingSigningProfile },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var fake = try FakeTools.init(a, io, tmp.dir, case.app_id);
        try tmp.dir.createDirPath(io, "G.app");
        if (case.profile) try tmp.dir.writeFile(io, .{ .sub_path = "dev.mobileprovision", .data = "PROFILE" });
        const in: Inputs = .{
            .app = try std.fs.path.join(a, &.{ fake.root, "G.app" }),
            .scratch = try std.fs.path.join(a, &.{ fake.root, "scratch" }),
            .project_dir = fake.root,
            .settings = try deviceSettings(a, case.extra),
            .env = &fake.env,
        };
        try std.testing.expectError(case.want, signDevice(a, io, in));
        try std.testing.expect(std.mem.indexOf(u8, try fake.log(a, io), "codesign") == null);
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "G.app/embedded.mobileprovision", .{}));
    }
}
