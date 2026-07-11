const std = @import("std");
const builtin = @import("builtin");

var runtime_io: std.Io = undefined;

pub fn init(value: std.Io) void {
    runtime_io = value;
}

pub fn io() std.Io {
    return if (builtin.is_test) std.testing.io else runtime_io;
}
