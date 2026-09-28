//! The one walk over `<target_dir>/assets` that both the `.app` copy and the
//! stale-app digest use, so they can never disagree about what ships.
//!
//! Entries are visited in sorted order, directories before their contents.
//! A symbolic link is followed when it resolves inside the project directory
//! (the assembler and asset tools link generated files into the target
//! directory): a linked file ships its target's contents, a linked
//! directory its tree. A link that dangles or points outside the project,
//! and anything that is not a file, directory or link, is refused with a
//! message. Nothing is ever silently skipped.
const std = @import("std");

/// Deeper than any real asset tree; hit only by a link cycle.
pub const max_depth = 32;

pub const Error = error{
    AssetLinkUnresolved,
    AssetLinkOutsideProject,
    AssetTreeTooDeep,
    UnsupportedAssetKind,
};

/// Walk `assets_dir` (which must exist), calling `visitor.dir(rel)` for each
/// directory and `visitor.file(rel, path)` for each file, where `rel` is the
/// '/'-separated path under `assets_dir` and `path` the file to read (the
/// link target for a linked file). `project_dir` bounds where links may go.
pub fn walk(a: std.mem.Allocator, io: std.Io, project_dir: []const u8, assets_dir: []const u8, visitor: anytype) !void {
    const cwd = std.Io.Dir.cwd();
    const root = try cwd.realPathFileAlloc(io, project_dir, a);
    // The root too: `assets` itself, or a directory above it, may be a link.
    // Walk from the resolved path, so every entry is bounded by the check.
    const real = try cwd.realPathFileAlloc(io, assets_dir, a);
    if (!inside(root, real)) {
        std.debug.print("labelle-ios: {s} resolves to {s}, outside the project {s}: keep the assets inside the project\n", .{ assets_dir, real, root });
        return error.AssetLinkOutsideProject;
    }
    try walkDir(a, io, root, real, "", 0, visitor);
}

const Item = struct { name: []const u8, kind: std.Io.File.Kind };

fn walkDir(a: std.mem.Allocator, io: std.Io, root: []const u8, dir_path: []const u8, rel: []const u8, depth: usize, visitor: anytype) !void {
    if (depth > max_depth) {
        std.debug.print("labelle-ios: assets/{s} is more than {d} directories deep (a symbolic link cycle?)\n", .{ rel, max_depth });
        return error.AssetTreeTooDeep;
    }
    const cwd = std.Io.Dir.cwd();
    var items: std.ArrayList(Item) = .empty;
    {
        var dir = try cwd.openDir(io, dir_path, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |e| try items.append(a, .{ .name = try a.dupe(u8, e.name), .kind = e.kind });
    }
    std.mem.sort(Item, items.items, {}, struct {
        fn lessThan(_: void, x: Item, y: Item) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lessThan);
    for (items.items) |item| {
        const full = try std.fs.path.join(a, &.{ dir_path, item.name });
        const child = if (rel.len == 0) item.name else try std.fmt.allocPrint(a, "{s}/{s}", .{ rel, item.name });
        var kind = item.kind;
        if (kind == .unknown) kind = (try cwd.statFile(io, full, .{ .follow_symlinks = false })).kind;
        var path = full;
        if (kind == .sym_link) {
            const real = cwd.realPathFileAlloc(io, full, a) catch |err| {
                std.debug.print("labelle-ios: assets/{s} is a symbolic link that does not resolve ({s})\n", .{ child, @errorName(err) });
                return error.AssetLinkUnresolved;
            };
            if (!inside(root, real)) {
                std.debug.print("labelle-ios: assets/{s} links to {s}, outside the project {s}: copy the file into the project instead\n", .{ child, real, root });
                return error.AssetLinkOutsideProject;
            }
            kind = (try cwd.statFile(io, real, .{})).kind;
            path = real;
        }
        switch (kind) {
            .directory => {
                try visitor.dir(child);
                try walkDir(a, io, root, path, child, depth + 1, visitor);
            },
            .file => try visitor.file(child, path),
            else => {
                std.debug.print("labelle-ios: assets/{s} is a {s}, not a file, directory or symbolic link\n", .{ child, @tagName(kind) });
                return error.UnsupportedAssetKind;
            },
        }
    }
}

/// `path` is `root` or below it (both resolved).
pub fn inside(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    return std.fs.path.isSep(path[root.len]) or (root.len > 0 and std.fs.path.isSep(root[root.len - 1]));
}

// ── Tests ─────────────────────────────────────────────────────────────────

const Recorder = struct {
    a: std.mem.Allocator,
    seen: std.ArrayList([]const u8) = .empty,

    fn dir(r: *Recorder, rel: []const u8) !void {
        try r.seen.append(r.a, try std.fmt.allocPrint(r.a, "{s}/", .{rel}));
    }

    fn file(r: *Recorder, rel: []const u8, path: []const u8) !void {
        const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, r.a, .limited(1024));
        try r.seen.append(r.a, try std.fmt.allocPrint(r.a, "{s}={s}", .{ rel, data }));
    }
};

test "inside" {
    try std.testing.expect(inside("/p", "/p"));
    try std.testing.expect(inside("/p", "/p/a"));
    try std.testing.expect(!inside("/p", "/pa"));
    try std.testing.expect(!inside("/p", "/"));
    try std.testing.expect(inside("/", "/x"));
}

test "walk: sorted, directories first, links inside the project followed" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // symlinks need privileges
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project/target/assets/sub");
    try tmp.dir.createDirPath(io, "project/shared/levels");
    try tmp.dir.writeFile(io, .{ .sub_path = "project/target/assets/sub/b.txt", .data = "B" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/target/assets/a.txt", .data = "A" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/shared/logo.txt", .data = "LOGO" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/shared/levels/1.json", .data = "L1" });
    try tmp.dir.symLink(io, "../../shared/logo.txt", "project/target/assets/logo.txt", .{});
    try tmp.dir.symLink(io, "../../shared/levels", "project/target/assets/levels", .{});
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    var r: Recorder = .{ .a = a };
    try walk(a, io, try std.fs.path.join(a, &.{ root, "project" }), try std.fs.path.join(a, &.{ root, "project/target/assets" }), &r);
    const want = [_][]const u8{ "a.txt=A", "levels/", "levels/1.json=L1", "logo.txt=LOGO", "sub/", "sub/b.txt=B" };
    try std.testing.expectEqual(want.len, r.seen.items.len);
    for (want, r.seen.items) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "walk: a link outside the project, a dangling link and a cycle are refused" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project/assets");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside.txt", .data = "SECRET" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const project = try std.fs.path.join(a, &.{ root, "project" });
    const assets = try std.fs.path.join(a, &.{ root, "project/assets" });
    var r: Recorder = .{ .a = a };

    try tmp.dir.symLink(io, "../../outside.txt", "project/assets/leak.txt", .{});
    try std.testing.expectError(error.AssetLinkOutsideProject, walk(a, io, project, assets, &r));
    try tmp.dir.deleteFile(io, "project/assets/leak.txt");

    try tmp.dir.symLink(io, "missing.txt", "project/assets/dangling.txt", .{});
    try std.testing.expectError(error.AssetLinkUnresolved, walk(a, io, project, assets, &r));
    try tmp.dir.deleteFile(io, "project/assets/dangling.txt");

    try tmp.dir.symLink(io, ".", "project/assets/loop", .{});
    try std.testing.expectError(error.AssetTreeTooDeep, walk(a, io, project, assets, &r));
}

test "walk: an assets root, or a parent of it, linked outside the project is refused" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project/target");
    try tmp.dir.createDirPath(io, "project/shared/assets");
    try tmp.dir.createDirPath(io, "elsewhere/tgt/assets");
    try tmp.dir.writeFile(io, .{ .sub_path = "elsewhere/tgt/assets/secret.txt", .data = "SECRET" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/shared/assets/ok.txt", .data = "OK" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const project = try std.fs.path.join(a, &.{ root, "project" });
    var r: Recorder = .{ .a = a };

    // `assets` itself links outside.
    try tmp.dir.symLink(io, "../../elsewhere/tgt/assets", "project/target/assets", .{});
    try std.testing.expectError(error.AssetLinkOutsideProject, walk(a, io, project, try std.fs.path.join(a, &.{ project, "target/assets" }), &r));
    try tmp.dir.deleteFile(io, "project/target/assets");

    // A parent of it links outside.
    try tmp.dir.symLink(io, "../elsewhere/tgt", "project/linked", .{});
    try std.testing.expectError(error.AssetLinkOutsideProject, walk(a, io, project, try std.fs.path.join(a, &.{ project, "linked/assets" }), &r));
    try std.testing.expectEqual(@as(usize, 0), r.seen.items.len);

    // `assets` linked inside the project is walked.
    try tmp.dir.symLink(io, "../shared/assets", "project/target/assets", .{});
    try walk(a, io, project, try std.fs.path.join(a, &.{ project, "target/assets" }), &r);
    try std.testing.expectEqual(@as(usize, 1), r.seen.items.len);
    try std.testing.expectEqualStrings("ok.txt=OK", r.seen.items[0]);
}
