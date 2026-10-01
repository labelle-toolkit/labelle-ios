//! The few `project.labelle` facts the iOS provider needs, read leniently:
//! the project's name, its title (the home-screen name default) and its
//! `app_icon`. Every other key is ignored, so this read never breaks on
//! project-schema keys the provider does not know.
const std = @import("std");

pub const Identity = struct {
    name: []const u8,
    /// Same default as labelle-cli's `ProjectConfig.title`.
    title: []const u8 = "LaBelle v2",
    app_icon: ?[]const u8 = null,
};

pub const Error = error{ InvalidProjectFile, OutOfMemory };

/// Parse `project.labelle` source. The result borrows from `a`.
pub fn parse(a: std.mem.Allocator, source: []const u8) Error!Identity {
    const z = try a.dupeZ(u8, source);
    return std.zon.parse.fromSliceAlloc(Identity, a, z, null, .{
        .ignore_unknown_fields = true,
        .free_on_error = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ParseZon => error.InvalidProjectFile,
    };
}

/// Read `<project_dir>/project.labelle`.
pub fn load(a: std.mem.Allocator, io: std.Io, project_dir: []const u8) !Identity {
    const path = try std.fs.path.join(a, &.{ project_dir, "project.labelle" });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 * 1024 * 1024));
    return parse(a, bytes);
}

/// The project's `.backend` (`.backend = .sokol` gives `sokol`), read by a
/// lenient scan: backends are open-ended names, so no enum can type them.
/// Null when the key is absent or not an enum literal.
pub fn backend(source: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, source, i, ".backend")) |at| {
        i = at + ".backend".len;
        // `.backend_package` and friends are other keys.
        if (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_')) continue;
        var j = i;
        while (j < source.len and (source[j] == ' ' or source[j] == '\t')) j += 1;
        if (j >= source.len or source[j] != '=') continue;
        j += 1;
        while (j < source.len and (source[j] == ' ' or source[j] == '\t')) j += 1;
        if (j >= source.len or source[j] != '.') return null;
        j += 1;
        const start = j;
        while (j < source.len and (std.ascii.isAlphanumeric(source[j]) or source[j] == '_')) j += 1;
        return if (j > start) source[start..j] else null;
    }
    return null;
}

test "backend: the enum literal of .backend, never .backend_package" {
    try std.testing.expectEqualStrings("sokol", backend(".{ .name = \"x\", .backend = .sokol, .backend_package = .{} }").?);
    try std.testing.expectEqualStrings("raylib", backend(".{ .backend_package = .{ .name = \"s\" },\n    .backend=.raylib,\n}").?);
    try std.testing.expect(backend(".{ .name = \"x\" }") == null);
    try std.testing.expect(backend(".{ .backend_package = .{} }") == null);
    try std.testing.expect(backend(".{ .backend = \"sokol\" }") == null);
}

test "reads identity and ignores every other project key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const id = try parse(arena.allocator(),
        \\.{
        \\    .name = "flying_platform",
        \\    .title = "Flying Platform",
        \\    .version = 3,
        \\    .app_icon = "assets/icon.png",
        \\    .backend = .sokol,
        \\    .plugins = .{ .{ .name = "ios", .repo = "local:../labelle-ios", .version = "0.1.0" } },
        \\    .ios = .{ .bundle_id = "legacy.key" },
        \\    .provider_config = .{ .{ .package = "ios", .file = "providers/ios.json" } },
        \\}
    );
    try std.testing.expectEqualStrings("flying_platform", id.name);
    try std.testing.expectEqualStrings("Flying Platform", id.title);
    try std.testing.expectEqualStrings("assets/icon.png", id.app_icon.?);
}

test "defaults match labelle-cli's project config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const id = try parse(arena.allocator(), ".{ .name = \"g\" }");
    try std.testing.expectEqualStrings("LaBelle v2", id.title);
    try std.testing.expect(id.app_icon == null);
}

test "a project without a name, or not ZON, is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidProjectFile, parse(arena.allocator(), ".{ .title = \"t\" }"));
    try std.testing.expectError(error.InvalidProjectFile, parse(arena.allocator(), "{}"));
    try std.testing.expectError(error.InvalidProjectFile, parse(arena.allocator(), ".{ .name = 3 }"));
}
