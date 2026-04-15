const std = @import("std");

pub const Secret = struct {
    _value: []const u8,

    pub fn wrap(value: []const u8) Secret {
        return .{ ._value = value };
    }

    pub fn reveal(self: Secret) []const u8 {
        return self._value;
    }

    pub fn format(self: Secret, w: *std.io.Writer) std.io.Writer.Error!void {
        _ = self;
        try w.writeAll("[REDACTED]");
    }
};

const scope = std.log.scoped(.insh);

pub fn info(comptime fmt: []const u8, args: anytype) void {
    scope.info(fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    scope.warn(fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    scope.err(fmt, args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    scope.debug(fmt, args);
}

test "Secret redacts on format" {
    var buf: [64]u8 = undefined;
    const printed = try std.fmt.bufPrint(&buf, "value={f}", .{Secret.wrap("hunter2")});
    try std.testing.expectEqualStrings("value=[REDACTED]", printed);
    try std.testing.expect(std.mem.indexOf(u8, printed, "hunter2") == null);
}

test "Secret.reveal returns raw value" {
    const s = Secret.wrap("hunter2");
    try std.testing.expectEqualStrings("hunter2", s.reveal());
}
