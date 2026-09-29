//! The `bundle` hook (replaces `bundle`): the `.app`, made again from this
//! build with `CFBundleVersion` = `labelle bundle --build-number` (and signed
//! again, since the signature seals Info.plist), archived into the bundle
//! output directory (`zig-out/bundle/ios/`, or `--output`):
//!
//!   - simulator: `<AppName>-simulator.zip`, the `.app` at the top;
//!   - device: `<AppName>.ipa`, the signed `.app` under `Payload/` (what
//!     `xcrun devicectl device install app`, Apple Configurator and TestFlight
//!     tooling take).
const std = @import("std");
const app_mod = @import("app.zig");
const settings_mod = @import("settings.zig");
const zip = @import("zip.zig");

/// The archive's file name for an app stem and destination.
pub fn archiveName(a: std.mem.Allocator, stem: []const u8, destination: settings_mod.Destination) ![]const u8 {
    return switch (destination) {
        .simulator => std.fmt.allocPrint(a, "{s}-simulator.zip", .{stem}),
        .device => std.fmt.allocPrint(a, "{s}.ipa", .{stem}),
    };
}

/// Where the `.app` sits inside the archive.
pub fn archivePrefix(a: std.mem.Allocator, app: []const u8, destination: settings_mod.Destination) ![]const u8 {
    return switch (destination) {
        .simulator => a.dupe(u8, app),
        .device => std.fmt.allocPrint(a, "Payload/{s}", .{app}),
    };
}

/// Make the app with the bundle's version and archive it into `output_dir`.
/// Returns the archive's path.
pub fn bundleHook(a: std.mem.Allocator, io: std.Io, in: app_mod.Inputs, output_dir: []const u8) ![]const u8 {
    const built = try app_mod.make(a, io, in);
    const name = built.record.app;
    const stem = name[0 .. name.len - ".app".len];
    const destination = built.record.destination;
    try std.Io.Dir.cwd().createDirPath(io, output_dir);
    const out = try std.fs.path.join(a, &.{ output_dir, try archiveName(a, stem, destination) });
    // Written beside the target and renamed, so `--output` never holds a
    // partial archive.
    const partial = try std.fmt.allocPrint(a, "{s}.partial", .{out});
    errdefer std.Io.Dir.cwd().deleteFile(io, partial) catch {};
    try zip.zipTree(a, io, built.path, try archivePrefix(a, name, destination), &.{built.record.executable}, partial);
    try std.Io.Dir.cwd().rename(partial, std.Io.Dir.cwd(), out, io);
    std.debug.print("labelle-ios: CFBundleVersion {d}\n", .{built.record.version});
    return out;
}

test "archive names and layout: a simulator zip, a device .ipa under Payload/" {
    const a = std.testing.allocator;
    const sim = try archiveName(a, "Game", .simulator);
    defer a.free(sim);
    try std.testing.expectEqualStrings("Game-simulator.zip", sim);
    const ipa = try archiveName(a, "Game", .device);
    defer a.free(ipa);
    try std.testing.expectEqualStrings("Game.ipa", ipa);
    const sim_prefix = try archivePrefix(a, "Game.app", .simulator);
    defer a.free(sim_prefix);
    try std.testing.expectEqualStrings("Game.app", sim_prefix);
    const dev_prefix = try archivePrefix(a, "Game.app", .device);
    defer a.free(dev_prefix);
    try std.testing.expectEqualStrings("Payload/Game.app", dev_prefix);
}

test "bundleHook: a device build becomes <App>.ipa with Payload/<App>.app" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "target/zig-out/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "target/zig-out/bin/game", .data = "EXE" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const json =
        \\{"schema_version": 1, "bundle_id": "com.a.b", "app_name": "Game", "destination": "device",
        \\ "signing": {"identity": "Apple Development: Jo", "profile": "dev.mobileprovision"}}
    ;
    var diag: settings_mod.Diagnostic = .{};
    var env = std.process.Environ.Map.init(a);
    const in: app_mod.Inputs = .{
        .project_dir = root,
        .target_dir = try std.fs.path.join(a, &.{ root, "target" }),
        .settings = try settings_mod.parse(a, json, &diag),
        .settings_bytes = json,
        .identity = .{ .name = "t", .title = "T" },
        .build_number = "7",
        .env = &env,
        .sign = false, // signing is covered in app.zig / signing.zig
        .host_macos = true,
    };
    const out = try bundleHook(a, io, in, try std.fs.path.join(a, &.{ root, "out" }));
    try std.testing.expectEqualStrings("Game.ipa", std.fs.path.basename(out));
    const bytes = try tmp.dir.readFileAlloc(io, "out/Game.ipa", a, .limited(1 << 20));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Payload/Game.app/Info.plist") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Payload/Game.app/game") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "<string>iPhoneOS</string>") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "out/Game-simulator.zip", .{}));
}
