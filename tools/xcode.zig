//! `labelle ios xcode [--output=DIR]`: an Xcode project around the built
//! game, for signing with Xcode's own team management, running under the
//! debugger, Instruments, or archiving (ported from labelle-cli v3.1.0
//! `src/cli/ios.zig` `iosXcode`/`generatePbxproj`).
//!
//! It builds nothing: it wraps the `.app` the last `labelle build
//! --platform=ios` made (checked against its record, like `run`). Layout,
//! under `<project>/ios-xcode/` (or `--output`):
//!
//!   <Name>.xcodeproj/project.pbxproj
//!   <Name>/<exe>                    the prebuilt executable
//!   <Name>/Info.plist               the app's own Info.plist
//!   <Name>/AppIcon60x60@2x.png ...  its icons, when it has them
//!   <Name>/assets/                  its assets
//!
//! The target has no sources: a Copy Files phase puts the executable in the
//! bundle and a Resources phase the icons and `assets/` (a folder
//! reference). Xcode signs it (automatic signing, `DEVELOPMENT_TEAM` from
//! `team_id`).
//!
//! Differences from the CLI's generator: object ids are 24 hex digits (what
//! Xcode writes); the executable is the build's, not a fixed `game`;
//! `INFOPLIST_FILE` points into the `<Name>/` group where the plist is; the
//! assets are actually referenced (the CLI copied them but never added them
//! to the project); the launch screen is the plist's `UILaunchScreen`
//! instead of an uncompiled storyboard; and a simulator build is limited to
//! the simulator (`SUPPORTED_PLATFORMS`), since its binary cannot run on a
//! device.
const std = @import("std");
const settings_mod = @import("settings.zig");

pub const Resource = struct {
    path: []const u8,
    kind: enum { png, folder },
};

pub const Project = struct {
    /// The target and product name: the `.app` directory's stem.
    name: []const u8,
    bundle_id: []const u8,
    minimum_ios: []const u8,
    device_family: []const u8,
    team_id: ?[]const u8 = null,
    executable: []const u8,
    resources: []const Resource = &.{},
    destination: settings_mod.Destination = .device,
    /// `CFBundleVersion` of the wrapped app.
    version: u32 = 1,
};

/// Object ids, fixed so a regenerated project diffs cleanly.
const Id = enum(u32) {
    project = 1,
    main_group,
    app_group,
    products_group,
    product,
    target,
    copy_phase,
    resources_phase,
    project_configs,
    target_configs,
    project_debug,
    project_release,
    target_debug,
    target_release,
    exe_ref,
    plist_ref,
    exe_build,
    /// Resource `i`: file reference `resource_base + 2i`, build file `+ 1`.
    resource_base = 0x100,

    fn hex(id: u32) [24]u8 {
        var out: [24]u8 = undefined;
        _ = std.fmt.bufPrint(&out, "1ABE11E0{X:0>16}", .{id}) catch unreachable;
        return out;
    }
};

fn idOf(id: Id) [24]u8 {
    return Id.hex(@intFromEnum(id));
}

fn resourceRef(i: usize) [24]u8 {
    return Id.hex(@intFromEnum(Id.resource_base) + 2 * @as(u32, @intCast(i)));
}

fn resourceBuild(i: usize) [24]u8 {
    return Id.hex(@intFromEnum(Id.resource_base) + 2 * @as(u32, @intCast(i)) + 1);
}

/// A pbxproj string: bare when it is only `[A-Za-z0-9_./$]`, else quoted.
fn str(w: *std.Io.Writer, s: []const u8) !void {
    var bare = s.len > 0;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '/' or c == '$')) bare = false;
    }
    if (bare) return w.writeAll(s);
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn strFmt(a: std.mem.Allocator, w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(a, fmt, args);
    defer a.free(text);
    try str(w, text);
}

/// The complete `project.pbxproj`. Caller owns the result.
pub fn pbxproj(a: std.mem.Allocator, p: Project) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n");

    // PBXBuildFile
    try w.writeAll("\n/* Begin PBXBuildFile section */\n");
    try w.print("\t\t{s} = {{isa = PBXBuildFile; fileRef = {s}; }};\n", .{ idOf(.exe_build), idOf(.exe_ref) });
    for (p.resources, 0..) |_, i| try w.print("\t\t{s} = {{isa = PBXBuildFile; fileRef = {s}; }};\n", .{ resourceBuild(i), resourceRef(i) });
    try w.writeAll("/* End PBXBuildFile section */\n");

    // PBXCopyFilesBuildPhase: the prebuilt executable into the bundle's
    // Executables (dstSubfolderSpec 6).
    try w.writeAll("\n/* Begin PBXCopyFilesBuildPhase section */\n");
    try w.print("\t\t{s} = {{\n\t\t\tisa = PBXCopyFilesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tdstPath = \"\";\n\t\t\tdstSubfolderSpec = 6;\n\t\t\tfiles = (\n\t\t\t\t{s},\n\t\t\t);\n\t\t\tname = \"Embed Executable\";\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n", .{ idOf(.copy_phase), idOf(.exe_build) });
    try w.writeAll("/* End PBXCopyFilesBuildPhase section */\n");

    // PBXFileReference
    try w.writeAll("\n/* Begin PBXFileReference section */\n");
    try w.print("\t\t{s} = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = ", .{idOf(.product)});
    try strFmt(a, w, "{s}.app", .{p.name});
    try w.writeAll("; sourceTree = BUILT_PRODUCTS_DIR; };\n");
    try w.print("\t\t{s} = {{isa = PBXFileReference; lastKnownFileType = \"compiled.mach-o.executable\"; path = ", .{idOf(.exe_ref)});
    try str(w, p.executable);
    try w.writeAll("; sourceTree = \"<group>\"; };\n");
    try w.print("\t\t{s} = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};\n", .{idOf(.plist_ref)});
    for (p.resources, 0..) |r, i| {
        try w.print("\t\t{s} = {{isa = PBXFileReference; lastKnownFileType = {s}; path = ", .{ resourceRef(i), switch (r.kind) {
            .png => "image.png",
            .folder => "folder",
        } });
        try str(w, r.path);
        try w.writeAll("; sourceTree = \"<group>\"; };\n");
    }
    try w.writeAll("/* End PBXFileReference section */\n");

    // PBXGroup
    try w.writeAll("\n/* Begin PBXGroup section */\n");
    try w.print("\t\t{s} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{s},\n\t\t\t\t{s},\n\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n", .{ idOf(.main_group), idOf(.app_group), idOf(.products_group) });
    try w.print("\t\t{s} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{s},\n\t\t\t\t{s},\n", .{ idOf(.app_group), idOf(.exe_ref), idOf(.plist_ref) });
    for (p.resources, 0..) |_, i| try w.print("\t\t\t\t{s},\n", .{resourceRef(i)});
    try w.writeAll("\t\t\t);\n\t\t\tpath = ");
    try str(w, p.name);
    try w.writeAll(";\n\t\t\tsourceTree = \"<group>\";\n\t\t};\n");
    try w.print("\t\t{s} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{s},\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n", .{ idOf(.products_group), idOf(.product) });
    try w.writeAll("/* End PBXGroup section */\n");

    // PBXNativeTarget
    try w.writeAll("\n/* Begin PBXNativeTarget section */\n");
    try w.print("\t\t{s} = {{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {s};\n\t\t\tbuildPhases = (\n\t\t\t\t{s},\n\t\t\t\t{s},\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = ", .{ idOf(.target), idOf(.target_configs), idOf(.copy_phase), idOf(.resources_phase) });
    try str(w, p.name);
    try w.writeAll(";\n\t\t\tproductName = ");
    try str(w, p.name);
    try w.print(";\n\t\t\tproductReference = {s};\n\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t}};\n", .{idOf(.product)});
    try w.writeAll("/* End PBXNativeTarget section */\n");

    // PBXProject
    try w.writeAll("\n/* Begin PBXProject section */\n");
    try w.print("\t\t{s} = {{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastUpgradeCheck = 1600;\n\t\t\t}};\n\t\t\tbuildConfigurationList = {s};\n\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n\t\t\tmainGroup = {s};\n\t\t\tproductRefGroup = {s};\n\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n\t\t\ttargets = (\n\t\t\t\t{s},\n\t\t\t);\n\t\t}};\n", .{ idOf(.project), idOf(.project_configs), idOf(.main_group), idOf(.products_group), idOf(.target) });
    try w.writeAll("/* End PBXProject section */\n");

    // PBXResourcesBuildPhase
    try w.writeAll("\n/* Begin PBXResourcesBuildPhase section */\n");
    try w.print("\t\t{s} = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n", .{idOf(.resources_phase)});
    for (p.resources, 0..) |_, i| try w.print("\t\t\t\t{s},\n", .{resourceBuild(i)});
    try w.writeAll("\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n");
    try w.writeAll("/* End PBXResourcesBuildPhase section */\n");

    // XCBuildConfiguration
    try w.writeAll("\n/* Begin XCBuildConfiguration section */\n");
    for ([_]struct { id: Id, name: []const u8 }{ .{ .id = .project_debug, .name = "Debug" }, .{ .id = .project_release, .name = "Release" } }) |c| {
        try w.print("\t\t{s} = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;\n\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = ", .{idOf(c.id)});
        try str(w, p.minimum_ios);
        try w.print(";\n\t\t\t\tSDKROOT = iphoneos;\n\t\t\t}};\n\t\t\tname = {s};\n\t\t}};\n", .{c.name});
    }
    for ([_]struct { id: Id, name: []const u8 }{ .{ .id = .target_debug, .name = "Debug" }, .{ .id = .target_release, .name = "Release" } }) |c| {
        try w.print("\t\t{s} = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n", .{idOf(c.id)});
        try w.writeAll("\t\t\t\tCODE_SIGN_STYLE = Automatic;\n");
        try w.print("\t\t\t\tCURRENT_PROJECT_VERSION = {d};\n", .{p.version});
        if (p.team_id) |team| {
            try w.writeAll("\t\t\t\tDEVELOPMENT_TEAM = ");
            try str(w, team);
            try w.writeAll(";\n");
        }
        try w.writeAll("\t\t\t\tGENERATE_INFOPLIST_FILE = NO;\n\t\t\t\tINFOPLIST_FILE = ");
        try strFmt(a, w, "{s}/Info.plist", .{p.name});
        try w.writeAll(";\n\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = ");
        try str(w, p.minimum_ios);
        try w.writeAll(";\n\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = ");
        try str(w, p.bundle_id);
        try w.writeAll(";\n\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";\n\t\t\t\tSDKROOT = iphoneos;\n");
        try w.print("\t\t\t\tSUPPORTED_PLATFORMS = {s};\n", .{switch (p.destination) {
            .device => "iphoneos",
            .simulator => "iphonesimulator",
        }});
        try w.writeAll("\t\t\t\tTARGETED_DEVICE_FAMILY = ");
        try str(w, p.device_family);
        try w.print(";\n\t\t\t}};\n\t\t\tname = {s};\n\t\t}};\n", .{c.name});
    }
    try w.writeAll("/* End XCBuildConfiguration section */\n");

    // XCConfigurationList
    try w.writeAll("\n/* Begin XCConfigurationList section */\n");
    for ([_][3]Id{ .{ .project_configs, .project_debug, .project_release }, .{ .target_configs, .target_debug, .target_release } }) |l| {
        try w.print("\t\t{s} = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{s},\n\t\t\t\t{s},\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Debug;\n\t\t}};\n", .{ idOf(l[0]), idOf(l[1]), idOf(l[2]) });
    }
    try w.writeAll("/* End XCConfigurationList section */\n");

    try w.print("\t}};\n\trootObject = {s};\n}}\n", .{idOf(.project)});
    return out.toOwnedSlice();
}

// ── Writing the project ───────────────────────────────────────────────────

pub const WriteInputs = struct {
    /// The built `<Name>.app`.
    app: []const u8,
    /// `ios-xcode/` (or `--output`).
    out_dir: []const u8,
    project: Project,
};

/// Files of the built app the project does not take: the signature and
/// profile (Xcode signs its own product) and the executable and plist,
/// which have their own references.
fn skipped(name: []const u8, p: Project) bool {
    return std.mem.eql(u8, name, "_CodeSignature") or std.mem.eql(u8, name, "embedded.mobileprovision") or
        std.mem.eql(u8, name, "PkgInfo") or std.mem.eql(u8, name, "Info.plist") or std.mem.eql(u8, name, p.executable);
}

/// The resources of a built app: its icon PNGs and its `assets/` folder,
/// sorted.
pub fn resourcesOf(a: std.mem.Allocator, io: std.Io, app: []const u8, p: Project) ![]Resource {
    var found: std.ArrayList(Resource) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(io, app, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (skipped(entry.name, p)) continue;
        const kind = if (entry.kind == .unknown) (try dir.statFile(io, entry.name, .{})).kind else entry.kind;
        if (kind == .directory and std.mem.eql(u8, entry.name, "assets")) {
            try found.append(a, .{ .path = try a.dupe(u8, entry.name), .kind = .folder });
        } else if (kind == .file and std.mem.endsWith(u8, entry.name, ".png")) {
            try found.append(a, .{ .path = try a.dupe(u8, entry.name), .kind = .png });
        }
    }
    std.mem.sort(Resource, found.items, {}, struct {
        fn lessThan(_: void, x: Resource, y: Resource) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lessThan);
    return found.items;
}

fn copyTree(a: std.mem.Allocator, io: std.Io, src: []const u8, dst: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dst);
    var dir = try cwd.openDir(io, src, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const from = try std.fs.path.join(a, &.{ src, entry.name });
        const to = try std.fs.path.join(a, &.{ dst, entry.name });
        const kind = if (entry.kind == .unknown) (try dir.statFile(io, entry.name, .{})).kind else entry.kind;
        switch (kind) {
            .directory => try copyTree(a, io, from, to),
            .file => try cwd.copyFile(from, cwd, to, io, .{}),
            else => {},
        }
    }
}

/// Write `<out>/<Name>.xcodeproj` and `<out>/<Name>/`, replacing an earlier
/// export of the same name (and nothing else in `<out>`). Returns the
/// `.xcodeproj` path.
pub fn write(a: std.mem.Allocator, io: std.Io, in: WriteInputs) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const p = in.project;
    const xcodeproj = try std.fs.path.join(a, &.{ in.out_dir, try std.fmt.allocPrint(a, "{s}.xcodeproj", .{p.name}) });
    const files = try std.fs.path.join(a, &.{ in.out_dir, p.name });
    try cwd.deleteTree(io, xcodeproj);
    try cwd.deleteTree(io, files);
    try cwd.createDirPath(io, xcodeproj);
    try cwd.createDirPath(io, files);

    try cwd.copyFile(try std.fs.path.join(a, &.{ in.app, p.executable }), cwd, try std.fs.path.join(a, &.{ files, p.executable }), io, .{});
    try cwd.copyFile(try std.fs.path.join(a, &.{ in.app, "Info.plist" }), cwd, try std.fs.path.join(a, &.{ files, "Info.plist" }), io, .{});
    for (p.resources) |r| {
        const from = try std.fs.path.join(a, &.{ in.app, r.path });
        const to = try std.fs.path.join(a, &.{ files, r.path });
        switch (r.kind) {
            .png => try cwd.copyFile(from, cwd, to, io, .{}),
            .folder => try copyTree(a, io, from, to),
        }
    }
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ xcodeproj, "project.pbxproj" }), .data = try pbxproj(a, p) });
    return xcodeproj;
}

pub const Args = struct { output: ?[]const u8 = null };

pub const usage = "usage: labelle ios xcode [--output=DIR]\n";

pub fn parseArgs(args: []const []const u8) !Args {
    var o: Args = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "--output=")) {
            o.output = arg["--output=".len..];
        } else if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            o.output = if (i < args.len) args[i] else "";
        } else {
            std.debug.print("labelle-ios: unknown argument '{s}'\n{s}", .{ arg, usage });
            return error.UnknownArgument;
        }
        if (o.output.?.len == 0) {
            std.debug.print("labelle-ios: --output needs a directory\n{s}", .{usage});
            return error.InvalidArgs;
        }
    }
    return o;
}

// ── Tests ─────────────────────────────────────────────────────────────────

const sample: Project = .{
    .name = "Flying_Platform",
    .bundle_id = "com.labelle.flying-platform",
    .minimum_ios = "15.0",
    .device_family = "1,2",
    .team_id = "ABCDE12345",
    .executable = "game",
    .resources = &.{
        .{ .path = "AppIcon60x60@2x.png", .kind = .png },
        .{ .path = "AppIcon60x60@3x.png", .kind = .png },
        .{ .path = "assets", .kind = .folder },
    },
    .version = 7,
};

test "pbxproj: snapshot" {
    const got = try pbxproj(std.testing.allocator, sample);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(@embedFile("testdata/Flying_Platform.pbxproj"), got);
}

test "pbxproj: no team, a simulator build, names that need quoting" {
    const a = std.testing.allocator;
    var p = sample;
    p.team_id = null;
    p.destination = .simulator;
    p.name = "My-Game";
    p.executable = "my game";
    p.resources = &.{};
    const got = try pbxproj(a, p);
    defer a.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "DEVELOPMENT_TEAM") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "SUPPORTED_PLATFORMS = iphonesimulator;") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "path = \"My-Game.app\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "path = \"my game\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "INFOPLIST_FILE = \"My-Game/Info.plist\";") != null);
    // Balanced braces and parentheses.
    try std.testing.expectEqual(std.mem.count(u8, got, "{"), std.mem.count(u8, got, "}"));
    try std.testing.expectEqual(std.mem.count(u8, got, "("), std.mem.count(u8, got, ")"));
}

test "pbxproj: plutil accepts it (macOS)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/usr/bin/plutil", .{}) catch return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "project.pbxproj", .data = try pbxproj(a, sample) });
    const path = try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(io, ".", a), "project.pbxproj" });
    const r = try std.process.run(a, io, .{ .argv = &.{ "/usr/bin/plutil", "-lint", path } });
    if (r.term != .exited or r.term.exited != 0) {
        std.debug.print("plutil: {s}{s}\n", .{ r.stdout, r.stderr });
        return error.TestUnexpectedResult;
    }
}

test "write: the project around a built app, replacing an earlier export only" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    for ([_][2][]const u8{
        .{ "G.app/game", "EXE" },
        .{ "G.app/Info.plist", "<plist/>" },
        .{ "G.app/PkgInfo", "APPL????" },
        .{ "G.app/AppIcon60x60@2x.png", "PNG" },
        .{ "G.app/embedded.mobileprovision", "P" },
        .{ "G.app/_CodeSignature/CodeResources", "S" },
        .{ "G.app/assets/sub/a.txt", "A" },
        .{ "out/G/stale.txt", "old" },
        .{ "out/keep.txt", "mine" },
    }) |f| {
        try tmp.dir.createDirPath(io, std.fs.path.dirname(f[0]).?);
        try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    }
    const app = try std.fs.path.join(a, &.{ root, "G.app" });
    var p = sample;
    p.name = "G";
    p.resources = try resourcesOf(a, io, app, p);
    try std.testing.expectEqual(@as(usize, 2), p.resources.len);
    try std.testing.expectEqualStrings("AppIcon60x60@2x.png", p.resources[0].path);
    try std.testing.expectEqualStrings("assets", p.resources[1].path);
    const proj = try write(a, io, .{ .app = app, .out_dir = try std.fs.path.join(a, &.{ root, "out" }), .project = p });
    try std.testing.expectEqualStrings("G.xcodeproj", std.fs.path.basename(proj));
    try std.testing.expectEqualStrings("EXE", try tmp.dir.readFileAlloc(io, "out/G/game", a, .limited(64)));
    try std.testing.expectEqualStrings("A", try tmp.dir.readFileAlloc(io, "out/G/assets/sub/a.txt", a, .limited(64)));
    try tmp.dir.access(io, "out/G/AppIcon60x60@2x.png", .{});
    try tmp.dir.access(io, "out/G.xcodeproj/project.pbxproj", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "out/G/stale.txt", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "out/G/embedded.mobileprovision", .{}));
    try std.testing.expectEqualStrings("mine", try tmp.dir.readFileAlloc(io, "out/keep.txt", a, .limited(64)));
}

test "parseArgs" {
    try std.testing.expectEqualStrings("x", (try parseArgs(&.{"--output=x"})).output.?);
    try std.testing.expectEqualStrings("y", (try parseArgs(&.{ "--output", "y" })).output.?);
    try std.testing.expect((try parseArgs(&.{})).output == null);
    try std.testing.expectError(error.UnknownArgument, parseArgs(&.{"--open"}));
    try std.testing.expectError(error.InvalidArgs, parseArgs(&.{"--output="}));
}
