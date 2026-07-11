const std = @import("std");
const paths_mod = @import("../paths.zig");
const crypto_mod = @import("../crypto.zig");
const runtime = @import("../runtime.zig");
const log = @import("../log.zig");

pub fn run(gpa: std.mem.Allocator, home: []const u8, args: []const []const u8) !void {
    validateArgs(args) catch |err| {
        log.err("unknown argument: {s}", .{args[0]});
        return err;
    };

    var paths = try paths_mod.Paths.init(gpa, home);
    defer paths.deinit();

    const key_path = try paths.masterKey();
    defer gpa.free(key_path);

    const key = readMasterKey(gpa, key_path) catch |err| {
        log.err("could not export master key at {s}: {s}", .{ key_path, @errorName(err) });
        return err;
    };

    var encoded: [crypto_mod.key_length * 2]u8 = undefined;
    encodeHex(key, &encoded);

    var stdout_buffer: [128]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(runtime.io(), &stdout_buffer);
    try stdout_writer.interface.writeAll(&encoded);
    try stdout_writer.interface.writeByte('\n');
    try stdout_writer.interface.flush();
}

fn validateArgs(args: []const []const u8) !void {
    if (args.len == 0) return;
    return error.UnknownArg;
}

fn readMasterKey(gpa: std.mem.Allocator, path: []const u8) !crypto_mod.Key {
    const bytes = std.Io.Dir.cwd().readFileAlloc(runtime.io(), path, gpa, .limited(crypto_mod.key_length + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.InvalidKeyFile,
        else => return err,
    };
    defer gpa.free(bytes);
    if (bytes.len != crypto_mod.key_length) return error.InvalidKeyFile;

    var key: crypto_mod.Key = undefined;
    @memcpy(&key, bytes);
    return key;
}

fn encodeHex(key: crypto_mod.Key, output: *[crypto_mod.key_length * 2]u8) void {
    const digits = "0123456789abcdef";
    for (key, 0..) |byte, index| {
        output[index * 2] = digits[byte >> 4];
        output[index * 2 + 1] = digits[byte & 0x0f];
    }
}

test "encodeHex emits init key-prompt format" {
    var key: crypto_mod.Key = undefined;
    for (&key, 0..) |*byte, index| byte.* = @intCast(index);

    var encoded: [crypto_mod.key_length * 2]u8 = undefined;
    encodeHex(key, &encoded);

    try std.testing.expectEqualStrings(
        "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
        &encoded,
    );
}

test "validateArgs rejects arguments" {
    try std.testing.expectError(error.UnknownArg, validateArgs(&.{"--show"}));
}

test "readMasterKey rejects files that are not exactly 32 bytes" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(std.testing.io, "master.key", .{});
    try file.writeStreamingAll(std.testing.io, &([_]u8{0x42} ** (crypto_mod.key_length - 1)));
    file.close(std.testing.io);

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const path = try std.fs.path.join(gpa, &.{ root, "master.key" });
    defer gpa.free(path);

    try std.testing.expectError(error.InvalidKeyFile, readMasterKey(gpa, path));
}
