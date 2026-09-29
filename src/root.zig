//! labelle-ios: the `labelle_ios` module.
//!
//! It carries no runtime code: the package is the `ios` CLI provider
//! (`plugin.labelle`, `tools/`). The module exists because the assembler wires
//! every `.plugins` entry into the generated build as a dependency and imports
//! its `labelle_<name>` module, so a project that pins this provider must find
//! one. iOS runtime services (lifecycle, safe areas, ...) will live here.

/// The provider release this module ships with.
pub const version = "0.2.0";

test "the module is importable" {
    const std = @import("std");
    try std.testing.expectEqualStrings("0.2.0", version);
}
