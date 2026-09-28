//! A minimal, deterministic zip writer for the `bundle` hook: one directory
//! tree (the `.app`) stored under a prefix, every entry uncompressed
//! ("stored"), UTF-8 names, fixed 1980-01-01 timestamps and Unix modes, so
//! `unzip`/`ditto -x -k` restore the executable bit. std has no zip writer,
//! and the tool must stay std-only (`zig build --system`).
//!
//! Limits (refused, never silently truncated): 65535 entries and 4 GiB per
//! file or archive (no zip64).
const std = @import("std");

const local_sig: u32 = 0x04034b50;
const central_sig: u32 = 0x02014b50;
const end_sig: u32 = 0x06054b50;
/// 2.0: directories and stored files.
const version_needed: u16 = 20;
/// Upper byte 3 = Unix, so the external attributes carry a Unix mode.
const version_made_by: u16 = (3 << 8) | 20;
/// General purpose bit 11: names are UTF-8.
const flag_utf8: u16 = 0x0800;
/// MS-DOS date for 1980-01-01 (the epoch of the format); time 00:00:00.
const dos_date: u16 = (0 << 9) | (1 << 5) | 1;
const dos_time: u16 = 0;

const Central = struct {
    name: []const u8,
    crc: u32,
    size: u32,
    mode: u32,
    offset: u32,
    dir: bool,
};

pub const Entry = struct {
    /// Relative to the zipped root, '/'-separated.
    path: []const u8,
    dir: bool,
};

/// Every entry under `root`, sorted by path ('/'-separated), directories
/// included. Symlinks and other special files are refused: an `.app` built
/// by `app.zig` has none.
pub fn listTree(a: std.mem.Allocator, io: std.Io, root: []const u8) ![]Entry {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    var entries: std.ArrayList(Entry) = .empty;
    while (try walker.next(io)) |e| {
        const path = try a.dupe(u8, e.path);
        std.mem.replaceScalar(u8, path, '\\', '/');
        switch (e.kind) {
            .directory => try entries.append(a, .{ .path = path, .dir = true }),
            .file => try entries.append(a, .{ .path = path, .dir = false }),
            else => {
                std.debug.print("labelle-ios: cannot zip '{s}': only regular files and directories are bundled\n", .{path});
                return error.UnsupportedFileKind;
            },
        }
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, x: Entry, y: Entry) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lessThan);
    return entries.items;
}

/// Zip the tree at `root` into `out_path`, each entry named
/// `<prefix>/<path>`, preceded by a `<prefix>/` directory entry. Files whose
/// path is in `executables` get mode 0755 (on every host: Windows has no
/// executable bit to read); every other file 0644, directories 0755.
pub fn zipTree(a: std.mem.Allocator, io: std.Io, root: []const u8, prefix: []const u8, executables: []const []const u8, out_path: []const u8) !void {
    return zipTreeHooked(a, io, root, prefix, executables, out_path, .{});
}

/// Test seam: runs between a file's checksum pass and its copy pass.
pub const Hooks = struct {
    between_passes: ?struct { ctx: *anyopaque, run: *const fn (*anyopaque, []const u8) anyerror!void } = null,
};

pub fn zipTreeHooked(a: std.mem.Allocator, io: std.Io, root: []const u8, prefix: []const u8, executables: []const []const u8, out_path: []const u8, hooks: Hooks) !void {
    const entries = try listTree(a, io, root);
    if (entries.len + 1 > std.math.maxInt(u16)) return error.TooManyZipEntries;

    var out = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer out.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = out.writer(io, &buf);
    // File contents pass through this buffer only: nothing proportional to
    // a file's size is allocated, whatever the app holds.
    var chunk: [64 * 1024]u8 = undefined;
    const w = &fw.interface;

    var central: std.ArrayList(Central) = .empty;
    var offset: u64 = 0;
    const top = try std.fmt.allocPrint(a, "{s}/", .{prefix});
    offset += try writeHeader(w, top, 0, 0);
    try central.append(a, .{ .name = top, .crc = 0, .size = 0, .mode = 0o40755, .offset = 0, .dir = true });
    for (entries) |e| {
        const at = std.math.cast(u32, offset) orelse return error.ZipTooLarge;
        if (e.dir) {
            const name = try std.fmt.allocPrint(a, "{s}/{s}/", .{ prefix, e.path });
            offset += try writeHeader(w, name, 0, 0);
            try central.append(a, .{ .name = name, .crc = 0, .size = 0, .mode = 0o40755, .offset = at, .dir = true });
            continue;
        }
        const name = try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, e.path });
        const native = try std.fs.path.join(a, &.{ root, e.path });
        // Two streaming passes: the CRC and size the local header needs
        // first, then the bytes.
        const sum = try checksum(io, native, &chunk);
        if (hooks.between_passes) |h| try h.run(h.ctx, native);
        offset += try writeHeader(w, name, sum.size, sum.crc);
        try copyExactly(io, native, w, &chunk, sum);
        offset += sum.size;
        const mode: u32 = if (contains(executables, e.path)) 0o100755 else 0o100644;
        try central.append(a, .{ .name = name, .crc = sum.crc, .size = sum.size, .mode = mode, .offset = at, .dir = false });
    }

    const cd_start = std.math.cast(u32, offset) orelse return error.ZipTooLarge;
    var cd_size: u64 = 0;
    for (central.items) |c| {
        try w.writeInt(u32, central_sig, .little);
        try w.writeInt(u16, version_made_by, .little);
        try w.writeInt(u16, version_needed, .little);
        try w.writeInt(u16, flag_utf8, .little);
        try w.writeInt(u16, 0, .little); // stored
        try w.writeInt(u16, dos_time, .little);
        try w.writeInt(u16, dos_date, .little);
        try w.writeInt(u32, c.crc, .little);
        try w.writeInt(u32, c.size, .little);
        try w.writeInt(u32, c.size, .little);
        try w.writeInt(u16, @intCast(c.name.len), .little);
        try w.writeInt(u16, 0, .little); // extra
        try w.writeInt(u16, 0, .little); // comment
        try w.writeInt(u16, 0, .little); // disk
        try w.writeInt(u16, 0, .little); // internal attributes
        // Unix mode in the high half; MS-DOS directory bit for directories.
        try w.writeInt(u32, (c.mode << 16) | @as(u32, if (c.dir) 0x10 else 0), .little);
        try w.writeInt(u32, c.offset, .little);
        try w.writeAll(c.name);
        cd_size += 46 + c.name.len;
    }
    const count: u16 = @intCast(central.items.len);
    try w.writeInt(u32, end_sig, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, count, .little);
    try w.writeInt(u16, count, .little);
    try w.writeInt(u32, std.math.cast(u32, cd_size) orelse return error.ZipTooLarge, .little);
    try w.writeInt(u32, cd_start, .little);
    try w.writeInt(u16, 0, .little); // comment
    try w.flush();
}

const Sum = struct { crc: u32, size: u32 };

/// CRC-32 and size of the file at `path`, read through `chunk`.
fn checksum(io: std.Io, path: []const u8, chunk: []u8) !Sum {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var crc = std.hash.Crc32.init();
    var size: u64 = 0;
    while (true) {
        const n = file.readStreaming(io, &.{chunk}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        crc.update(chunk[0..n]);
        size += n;
    }
    return .{ .crc = crc.final(), .size = std.math.cast(u32, size) orelse return error.ZipTooLarge };
}

/// Copy the file at `path` into `w` through `chunk`. It must still be what
/// the checksum pass saw, the size AND the CRC the header already promised:
/// a file rewritten in between, even at the same length, fails the bundle
/// instead of producing an archive whose entry does not match its header.
fn copyExactly(io: std.Io, path: []const u8, w: *std.Io.Writer, chunk: []u8, sum: Sum) !void {
    const size = sum.size;
    var crc = std.hash.Crc32.init();
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var copied: u64 = 0;
    while (true) {
        const n = file.readStreaming(io, &.{chunk}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        copied += n;
        if (copied > size) return changed(path);
        crc.update(chunk[0..n]);
        try w.writeAll(chunk[0..n]);
    }
    if (copied != size or crc.final() != sum.crc) return changed(path);
}

fn changed(path: []const u8) error{FileChangedWhileZipping} {
    std.debug.print("labelle-ios: {s} changed while it was being zipped; bundle again\n", .{path});
    return error.FileChangedWhileZipping;
}

/// A local file header for an entry of `size` stored bytes; the data follows.
fn writeHeader(w: *std.Io.Writer, name: []const u8, size: u32, crc: u32) !u64 {
    if (name.len > std.math.maxInt(u16)) return error.ZipNameTooLong;
    try w.writeInt(u32, local_sig, .little);
    try w.writeInt(u16, version_needed, .little);
    try w.writeInt(u16, flag_utf8, .little);
    try w.writeInt(u16, 0, .little); // stored
    try w.writeInt(u16, dos_time, .little);
    try w.writeInt(u16, dos_date, .little);
    try w.writeInt(u32, crc, .little);
    try w.writeInt(u32, size, .little);
    try w.writeInt(u32, size, .little);
    try w.writeInt(u16, @intCast(name.len), .little);
    try w.writeInt(u16, 0, .little);
    try w.writeAll(name);
    return 30 + name.len;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, item)) return true;
    }
    return false;
}

// ── Tests ─────────────────────────────────────────────────────────────────

const U16 = struct {
    fn at(b: []const u8, i: usize) u16 {
        return std.mem.readInt(u16, b[i..][0..2], .little);
    }
};

fn u32At(b: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, b[i..][0..4], .little);
}

test "zipTree: a stored, sorted, prefixed archive with Unix modes" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Game.app/assets");
    try tmp.dir.writeFile(io, .{ .sub_path = "Game.app/game", .data = "MACHO" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Game.app/Info.plist", .data = "<plist/>" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Game.app/assets/a.txt", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, "Game.app", a);
    const out = try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(io, ".", a), "Game.zip" });
    try zipTree(a, io, root, "Game.app", &.{"game"}, out);

    const z = try std.Io.Dir.cwd().readFileAlloc(io, out, a, .limited(1 << 20));
    // End of central directory: 5 entries (the prefix dir, assets/, 3 files).
    const eocd = z.len - 22;
    try std.testing.expectEqual(end_sig, u32At(z, eocd));
    try std.testing.expectEqual(@as(u16, 5), U16.at(z, eocd + 10));
    // Walk the central directory: names, sorted, modes and CRCs.
    var i: usize = u32At(z, eocd + 16);
    const want = [_]struct { name: []const u8, mode: u32, data: []const u8 }{
        .{ .name = "Game.app/", .mode = 0o40755, .data = "" },
        .{ .name = "Game.app/Info.plist", .mode = 0o100644, .data = "<plist/>" },
        .{ .name = "Game.app/assets/", .mode = 0o40755, .data = "" },
        .{ .name = "Game.app/assets/a.txt", .mode = 0o100644, .data = "" },
        .{ .name = "Game.app/game", .mode = 0o100755, .data = "MACHO" },
    };
    for (want) |e| {
        try std.testing.expectEqual(central_sig, u32At(z, i));
        try std.testing.expectEqual(@as(u16, 0), U16.at(z, i + 10)); // stored
        const crc = u32At(z, i + 16);
        const size = u32At(z, i + 24);
        const name_len = U16.at(z, i + 28);
        const mode = u32At(z, i + 38) >> 16;
        const local = u32At(z, i + 42);
        const name = z[i + 46 ..][0..name_len];
        try std.testing.expectEqualStrings(e.name, name);
        try std.testing.expectEqual(e.mode, mode);
        try std.testing.expectEqual(@as(u32, @intCast(e.data.len)), size);
        try std.testing.expectEqual(std.hash.Crc32.hash(e.data), crc);
        // The local header names the same entry, and its data follows it.
        try std.testing.expectEqual(local_sig, u32At(z, local));
        try std.testing.expectEqualStrings(e.name, z[local + 30 ..][0..name_len]);
        try std.testing.expectEqualStrings(e.data, z[local + 30 + name_len ..][0..e.data.len]);
        i += 46 + name_len;
    }
    try std.testing.expectEqual(eocd, i);
}

test "zipTree is deterministic" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "X.app");
    try tmp.dir.writeFile(io, .{ .sub_path = "X.app/b", .data = "2" });
    try tmp.dir.writeFile(io, .{ .sub_path = "X.app/a", .data = "1" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const root = try std.fs.path.join(a, &.{ base, "X.app" });
    const one = try std.fs.path.join(a, &.{ base, "1.zip" });
    const two = try std.fs.path.join(a, &.{ base, "2.zip" });
    try zipTree(a, io, root, "X.app", &.{}, one);
    try zipTree(a, io, root, "X.app", &.{}, two);
    try std.testing.expectEqualSlices(
        u8,
        try std.Io.Dir.cwd().readFileAlloc(io, one, a, .limited(1 << 20)),
        try std.Io.Dir.cwd().readFileAlloc(io, two, a, .limited(1 << 20)),
    );
}

test "zipTree streams: a file far larger than the allocations it causes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 4 MiB of position-dependent bytes, several chunks plus a partial tail.
    const big_len = 4 * 1024 * 1024 + 1234;
    const data = try std.testing.allocator.alloc(u8, big_len);
    defer std.testing.allocator.free(data);
    for (data, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% (i >> 9));
    try tmp.dir.createDirPath(io, "Big.app");
    try tmp.dir.writeFile(io, .{ .sub_path = "Big.app/game", .data = data });
    const base = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const root = try std.fs.path.join(std.testing.allocator, &.{ base, "Big.app" });
    defer std.testing.allocator.free(root);
    const out = try std.fs.path.join(std.testing.allocator, &.{ base, "big.zip" });
    defer std.testing.allocator.free(out);

    // Everything zipTree allocates, arena included, is counted here.
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    {
        var arena = std.heap.ArenaAllocator.init(counting.allocator());
        defer arena.deinit();
        try zipTree(arena.allocator(), io, root, "Big.app", &.{"game"}, out);
    }
    try std.testing.expect(counting.allocated_bytes < 256 * 1024);

    // And the archive holds the file intact.
    const z = try std.Io.Dir.cwd().readFileAlloc(io, out, std.testing.allocator, .limited(8 * 1024 * 1024));
    defer std.testing.allocator.free(z);
    const eocd = z.len - 22;
    var i: usize = u32At(z, eocd + 16);
    i += 46 + U16.at(z, i + 28); // the Big.app/ directory entry
    try std.testing.expectEqual(@as(u32, big_len), u32At(z, i + 24));
    try std.testing.expectEqual(std.hash.Crc32.hash(data), u32At(z, i + 16));
    const local = u32At(z, i + 42);
    const name_len = U16.at(z, local + 26);
    try std.testing.expectEqualSlices(u8, data, z[local + 30 + name_len ..][0..big_len]);
}

test "zipTree: a file rewritten at the same length between the passes fails the bundle" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "X.app");
    try tmp.dir.writeFile(io, .{ .sub_path = "X.app/game", .data = "ORIGINAL" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const Rewrite = struct {
        fn run(_: *anyopaque, path: []const u8) anyerror!void {
            // Same length, other bytes: only the CRC can tell.
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "REWRITES" });
        }
    };
    var unused: u8 = 0;
    try std.testing.expectError(error.FileChangedWhileZipping, zipTreeHooked(a, io, try std.fs.path.join(a, &.{ base, "X.app" }), "X.app", &.{}, try std.fs.path.join(a, &.{ base, "x.zip" }), .{
        .between_passes = .{ .ctx = &unused, .run = Rewrite.run },
    }));
    // Without a rewrite the same tree zips.
    try zipTree(a, io, try std.fs.path.join(a, &.{ base, "X.app" }), "X.app", &.{}, try std.fs.path.join(a, &.{ base, "y.zip" }));
}
