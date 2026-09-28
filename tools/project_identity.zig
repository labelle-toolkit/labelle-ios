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
