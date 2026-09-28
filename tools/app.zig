//! The `app` hook (after `build`): wrap the core build's executable into a
//! simulator `.app` (ported from labelle-cli `src/cli/ios.zig`
//! `deployToSimulator`, origin/main e2e0e85, which did it at launch time).
//!
//! Layout, under the generated target directory `.labelle/<backend>_ios/`:
//!
//!   zig-out/bin/<exe>              the core build's output (input; exactly one)
//!   zig-out/ios/<AppName>.app/     this hook
//!       <exe>                      the executable, unchanged
//!       Info.plist                 `plist.zig`
//!       PkgInfo
//!       AppIcon60x60@2x.png, @3x   the project's `app_icon`, when it has one
//!       assets/                    `<target_dir>/assets`, when present
//!   zig-out/ios/app.json           what the `.app` was made from (`Record`)
//!
//! The previous `zig-out/ios/` is removed first and the bundle is staged and
//! renamed into place, so a failure leaves no `.app`: an older one is never
//! presented as this build's.
const std = @import("std");
const builtin = @import("builtin");
const settings_mod = @import("settings.zig");
const identity_mod = @import("project_identity.zig");
const plist = @import("plist.zig");
const proc = @import("proc.zig");

pub const Inputs = struct {
    project_dir: []const u8,
    target_dir: []const u8,
    settings: settings_mod.Settings,
    /// The raw `providers/ios.json`, for the record's digest: any change to
    /// it can change the bundle.
    settings_bytes: []const u8,
    identity: identity_mod.Identity,
    /// `labelle bundle --build-number`: stamped as `CFBundleVersion`
    /// (`bundleVersion`); null is 1.
    build_number: ?[]const u8 = null,
    /// The environment tools (`codesign`) are looked up in.
    env: *const std.process.Environ.Map,
    /// Ad-hoc sign the bundle: on a macOS host, the only one with
    /// `codesign` and the only one that can run the simulator.
    sign: bool = builtin.os.tag == .macos,
};

pub const record_name = "app.json";
pub const icon_base = "AppIcon60x60";

/// What `zig-out/ios/<AppName>.app` was made from; the `launch` hook reads
/// it to find the app and to refuse one that is no longer what this build
/// and these settings would make (`built`).
pub const Record = struct {
    schema: u32 = 2,
    /// `<AppName>.app`, relative to `zig-out/ios/`.
    app: []const u8,
    bundle_id: []const u8,
    executable: []const u8,
    /// SHA-256 of `zig-out/bin/<executable>` when the app was made.
    executable_sha256: []const u8,
    /// `inputsDigest`: the settings file, the resolved app name and the icon.
    inputs_sha256: []const u8,
    /// `CFBundleVersion`.
    version: u32,
    signed: bool,
};

pub const Built = struct { path: []const u8, record: Record };

/// `CFBundleVersion` from `--build-number`: a positive integer (absent
/// means 1). App Store Connect takes up to three period-separated integers;
/// v0.1 keeps the one the CLI and the Android provider share.
pub fn bundleVersion(build_number: ?[]const u8) !u32 {
    const text = build_number orelse return 1;
    const value = std.fmt.parseInt(u32, text, 10) catch 0;
    if (value == 0 or text[0] == '+') {
        std.debug.print("labelle-ios: --build-number '{s}' is not a CFBundleVersion here (a positive integer)\n", .{text});
        return error.InvalidBuildNumber;
    }
    return value;
}

/// The home-screen name: `app_name`, else the project `.title`, which then
/// has to pass the same rule an explicit `app_name` does (it is written into
/// Info.plist and names the bundle).
pub fn resolvedAppName(in: Inputs) ![]const u8 {
    if (in.settings.app_name) |name| return name;
    const title = in.identity.title;
    if (!settings_mod.displayText(title)) {
        std.debug.print("labelle-ios: the project .title is not usable as the app name (empty, or it has control characters): set \"app_name\" in providers/ios.json\n", .{});
        return error.InvalidAppName;
    }
    return title;
}

/// The project's `app_icon` path, when it names one.
fn iconPath(a: std.mem.Allocator, in: Inputs) !?[]const u8 {
    const rel = in.identity.app_icon orelse return null;
    return if (std.fs.path.isAbsolute(rel)) rel else try std.fs.path.join(a, &.{ in.project_dir, rel });
}

/// A digest of every input besides the executable that shapes the bundle:
/// the settings file byte for byte, the resolved app name (the project title
/// when `app_name` is absent) and the icon's path and bytes. The build
/// number is left out: it stamps a bundle, it does not make an app stale.
pub fn inputsDigest(a: std.mem.Allocator, io: std.Io, in: Inputs) ![]const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    const part = struct {
        fn add(hash: *std.crypto.hash.sha2.Sha256, label: []const u8, bytes: []const u8) void {
            var len: [8]u8 = undefined;
            std.mem.writeInt(u64, &len, bytes.len, .little);
            hash.update(label);
            hash.update(&len);
            hash.update(bytes);
        }
    }.add;
    part(&h, "settings", in.settings_bytes);
    part(&h, "app_name", try resolvedAppName(in));
    if (try iconPath(a, in)) |path| {
        part(&h, "icon_path", path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 * 1024 * 1024)) catch |err| @errorName(err);
        part(&h, "icon", bytes);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

/// The hex SHA-256 of the file at `path`, read through a fixed buffer.
pub fn fileSha256(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    while (true) {
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return reader.err.?,
        };
        hasher.update(chunk);
        reader.interface.toss(chunk.len);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

pub fn iosDir(a: std.mem.Allocator, target_dir: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ target_dir, "zig-out", "ios" });
}

/// `<AppName>.app` for a home-screen name: anything but ASCII letters,
/// digits, `-` and `_` becomes `_`, so the bundle path is portable.
pub fn bundleDirName(a: std.mem.Allocator, app_name: []const u8) ![]const u8 {
    const out = try a.alloc(u8, app_name.len + 4);
    for (app_name, 0..) |c, i| {
        out[i] = if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') c else '_';
    }
    @memcpy(out[app_name.len..], ".app");
    return out;
}

// ── Executable discovery ──────────────────────────────────────────────────

/// The regular files directly in `<target_dir>/zig-out/bin`, sorted.
pub fn listExecutables(a: std.mem.Allocator, io: std.Io, bin_dir: []const u8) ![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, bin_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return found.items,
        else => return err,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const kind = if (entry.kind == .unknown)
            (dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch continue).kind
        else
            entry.kind;
        if (kind != .file) continue;
        try found.append(a, try a.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, found.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    return found.items;
}

/// Exactly one executable, or an actionable refusal. The assembler names the
/// iOS executable `game` today (assembler#774) and after the project before
/// that; the hook takes whatever the build produced.
pub fn singleExecutable(names: []const []const u8, bin_dir: []const u8) ![]const u8 {
    if (names.len == 1) return names[0];
    if (names.len == 0) {
        std.debug.print("labelle-ios: no executable in {s}: the iOS build produced nothing to bundle\n", .{bin_dir});
        return error.NoExecutable;
    }
    std.debug.print("labelle-ios: {d} executables in {s}; an iOS app bundles exactly one:\n", .{ names.len, bin_dir });
    for (names) |name| std.debug.print("  {s}\n", .{name});
    // `zig build` never removes an install it no longer makes, so a renamed
    // executable leaves the old one behind.
    std.debug.print("  if some are left over from an older build, delete {s} and build again\n", .{bin_dir});
    return error.AmbiguousExecutable;
}

// ── The bundle ────────────────────────────────────────────────────────────

/// `staging-<pid>`: unique per process.
fn stagingName(a: std.mem.Allocator) ![]const u8 {
    const pid: u64 = switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        else => @intCast(std.c.getpid()),
    };
    return std.fmt.allocPrint(a, ".staging-{d}", .{pid});
}

/// Build `zig-out/ios/<AppName>.app` and its record.
pub fn make(a: std.mem.Allocator, io: std.Io, in: Inputs) !Built {
    const cwd = std.Io.Dir.cwd();
    // First, so any refusal below leaves no app of an older build.
    const ios_dir = try iosDir(a, in.target_dir);
    try cwd.deleteTree(io, ios_dir);
    const bin_dir = try std.fs.path.join(a, &.{ in.target_dir, "zig-out", "bin" });
    const exe = try singleExecutable(try listExecutables(a, io, bin_dir), bin_dir);
    const version = try bundleVersion(in.build_number);
    const app_name = try resolvedAppName(in);
    const inputs_sha256 = try inputsDigest(a, io, in);
    const bundle_name = try bundleDirName(a, app_name);
    const staging_root = try std.fs.path.join(a, &.{ ios_dir, try stagingName(a) });
    defer cwd.deleteTree(io, staging_root) catch {};
    const staged = try std.fs.path.join(a, &.{ staging_root, bundle_name });
    try cwd.createDirPath(io, staged);

    // The executable, permissions kept.
    const exe_src = try std.fs.path.join(a, &.{ bin_dir, exe });
    try cwd.copyFile(exe_src, cwd, try std.fs.path.join(a, &.{ staged, exe }), io, .{});
    const executable_sha256 = try fileSha256(a, io, exe_src);

    // The icon, when the project names one.
    var icon: ?[]const u8 = null;
    if (try iconPath(a, in)) |src| {
        const png = cwd.readFileAlloc(io, src, a, .limited(16 * 1024 * 1024)) catch |err| {
            std.debug.print("labelle-ios: app_icon '{s}' cannot be read: {s}\n", .{ src, @errorName(err) });
            return error.InvalidAppIcon;
        };
        if (!isPng(png)) {
            std.debug.print("labelle-ios: app_icon '{s}' is not a PNG\n", .{src});
            return error.InvalidAppIcon;
        }
        // Copied as-is under the names `CFBundleIconFiles` resolves: the
        // home screen scales it. Sized renditions and an asset catalog
        // (actool) come with device builds (v0.2).
        for ([_][]const u8{ "@2x", "@3x" }) |scale| {
            const name = try std.fmt.allocPrint(a, "{s}{s}.png", .{ icon_base, scale });
            try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ staged, name }), .data = png });
        }
        icon = icon_base;
    }

    const info = try plist.infoPlist(a, .{
        .bundle_id = in.settings.bundle_id,
        .app_name = app_name,
        .executable = exe,
        .minimum_ios = in.settings.minimum_ios,
        .orientation = in.settings.orientation,
        .device_family = in.settings.device_family,
        .icon = icon,
        .version = version,
    });
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ staged, "Info.plist" }), .data = info });
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ staged, "PkgInfo" }), .data = "APPL????" });

    const assets = try std.fs.path.join(a, &.{ in.target_dir, "assets" });
    // Absent is fine (not every project has assets); anything else that
    // stops us reading them fails the hook rather than ship an app without
    // them.
    if (cwd.access(io, assets, .{})) |_| {
        copyTree(a, io, assets, try std.fs.path.join(a, &.{ staged, "assets" })) catch |err| {
            std.debug.print("labelle-ios: cannot copy {s} into the app: {s}\n", .{ assets, @errorName(err) });
            return err;
        };
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => {
            std.debug.print("labelle-ios: cannot read {s}: {s}\n", .{ assets, @errorName(err) });
            return err;
        },
    }

    const signed = if (in.sign) try adHocSign(a, io, in.env, staged) else blk: {
        std.debug.print("labelle-ios: note: {s} is not signed: codesign needs a macOS host\n", .{bundle_name});
        break :blk false;
    };

    const final = try std.fs.path.join(a, &.{ ios_dir, bundle_name });
    try cwd.rename(staged, cwd, final, io);
    const record: Record = .{
        .app = bundle_name,
        .bundle_id = in.settings.bundle_id,
        .executable = exe,
        .executable_sha256 = executable_sha256,
        .inputs_sha256 = inputs_sha256,
        .version = version,
        .signed = signed,
    };
    const json = try std.json.Stringify.valueAlloc(a, record, .{ .whitespace = .indent_2 });
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(a, &.{ ios_dir, record_name }),
        .data = try std.fmt.allocPrint(a, "{s}\n", .{json}),
    });
    return .{ .path = final, .record = record };
}

pub fn isPng(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n");
}

/// Ad-hoc sign the bundle (`codesign --force --sign - --timestamp=none`), as
/// Xcode does for every simulator build: arm64 code must carry a signature,
/// and the signature seals Info.plist and the resources.
fn adHocSign(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, app: []const u8) !bool {
    const codesign = (try proc.findOnPath(a, io, env, "codesign")) orelse {
        std.debug.print("labelle-ios: codesign not found on PATH (install the Xcode command line tools)\n", .{});
        return error.CodesignNotFound;
    };
    const result = proc.run(a, io, &.{ codesign, "--force", "--sign", "-", "--timestamp=none", app }, .{}) catch |err| {
        std.debug.print("labelle-ios: codesign failed to start: {s}\n", .{@errorName(err)});
        return error.CodesignFailed;
    };
    if (!proc.succeeded(result.term)) {
        std.debug.print("labelle-ios: codesign failed: {s}{s}\n", .{ result.stdout, result.stderr });
        return error.CodesignFailed;
    }
    return true;
}

/// Copy the directory tree `src` to `dst` (created), regular files and
/// directories only.
fn copyTree(a: std.mem.Allocator, io: std.Io, src: []const u8, dst: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dst);
    var dir = try cwd.openDir(io, src, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        const to = try std.fs.path.join(a, &.{ dst, e.path });
        switch (e.kind) {
            .directory => try cwd.createDirPath(io, to),
            .file => try cwd.copyFile(try std.fs.path.join(a, &.{ src, e.path }), cwd, to, io, .{}),
            else => {},
        }
    }
}

/// Read `zig-out/ios/app.json` and check that the app is still what this
/// build and these inputs would make: the same executable (by content) and
/// the same `inputsDigest` (settings, app name, icon). Returns the app.
pub fn built(a: std.mem.Allocator, io: std.Io, in: Inputs) !Built {
    const ios_dir = try iosDir(a, in.target_dir);
    const raw = std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ ios_dir, record_name }), a, .limited(64 * 1024)) catch {
        std.debug.print("labelle-ios: no app in {s}: run `labelle build --platform=ios` first\n", .{ios_dir});
        return error.NoBuiltApp;
    };
    const record = std.json.parseFromSliceLeaky(Record, a, raw, .{}) catch {
        std.debug.print("labelle-ios: {s} is from another labelle-ios version: rebuild with `labelle build --platform=ios`\n", .{record_name});
        return error.StaleApp;
    };
    if (std.mem.indexOfAny(u8, record.app, "/\\") != null or !std.mem.endsWith(u8, record.app, ".app") or
        std.mem.indexOfAny(u8, record.executable, "/\\") != null) return error.NoBuiltApp;
    const path = try std.fs.path.join(a, &.{ ios_dir, record.app });
    std.Io.Dir.cwd().access(io, path, .{}) catch {
        std.debug.print("labelle-ios: {s} is missing: run `labelle build --platform=ios` first\n", .{path});
        return error.NoBuiltApp;
    };
    const exe = try std.fs.path.join(a, &.{ in.target_dir, "zig-out", "bin", record.executable });
    const exe_now = fileSha256(a, io, exe) catch "";
    if (!std.mem.eql(u8, exe_now, record.executable_sha256)) {
        std.debug.print("labelle-ios: {s} was made from an older build of {s}: rebuild with `labelle build --platform=ios`\n", .{ path, record.executable });
        return error.StaleApp;
    }
    if (!std.mem.eql(u8, try inputsDigest(a, io, in), record.inputs_sha256)) {
        std.debug.print("labelle-ios: {s} was made with other providers/ios.json settings, app name or icon: rebuild with `labelle build --platform=ios`\n", .{path});
        return error.StaleApp;
    }
    return .{ .path = path, .record = record };
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "singleExecutable: one wins; none and several are refused" {
    try std.testing.expectEqualStrings("game", try singleExecutable(&.{"game"}, "/b"));
    try std.testing.expectError(error.NoExecutable, singleExecutable(&.{}, "/b"));
    try std.testing.expectError(error.AmbiguousExecutable, singleExecutable(&.{ "game", "tool" }, "/b"));
}

test "listExecutables: regular files only, sorted; a missing bin dir is empty" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    try std.testing.expectEqual(@as(usize, 0), (try listExecutables(a, io, try std.fs.path.join(a, &.{ root, "nope" }))).len);
    try tmp.dir.createDirPath(io, "bin/game.dSYM/Contents");
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/zeta", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/game", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/.DS_Store", .data = "" });
    const names = try listExecutables(a, io, try std.fs.path.join(a, &.{ root, "bin" }));
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("game", names[0]);
    try std.testing.expectEqualStrings("zeta", names[1]);
}

test "bundleDirName keeps the bundle path portable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Flying_Platform.app", try bundleDirName(a, "Flying Platform"));
    try std.testing.expectEqualStrings("a-b_c_.app", try bundleDirName(a, "a-b_c/"));
}

/// A fixture: `target/zig-out/bin/game`, `target/assets/sub/a.txt` and
/// `icon.png` under a temporary project directory.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,
    root: []const u8,

    fn init(a: std.mem.Allocator) !Fixture {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        try tmp.dir.createDirPath(io, "target/zig-out/bin");
        try tmp.dir.createDirPath(io, "target/assets/sub");
        try tmp.dir.writeFile(io, .{ .sub_path = "target/zig-out/bin/game", .data = "EXE" });
        try tmp.dir.writeFile(io, .{ .sub_path = "target/assets/sub/a.txt", .data = "A" });
        try tmp.dir.writeFile(io, .{ .sub_path = "icon.png", .data = "\x89PNG\r\n\x1a\nDATA" });
        return .{ .tmp = tmp, .env = std.process.Environ.Map.init(a), .root = try tmp.dir.realPathFileAlloc(io, ".", a) };
    }

    fn inputs(f: *Fixture, a: std.mem.Allocator, settings_json: []const u8) !Inputs {
        var diag: settings_mod.Diagnostic = .{};
        return .{
            .project_dir = f.root,
            .target_dir = try std.fs.path.join(a, &.{ f.root, "target" }),
            .settings = try settings_mod.parse(a, settings_json, &diag),
            .settings_bytes = settings_json,
            .identity = .{ .name = "t", .title = "My Game", .app_icon = "icon.png" },
            .env = &f.env,
            .sign = false, // the real codesign would refuse the fake executable
        };
    }
};

const test_settings = "{\"schema_version\": 1, \"bundle_id\": \"com.labelle.test\"}";

test "make: the bundle, its plist, icon and record; a rebuild replaces it" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    defer f.tmp.cleanup();
    const tmp = f.tmp;
    const in = try f.inputs(a, test_settings);
    const app = try make(a, io, in);
    try std.testing.expectEqualStrings("My_Game.app", std.fs.path.basename(app.path));
    try std.testing.expectEqual(@as(u32, 1), app.record.version);
    try std.testing.expectEqualStrings("EXE", try tmp.dir.readFileAlloc(io, "target/zig-out/ios/My_Game.app/game", a, .limited(64)));
    try std.testing.expectEqualStrings("A", try tmp.dir.readFileAlloc(io, "target/zig-out/ios/My_Game.app/assets/sub/a.txt", a, .limited(64)));
    try std.testing.expect(isPng(try tmp.dir.readFileAlloc(io, "target/zig-out/ios/My_Game.app/AppIcon60x60@3x.png", a, .limited(64))));
    const info = try tmp.dir.readFileAlloc(io, "target/zig-out/ios/My_Game.app/Info.plist", a, .limited(1 << 16));
    try std.testing.expect(std.mem.indexOf(u8, info, "<string>My Game</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, info, "<string>AppIcon60x60</string>") != null);
    const got = try built(a, io, in);
    try std.testing.expectEqualStrings("game", got.record.executable);

    // A failing rebuild (two executables) leaves no app behind.
    try tmp.dir.writeFile(io, .{ .sub_path = "target/zig-out/bin/other", .data = "" });
    try std.testing.expectError(error.AmbiguousExecutable, make(a, io, in));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "target/zig-out/ios/My_Game.app", .{}));
    try std.testing.expectError(error.NoBuiltApp, built(a, io, in));
}

test "built: any change to what shapes the bundle makes the app stale until it is made again" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    defer f.tmp.cleanup();
    const in = try f.inputs(a, test_settings);
    _ = try make(a, io, in);
    _ = try built(a, io, in);

    // Settings that keep the bundle_id but change the app: stale...
    const landscape = try f.inputs(a, "{\"schema_version\": 1, \"bundle_id\": \"com.labelle.test\", \"orientation\": \"landscape\"}");
    try std.testing.expectError(error.StaleApp, built(a, io, landscape));
    // ...until the app is made again, now with the new plist.
    const again = try make(a, io, landscape);
    _ = try built(a, io, landscape);
    const info = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ again.path, "Info.plist" }), a, .limited(1 << 16));
    try std.testing.expect(std.mem.indexOf(u8, info, "UIInterfaceOrientationPortrait") == null);
    try std.testing.expectError(error.StaleApp, built(a, io, in));

    // A new project title (the fallback name) and a new icon: stale too.
    var retitled = landscape;
    retitled.identity.title = "Other Game";
    try std.testing.expectError(error.StaleApp, built(a, io, retitled));
    try f.tmp.dir.writeFile(io, .{ .sub_path = "icon.png", .data = "\x89PNG\r\n\x1a\nNEW" });
    try std.testing.expectError(error.StaleApp, built(a, io, landscape));
    _ = try make(a, io, landscape);
    _ = try built(a, io, landscape);

    // A rebuilt executable: stale.
    try f.tmp.dir.writeFile(io, .{ .sub_path = "target/zig-out/bin/game", .data = "REBUILT" });
    try std.testing.expectError(error.StaleApp, built(a, io, landscape));
}

test "bundleVersion: absent is 1; a positive integer; nothing else" {
    try std.testing.expectEqual(@as(u32, 1), try bundleVersion(null));
    try std.testing.expectEqual(@as(u32, 7), try bundleVersion("7"));
    try std.testing.expectEqual(@as(u32, 4294967295), try bundleVersion("4294967295"));
    for ([_][]const u8{ "0", "", "-1", "+3", "1.2", "x", "4294967296" }) |bad| {
        try std.testing.expectError(error.InvalidBuildNumber, bundleVersion(bad));
    }
}

test "make: --build-number stamps CFBundleVersion and the record" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    defer f.tmp.cleanup();
    var in = try f.inputs(a, test_settings);
    in.build_number = "42";
    const app = try make(a, io, in);
    try std.testing.expectEqual(@as(u32, 42), app.record.version);
    const info = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ app.path, "Info.plist" }), a, .limited(1 << 16));
    try std.testing.expect(std.mem.indexOf(u8, info, "<key>CFBundleVersion</key>\n    <string>42</string>") != null);
    // The build number does not make the app stale.
    in.build_number = null;
    _ = try built(a, io, in);
    in.build_number = "0";
    try std.testing.expectError(error.InvalidBuildNumber, make(a, io, in));
}

test "make: the project title falls back only when it is a valid app name, and is escaped" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    defer f.tmp.cleanup();
    var in = try f.inputs(a, test_settings);
    for ([_][]const u8{ "", "  ", "Bad\x01Title", "Bad\x00", "Tab\ttitle\n" }) |bad| {
        in.identity.title = bad;
        try std.testing.expectError(error.InvalidAppName, make(a, io, in));
    }
    // An explicit app_name is used instead of an unusable title.
    var named = try f.inputs(a, "{\"schema_version\": 1, \"bundle_id\": \"com.labelle.test\", \"app_name\": \"Named\"}");
    named.identity.title = "Bad\x01Title";
    try std.testing.expectEqualStrings("Named.app", std.fs.path.basename((try make(a, io, named)).path));
    // A valid title with XML specials is escaped in the plist.
    in.identity.title = "Cats & <Dogs>";
    const app = try make(a, io, in);
    const info = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ app.path, "Info.plist" }), a, .limited(1 << 16));
    try std.testing.expect(std.mem.indexOf(u8, info, "<string>Cats &amp; &lt;Dogs&gt;</string>") != null);
}

test "make: an unreadable assets/ fails the hook instead of shipping without it" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    defer f.tmp.cleanup();
    const in = try f.inputs(a, test_settings);
    // `assets` that is not a directory: the copy's error, not "no assets".
    try f.tmp.dir.deleteTree(io, "target/assets");
    try f.tmp.dir.writeFile(io, .{ .sub_path = "target/assets", .data = "not a dir" });
    try std.testing.expectError(error.NotDir, make(a, io, in));
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "target/zig-out/ios/My_Game.app", .{}));
    if (builtin.os.tag != .windows) {
        // An `assets` that cannot even be checked (a symlink loop): its own
        // error, not "no assets".
        try f.tmp.dir.deleteFile(io, "target/assets");
        try f.tmp.dir.symLink(io, "assets", "target/assets", .{});
        try std.testing.expectError(error.SymLinkLoop, make(a, io, in));
    }
    // Absent: fine.
    try f.tmp.dir.deleteFile(io, "target/assets");
    _ = try make(a, io, in);
}

test "make: a non-PNG app_icon is refused" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    defer f.tmp.cleanup();
    try f.tmp.dir.writeFile(io, .{ .sub_path = "icon.jpg", .data = "JFIF" });
    var in = try f.inputs(a, test_settings);
    in.identity.app_icon = "icon.jpg";
    try std.testing.expectError(error.InvalidAppIcon, make(a, io, in));
}
