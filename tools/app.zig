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
    identity: identity_mod.Identity,
    /// The environment tools (`codesign`) are looked up in.
    env: *const std.process.Environ.Map,
    /// Ad-hoc sign the bundle: on a macOS host, the only one with
    /// `codesign` and the only one that can run the simulator.
    sign: bool = builtin.os.tag == .macos,
};

pub const record_name = "app.json";
pub const icon_base = "AppIcon60x60";

/// What `zig-out/ios/<AppName>.app` was made from; the `launch` and `bundle`
/// hooks read it to find the app and to refuse one made with other settings.
pub const Record = struct {
    schema: u32 = 1,
    /// `<AppName>.app`, relative to `zig-out/ios/`.
    app: []const u8,
    bundle_id: []const u8,
    executable: []const u8,
    signed: bool,
};

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

/// Build `zig-out/ios/<AppName>.app` and its record. Returns the app path.
pub fn make(a: std.mem.Allocator, io: std.Io, in: Inputs) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    // First, so any refusal below leaves no app of an older build.
    const ios_dir = try iosDir(a, in.target_dir);
    try cwd.deleteTree(io, ios_dir);
    const bin_dir = try std.fs.path.join(a, &.{ in.target_dir, "zig-out", "bin" });
    const exe = try singleExecutable(try listExecutables(a, io, bin_dir), bin_dir);
    const app_name = settings_mod.appName(in.settings, in.identity.title);
    const bundle_name = try bundleDirName(a, app_name);
    const staging_root = try std.fs.path.join(a, &.{ ios_dir, try stagingName(a) });
    defer cwd.deleteTree(io, staging_root) catch {};
    const staged = try std.fs.path.join(a, &.{ staging_root, bundle_name });
    try cwd.createDirPath(io, staged);

    // The executable, permissions kept.
    try cwd.copyFile(try std.fs.path.join(a, &.{ bin_dir, exe }), cwd, try std.fs.path.join(a, &.{ staged, exe }), io, .{});

    // The icon, when the project names one.
    var icon: ?[]const u8 = null;
    if (in.identity.app_icon) |rel| {
        const src = if (std.fs.path.isAbsolute(rel)) rel else try std.fs.path.join(a, &.{ in.project_dir, rel });
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
    });
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ staged, "Info.plist" }), .data = info });
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ staged, "PkgInfo" }), .data = "APPL????" });

    const assets = try std.fs.path.join(a, &.{ in.target_dir, "assets" });
    if (cwd.access(io, assets, .{})) |_| {
        try copyTree(a, io, assets, try std.fs.path.join(a, &.{ staged, "assets" }));
    } else |_| {}

    const signed = if (in.sign) try adHocSign(a, io, in.env, staged) else blk: {
        std.debug.print("labelle-ios: note: {s} is not signed: codesign needs a macOS host\n", .{bundle_name});
        break :blk false;
    };

    const final = try std.fs.path.join(a, &.{ ios_dir, bundle_name });
    try cwd.rename(staged, cwd, final, io);
    const record: Record = .{ .app = bundle_name, .bundle_id = in.settings.bundle_id, .executable = exe, .signed = signed };
    const json = try std.json.Stringify.valueAlloc(a, record, .{ .whitespace = .indent_2 });
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(a, &.{ ios_dir, record_name }),
        .data = try std.fmt.allocPrint(a, "{s}\n", .{json}),
    });
    return final;
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

/// Read `zig-out/ios/app.json` and check it against the current settings:
/// the app exists and was made for this `bundle_id`. Returns the app path.
pub fn built(a: std.mem.Allocator, io: std.Io, target_dir: []const u8, bundle_id: []const u8) !struct { path: []const u8, record: Record } {
    const ios_dir = try iosDir(a, target_dir);
    const raw = std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ ios_dir, record_name }), a, .limited(64 * 1024)) catch {
        std.debug.print("labelle-ios: no app in {s}: run `labelle build --platform=ios` first\n", .{ios_dir});
        return error.NoBuiltApp;
    };
    const record = std.json.parseFromSliceLeaky(Record, a, raw, .{}) catch return error.NoBuiltApp;
    if (std.mem.indexOfAny(u8, record.app, "/\\") != null or !std.mem.endsWith(u8, record.app, ".app")) return error.NoBuiltApp;
    const path = try std.fs.path.join(a, &.{ ios_dir, record.app });
    std.Io.Dir.cwd().access(io, path, .{}) catch {
        std.debug.print("labelle-ios: {s} is missing: run `labelle build --platform=ios` first\n", .{path});
        return error.NoBuiltApp;
    };
    if (!std.mem.eql(u8, record.bundle_id, bundle_id)) {
        std.debug.print("labelle-ios: {s} was made for bundle_id {s}, not {s}: rebuild with `labelle build --platform=ios`\n", .{ path, record.bundle_id, bundle_id });
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

test "make: the bundle, its plist, icon and record; a rebuild replaces it" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    try tmp.dir.createDirPath(io, "target/zig-out/bin");
    try tmp.dir.createDirPath(io, "target/assets/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "target/zig-out/bin/game", .data = "EXE" });
    try tmp.dir.writeFile(io, .{ .sub_path = "target/assets/sub/a.txt", .data = "A" });
    try tmp.dir.writeFile(io, .{ .sub_path = "icon.png", .data = "\x89PNG\r\n\x1a\nDATA" });
    var env = std.process.Environ.Map.init(a);
    const in: Inputs = .{
        .project_dir = root,
        .target_dir = try std.fs.path.join(a, &.{ root, "target" }),
        .settings = .{ .schema_version = 1, .bundle_id = "com.labelle.test" },
        .identity = .{ .name = "t", .title = "My Game", .app_icon = "icon.png" },
        .env = &env,
        .sign = false, // the real codesign would refuse the fake executable
    };
    const app = try make(a, io, in);
    try std.testing.expectEqualStrings("My_Game.app", std.fs.path.basename(app));
    try std.testing.expectEqualStrings("EXE", try tmp.dir.readFileAlloc(io, "target/zig-out/ios/My_Game.app/game", a, .limited(64)));
    try std.testing.expectEqualStrings("A", try tmp.dir.readFileAlloc(io, "target/zig-out/ios/My_Game.app/assets/sub/a.txt", a, .limited(64)));
    try std.testing.expect(isPng(try tmp.dir.readFileAlloc(io, "target/zig-out/ios/My_Game.app/AppIcon60x60@3x.png", a, .limited(64))));
    const info = try tmp.dir.readFileAlloc(io, "target/zig-out/ios/My_Game.app/Info.plist", a, .limited(1 << 16));
    try std.testing.expect(std.mem.indexOf(u8, info, "<string>My Game</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, info, "<string>AppIcon60x60</string>") != null);
    const got = try built(a, io, in.target_dir, "com.labelle.test");
    try std.testing.expectEqualStrings("game", got.record.executable);
    try std.testing.expectError(error.StaleApp, built(a, io, in.target_dir, "com.labelle.other"));

    // A failing rebuild (two executables) leaves no app behind.
    try tmp.dir.writeFile(io, .{ .sub_path = "target/zig-out/bin/other", .data = "" });
    try std.testing.expectError(error.AmbiguousExecutable, make(a, io, in));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "target/zig-out/ios/My_Game.app", .{}));
    try std.testing.expectError(error.NoBuiltApp, built(a, io, in.target_dir, "com.labelle.test"));
}

test "make: a non-PNG app_icon is refused" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    try tmp.dir.createDirPath(io, "target/zig-out/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "target/zig-out/bin/game", .data = "EXE" });
    try tmp.dir.writeFile(io, .{ .sub_path = "icon.jpg", .data = "JFIF" });
    var env = std.process.Environ.Map.init(a);
    try std.testing.expectError(error.InvalidAppIcon, make(a, io, .{
        .project_dir = root,
        .target_dir = try std.fs.path.join(a, &.{ root, "target" }),
        .settings = .{ .schema_version = 1, .bundle_id = "com.labelle.test" },
        .identity = .{ .name = "t", .app_icon = "icon.jpg" },
        .env = &env,
        .sign = false,
    }));
}
