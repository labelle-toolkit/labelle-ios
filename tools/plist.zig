//! The `.app` bundle's `Info.plist` (ported from labelle-cli `src/cli/ios.zig`
//! `generateInfoPlist`, origin/main e2e0e85).
//!
//! Differences from the CLI's copy:
//! - `CFBundleExecutable` names the executable the build produced (the
//!   assembler names it `game`, assembler#774) instead of assuming it.
//! - The launch screen is the storyboard-free `UILaunchScreen` dictionary
//!   (iOS 14+). The CLI wrote an uncompiled `LaunchScreen.storyboard`, which
//!   iOS cannot load without `ibtool`; with no usable launch screen iOS runs
//!   the app letterboxed in a legacy screen size.
//! - Text is XML-escaped, so an `&` in the app name cannot break the plist.
//! - An app icon is declared through `CFBundleIcons` when the project has one.
const std = @import("std");
const settings_mod = @import("settings.zig");

pub const Info = struct {
    bundle_id: []const u8,
    app_name: []const u8,
    executable: []const u8,
    minimum_ios: []const u8,
    orientation: settings_mod.Orientation,
    device_family: []const u8,
    /// `CFBundleIconFiles` base name (e.g. `AppIcon60x60`), when the bundle
    /// carries icon PNGs.
    icon: ?[]const u8 = null,
    /// `CFBundleVersion`: `labelle bundle --build-number`, else 1.
    version: u32 = 1,
};

/// The complete `Info.plist` document. Caller owns the result.
pub fn infoPlist(a: std.mem.Allocator, info: Info) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\
    );
    try string(w, "CFBundleDevelopmentRegion", "en");
    try string(w, "CFBundleDisplayName", info.app_name);
    try string(w, "CFBundleExecutable", info.executable);
    if (info.icon) |icon| {
        try w.writeAll("    <key>CFBundleIcons</key>\n    <dict>\n        <key>CFBundlePrimaryIcon</key>\n        <dict>\n");
        try w.writeAll("            <key>CFBundleIconFiles</key>\n            <array>\n                <string>");
        try escaped(w, icon);
        try w.writeAll("</string>\n            </array>\n        </dict>\n    </dict>\n");
    }
    try string(w, "CFBundleIdentifier", info.bundle_id);
    try string(w, "CFBundleInfoDictionaryVersion", "6.0");
    try string(w, "CFBundleName", info.app_name);
    try string(w, "CFBundlePackageType", "APPL");
    try string(w, "CFBundleShortVersionString", "1.0");
    try w.writeAll("    <key>CFBundleSupportedPlatforms</key>\n    <array>\n        <string>iPhoneSimulator</string>\n    </array>\n");
    try w.print("    <key>CFBundleVersion</key>\n    <string>{d}</string>\n", .{info.version});
    try boolean(w, "LSRequiresIPhoneOS", true);
    try string(w, "MinimumOSVersion", info.minimum_ios);
    try w.writeAll("    <key>UIDeviceFamily</key>\n    <array>\n");
    var families = std.mem.splitScalar(u8, info.device_family, ',');
    while (families.next()) |family| try w.print("        <integer>{s}</integer>\n", .{family});
    try w.writeAll("    </array>\n");
    try w.writeAll("    <key>UILaunchScreen</key>\n    <dict/>\n");
    try w.writeAll("    <key>UIRequiredDeviceCapabilities</key>\n    <array>\n        <string>arm64</string>\n        <string>metal</string>\n    </array>\n");
    try boolean(w, "UIRequiresFullScreen", true);
    try boolean(w, "UIStatusBarHidden", true);
    for ([_][]const u8{ "UISupportedInterfaceOrientations", "UISupportedInterfaceOrientations~ipad" }) |key| {
        try w.print("    <key>{s}</key>\n    <array>\n", .{key});
        for (orientations(info.orientation)) |o| try w.print("        <string>{s}</string>\n", .{o});
        try w.writeAll("    </array>\n");
    }
    try w.writeAll("</dict>\n</plist>\n");
    return out.toOwnedSlice();
}

/// `UISupportedInterfaceOrientations` for an orientation setting. iOS
/// `landscape` allows both directions, so `sensor_landscape` is the same.
pub fn orientations(o: settings_mod.Orientation) []const []const u8 {
    return switch (o) {
        .portrait => &.{"UIInterfaceOrientationPortrait"},
        .landscape, .sensor_landscape => &.{ "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight" },
        .all => &.{ "UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight" },
    };
}

fn string(w: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    try w.print("    <key>{s}</key>\n    <string>", .{key});
    try escaped(w, value);
    try w.writeAll("</string>\n");
}

fn boolean(w: *std.Io.Writer, key: []const u8, value: bool) !void {
    try w.print("    <key>{s}</key>\n    <{s}/>\n", .{ key, if (value) "true" else "false" });
}

/// XML character data: `&`, `<` and `>` escaped.
pub fn escaped(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(c),
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────

const base: Info = .{
    .bundle_id = "com.labelle.game",
    .app_name = "Game",
    .executable = "game",
    .minimum_ios = "15.0",
    .orientation = .all,
    .device_family = "1,2",
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("missing:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.TestUnexpectedResult;
    }
}

test "Info.plist carries the identity, executable, OS floor and launch screen" {
    const a = std.testing.allocator;
    const plist = try infoPlist(a, base);
    defer a.free(plist);
    try std.testing.expect(std.mem.startsWith(u8, plist, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist"));
    try std.testing.expect(std.mem.endsWith(u8, plist, "</dict>\n</plist>\n"));
    try expectContains(plist, "<key>CFBundleIdentifier</key>\n    <string>com.labelle.game</string>");
    try expectContains(plist, "<key>CFBundleExecutable</key>\n    <string>game</string>");
    try expectContains(plist, "<key>CFBundleDisplayName</key>\n    <string>Game</string>");
    try expectContains(plist, "<key>CFBundlePackageType</key>\n    <string>APPL</string>");
    try expectContains(plist, "<key>MinimumOSVersion</key>\n    <string>15.0</string>");
    try expectContains(plist, "<key>UILaunchScreen</key>\n    <dict/>");
    try expectContains(plist, "<key>UIDeviceFamily</key>\n    <array>\n        <integer>1</integer>\n        <integer>2</integer>\n    </array>");
    try expectContains(plist, "<key>LSRequiresIPhoneOS</key>\n    <true/>");
    // No storyboard reference (it would name a file that cannot load) and
    // no icon block without an icon.
    try std.testing.expect(std.mem.indexOf(u8, plist, "UILaunchStoryboardName") == null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "CFBundleIcons") == null);
    // Every <key> is followed by exactly one value: keys and values balance.
    try std.testing.expectEqual(std.mem.count(u8, plist, "<key>"), std.mem.count(u8, plist, "</key>"));
}

test "the executable name comes from the build, not a fixed 'game'" {
    const a = std.testing.allocator;
    var info = base;
    info.executable = "sokol_ios_fixture";
    const plist = try infoPlist(a, info);
    defer a.free(plist);
    try expectContains(plist, "<key>CFBundleExecutable</key>\n    <string>sokol_ios_fixture</string>");
}

test "every orientation maps to its UISupportedInterfaceOrientations array" {
    const a = std.testing.allocator;
    const portrait = "<string>UIInterfaceOrientationPortrait</string>";
    const left = "<string>UIInterfaceOrientationLandscapeLeft</string>";
    const right = "<string>UIInterfaceOrientationLandscapeRight</string>";
    inline for (.{
        .{ settings_mod.Orientation.portrait, true, false },
        .{ settings_mod.Orientation.landscape, false, true },
        .{ settings_mod.Orientation.sensor_landscape, false, true },
        .{ settings_mod.Orientation.all, true, true },
    }) |case| {
        var info = base;
        info.orientation = case[0];
        const plist = try infoPlist(a, info);
        defer a.free(plist);
        // iPhone and iPad keys, each with the same list.
        try std.testing.expectEqual(@as(usize, if (case[1]) 2 else 0), std.mem.count(u8, plist, portrait));
        try std.testing.expectEqual(@as(usize, if (case[2]) 2 else 0), std.mem.count(u8, plist, left));
        try std.testing.expectEqual(@as(usize, if (case[2]) 2 else 0), std.mem.count(u8, plist, right));
    }
    // `sensor_landscape` and `landscape` are the same plist on iOS.
    var l = base;
    l.orientation = .landscape;
    var s = base;
    s.orientation = .sensor_landscape;
    const lp = try infoPlist(a, l);
    defer a.free(lp);
    const sp = try infoPlist(a, s);
    defer a.free(sp);
    try std.testing.expectEqualStrings(lp, sp);
}

test "device families and the icon block" {
    const a = std.testing.allocator;
    var info = base;
    info.device_family = "2";
    info.icon = "AppIcon60x60";
    const plist = try infoPlist(a, info);
    defer a.free(plist);
    try expectContains(plist, "<key>UIDeviceFamily</key>\n    <array>\n        <integer>2</integer>\n    </array>");
    try expectContains(plist, "<key>CFBundleIconFiles</key>\n            <array>\n                <string>AppIcon60x60</string>");
}

test "text is XML-escaped" {
    const a = std.testing.allocator;
    var info = base;
    info.app_name = "Cats & <Dogs>";
    const plist = try infoPlist(a, info);
    defer a.free(plist);
    try expectContains(plist, "<string>Cats &amp; &lt;Dogs&gt;</string>");
    try std.testing.expect(std.mem.indexOf(u8, plist, "Cats & ") == null);
}

test "CFBundleVersion is the build number" {
    const a = std.testing.allocator;
    const one = try infoPlist(a, base);
    defer a.free(one);
    try expectContains(one, "<key>CFBundleVersion</key>\n    <string>1</string>");
    var info = base;
    info.version = 42;
    const stamped = try infoPlist(a, info);
    defer a.free(stamped);
    try expectContains(stamped, "<key>CFBundleVersion</key>\n    <string>42</string>");
}
