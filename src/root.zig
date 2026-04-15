//! Library module for inshtaller. Re-exports the pieces needed for testing.
const std = @import("std");

pub const paths = @import("paths.zig");
pub const config = @import("config.zig");
pub const crypto = @import("crypto.zig");
pub const git = @import("git.zig");
pub const log = @import("log.zig");
pub const provider = @import("provider.zig");
pub const Secret = log.Secret;

test {
    std.testing.refAllDeclsRecursive(@This());
}
