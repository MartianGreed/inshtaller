//! bash provider. POSIX `export KEY='value'` with single-quote escaping.
const std = @import("std");
const iface = @import("../provider.zig");

pub const provider: iface.Provider = .{
    .shell = .bash,
    .file_extension = ".sh",
    .writeExportFn = writeExport,
    .writeSourceCommandFn = writeSourceCommand,
};

fn writeExport(w: *std.io.Writer, env: iface.Env) std.io.Writer.Error!void {
    try w.print("export {s}=", .{env.key});
    try writeSingleQuoted(w, env.value);
    try w.writeByte('\n');
}

fn writeSourceCommand(w: *std.io.Writer, path: []const u8) std.io.Writer.Error!void {
    try w.print("source {s}", .{path});
}

/// POSIX single-quote escaping: `'` → `'\''` (close, escaped, reopen).
/// Every byte other than `'` is literal inside single quotes.
fn writeSingleQuoted(w: *std.io.Writer, s: []const u8) !void {
    try w.writeByte('\'');
    for (s) |c| {
        if (c == '\'') {
            try w.writeAll("'\\''");
        } else {
            try w.writeByte(c);
        }
    }
    try w.writeByte('\'');
}

test "bash writeExport escapes single quotes" {
    const gpa = std.testing.allocator;
    var aw: std.io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeExport(&aw.writer, .{ .key = "FOO", .value = "qu'ux" });
    try std.testing.expectEqualStrings("export FOO='qu'\\''ux'\n", aw.writer.buffered());
}

test "bash writeExport wraps plain value" {
    const gpa = std.testing.allocator;
    var aw: std.io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeExport(&aw.writer, .{ .key = "BAR", .value = "simple" });
    try std.testing.expectEqualStrings("export BAR='simple'\n", aw.writer.buffered());
}

test "bash writeSourceCommand" {
    const gpa = std.testing.allocator;
    var aw: std.io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeSourceCommand(&aw.writer, "/home/x/.inshtaller/env.sh");
    try std.testing.expectEqualStrings("source /home/x/.inshtaller/env.sh", aw.writer.buffered());
}
