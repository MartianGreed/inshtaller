const std = @import("std");
const paths_mod = @import("../paths.zig");
const crypto_mod = @import("../crypto.zig");
const config_mod = @import("../config.zig");
const log = @import("../log.zig");
const Secret = @import("../log.zig").Secret;

pub fn run(gpa: std.mem.Allocator, args: []const []const u8) !void {
    var type_opt: ?[]const u8 = null;
    var key_opt: ?[]const u8 = null;
    var value_opt: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--type")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            type_opt = args[i];
        } else if (std.mem.eql(u8, a, "--key")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            key_opt = args[i];
        } else if (std.mem.eql(u8, a, "--value")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            value_opt = args[i];
        } else {
            log.err("unknown argument: {s}", .{a});
            return error.UnknownArg;
        }
    }

    const type_s = type_opt orelse return error.MissingType;
    const key = key_opt orelse return error.MissingKey;
    const value = value_opt orelse return error.MissingValue;

    if (!std.mem.eql(u8, type_s, "env")) {
        log.err("unsupported --type: {s} (only 'env' is supported in v1)", .{type_s});
        return error.UnsupportedType;
    }

    if (!isValidKey(key)) {
        log.err("invalid --key: {s} (must match [A-Za-z_][A-Za-z0-9_]*)", .{key});
        return error.InvalidKey;
    }

    var p = try paths_mod.Paths.init(gpa);
    defer p.deinit();

    const key_path = try p.masterKey();
    defer gpa.free(key_path);
    const master: crypto_mod.Key = readMasterKey(key_path) catch |e| {
        log.err("could not read master key at {s}: {s}", .{ key_path, @errorName(e) });
        return error.NoMasterKey;
    };

    const cfg_path = try p.config();
    defer gpa.free(cfg_path);
    const cfg_src = std.fs.cwd().readFileAlloc(gpa, cfg_path, 1 * 1024 * 1024) catch |e| {
        log.err("could not read {s}: {s}. Run `insh init` first.", .{ cfg_path, @errorName(e) });
        return error.NotInitialized;
    };
    defer gpa.free(cfg_src);

    var cfg = try config_mod.parse(gpa, cfg_src);
    defer cfg.deinit();

    try cfg.addKey(key);
    const new_src = try config_mod.emitToOwnedSlice(gpa, cfg);
    defer gpa.free(new_src);
    try atomicWriteFile(gpa, cfg_path, new_src, 0o644);

    const pending_dir = try p.pending();
    defer gpa.free(pending_dir);
    try std.fs.cwd().makePath(pending_dir);

    const enc = try crypto_mod.encrypt(gpa, value, master);
    defer gpa.free(enc);

    const enc_name = try std.fmt.allocPrint(gpa, "{s}.enc", .{key});
    defer gpa.free(enc_name);
    const enc_path = try std.fs.path.join(gpa, &.{ pending_dir, enc_name });
    defer gpa.free(enc_path);

    try atomicWriteFile(gpa, enc_path, enc, 0o600);

    log.info("added key {s} (value {f}); run `insh sync` to push to backend", .{ key, Secret.wrap(value) });
}

fn isValidKey(key: []const u8) bool {
    if (key.len == 0) return false;
    const first = key[0];
    if (!(std.ascii.isAlphabetic(first) or first == '_')) return false;
    for (key[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

fn readMasterKey(path: []const u8) !crypto_mod.Key {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var key: crypto_mod.Key = undefined;
    const n = try file.readAll(&key);
    if (n != key.len) return error.InvalidKeyFile;
    return key;
}

fn atomicWriteFile(gpa: std.mem.Allocator, path: []const u8, bytes: []const u8, mode: std.fs.File.Mode) !void {
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp_path);

    {
        var file = try std.fs.cwd().createFile(tmp_path, .{
            .mode = mode,
            .truncate = true,
        });
        defer file.close();
        try file.writeAll(bytes);
        try file.sync();
    }
    try std.fs.cwd().rename(tmp_path, path);
}

test "isValidKey accepts standard env names" {
    try std.testing.expect(isValidKey("FOO"));
    try std.testing.expect(isValidKey("FOO_BAR"));
    try std.testing.expect(isValidKey("_private"));
    try std.testing.expect(isValidKey("A1"));
}

test "isValidKey rejects bad names" {
    try std.testing.expect(!isValidKey(""));
    try std.testing.expect(!isValidKey("1FOO"));
    try std.testing.expect(!isValidKey("FOO-BAR"));
    try std.testing.expect(!isValidKey("FOO BAR"));
}
