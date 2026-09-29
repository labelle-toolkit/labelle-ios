//! The `device` hook (before `build`, target `ios`): a device build asks the
//! core `zig build` for `-Ddevice=true` (the generated iOS build's option,
//! read by labelle-sokol's build hook) through the contract's
//! `build_options` in `env_file` (wire `1.6.0`+, RFC labelle-cli#471 D3).
//!
//! A simulator build writes nothing: no `env_file`, the default build. A
//! device build on a CLI that negotiated a wire below `1.6.0` cannot carry the
//! option, and building the simulator binary instead would be a silent wrong
//! build, so the hook refuses and names the CLI upgrade.
const std = @import("std");
const contract = @import("contract.zig");
const settings_mod = @import("settings.zig");

/// What the hook does for one build.
pub const Decision = enum {
    /// A simulator build: nothing to contribute.
    none,
    /// A device build: write `env_file` with `-Ddevice=true`.
    device,
    /// A device build on a wire below `1.6.0`: refuse.
    wire_too_old,
};

pub fn decide(settings: settings_mod.Settings, wire: []const u8) Decision {
    if (settings.destination != .device) return .none;
    return if (contract.carriesBuildOptions(wire)) .device else .wire_too_old;
}

/// The `env_file` document of a device build.
pub const device_env_file = "{\"build_options\":[{\"name\":\"device\",\"value\":\"true\"}]}\n";

pub const wire_too_old_message =
    "destination \"device\" needs labelle-cli with provider contract 1.6.0 (build_options) to build with -Ddevice=true; " ++
    "this CLI negotiated {s}. Upgrade labelle-cli, or set \"destination\": \"simulator\" in providers/ios.json";

/// Run the hook: write `ctx.env_file` for a device build, nothing otherwise.
/// Returns the decision it acted on.
pub fn hook(io: std.Io, settings: settings_mod.Settings, ctx: contract.Context) !Decision {
    const decision = decide(settings, ctx.contract_version);
    switch (decision) {
        .none => {},
        .wire_too_old => {
            std.debug.print("labelle-ios: " ++ wire_too_old_message ++ "\n", .{ctx.contract_version});
            return error.ContractTooOldForDevice;
        },
        .device => {
            // The CLI hands every `before build` hook an env_file on 1.3.0+,
            // and only the target owner's `before` hooks may carry options.
            if (!contract.buildOptionsSlot(ctx.invocation)) return error.InvalidInvocation;
            const path = ctx.env_file orelse return error.MissingEnvFile;
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = device_env_file });
            std.debug.print("labelle-ios: device build: -Ddevice=true\n", .{});
        },
    }
    return decision;
}

// ── Tests ─────────────────────────────────────────────────────────────────

fn settingsFor(a: std.mem.Allocator, json: []const u8) !settings_mod.Settings {
    var diag: settings_mod.Diagnostic = .{};
    return settings_mod.parse(a, json, &diag);
}

const device_json =
    \\{"schema_version": 1, "bundle_id": "com.a.b", "destination": "device",
    \\ "signing": {"identity": "Apple Development: A", "profile": "a.mobileprovision"}}
;

test "decide: simulator contributes nothing on any wire; device needs 1.6.0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sim = try settingsFor(arena.allocator(), "{\"schema_version\": 1, \"bundle_id\": \"com.a.b\"}");
    const dev = try settingsFor(arena.allocator(), device_json);
    for ([_][]const u8{ "1.3.0", "1.4.0", "1.5.0", "1.6.0" }) |wire| try std.testing.expectEqual(Decision.none, decide(sim, wire));
    for ([_][]const u8{ "1.3.0", "1.4.0", "1.5.0" }) |wire| try std.testing.expectEqual(Decision.wire_too_old, decide(dev, wire));
    try std.testing.expectEqual(Decision.device, decide(dev, "1.6.0"));
}

test "the device env_file is what the CLI's build_options decoder takes" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, device_env_file, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 1), root.count());
    const options = root.get("build_options").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), options.len);
    try std.testing.expectEqual(@as(usize, 2), options[0].object.count());
    try std.testing.expectEqualStrings("device", options[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("true", options[0].object.get("value").?.string);
}

fn hookContext(wire: []const u8, env_file: ?[]const u8) contract.Context {
    const root = if (@import("builtin").os.tag == .windows) "C:/p" else "/p";
    return .{
        .contract_version = wire,
        .invocation = .{ .kind = .hook, .id = "device", .step = .build, .phase = .before },
        .package_dir = root,
        .project_dir = root,
        .target = "ios",
        .lock_file = root,
        .config_file = null,
        .output_dir = root,
        .zig_executable = root,
        .optimize = .Debug,
        .progress = .human,
        .env_file = env_file,
    };
}

test "hook: writes env_file only for a device build on 1.6.0; refuses older wires" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const env_file = try std.fs.path.join(a, &.{ root, "env.json" });

    const sim = try settingsFor(a, "{\"schema_version\": 1, \"bundle_id\": \"com.a.b\"}");
    try std.testing.expectEqual(Decision.none, try hook(io, sim, hookContext("1.6.0", env_file)));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "env.json", .{}));

    const dev = try settingsFor(a, device_json);
    try std.testing.expectError(error.ContractTooOldForDevice, hook(io, dev, hookContext("1.5.0", env_file)));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "env.json", .{}));

    try std.testing.expectEqual(Decision.device, try hook(io, dev, hookContext("1.6.0", env_file)));
    try std.testing.expectEqualStrings(device_env_file, try tmp.dir.readFileAlloc(io, "env.json", a, .limited(1024)));
}
