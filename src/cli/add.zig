const std = @import("std");
const paths_mod = @import("../paths.zig");
const log = @import("../log.zig");
const runtime = @import("../runtime.zig");
const secrets = @import("../secrets.zig");

pub fn run(gpa: std.mem.Allocator, p: paths_mod.Paths, namespace: []const u8, args: []const []const u8, remove: bool) !void {
    const parsed = parseArgs(args) catch |e| {
        if (e == error.InsecureValueArgument) log.err("use the hidden prompt or --stdin; secret values cannot be passed in argv", .{});
        return e;
    };
    if (!std.mem.eql(u8, parsed.type_s, "env")) return error.UnsupportedType;
    if (!secrets.validKey(parsed.key)) return error.InvalidKey;
    if (namespace.len > 0 and !secrets.validNamespace(namespace)) return error.InvalidNamespace;
    try @import("../profiles.zig").require(p);
    const master = try secrets.masterKey(p);
    if (remove and parsed.read_from_stdin) return error.UnknownArg;
    const value = if (remove) null else try readSecretValue(gpa, parsed.read_from_stdin);
    defer if (value) |v| gpa.free(v);
    try secrets.stage(p, master, .{ .namespace = namespace, .key = parsed.key, .value = value });
    log.info("staged {s} for key {s}; run `insh sync` to push", .{ if (remove) "removal" else "value", parsed.key });
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
        defer gpa.free(raw);
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

test "isValidKey accepts standard env names" {
    try std.testing.expect(secrets.validKey("FOO"));
    try std.testing.expect(secrets.validKey("FOO_BAR"));
    try std.testing.expect(secrets.validKey("_private"));
    try std.testing.expect(secrets.validKey("A1"));
}

test "isValidKey rejects bad names" {
    try std.testing.expect(!secrets.validKey(""));
    try std.testing.expect(!secrets.validKey("1FOO"));
    try std.testing.expect(!secrets.validKey("FOO-BAR"));
    try std.testing.expect(!secrets.validKey("FOO BAR"));
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
