//! nushell provider. `$env.KEY = "value"` with double-quote escaping.
//!
//! Nushell's single-quoted strings are fully raw (no escapes possible), so
//! any value containing `'` would be impossible to express that way. Using
//! double quotes with `\"`, `\\`, `\n`, `\r`, `\t` escapes handles every
//! byte unambiguously.
const std = @import("std");
const iface = @import("../provider.zig");

pub const provider: iface.Provider = .{
    .shell = .nushell,
    .file_extension = ".nu",
    .writeExportFn = writeExport,
    .writeSourceCommandFn = writeSourceCommand,
};

fn writeExport(w: *std.Io.Writer, env: iface.Env) std.Io.Writer.Error!void {
    try w.print("$env.{s} = ", .{env.key});
    try writeDoubleQuoted(w, env.value);
    try w.writeByte('\n');
}

fn writeSourceCommand(w: *std.Io.Writer, path: []const u8) std.Io.Writer.Error!void {
    try w.print("source {s}", .{path});
}

fn writeDoubleQuoted(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

test "nushell writeExport uses \\$env" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeExport(&aw.writer, .{ .key = "FOO", .value = "simple" });
    try std.testing.expectEqualStrings("$env.FOO = \"simple\"\n", aw.writer.buffered());
}

test "nushell escapes double quotes, backslashes, and newlines" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeExport(&aw.writer, .{ .key = "X", .value = "a\"b\\c\nd" });
    try std.testing.expectEqualStrings("$env.X = \"a\\\"b\\\\c\\nd\"\n", aw.writer.buffered());
}

test "nushell leaves single quotes untouched (they're literal inside double quotes)" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeExport(&aw.writer, .{ .key = "Y", .value = "it's fine" });
    try std.testing.expectEqualStrings("$env.Y = \"it's fine\"\n", aw.writer.buffered());
}
