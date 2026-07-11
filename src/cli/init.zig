const std = @import("std");
const paths_mod = @import("../paths.zig");
const crypto_mod = @import("../crypto.zig");
const config_mod = @import("../config.zig");
const git_mod = @import("../git.zig");
const log = @import("../log.zig");
const runtime = @import("../runtime.zig");

const KeySource = union(enum) {
    generate,
    file: []const u8,
    prompt,
};

const ParsedArgs = struct {
    key_source: KeySource = .generate,
    force: bool = false,
};

pub fn run(gpa: std.mem.Allocator, home: []const u8, github_token: ?[]const u8, args: []const []const u8) !void {
    const parsed = parseArgs(args) catch |e| {
        switch (e) {
            error.MissingValue => log.err("--key-file requires a path", .{}),
            error.ConflictingKeySources => log.err("--key-file and --key-prompt cannot be used together", .{}),
            error.ForceWithoutImport => log.err("--force requires --key-file or --key-prompt", .{}),
            error.DuplicateArgument => log.err("key import options may only be specified once", .{}),
            else => {},
        }
        return e;
    };

    var p = try paths_mod.Paths.init(gpa, home);
    defer p.deinit();

    try p.ensureRoot();

    var stdin_buf: [4096]u8 = undefined;
    var stdin_r = std.Io.File.stdin().reader(runtime.io(), &stdin_buf);
    const stdin = &stdin_r.interface;

    var stdout_buf: [256]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(runtime.io(), &stdout_buf);
    const stdout = &stdout_w.interface;

    const key_path = try p.masterKey();
    defer gpa.free(key_path);

    try setupMasterKey(gpa, parsed, key_path, stdin, stdout);

    const pending_dir = try p.pending();
    defer gpa.free(pending_dir);
    try std.Io.Dir.cwd().createDirPath(runtime.io(), pending_dir);

    const cfg_path = try p.config();
    defer gpa.free(cfg_path);

    const repo_url_owned = blk: {
        if (fileExists(cfg_path)) {
            const src = try std.Io.Dir.cwd().readFileAlloc(runtime.io(), cfg_path, gpa, .limited(1 * 1024 * 1024));
            defer gpa.free(src);

            const repo = repoUrlFromExistingConfig(gpa, src) catch |e| switch (e) {
                error.InvalidConfig => {
                    log.err("existing {s} did not parse; remove it and re-run init", .{cfg_path});
                    std.process.exit(1);
                },
                error.CredentialedRepoUrl => {
                    log.err("existing config contains a backend repo URL with embedded credentials; remove the userinfo from config.yaml and re-run init", .{});
                    std.process.exit(1);
                },
                else => return e,
            };

            log.info("reusing existing config (repo {f})", .{git_mod.redactUrl(repo)});
            break :blk repo;
        }

        const raw = try promptLine(gpa, stdin, stdout, "Backend repo URL (e.g. https://github.com/you/secrets.git): ", false);
        defer gpa.free(raw);

        break :blk repoUrlFromPrompt(gpa, raw) catch |e| switch (e) {
            error.MissingRepoUrl => {
                log.err("backend repo URL is required", .{});
                std.process.exit(1);
            },
            error.CredentialedRepoUrl => {
                log.err("backend repo URL must not include embedded credentials; use a plain repo URL and provide the PAT separately", .{});
                std.process.exit(1);
            },
            else => return e,
        };
    };
    defer gpa.free(repo_url_owned);
    const repo_url = repo_url_owned;

    const token_path = try p.token();
    defer gpa.free(token_path);

    if (fileExists(token_path) and github_token == null) {
        log.info("reusing existing github_token at {s}", .{token_path});
    } else {
        const token = blk: {
            if (github_token) |env_token| {
                const trimmed = std.mem.trim(u8, env_token, " \t\r\n");
                if (trimmed.len > 0) {
                    log.info("using PAT from $INSH_GITHUB_TOKEN", .{});
                    break :blk try gpa.dupe(u8, trimmed);
                }
            }
            var attempts: u8 = 0;
            while (attempts < 3) : (attempts += 1) {
                const raw = try promptLine(gpa, stdin, stdout, "GitHub personal access token (input hidden): ", true);
                defer gpa.free(raw);
                const trimmed = std.mem.trim(u8, raw, " \t\r\n");
                if (trimmed.len > 0) break :blk try gpa.dupe(u8, trimmed);
                try stdout.writeAll("(empty input — try again, or set $INSH_GITHUB_TOKEN to skip this prompt)\n");
                try stdout.flush();
            }
            log.err("PAT is required (3 empty attempts)", .{});
            std.process.exit(1);
        };
        defer gpa.free(token);

        try writeFileSecret(token_path, token, 0o600);
        log.info("wrote github_token (mode 0600)", .{});
    }

    if (!fileExists(cfg_path)) {
        var cfg = try config_mod.initEmpty(gpa, repo_url);
        defer cfg.deinit();
        const serialized = try config_mod.emitToOwnedSlice(gpa, cfg);
        defer gpa.free(serialized);
        try writeFile(cfg_path, serialized, 0o644);
        log.info("wrote {s}", .{cfg_path});
    }

    try stdout.writeAll("\nDone. Next steps:\n");
    try stdout.print("  1) Transfer {s} through a trusted channel when adding another machine.\n", .{key_path});
    try stdout.writeAll("  2) Add env vars:      insh add --type env --key NAME      # hidden prompt\n");
    try stdout.writeAll("                         printf 'VALUE' | insh add --type env --key NAME --stdin\n");
    try stdout.writeAll("  3) Sync to backend:   insh sync\n");
    try stdout.writeAll("  4) Shell integration: echo 'source ~/.inshtaller/env.sh' >> ~/.zshrc\n");
    try stdout.flush();
}

fn parseArgs(args: []const []const u8) !ParsedArgs {
    var parsed: ParsedArgs = .{};
    var has_key_source = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--key-file")) {
            if (has_key_source) return error.ConflictingKeySources;
            i += 1;
            if (i >= args.len) return error.MissingValue;
            parsed.key_source = .{ .file = args[i] };
            has_key_source = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--key-prompt")) {
            if (has_key_source) return error.ConflictingKeySources;
            parsed.key_source = .prompt;
            has_key_source = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--force")) {
            if (parsed.force) return error.DuplicateArgument;
            parsed.force = true;
            continue;
        }

        log.err("unknown argument: {s}", .{arg});
        return error.UnknownArg;
    }

    if (parsed.force and !has_key_source) return error.ForceWithoutImport;
    return parsed;
}

fn setupMasterKey(
    gpa: std.mem.Allocator,
    parsed: ParsedArgs,
    key_path: []const u8,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
) !void {
    switch (parsed.key_source) {
        .generate => {
            if (fileExists(key_path)) {
                log.info("reusing existing master key at {s}", .{key_path});
                return;
            }
            const key = crypto_mod.generateKey();
            try writeFileExclusive(key_path, &key, 0o600);
            log.info("wrote master key (32 bytes, mode 0600)", .{});
        },
        .file => |source_path| {
            const key = readKeyFile(gpa, source_path) catch |e| {
                log.err("could not import master key from {s}: {s} (expected exactly 32 raw bytes)", .{ source_path, @errorName(e) });
                return e;
            };
            try installImportedKeyLogged(gpa, key_path, key, parsed.force);
        },
        .prompt => {
            if (!(std.Io.File.stdin().isTty(runtime.io()) catch false)) {
                log.err("--key-prompt requires an interactive terminal", .{});
                return error.NonInteractiveStdin;
            }
            const raw = try promptLine(gpa, stdin, stdout, "Master key (64 hex characters, input hidden): ", true);
            defer gpa.free(raw);
            const key = decodeHexKey(raw) catch |e| {
                log.err("invalid master key: expected exactly 64 hexadecimal characters", .{});
                return e;
            };
            try installImportedKeyLogged(gpa, key_path, key, parsed.force);
        },
    }
}

fn readKeyFile(gpa: std.mem.Allocator, path: []const u8) !crypto_mod.Key {
    const bytes = std.Io.Dir.cwd().readFileAlloc(runtime.io(), path, gpa, .limited(crypto_mod.key_length + 1)) catch |e| switch (e) {
        error.StreamTooLong => return error.InvalidKeyFile,
        else => return e,
    };
    defer gpa.free(bytes);
    if (bytes.len != crypto_mod.key_length) return error.InvalidKeyFile;

    var key: crypto_mod.Key = undefined;
    @memcpy(&key, bytes);
    return key;
}

fn decodeHexKey(raw: []const u8) !crypto_mod.Key {
    const hex = std.mem.trim(u8, raw, " \t\r\n");
    if (hex.len != crypto_mod.key_length * 2) return error.InvalidHexKey;

    var key: crypto_mod.Key = undefined;
    for (&key, 0..) |*byte, i| {
        const high = hexNibble(hex[i * 2]) orelse return error.InvalidHexKey;
        const low = hexNibble(hex[i * 2 + 1]) orelse return error.InvalidHexKey;
        byte.* = (high << 4) | low;
    }
    return key;
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn installImportedKeyLogged(gpa: std.mem.Allocator, key_path: []const u8, key: crypto_mod.Key, force: bool) !void {
    installImportedKey(gpa, key_path, key, force) catch |e| {
        switch (e) {
            error.InvalidKeyFile => log.err("existing master key at {s} is invalid; pass --force to replace it", .{key_path}),
            error.MasterKeyConflict => log.err("imported key differs from {s}; pass --force to replace it", .{key_path}),
            else => {},
        }
        return e;
    };
}

fn installImportedKey(gpa: std.mem.Allocator, key_path: []const u8, key: crypto_mod.Key, force: bool) !void {
    if (fileExists(key_path)) {
        const existing = readKeyFile(gpa, key_path) catch |e| {
            if (!force) return e;
            try atomicWriteSecret(gpa, key_path, &key, 0o600);
            log.info("replaced existing master key (32 bytes, mode 0600)", .{});
            return;
        };
        if (std.mem.eql(u8, &existing, &key)) {
            log.info("imported key matches existing master key at {s}; reusing it", .{key_path});
            return;
        }
        if (!force) return error.MasterKeyConflict;
        try atomicWriteSecret(gpa, key_path, &key, 0o600);
        log.info("replaced existing master key (32 bytes, mode 0600)", .{});
        return;
    }

    try writeFileExclusive(key_path, &key, 0o600);
    log.info("imported master key (32 bytes, mode 0600)", .{});
}

/// Reads a single line of input. If `hide_input` is true, disables tty echo
/// for the duration of the read. Always consumes the trailing newline so that
/// subsequent calls don't see leftover bytes in the buffer.
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
            // Echo was off so the user's <Enter> didn't move the cursor down.
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

fn repoUrlFromExistingConfig(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var existing = config_mod.parse(gpa, src) catch return error.InvalidConfig;
    defer existing.deinit();

    try git_mod.ensureSafeRepoUrl(existing.repo);
    return gpa.dupe(u8, existing.repo);
}

fn repoUrlFromPrompt(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.MissingRepoUrl;

    try git_mod.ensureSafeRepoUrl(trimmed);
    return gpa.dupe(u8, trimmed);
}

fn writeFileExclusive(path: []const u8, bytes: []const u8, mode: std.posix.mode_t) !void {
    var file = try std.Io.Dir.cwd().createFile(runtime.io(), path, .{
        .exclusive = true,
        .permissions = .fromMode(mode),
        .truncate = true,
    });
    defer file.close(runtime.io());
    try file.writeStreamingAll(runtime.io(), bytes);
}

fn atomicWriteSecret(gpa: std.mem.Allocator, path: []const u8, bytes: []const u8, mode: std.posix.mode_t) !void {
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp_path);

    std.Io.Dir.cwd().deleteFile(runtime.io(), tmp_path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };

    {
        var file = try std.Io.Dir.cwd().createFile(runtime.io(), tmp_path, .{
            .exclusive = true,
            .permissions = .fromMode(mode),
        });
        defer file.close(runtime.io());
        try file.writeStreamingAll(runtime.io(), bytes);
        try file.sync(runtime.io());
    }
    errdefer std.Io.Dir.cwd().deleteFile(runtime.io(), tmp_path) catch {};
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, runtime.io());
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(runtime.io(), path, .{}) catch return false;
    return true;
}

fn writeFileSecret(path: []const u8, bytes: []const u8, mode: std.posix.mode_t) !void {
    var file = try std.Io.Dir.cwd().createFile(runtime.io(), path, .{
        .permissions = .fromMode(mode),
        .truncate = true,
    });
    defer file.close(runtime.io());
    try file.writeStreamingAll(runtime.io(), bytes);
}

fn writeFile(path: []const u8, bytes: []const u8, mode: std.posix.mode_t) !void {
    var file = try std.Io.Dir.cwd().createFile(runtime.io(), path, .{
        .permissions = .fromMode(mode),
        .truncate = true,
    });
    defer file.close(runtime.io());
    try file.writeStreamingAll(runtime.io(), bytes);
}

test "repoUrlFromPrompt rejects embedded credentials" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.CredentialedRepoUrl, repoUrlFromPrompt(gpa, " https://user:secret@github.com/me/repo.git\n"));
}

test "repoUrlFromExistingConfig rejects embedded credentials" {
    const gpa = std.testing.allocator;
    const src =
        \\version: 1
        \\backend:
        \\  repo: https://user:secret@github.com/me/repo.git
        \\env:
        \\
    ;

    try std.testing.expectError(error.CredentialedRepoUrl, repoUrlFromExistingConfig(gpa, src));
}

test "parseArgs accepts both secure key import modes" {
    const from_file = try parseArgs(&.{ "--key-file", "/tmp/master.key", "--force" });
    try std.testing.expect(from_file.force);
    try std.testing.expectEqualStrings("/tmp/master.key", from_file.key_source.file);

    const from_prompt = try parseArgs(&.{"--key-prompt"});
    try std.testing.expect(!from_prompt.force);
    try std.testing.expect(from_prompt.key_source == .prompt);
}

test "parseArgs rejects conflicting key sources and force without import" {
    try std.testing.expectError(error.ConflictingKeySources, parseArgs(&.{ "--key-file", "master.key", "--key-prompt" }));
    try std.testing.expectError(error.ForceWithoutImport, parseArgs(&.{"--force"}));
    try std.testing.expectError(error.MissingValue, parseArgs(&.{"--key-file"}));
}

test "decodeHexKey accepts lowercase and uppercase" {
    const lower = try decodeHexKey("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f\n");
    const upper = try decodeHexKey("000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F");
    try std.testing.expectEqualSlices(u8, &lower, &upper);
    for (lower, 0..) |byte, i| try std.testing.expectEqual(@as(u8, @intCast(i)), byte);
}

test "decodeHexKey rejects invalid input" {
    try std.testing.expectError(error.InvalidHexKey, decodeHexKey("abcd"));
    try std.testing.expectError(error.InvalidHexKey, decodeHexKey("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1g"));
}

test "readKeyFile requires exactly 32 raw bytes" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(runtime.io(), ".", gpa);
    defer gpa.free(root);
    const path = try std.fs.path.join(gpa, &.{ root, "master.key" });
    defer gpa.free(path);

    const valid = [_]u8{0x42} ** crypto_mod.key_length;
    try writeFile(path, &valid, 0o600);
    const loaded = try readKeyFile(gpa, path);
    try std.testing.expectEqualSlices(u8, &valid, &loaded);

    const short = [_]u8{0x42} ** (crypto_mod.key_length - 1);
    try writeFile(path, &short, 0o600);
    try std.testing.expectError(error.InvalidKeyFile, readKeyFile(gpa, path));

    const long = [_]u8{0x42} ** (crypto_mod.key_length + 1);
    try writeFile(path, &long, 0o600);
    try std.testing.expectError(error.InvalidKeyFile, readKeyFile(gpa, path));
}

test "installImportedKey verifies conflicts and supports forced replacement" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(runtime.io(), ".", gpa);
    defer gpa.free(root);
    const path = try std.fs.path.join(gpa, &.{ root, "master.key" });
    defer gpa.free(path);

    const first = [_]u8{0x11} ** crypto_mod.key_length;
    const second = [_]u8{0x22} ** crypto_mod.key_length;
    try installImportedKey(gpa, path, first, false);
    try installImportedKey(gpa, path, first, false);
    try std.testing.expectError(error.MasterKeyConflict, installImportedKey(gpa, path, second, false));
    try installImportedKey(gpa, path, second, true);

    const loaded = try readKeyFile(gpa, path);
    try std.testing.expectEqualSlices(u8, &second, &loaded);

    var file = try std.Io.Dir.cwd().openFile(runtime.io(), path, .{});
    defer file.close(runtime.io());
    const stat = try file.stat(runtime.io());
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}
