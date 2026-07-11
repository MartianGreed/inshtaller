//! fish provider. `set -gx KEY 'value'` syntax with fish's single-quote
//! escaping: `\\` for backslash and `\'` for single-quote. Every other byte
//! is literal inside single quotes.
const std = @import("std");
const iface = @import("../provider.zig");

pub const provider: iface.Provider = .{
    .shell = .fish,
    .file_extension = ".fish",
    .writeExportFn = writeExport,
    .writeSourceCommandFn = writeSourceCommand,
};

fn writeExport(w: *std.Io.Writer, env: iface.Env) std.Io.Writer.Error!void {
    try w.print("set -gx {s} ", .{env.key});
    try writeSingleQuoted(w, env.value);
    try w.writeByte('\n');
}

fn writeSourceCommand(w: *std.Io.Writer, path: []const u8) std.Io.Writer.Error!void {
    try w.print("source {s}", .{path});
}

fn writeSingleQuoted(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('\'');
    for (s) |c| {
        switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '\'' => try w.writeAll("\\'"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('\'');
}

test "fish writeExport uses set -gx" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeExport(&aw.writer, .{ .key = "FOO", .value = "simple" });
    try std.testing.expectEqualStrings("set -gx FOO 'simple'\n", aw.writer.buffered());
}

test "fish escapes single quotes and backslashes" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeExport(&aw.writer, .{ .key = "X", .value = "it's \\ok" });
    try std.testing.expectEqualStrings("set -gx X 'it\\'s \\\\ok'\n", aw.writer.buffered());
}
