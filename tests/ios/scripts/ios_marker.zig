//! The fixture's proof of life: log lines `tests/ios/sim_e2e.py` waits for in
//! the simulator console (`simctl launch --console-pty`). The first frame also
//! echoes `LABELLE_SCENE`, which `labelle run --scene=` hands the app through
//! the launch environment (`SIMCTL_CHILD_LABELLE_SCENE`).
const std = @import("std");

var frames: u32 = 0;

pub fn tick(_: anytype, _: f32) void {
    frames += 1;
    if (frames == 1) {
        const scene: []const u8 = if (std.c.getenv("LABELLE_SCENE")) |s| std.mem.span(s) else "(unset)";
        std.debug.print("LABELLE_IOS_FIXTURE first frame LABELLE_SCENE={s}\n", .{scene});
    }
    if (frames == 120) std.debug.print("LABELLE_IOS_FIXTURE frame 120\n", .{});
}
