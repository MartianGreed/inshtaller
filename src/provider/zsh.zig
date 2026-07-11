//! zsh provider. Syntax is identical to bash (POSIX `export`), but kept as
//! its own file/tag so the two can diverge if needed (zsh-specific
//! `typeset -gx`, parameter expansion, etc.).
const std = @import("std");
const iface = @import("../provider.zig");

pub const provider: iface.Provider = .{
    .shell = .zsh,
    .file_extension = ".sh",
    .writeExportFn = writeExport,
    .writeSourceCommandFn = writeSourceCommand,
};

fn writeExport(w: *std.Io.Writer, env: iface.Env) std.Io.Writer.Error!void {
    try w.print("export {s}=", .{env.key});
    try writeSingleQuoted(w, env.value);
    try w.writeByte('\n');
}

fn writeSourceCommand(w: *std.Io.Writer, path: []const u8) std.Io.Writer.Error!void {
    try w.print("source {s}", .{path});
}

fn writeSingleQuoted(w: *std.Io.Writer, s: []const u8) !void {
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

test "zsh writeExport matches bash" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeExport(&aw.writer, .{ .key = "FOO", .value = "it's ok" });
    try std.testing.expectEqualStrings("export FOO='it'\\''s ok'\n", aw.writer.buffered());
}
