const std = @import("std");
const paths_mod = @import("../paths.zig");
const crypto_mod = @import("../crypto.zig");
const config_mod = @import("../config.zig");
const log = @import("../log.zig");
const Secret = @import("../log.zig").Secret;
const runtime = @import("../runtime.zig");

pub fn run(gpa: std.mem.Allocator, home: []const u8, args: []const []const u8) !void {
    const parsed = parseArgs(args) catch |e| switch (e) {
        error.InsecureValueArgument => {
            log.err("--value is no longer accepted because argv is visible to other local processes; use the hidden prompt or pass --stdin", .{});
            return e;
        },
        else => return e,
    };

    if (!std.mem.eql(u8, parsed.type_s, "env")) {
        log.err("unsupported --type: {s} (only 'env' is supported in v1)", .{parsed.type_s});
        return error.UnsupportedType;
    }

    if (!isValidKey(parsed.key)) {
        log.err("invalid --key: {s} (must match [A-Za-z_][A-Za-z0-9_]*)", .{parsed.key});
        return error.InvalidKey;
    }

    const value = try readSecretValue(gpa, parsed.read_from_stdin);
    defer gpa.free(value);

    var p = try paths_mod.Paths.init(gpa, home);
    defer p.deinit();

    const key_path = try p.masterKey();
    defer gpa.free(key_path);
    const master: crypto_mod.Key = readMasterKey(key_path) catch |e| {
        log.err("could not read master key at {s}: {s}", .{ key_path, @errorName(e) });
        return error.NoMasterKey;
    };

    const cfg_path = try p.config();
    defer gpa.free(cfg_path);
    const cfg_src = std.Io.Dir.cwd().readFileAlloc(runtime.io(), cfg_path, gpa, .limited(1 * 1024 * 1024)) catch |e| {
        log.err("could not read {s}: {s}. Run `insh init` first.", .{ cfg_path, @errorName(e) });
        return error.NotInitialized;
    };
    defer gpa.free(cfg_src);

    var cfg = try config_mod.parse(gpa, cfg_src);
    defer cfg.deinit();

    try cfg.addKey(parsed.key);
    const new_src = try config_mod.emitToOwnedSlice(gpa, cfg);
    defer gpa.free(new_src);
    try atomicWriteFile(gpa, cfg_path, new_src, 0o644);

    const pending_dir = try p.pending();
    defer gpa.free(pending_dir);
    try std.Io.Dir.cwd().createDirPath(runtime.io(), pending_dir);

    const enc = try crypto_mod.encrypt(gpa, value, master);
    defer gpa.free(enc);

    const enc_name = try std.fmt.allocPrint(gpa, "{s}.enc", .{parsed.key});
    defer gpa.free(enc_name);
    const enc_path = try std.fs.path.join(gpa, &.{ pending_dir, enc_name });
    defer gpa.free(enc_path);

    try atomicWriteFile(gpa, enc_path, enc, 0o600);

    log.info("added key {s} (value {f}); run `insh sync` to push to backend", .{ parsed.key, Secret.wrap(value) });
}

const ParsedArgs = struct {
    type_s: []const u8,
    key: []const u8,
    read_from_stdin: bool,
};

fn parseArgs(args: []const []const u8) !ParsedArgs {
    var type_opt: ?[]const u8 = null;
    var key_opt: ?[]const u8 = null;
    var read_from_stdin = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--type")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            type_opt = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--key")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            key_opt = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--stdin")) {
            read_from_stdin = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--value")) {
            return error.InsecureValueArgument;
        }

        log.err("unknown argument: {s}", .{a});
        return error.UnknownArg;
    }

    return .{
        .type_s = type_opt orelse return error.MissingType,
        .key = key_opt orelse return error.MissingKey,
        .read_from_stdin = read_from_stdin,
    };
}

fn readSecretValue(gpa: std.mem.Allocator, read_from_stdin: bool) ![]u8 {
    if (read_from_stdin) {
        var buffer: [4096]u8 = undefined;
        var reader = std.Io.File.stdin().readerStreaming(runtime.io(), &buffer);
        const raw = try reader.interface.allocRemaining(gpa, .limited(1 * 1024 * 1024));
        errdefer gpa.free(raw);
        const trimmed = std.mem.trim(u8, raw, "\r\n");
        if (trimmed.len == 0) return error.MissingValue;
        return gpa.dupe(u8, trimmed);
    }

    if (!(std.Io.File.stdin().isTty(runtime.io()) catch false)) {
        log.err("refusing to prompt for a secret on non-interactive stdin; pass --stdin to read the value from stdin", .{});
        return error.NonInteractiveStdin;
    }

    var stdin_buf: [4096]u8 = undefined;
    var stdin_r = std.Io.File.stdin().reader(runtime.io(), &stdin_buf);
    const stdin = &stdin_r.interface;

    var stdout_buf: [256]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(runtime.io(), &stdout_buf);
    const stdout = &stdout_w.interface;

    const raw = try promptLine(gpa, stdin, stdout, "Secret value (input hidden): ", true);
    defer gpa.free(raw);

    const trimmed = std.mem.trim(u8, raw, "\r\n");
    if (trimmed.len == 0) return error.MissingValue;
    return gpa.dupe(u8, trimmed);
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
    const bytes = try std.Io.Dir.cwd().readFileAlloc(runtime.io(), path, std.heap.page_allocator, .limited(crypto_mod.key_length + 1));
    defer std.heap.page_allocator.free(bytes);
    if (bytes.len != crypto_mod.key_length) return error.InvalidKeyFile;
    var key: crypto_mod.Key = undefined;
    @memcpy(&key, bytes);
    return key;
}

fn promptLine(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    prompt: []const u8,
    hide_input: bool,
) ![]u8 {
    try writer.writeAll(prompt);
    try writer.flush();

    const stdin_fd = std.posix.STDIN_FILENO;
    var original: ?std.posix.termios = null;
    if (hide_input and (std.Io.File.stdin().isTty(runtime.io()) catch false)) {
        if (std.posix.tcgetattr(stdin_fd)) |t| {
            original = t;
            var modified = t;
            modified.lflag.ECHO = false;
            std.posix.tcsetattr(stdin_fd, .NOW, modified) catch {};
        } else |_| {}
    }
    defer {
        if (original) |t| std.posix.tcsetattr(stdin_fd, .NOW, t) catch {};
        if (hide_input) {
            writer.writeByte('\n') catch {};
            writer.flush() catch {};
        }
    }

    const line = reader.takeDelimiterInclusive('\n') catch |e| switch (e) {
        error.EndOfStream => return error.InputAborted,
        else => return e,
    };
    return gpa.dupe(u8, line);
}

fn atomicWriteFile(gpa: std.mem.Allocator, path: []const u8, bytes: []const u8, mode: std.posix.mode_t) !void {
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp_path);

    {
        var file = try std.Io.Dir.cwd().createFile(runtime.io(), tmp_path, .{
            .permissions = .fromMode(mode),
            .truncate = true,
        });
        defer file.close(runtime.io());
        try file.writeStreamingAll(runtime.io(), bytes);
        try file.sync(runtime.io());
    }
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, runtime.io());
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

test "parseArgs rejects insecure value flag" {
    try std.testing.expectError(error.InsecureValueArgument, parseArgs(&.{ "--type", "env", "--key", "TOKEN", "--value", "secret" }));
}

test "parseArgs accepts stdin mode" {
    const parsed = try parseArgs(&.{ "--type", "env", "--key", "TOKEN", "--stdin" });
    try std.testing.expectEqualStrings("env", parsed.type_s);
    try std.testing.expectEqualStrings("TOKEN", parsed.key);
    try std.testing.expect(parsed.read_from_stdin);
}
