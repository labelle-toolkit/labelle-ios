//! The `bundle` hook (replaces `bundle`): the simulator `.app` the `app` hook
//! made, zipped into the bundle output directory (`zig-out/bundle/ios/`, or
//! `labelle bundle --output`) as `<AppName>-simulator.zip`. A device `.ipa`
//! (signed) is v0.2.
const std = @import("std");
const app_mod = @import("app.zig");
const zip = @import("zip.zig");

/// Zip the built app into `output_dir`. Returns the archive's path.
pub fn bundleHook(a: std.mem.Allocator, io: std.Io, target_dir: []const u8, output_dir: []const u8, bundle_id: []const u8) ![]const u8 {
    const built = try app_mod.built(a, io, target_dir, bundle_id);
    const name = built.record.app;
    const stem = name[0 .. name.len - ".app".len];
    try std.Io.Dir.cwd().createDirPath(io, output_dir);
    const out = try std.fs.path.join(a, &.{ output_dir, try std.fmt.allocPrint(a, "{s}-simulator.zip", .{stem}) });
    // Written beside the target and renamed, so `--output` never holds a
    // partial archive.
    const partial = try std.fmt.allocPrint(a, "{s}.partial", .{out});
    errdefer std.Io.Dir.cwd().deleteFile(io, partial) catch {};
    try zip.zipTree(a, io, built.path, name, &.{built.record.executable}, partial);
    try std.Io.Dir.cwd().rename(partial, std.Io.Dir.cwd(), out, io);
    return out;
}
