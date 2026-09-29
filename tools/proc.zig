//! Child processes and PATH lookup for the provider's external tools
//! (`xcrun`, `codesign`). Ported from labelle-android `tools/proc.zig` and
//! `tools/sdk.zig` `findOnPath`.
const std = @import("std");
const builtin = @import("builtin");

pub const Options = struct {
    cwd: ?[]const u8 = null,
    /// Replaces the child's environment when set.
    environ_map: ?*const std.process.Environ.Map = null,
};

/// Run `argv` to completion, capturing stdout and stderr. Caller owns both.
pub fn run(a: std.mem.Allocator, io: std.Io, argv: []const []const u8, opts: Options) !std.process.RunResult {
    return std.process.run(a, io, .{
        .argv = argv,
        .cwd = if (opts.cwd) |dir| .{ .path = dir } else .inherit,
        .environ_map = opts.environ_map,
    });
}

/// This process's id, for per-process scratch names.
pub fn pid() u64 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        else => @intCast(std.c.getpid()),
    };
}

/// True when a child exited normally with status 0.
pub fn succeeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// A child's termination as a shell reports it: its exit status, or
/// 128 + the signal that ended it.
pub fn status(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped => |sig| 128 +| @as(u8, @truncate(@intFromEnum(sig))),
        .unknown => 1,
    };
}

/// The first `PATH` entry holding `name` (with `.exe`/`.bat`/`.cmd` on
/// Windows), as an absolute path; null when there is none.
pub fn findOnPath(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, name: []const u8) !?[]const u8 {
    const path_var = env.get("PATH") orelse env.get("Path") orelse return null;
    const suffixes: []const []const u8 = if (builtin.os.tag == .windows) &.{ ".exe", ".bat", ".cmd", "" } else &.{""};
    var dirs = std.mem.tokenizeScalar(u8, path_var, std.fs.path.delimiter);
    while (dirs.next()) |dir| {
        for (suffixes) |suffix| {
            const file = try std.fmt.allocPrint(a, "{s}{s}", .{ name, suffix });
            const candidate = try std.fs.path.join(a, &.{ dir, file });
            const stat = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch continue;
            if (stat.kind != .file) continue;
            // As a shell does: a match it may not execute is passed over, so
            // a later PATH entry can still supply the tool. (Windows decides
            // by the suffix above, PATHEXT-style.)
            if (builtin.os.tag != .windows) {
                std.Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch continue;
            }
            return candidate;
        }
    }
    return null;
}

test "succeeded accepts only a clean zero exit" {
    try std.testing.expect(succeeded(.{ .exited = 0 }));
    try std.testing.expect(!succeeded(.{ .exited = 1 }));
}

test "status: the exit code, or 128 + signal" {
    try std.testing.expectEqual(@as(u8, 0), status(.{ .exited = 0 }));
    try std.testing.expectEqual(@as(u8, 3), status(.{ .exited = 3 }));
    if (builtin.os.tag != .windows) try std.testing.expectEqual(@as(u8, 143), status(.{ .signal = .TERM }));
}

test "a missing executable is an error, not a silent success" {
    const argv = [_][]const u8{"labelle-ios-test-no-such-tool-4f1c"};
    if (run(std.testing.allocator, std.testing.io, &argv, .{})) |result| {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "findOnPath: the first PATH directory that has it; none is null" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const name = if (builtin.os.tag == .windows) "xcrun.exe" else "xcrun";
    try tmp.dir.createDirPath(io, "one");
    try tmp.dir.createDirPath(io, "two");
    try tmp.dir.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ "two", name }), .data = "", .flags = .{ .permissions = .executable_file } });
    var env = std.process.Environ.Map.init(a);
    try std.testing.expect(try findOnPath(a, io, &env, "xcrun") == null);
    const joined = try std.mem.join(a, &[_]u8{std.fs.path.delimiter}, &.{ try std.fs.path.join(a, &.{ root, "one" }), try std.fs.path.join(a, &.{ root, "two" }) });
    try env.put("PATH", joined);
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, "two", name }), (try findOnPath(a, io, &env, "xcrun")).?);
    try std.testing.expect(try findOnPath(a, io, &env, "codesign") == null);
}

test "findOnPath: a non-executable match earlier in PATH is passed over" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // no execute bit
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    try tmp.dir.createDirPath(io, "early");
    try tmp.dir.createDirPath(io, "late");
    try tmp.dir.writeFile(io, .{ .sub_path = "early/xcrun", .data = "not executable" });
    try tmp.dir.writeFile(io, .{ .sub_path = "late/xcrun", .data = "", .flags = .{ .permissions = .executable_file } });
    var env = std.process.Environ.Map.init(a);
    try env.put("PATH", try std.mem.join(a, ":", &.{ try std.fs.path.join(a, &.{ root, "early" }), try std.fs.path.join(a, &.{ root, "late" }) }));
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, "late", "xcrun" }), (try findOnPath(a, io, &env, "xcrun")).?);
    // Only the non-executable one: none.
    try env.put("PATH", try std.fs.path.join(a, &.{ root, "early" }));
    try std.testing.expect(try findOnPath(a, io, &env, "xcrun") == null);
}
