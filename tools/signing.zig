//! Device signing (`destination: "device"`): the `.app` the `app` hook
//! stages is signed with the project's identity and provisioning profile,
//! the way Xcode signs a development build:
//!
//!   1. `security cms -D -i <profile>` decodes the profile to a plist;
//!   2. `PlistBuddy` reads its `Entitlements:application-identifier`, which
//!      must cover `bundle_id`, and its `TeamIdentifier`, which must be
//!      `team_id` when set (the App ID prefix may be a legacy one, not the
//!      team);
//!   3. the identity's certificate (SHA-1, from `security find-identity`)
//!      must be one of the profile's `DeveloperCertificates`, or the device
//!      would refuse the app that `codesign` happily signs;
//!   4. its `Entitlements` dictionary is written to a file, a wildcard
//!      profile's `application-identifier` and `keychain-access-groups`
//!      expanded to the concrete `<prefix>.<bundle_id>`, as Xcode does
//!      (installd refuses a `TEAM.*` entitlement);
//!   5. the profile is embedded as `<App>.app/embedded.mobileprovision`;
//!   6. `codesign --force --sign <identity> --entitlements <file>` signs it.
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

/// A wildcard entitlement value (`TEAM.*`, `TEAM.com.a.*`) as the concrete
/// App ID `<prefix>.<bundle_id>`; null when the value has no wildcard.
pub fn expandWildcard(a: std.mem.Allocator, value: []const u8, bundle_id: []const u8) !?[]const u8 {
    if (!std.mem.endsWith(u8, value, "*")) return null;
    return try std.fmt.allocPrint(a, "{s}.{s}", .{ teamOf(value), bundle_id });
}

/// The entries of a PlistBuddy `Print` of an array of strings:
///
///     Array {
///         ABCDE12345.*
///     }
pub fn parseArray(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var inside = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!inside) {
            if (std.mem.startsWith(u8, line, "Array {")) inside = true;
            continue;
        }
        if (std.mem.eql(u8, line, "}")) break;
        if (line.len > 0) try out.append(a, line);
    }
    return out.items;
}

/// The upper-case hex SHA-1 of every `<data>` certificate in a PlistBuddy
/// `-x Print :DeveloperCertificates` document.
pub fn certificateSha1s(a: std.mem.Allocator, xml: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, xml, at, "<data>")) |open| {
        const start = open + "<data>".len;
        const close = std.mem.indexOfPos(u8, xml, start, "</data>") orelse return error.InvalidProfile;
        at = close + "</data>".len;
        var b64: std.ArrayList(u8) = .empty;
        for (xml[start..close]) |c| if (!std.ascii.isWhitespace(c)) try b64.append(a, c);
        const decoder = std.base64.standard.Decoder;
        const der = try a.alloc(u8, decoder.calcSizeForSlice(b64.items) catch return error.InvalidProfile);
        decoder.decode(der, b64.items) catch return error.InvalidProfile;
        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(der, &digest, .{});
        try out.append(a, try a.dupe(u8, &std.fmt.bytesToHex(digest, .upper)));
    }
    return out.items;
}

fn isSha1(value: []const u8) bool {
    if (value.len != 40) return false;
    for (value) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// The certificate SHA-1s `identity` names in `security find-identity -v -p
/// codesigning` output: itself when it is a SHA-1, else every listed
/// identity with exactly that name (`  1) <SHA-1> "<name>"`).
pub fn identitySha1s(a: std.mem.Allocator, listing: []const u8, identity: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (isSha1(identity)) {
        const upper = try a.dupe(u8, identity);
        for (upper) |*c| c.* = std.ascii.toUpper(c.*);
        try out.append(a, upper);
        return out.items;
    }
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const paren = std.mem.indexOf(u8, line, ") ") orelse continue;
        const rest = line[paren + 2 ..];
        if (rest.len < 43 or !isSha1(rest[0..40]) or rest[40] != ' ' or rest[41] != '"') continue;
        const name = rest[42..];
        if (name.len == 0 or name[name.len - 1] != '"') continue;
        if (std.mem.eql(u8, name[0 .. name.len - 1], identity)) try out.append(a, rest[0..40]);
    }
    return out.items;
}

/// Run a step whose failure means "absent" (a missing plist key): its
/// trimmed stdout, or null.
fn optional(a: std.mem.Allocator, io: std.Io, argv: []const []const u8) ?[]const u8 {
    const result = proc.run(a, io, argv, .{}) catch return null;
    if (!proc.succeeded(result.term)) return null;
    const value = std.mem.trim(u8, result.stdout, " \t\r\n");
    return if (value.len == 0) null else value;
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
        // The team, not the App ID prefix: an old account's prefix differs.
        const profile_team = optional(a, io, &.{ buddy, "-c", "Print :TeamIdentifier:0", profile_plist }) orelse
            optional(a, io, &.{ buddy, "-c", "Print :Entitlements:com.apple.developer.team-identifier", profile_plist }) orelse {
            std.debug.print("labelle-ios: the provisioning profile names no TeamIdentifier, so it cannot be checked against team_id {s}\n", .{team});
            return error.ProfileMismatch;
        };
        if (!std.mem.eql(u8, profile_team, team)) {
            std.debug.print("labelle-ios: the provisioning profile belongs to team {s}, but team_id is {s}\n", .{ profile_team, team });
            return error.ProfileMismatch;
        }
    }

    // The profile must authorize the identity's certificate.
    const certs_xml = try step(a, io, &.{ buddy, "-x", "-c", "Print :DeveloperCertificates", profile_plist }, "read the profile's certificates");
    const authorized = try certificateSha1s(a, certs_xml);
    const listing = try step(a, io, &.{ security, "find-identity", "-v", "-p", "codesigning" }, "list the codesigning identities");
    const chosen = try identitySha1s(a, listing, identity);
    if (chosen.len == 0) {
        std.debug.print("labelle-ios: signing.identity '{s}' is not a valid codesigning identity in the keychain (list them with `security find-identity -v -p codesigning`)\n", .{identity});
        return error.SigningIdentityNotFound;
    }
    var covered = false;
    for (chosen) |sha| {
        for (authorized) |cert| covered = covered or std.mem.eql(u8, sha, cert);
    }
    if (!covered) {
        std.debug.print("labelle-ios: the provisioning profile does not include the certificate of '{s}' ({s}); regenerate the profile with that certificate, or pick one of its identities\n", .{ identity, chosen[0] });
        return error.ProfileMismatch;
    }

    const entitlements_xml = try step(a, io, &.{ buddy, "-x", "-c", "Print :Entitlements", profile_plist }, "extract the profile's entitlements");
    const entitlements = try std.fs.path.join(a, &.{ in.scratch, "entitlements.plist" });
    try cwd.writeFile(io, .{ .sub_path = entitlements, .data = entitlements_xml });
    // A wildcard profile: sign with the concrete App ID, as Xcode does.
    if (try expandWildcard(a, app_id, in.settings.bundle_id)) |concrete| {
        _ = try step(a, io, &.{ buddy, "-c", try std.fmt.allocPrint(a, "Set :application-identifier {s}", .{concrete}), entitlements }, "set the app's application-identifier");
    }
    if (optional(a, io, &.{ buddy, "-c", "Print :keychain-access-groups", entitlements })) |groups| {
        for (try parseArray(a, groups), 0..) |group, i| {
            const concrete = (try expandWildcard(a, group, in.settings.bundle_id)) orelse continue;
            _ = try step(a, io, &.{ buddy, "-c", try std.fmt.allocPrint(a, "Set :keychain-access-groups:{d} {s}", .{ i, concrete }), entitlements }, "set the app's keychain access group");
        }
    }

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

    pub const Options = struct {
        /// The profile's `Entitlements:application-identifier`.
        app_id: []const u8 = "ABCDE12345.com.a.game",
        /// The profile's `TeamIdentifier`; null: the key is absent.
        team: ?[]const u8 = "ABCDE12345",
        /// The certificate (DER bytes) the profile authorizes.
        profile_cert: []const u8 = "CERT-JO",
        /// The keychain identity: its name and certificate.
        identity: []const u8 = "Apple Development: Jo",
        identity_cert: []const u8 = "CERT-JO",
        /// The entitlements' keychain-access-groups; null: absent.
        keychain_group: ?[]const u8 = null,
    };

    pub fn init(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, o: Options) !FakeTools {
        const root = try dir.realPathFileAlloc(io, ".", a);
        try dir.createDirPath(io, "fakebin");
        const enc = std.base64.standard.Encoder;
        const cert_b64 = try a.alloc(u8, enc.calcSize(o.profile_cert.len));
        _ = enc.encode(cert_b64, o.profile_cert);
        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(o.identity_cert, &digest, .{});
        const team_line = if (o.team) |t| try std.fmt.allocPrint(a, "echo \"{s}\"", .{t}) else "exit 1";
        const keychain_line = if (o.keychain_group) |g| try std.fmt.allocPrint(a, "printf 'Array {{\\n    {s}\\n}}\\n'", .{g}) else "exit 1";
        const scripts = [_]struct { name: []const u8, body: []const u8 }{
            .{ .name = "security", .body = try std.fmt.allocPrint(a,
                \\case "$1" in
                \\  find-identity) echo '  1) {s} "{s}"'; echo '     1 valid identities found' ;;
                \\  *) printf '<plist>decoded</plist>' ;;
                \\esac
                \\
            , .{ std.fmt.bytesToHex(digest, .upper), o.identity }) },
            .{ .name = "PlistBuddy", .body = try std.fmt.allocPrint(a,
                \\case "$*" in
                \\  *"Print :Entitlements:application-identifier"*) echo "{s}" ;;
                \\  *"Print :TeamIdentifier:0"*) {s} ;;
                \\  *"Print :Entitlements:com.apple.developer.team-identifier"*) exit 1 ;;
                \\  *"-x -c Print :DeveloperCertificates"*) printf '<plist><array><data>\n{s}\n</data></array></plist>' ;;
                \\  *"-x -c Print :Entitlements"*) printf '<plist><dict/></plist>' ;;
                \\  *"Print :keychain-access-groups"*) {s} ;;
                \\  *"Set :"*) exit 0 ;;
                \\  *) exit 3 ;;
                \\esac
                \\
            , .{ o.app_id, team_line, cert_b64, keychain_line }) },
            .{ .name = "codesign", .body = "exit 0\n" },
        };
        for (scripts) |sc| {
            const body = try std.fmt.allocPrint(a, "#!/bin/sh\necho \"{s} $*\" >> \"{s}/log\"\n{s}", .{ sc.name, root, sc.body });
            try dir.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ "fakebin", sc.name }), .data = body, .flags = .{ .permissions = .executable_file } });
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

fn signIn(a: std.mem.Allocator, fake: *FakeTools, extra: []const u8) !Inputs {
    return .{
        .app = try std.fs.path.join(a, &.{ fake.root, "G.app" }),
        .scratch = try std.fs.path.join(a, &.{ fake.root, "scratch" }),
        .project_dir = fake.root,
        .settings = try deviceSettings(a, extra),
        .env = &fake.env,
    };
}

test "signDevice: decode, check, embed, sign (fake tools)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fake = try FakeTools.init(a, io, tmp.dir, .{ .app_id = "ABCDE12345.com.a.game" });
    try tmp.dir.createDirPath(io, "G.app");
    try tmp.dir.writeFile(io, .{ .sub_path = "dev.mobileprovision", .data = "PROFILE" });
    try signDevice(a, io, try signIn(a, &fake, ", \"team_id\": \"ABCDE12345\""));
    try std.testing.expectEqualStrings("PROFILE", try tmp.dir.readFileAlloc(io, "G.app/embedded.mobileprovision", a, .limited(64)));
    try std.testing.expectEqualStrings("<plist><dict/></plist>", try tmp.dir.readFileAlloc(io, "scratch/entitlements.plist", a, .limited(64)));
    const log = try fake.log(a, io);
    try std.testing.expect(std.mem.indexOf(u8, log, "security cms -D -i ") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "security find-identity -v -p codesigning") != null);
    // An exact App ID needs no rewrite.
    try std.testing.expect(std.mem.indexOf(u8, log, "Set :") == null);
    const sign_line = try std.fmt.allocPrint(a, "codesign --force --sign Apple Development: Jo --entitlements {s}/scratch/entitlements.plist --timestamp=none --generate-entitlement-der {s}/G.app", .{ fake.root, fake.root });
    try std.testing.expect(std.mem.indexOf(u8, log, sign_line) != null);
}

test "signDevice: a wildcard profile is signed with the concrete App ID and keychain group" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fake = try FakeTools.init(a, io, tmp.dir, .{ .app_id = "PREFIX0001.com.a.*", .keychain_group = "PREFIX0001.*" });
    try tmp.dir.createDirPath(io, "G.app");
    try tmp.dir.writeFile(io, .{ .sub_path = "dev.mobileprovision", .data = "PROFILE" });
    // The App ID prefix is a legacy one: the team comes from TeamIdentifier.
    try signDevice(a, io, try signIn(a, &fake, ", \"team_id\": \"ABCDE12345\""));
    const log = try fake.log(a, io);
    const ent = try std.fmt.allocPrint(a, "{s}/scratch/entitlements.plist", .{fake.root});
    try std.testing.expect(std.mem.indexOf(u8, log, try std.fmt.allocPrint(a, "PlistBuddy -c Set :application-identifier PREFIX0001.com.a.game {s}", .{ent})) != null);
    try std.testing.expect(std.mem.indexOf(u8, log, try std.fmt.allocPrint(a, "PlistBuddy -c Set :keychain-access-groups:0 PREFIX0001.com.a.game {s}", .{ent})) != null);
    // The rewrite happens before signing.
    try std.testing.expect(std.mem.indexOf(u8, log, "Set :application-identifier").? < std.mem.indexOf(u8, log, "codesign --force").?);
}

test "signDevice: a profile for another app, team or certificate, or a missing one, is refused before signing" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { opts: FakeTools.Options, extra: []const u8 = "", profile: bool = true, want: anyerror }{
        .{ .opts = .{ .app_id = "ABCDE12345.com.other.game" }, .want = error.ProfileMismatch },
        // TeamIdentifier decides, not the App ID prefix.
        .{ .opts = .{ .app_id = "ABCDE12345.*", .team = "ZZZZZ99999" }, .extra = ", \"team_id\": \"ABCDE12345\"", .want = error.ProfileMismatch },
        .{ .opts = .{ .app_id = "ABCDE12345.*", .team = null }, .extra = ", \"team_id\": \"ABCDE12345\"", .want = error.ProfileMismatch },
        // The identity's certificate is not in the profile.
        .{ .opts = .{ .identity_cert = "CERT-NEW" }, .want = error.ProfileMismatch },
        // The identity is not in the keychain.
        .{ .opts = .{ .identity = "Apple Development: Someone Else" }, .want = error.SigningIdentityNotFound },
        .{ .opts = .{}, .profile = false, .want = error.MissingSigningProfile },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var fake = try FakeTools.init(a, io, tmp.dir, case.opts);
        try tmp.dir.createDirPath(io, "G.app");
        if (case.profile) try tmp.dir.writeFile(io, .{ .sub_path = "dev.mobileprovision", .data = "PROFILE" });
        try std.testing.expectError(case.want, signDevice(a, io, try signIn(a, &fake, case.extra)));
        try std.testing.expect(std.mem.indexOf(u8, try fake.log(a, io), "codesign --force") == null);
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "G.app/embedded.mobileprovision", .{}));
    }
}

test "helpers: wildcard expansion, PlistBuddy arrays, certificate and identity SHA-1s" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("T.com.a.b", (try expandWildcard(a, "T.*", "com.a.b")).?);
    try std.testing.expectEqualStrings("T.com.a.b", (try expandWildcard(a, "T.com.a.*", "com.a.b")).?);
    try std.testing.expect(try expandWildcard(a, "T.com.a.b", "com.a.b") == null);

    const arr = try parseArray(a, "Array {\n    T.*\n    T.shared\n}\n");
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqualStrings("T.shared", arr[1]);

    // SHA-1("abc") = A9993E36...; base64("abc") = "YWJj".
    const shas = try certificateSha1s(a, "<plist><array>\n\t<data>\n\tYW\n\tJj\n\t</data>\n\t<data>YWJj</data></array></plist>");
    try std.testing.expectEqual(@as(usize, 2), shas.len);
    try std.testing.expectEqualStrings("A9993E364706816ABA3E25717850C26C9CD0D89D", shas[0]);
    try std.testing.expectError(error.InvalidProfile, certificateSha1s(a, "<data>YWJj"));

    const listing =
        \\  1) A9993E364706816ABA3E25717850C26C9CD0D89D "Apple Development: Jo (ABCDE12345)"
        \\  2) 0000000000000000000000000000000000000001 "Apple Distribution: Jo (ABCDE12345)"
        \\     2 valid identities found
    ;
    const by_name = try identitySha1s(a, listing, "Apple Development: Jo (ABCDE12345)");
    try std.testing.expectEqual(@as(usize, 1), by_name.len);
    try std.testing.expectEqualStrings("A9993E364706816ABA3E25717850C26C9CD0D89D", by_name[0]);
    try std.testing.expectEqualStrings("A9993E364706816ABA3E25717850C26C9CD0D89D", (try identitySha1s(a, "", "a9993e364706816aba3e25717850c26c9cd0d89d"))[0]);
    try std.testing.expectEqual(@as(usize, 0), (try identitySha1s(a, listing, "Apple Development: Jo")).len);
}
