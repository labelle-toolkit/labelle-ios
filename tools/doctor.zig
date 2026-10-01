//! `labelle ios doctor [--json] [--fix]`: probe what building, running and
//! signing iOS apps needs, and report it (RFC labelle-cli#471 I6).
//!
//! Checks, in order: a macOS host; `xcrun`; Xcode selected (`xcode-select
//! -p`, not the Command Line Tools); the Xcode license (`xcodebuild -license
//! check`); the iOS simulator and device SDKs; an iOS simulator runtime at
//! `minimum_ios` or newer (`simctl list -j runtimes`); `codesign`;
//! `devicectl` (Xcode 15+, device runs); the project's backend; and, for
//! `destination: "device"`, the signing identity and profile.
//!
//! A required miss makes the command fail; an optional one only warns.
//! `--json` prints one line on stdout instead, the capability object
//! `labelle doctor --json` aggregates (labelle-cli
//! `src/cli/provider_doctor_json.zig`, the shape labelle-android prints):
//!
//!     {"id":"ios", "required":true, "ok":bool, "items":[...]}
//!
//! `--fix` (labelle-cli#521, forwarded by `labelle doctor --fix`): nothing
//! here is fixed automatically, since every fix needs `sudo`, Xcode's UI or a
//! multi-gigabyte download, which a doctor must not start on its own. It
//! prints the exact command for each miss instead. The doctor never runs
//! `sudo`.
const std = @import("std");
const settings_mod = @import("settings.zig");
const simctl = @import("simctl.zig");
const proc = @import("proc.zig");

/// The capability id this provider reports.
pub const capability_id = "ios";

/// The one backend known to declare the `ios` capability today. Any other is
/// a warning, not a failure: the assembler is the authority (it refuses an
/// unsupported backend x target pair) and a new backend may add iOS.
pub const known_ios_backends = [_][]const u8{"sokol"};

/// A finished child process, as the checks see it.
pub const Output = struct {
    ok: bool,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
};

/// Runs a probe command. `error.FileNotFound` means the tool is absent.
pub const Exec = struct {
    ctx: *anyopaque,
    runFn: *const fn (ctx: *anyopaque, a: std.mem.Allocator, argv: []const []const u8) anyerror!Output,

    pub fn run(e: Exec, a: std.mem.Allocator, argv: []const []const u8) ?Output {
        return e.runFn(e.ctx, a, argv) catch null;
    }
};

/// The real `Exec`: the tool is looked up on `env`'s PATH (absent is
/// `FileNotFound`) and run to completion.
pub const SystemExec = struct {
    io: std.Io,
    env: *const std.process.Environ.Map,

    fn run(ctx: *anyopaque, a: std.mem.Allocator, argv: []const []const u8) anyerror!Output {
        const self: *SystemExec = @ptrCast(@alignCast(ctx));
        const exe = (try proc.findOnPath(a, self.io, self.env, argv[0])) orelse return error.FileNotFound;
        const full = try a.dupe([]const u8, argv);
        full[0] = exe;
        const r = try proc.run(a, self.io, full, .{});
        return .{ .ok = proc.succeeded(r.term), .stdout = r.stdout, .stderr = r.stderr };
    }

    pub fn exec(self: *SystemExec) Exec {
        return .{ .ctx = self, .runFn = run };
    }
};

pub const Options = struct {
    host_macos: bool,
    /// `minimum_ios` from the settings (else the default).
    minimum_ios: []const u8 = "15.0",
    destination: settings_mod.Destination = .simulator,
    identity: ?[]const u8 = null,
    /// The resolved `signing.profile`, and whether it exists.
    profile: ?[]const u8 = null,
    profile_exists: bool = false,
    /// The project's backend; null outside a project (no check).
    backend: ?[]const u8 = null,
    in_project: bool = false,
};

pub const Check = struct {
    id: []const u8,
    name: []const u8,
    required: bool,
    ok: bool,
    detail: ?[]const u8 = null,
    hint: ?[]const u8 = null,
    /// The exact command that fixes the miss, when there is one.
    fix: ?[]const u8 = null,
};

pub const Summary = struct { failures: usize, warnings: usize };

pub const select_xcode = "sudo xcode-select -s /Applications/Xcode.app/Contents/Developer";
pub const accept_license = "sudo xcodebuild -license accept";
pub const download_runtime = "xcodebuild -downloadPlatform iOS";
pub const install_clt = "xcode-select --install";

fn firstLine(text: []const u8) []const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    return t[0 .. std.mem.indexOfScalar(u8, t, '\n') orelse t.len];
}

/// Run every probe. Allocations borrow from `a`.
pub fn detect(a: std.mem.Allocator, exec: Exec, o: Options) ![]Check {
    var checks: std.ArrayList(Check) = .empty;
    if (!o.host_macos) {
        try checks.append(a, .{ .id = "macos", .name = "macOS host", .required = true, .ok = false, .hint = "building and running iOS apps needs macOS with Xcode; this host cannot" });
        return checks.items;
    }
    try checks.append(a, .{ .id = "macos", .name = "macOS host", .required = true, .ok = true });

    // xcrun: the entry point of every Xcode tool.
    const xcrun = exec.run(a, &.{ "xcrun", "--version" });
    try checks.append(a, .{
        .id = "xcrun",
        .name = "xcrun",
        .required = true,
        .ok = xcrun != null and xcrun.?.ok,
        .detail = if (xcrun) |r| if (r.ok) firstLine(r.stdout) else null else null,
        .hint = "install Xcode from the App Store (or the command line tools: xcode-select --install)",
        .fix = install_clt,
    });

    // Xcode, not the Command Line Tools: only Xcode has the iOS SDKs and simctl.
    const selected = exec.run(a, &.{ "xcode-select", "-p" });
    const dev_dir = if (selected) |r| (if (r.ok) std.mem.trim(u8, r.stdout, " \t\r\n") else null) else null;
    const xcode_ok = if (dev_dir) |d| std.mem.indexOf(u8, d, ".app/Contents/Developer") != null else false;
    var xcode_detail: ?[]const u8 = dev_dir;
    if (xcode_ok) {
        if (exec.run(a, &.{ "xcodebuild", "-version" })) |v| {
            if (v.ok) xcode_detail = try std.fmt.allocPrint(a, "{s} ({s})", .{ firstLine(v.stdout), dev_dir.? });
        }
    }
    try checks.append(a, .{
        .id = "xcode",
        .name = "Xcode selected",
        .required = true,
        .ok = xcode_ok,
        .detail = xcode_detail,
        .hint = if (dev_dir != null)
            "the active developer directory is not Xcode (the Command Line Tools have no iOS SDK); install Xcode and select it"
        else
            "install Xcode and select it",
        .fix = select_xcode,
    });

    // The license: until it is accepted, xcodebuild and the SDK tools refuse.
    const license = if (xcode_ok) exec.run(a, &.{ "xcodebuild", "-license", "check" }) else null;
    try checks.append(a, .{
        .id = "license",
        .name = "Xcode license accepted",
        .required = true,
        .ok = license != null and license.?.ok,
        .hint = if (xcode_ok) "the Xcode license has not been accepted" else "select Xcode first",
        .fix = accept_license,
    });

    // SDKs. The simulator SDK is always needed (and is what the simulator
    // runs); the device SDK for a device build.
    for ([_]struct { id: []const u8, name: []const u8, sdk: []const u8, required: bool }{
        .{ .id = "sdk_simulator", .name = "iOS Simulator SDK", .sdk = "iphonesimulator", .required = o.destination == .simulator },
        .{ .id = "sdk_device", .name = "iOS device SDK", .sdk = "iphoneos", .required = o.destination == .device },
    }) |sdk| {
        const r = if (xcode_ok) exec.run(a, &.{ "xcrun", "--sdk", sdk.sdk, "--show-sdk-path" }) else null;
        const ok = r != null and r.?.ok;
        try checks.append(a, .{
            .id = sdk.id,
            .name = sdk.name,
            .required = sdk.required,
            .ok = ok,
            .detail = if (ok) std.mem.trim(u8, r.?.stdout, " \t\r\n") else null,
            .hint = if (xcode_ok) "the SDK is missing from the selected Xcode (reinstall Xcode, or accept the license)" else "select Xcode first",
        });
    }

    // A simulator runtime the app can install on.
    const minimum = settings_mod.osTriple(o.minimum_ios) orelse .{ 15, 0, 0 };
    var runtime_detail: ?[]const u8 = null;
    var runtime_ok = false;
    if (xcode_ok) if (exec.run(a, &(.{"xcrun"} ++ simctl.runtimes_args))) |r| {
        if (r.ok) {
            if (simctl.parseRuntimes(a, r.stdout)) |runtimes| {
                var names: std.ArrayList(u8) = .empty;
                for (runtimes) |rt| {
                    if (!rt.available) continue;
                    if (names.items.len > 0) try names.appendSlice(a, ", ");
                    try names.appendSlice(a, rt.name);
                }
                runtime_ok = simctl.newestRuntime(runtimes, minimum) != null;
                runtime_detail = if (names.items.len > 0) names.items else "none installed";
            } else |_| runtime_detail = "simctl printed an unexpected runtime list";
        }
    };
    try checks.append(a, .{
        .id = "simulator_runtime",
        .name = try std.fmt.allocPrint(a, "iOS simulator runtime ({s}+)", .{o.minimum_ios}),
        .required = o.destination == .simulator,
        .ok = runtime_ok,
        .detail = runtime_detail,
        .hint = try std.fmt.allocPrint(a, "install an iOS {s}+ simulator runtime (Xcode > Settings > Components)", .{o.minimum_ios}),
        .fix = download_runtime,
    });

    // codesign: every app is signed (ad hoc for the simulator).
    const codesign = exec.run(a, &.{ "codesign", "--help" });
    try checks.append(a, .{
        .id = "codesign",
        .name = "codesign",
        // `codesign --help` exits non-zero but prints usage: present is enough.
        .required = true,
        .ok = codesign != null,
        .hint = "codesign ships with the Xcode command line tools",
        .fix = install_clt,
    });

    // devicectl: running on a physical device (Xcode 15+).
    const devicectl = if (xcode_ok) exec.run(a, &.{ "xcrun", "--find", "devicectl" }) else null;
    const devicectl_ok = devicectl != null and devicectl.?.ok;
    try checks.append(a, .{
        .id = "devicectl",
        .name = "devicectl (device runs)",
        .required = o.destination == .device,
        .ok = devicectl_ok,
        .detail = if (devicectl_ok) std.mem.trim(u8, devicectl.?.stdout, " \t\r\n") else null,
        .hint = "Xcode 15 or newer runs apps on devices from the command line; otherwise use `labelle ios xcode`",
    });

    // The backend: only one declares iOS today.
    if (o.in_project) {
        const name = o.backend;
        var known = false;
        if (name) |n| for (known_ios_backends) |k| {
            if (std.mem.eql(u8, n, k)) known = true;
        };
        try checks.append(a, .{
            .id = "backend",
            .name = "backend builds iOS",
            .required = false,
            .ok = known,
            .detail = name,
            .hint = if (name) |n|
                try std.fmt.allocPrint(a, "backend '{s}' is not known to build iOS (labelle-sokol does: .backend = .sokol); the build will say if it cannot", .{n})
            else
                "project.labelle names no .backend (labelle-sokol builds iOS: .backend = .sokol)",
        });
    }

    // Device signing.
    if (o.destination == .device) {
        var identity_ok = false;
        if (o.identity) |want| if (exec.run(a, &.{ "security", "find-identity", "-v", "-p", "codesigning" })) |r| {
            identity_ok = r.ok and std.mem.indexOf(u8, r.stdout, want) != null;
        };
        try checks.append(a, .{
            .id = "signing_identity",
            .name = "signing identity",
            .required = true,
            .ok = identity_ok,
            .detail = o.identity,
            .hint = "the signing.identity is not in the keychain: list the valid ones with `security find-identity -v -p codesigning` (create one in Xcode > Settings > Accounts)",
        });
        try checks.append(a, .{
            .id = "signing_profile",
            .name = "provisioning profile",
            .required = true,
            .ok = o.profile_exists,
            .detail = o.profile,
            .hint = "the signing.profile file does not exist (download it from developer.apple.com, or Xcode > Settings > Accounts)",
        });
    }
    return checks.items;
}

pub fn summarize(checks: []const Check) Summary {
    var s: Summary = .{ .failures = 0, .warnings = 0 };
    for (checks) |c| {
        if (c.ok) continue;
        if (c.required) s.failures += 1 else s.warnings += 1;
    }
    return s;
}

pub const Item = struct {
    id: []const u8,
    name: []const u8,
    ok: bool,
    fixable: bool,
    size_mb: u32,
    action: ?[]const u8,
    detail: ?[]const u8,
    hint: ?[]const u8,
};

pub const Capability = struct {
    id: []const u8 = capability_id,
    required: bool = true,
    ok: bool,
    items: []const Item,
};

/// The checks as the capability object `--json` prints. Nothing is fixable
/// by the tool: a miss's command is part of its hint.
pub fn capability(a: std.mem.Allocator, checks: []const Check) !Capability {
    const items = try a.alloc(Item, checks.len);
    for (checks, items) |c, *item| item.* = .{
        .id = c.id,
        .name = c.name,
        .ok = c.ok,
        .fixable = false,
        .size_mb = 0,
        .action = null,
        .detail = c.detail,
        .hint = if (c.ok) null else if (c.fix) |fix| try std.fmt.allocPrint(a, "{s} (run: {s})", .{ c.hint.?, fix }) else c.hint,
    };
    return .{ .ok = summarize(checks).failures == 0, .items = items };
}

pub fn writeJson(a: std.mem.Allocator, checks: []const Check, out: *std.Io.Writer) !void {
    try std.json.Stringify.value(try capability(a, checks), .{}, out);
    try out.writeByte('\n');
    try out.flush();
}

/// The human report.
pub fn writeReport(checks: []const Check, fix: bool, out: *std.Io.Writer) !void {
    try out.writeAll("\nlabelle ios doctor\n==================\n");
    for (checks) |c| {
        const tag = if (c.ok) "  OK  " else if (c.required) " FAIL " else " WARN ";
        try out.print("  [{s}] {s}\n", .{ tag, c.name });
        if (c.detail) |d| try out.print("           {s}\n", .{d});
        if (!c.ok) {
            if (c.hint) |h| try out.print("           -> {s}\n", .{h});
            if (c.fix) |f| try out.print("              run: {s}\n", .{f});
        }
    }
    const s = summarize(checks);
    try out.writeAll("\n");
    if (s.failures == 0) {
        try out.writeAll("  Everything iOS builds need is present.\n");
        if (s.warnings > 0) try out.print("  ({d} optional item(s) missing: see WARN lines above.)\n", .{s.warnings});
    } else try out.print("  {d} required item(s) missing: see FAIL lines above.\n", .{s.failures});
    if (fix) try writeFixes(checks, out);
    try out.writeAll("\n");
    try out.flush();
}

/// `--fix`: the commands to run, in order; nothing is run.
pub fn writeFixes(checks: []const Check, out: *std.Io.Writer) !void {
    var any = false;
    for (checks) |c| {
        if (c.ok) continue;
        const f = c.fix orelse continue;
        if (!any) try out.writeAll("\n  --fix: nothing is fixed automatically (these need sudo, Xcode or a large download). Run:\n");
        any = true;
        try out.print("    {s}\n", .{f});
    }
    if (!any) try out.writeAll("\n  --fix: nothing to fix automatically.\n");
}

// ── Tests: a fake xcrun / xcode-select / xcodebuild ───────────────────────

const Fake = struct {
    /// `argv joined by spaces` → output; absent means the tool is missing.
    answers: []const struct { []const u8, Output },

    fn run(ctx: *anyopaque, a: std.mem.Allocator, argv: []const []const u8) anyerror!Output {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        const key = try std.mem.join(a, " ", argv);
        for (self.answers) |entry| if (std.mem.eql(u8, entry[0], key)) return entry[1];
        return error.FileNotFound;
    }

    fn exec(self: *Fake) Exec {
        return .{ .ctx = self, .runFn = run };
    }
};

const healthy = [_]struct { []const u8, Output }{
    .{ "xcrun --version", .{ .ok = true, .stdout = "xcrun version 70.\n" } },
    .{ "xcode-select -p", .{ .ok = true, .stdout = "/Applications/Xcode.app/Contents/Developer\n" } },
    .{ "xcodebuild -version", .{ .ok = true, .stdout = "Xcode 16.2\nBuild version 16C5032a\n" } },
    .{ "xcodebuild -license check", .{ .ok = true } },
    .{ "xcrun --sdk iphonesimulator --show-sdk-path", .{ .ok = true, .stdout = "/X/iPhoneSimulator18.2.sdk\n" } },
    .{ "xcrun --sdk iphoneos --show-sdk-path", .{ .ok = true, .stdout = "/X/iPhoneOS18.2.sdk\n" } },
    .{ "xcrun simctl list -j runtimes", .{ .ok = true, .stdout = simctl.runtimes_fixture } },
    .{ "codesign --help", .{ .ok = false, .stderr = "Usage: codesign ..." } },
    .{ "xcrun --find devicectl", .{ .ok = true, .stdout = "/X/usr/bin/devicectl\n" } },
    .{ "security find-identity -v -p codesigning", .{ .ok = true, .stdout = "  1) ABCD \"Apple Development: Jo (ABCDE12345)\"\n     1 valid identities found\n" } },
};

fn find(checks: []const Check, id: []const u8) Check {
    for (checks) |c| if (std.mem.eql(u8, c.id, id)) return c;
    @panic("no such check");
}

test "doctor: a healthy Xcode passes every check, and the JSON is the capability object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{ .answers = &healthy };
    const checks = try detect(a, fake.exec(), .{ .host_macos = true, .in_project = true, .backend = "sokol" });
    for (checks) |c| if (!c.ok) {
        std.debug.print("unexpected miss: {s}\n", .{c.id});
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqualStrings("Xcode 16.2 (/Applications/Xcode.app/Contents/Developer)", find(checks, "xcode").detail.?);
    try std.testing.expectEqualStrings("iOS 17.5, iOS 18.2", find(checks, "simulator_runtime").detail.?);

    var out: std.Io.Writer.Allocating = .init(a);
    try writeJson(a, checks, &out.writer);
    const line = out.written();
    try std.testing.expect(std.mem.endsWith(u8, line, "}\n") and std.mem.count(u8, line, "\n") == 1);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
    const o = parsed.object;
    try std.testing.expectEqualStrings("ios", o.get("id").?.string);
    try std.testing.expect(o.get("required").?.bool);
    try std.testing.expect(o.get("ok").?.bool);
    const items = o.get("items").?.array.items;
    try std.testing.expectEqual(checks.len, items.len);
    for (items) |item| {
        for ([_][]const u8{ "id", "name", "ok", "fixable", "size_mb", "action", "detail", "hint" }) |key| {
            try std.testing.expect(item.object.contains(key));
        }
        try std.testing.expectEqual(@as(usize, 8), item.object.count());
    }
}

test "doctor: the Command Line Tools and an unaccepted license fail with the exact commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // This Mac as the RFC describes it: CLT selected, license not accepted.
    var fake: Fake = .{ .answers = &.{
        .{ "xcrun --version", .{ .ok = true, .stdout = "xcrun version 70.\n" } },
        .{ "xcode-select -p", .{ .ok = true, .stdout = "/Library/Developer/CommandLineTools\n" } },
        .{ "codesign --help", .{ .ok = false } },
    } };
    const checks = try detect(a, fake.exec(), .{ .host_macos = true });
    try std.testing.expect(!find(checks, "xcode").ok);
    try std.testing.expectEqualStrings("/Library/Developer/CommandLineTools", find(checks, "xcode").detail.?);
    try std.testing.expect(!find(checks, "license").ok);
    try std.testing.expect(!find(checks, "simulator_runtime").ok);
    try std.testing.expect(find(checks, "codesign").ok);
    // Outside a project: no backend check.
    for (checks) |c| try std.testing.expect(!std.mem.eql(u8, c.id, "backend"));
    try std.testing.expect(summarize(checks).failures >= 4);

    var out: std.Io.Writer.Allocating = .init(a);
    try writeReport(checks, true, &out.writer);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "[ FAIL ] Xcode selected") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "--fix: nothing is fixed automatically") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "    " ++ select_xcode ++ "\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "    " ++ accept_license ++ "\n") != null);

    // The JSON puts the command in the hint; the capability fails.
    const cap = try capability(a, checks);
    try std.testing.expect(!cap.ok);
    for (cap.items) |item| if (std.mem.eql(u8, item.id, "license")) {
        try std.testing.expect(std.mem.indexOf(u8, item.hint.?, accept_license) != null);
        try std.testing.expect(!item.fixable);
    };
}

test "doctor: the license alone missing, and a runtime below minimum_ios" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var answers = healthy;
    answers[3] = .{ "xcodebuild -license check", .{ .ok = false, .stderr = "You have not agreed to the Xcode license agreements." } };
    var fake: Fake = .{ .answers = &answers };
    const checks = try detect(a, fake.exec(), .{ .host_macos = true, .minimum_ios = "19.0" });
    try std.testing.expect(!find(checks, "license").ok);
    try std.testing.expect(!find(checks, "simulator_runtime").ok);
    try std.testing.expectEqualStrings("iOS simulator runtime (19.0+)", find(checks, "simulator_runtime").name);
    try std.testing.expectEqual(@as(usize, 2), summarize(checks).failures);
}

test "doctor: a device destination requires devicectl, the device SDK and signing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{ .answers = &healthy };
    const ok = try detect(a, fake.exec(), .{ .host_macos = true, .destination = .device, .identity = "Apple Development: Jo (ABCDE12345)", .profile = "/p/dev.mobileprovision", .profile_exists = true });
    try std.testing.expectEqual(@as(usize, 0), summarize(ok).failures);
    try std.testing.expect(find(ok, "devicectl").required and find(ok, "sdk_device").required);
    try std.testing.expect(!find(ok, "simulator_runtime").required);

    const bad = try detect(a, fake.exec(), .{ .host_macos = true, .destination = .device, .identity = "Apple Distribution: Nobody", .profile = "/p/missing.mobileprovision" });
    try std.testing.expect(!find(bad, "signing_identity").ok and !find(bad, "signing_profile").ok);
    try std.testing.expectEqual(@as(usize, 2), summarize(bad).failures);
}

test "doctor: an unknown backend warns, a non-macOS host fails at once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{ .answers = &healthy };
    const checks = try detect(a, fake.exec(), .{ .host_macos = true, .in_project = true, .backend = "raylib" });
    const backend = find(checks, "backend");
    try std.testing.expect(!backend.ok and !backend.required);
    try std.testing.expectEqual(Summary{ .failures = 0, .warnings = 1 }, summarize(checks));

    const other = try detect(a, fake.exec(), .{ .host_macos = false });
    try std.testing.expectEqual(@as(usize, 1), other.len);
    try std.testing.expect(!other[0].ok);
    var out: std.Io.Writer.Allocating = .init(a);
    try writeReport(other, true, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "--fix: nothing to fix automatically") != null);
}
