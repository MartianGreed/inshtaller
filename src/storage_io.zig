//! Bounded reads, exclusive process locks and atomic private writes.
const std = @import("std");
const runtime = @import("runtime.zig");
pub fn read(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(runtime.io(), path, gpa, .limited(16 * 1024 * 1024));
}
pub fn exists(path: []const u8) !bool {
    std.Io.Dir.cwd().access(runtime.io(), path, .{}) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return e,
    };
    return true;
}
pub fn mkdir(path: []const u8) !void {
    _ = try std.Io.Dir.cwd().createDirPathStatus(runtime.io(), path, .fromMode(0o700));
}
pub fn write(gpa: std.mem.Allocator, path: []const u8, bytes: []const u8, mode: std.posix.mode_t) !void {
    var random: [8]u8 = undefined;
    runtime.io().random(&random);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.{x}.tmp", .{ path, random });
    defer gpa.free(tmp);
    const file = try std.Io.Dir.cwd().createFile(runtime.io(), tmp, .{ .exclusive = true, .permissions = .fromMode(mode) });
    defer std.Io.Dir.cwd().deleteFile(runtime.io(), tmp) catch {};
    defer file.close(runtime.io());
    try file.writeStreamingAll(runtime.io(), bytes);
    try file.sync(runtime.io());
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, runtime.io());
}
pub fn lock(gpa: std.mem.Allocator, root: []const u8) !std.Io.File {
    try mkdir(root);
    const path = try std.fs.path.join(gpa, &.{ root, ".lock" });
    defer gpa.free(path);
    const file = try std.Io.Dir.cwd().createFile(runtime.io(), path, .{ .truncate = false, .permissions = .fromMode(0o600) });
    errdefer file.close(runtime.io());
    if (!try file.tryLock(runtime.io(), .exclusive)) return error.ProfileBusy;
    return file;
}
