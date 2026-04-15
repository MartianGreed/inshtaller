const std = @import("std");
const paths_mod = @import("../paths.zig");
const crypto_mod = @import("../crypto.zig");
const config_mod = @import("../config.zig");
const log = @import("../log.zig");

pub fn run(gpa: std.mem.Allocator) !void {
    var p = try paths_mod.Paths.init(gpa);
    defer p.deinit();

    try p.ensureRoot();

    const key_path = try p.masterKey();
    defer gpa.free(key_path);

    if (fileExists(key_path)) {
        log.info("reusing existing master key at {s}", .{key_path});
    } else {
        const key = crypto_mod.generateKey();
        try writeFileExclusive(key_path, &key, 0o600);
        log.info("wrote master key (32 bytes, mode 0600)", .{});
    }

    const pending_dir = try p.pending();
    defer gpa.free(pending_dir);
    try std.fs.cwd().makePath(pending_dir);

    var stdin_buf: [4096]u8 = undefined;
    var stdin_r = std.fs.File.stdin().reader(&stdin_buf);
    const stdin = &stdin_r.interface;

    var stdout_buf: [256]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_w.interface;

    const cfg_path = try p.config();
    defer gpa.free(cfg_path);

    const repo_url_owned = blk: {
        if (fileExists(cfg_path)) {
            const src = try std.fs.cwd().readFileAlloc(gpa, cfg_path, 1 * 1024 * 1024);
            defer gpa.free(src);
            var existing = config_mod.parse(gpa, src) catch {
                log.err("existing {s} did not parse; remove it and re-run init", .{cfg_path});
                std.process.exit(1);
            };
            defer existing.deinit();
            log.info("reusing existing config (repo {s})", .{existing.repo});
            break :blk try gpa.dupe(u8, existing.repo);
        }
        const raw = try promptLine(gpa, stdin, stdout, "Backend repo URL (e.g. https://github.com/you/secrets.git): ", false);
        defer gpa.free(raw);
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) {
            log.err("backend repo URL is required", .{});
            std.process.exit(1);
        }
        break :blk try gpa.dupe(u8, trimmed);
    };
    defer gpa.free(repo_url_owned);
    const repo_url = repo_url_owned;

    const token_path = try p.token();
    defer gpa.free(token_path);

    if (fileExists(token_path) and std.posix.getenv("INSH_GITHUB_TOKEN") == null) {
        log.info("reusing existing github_token at {s}", .{token_path});
    } else {
        const token = blk: {
            if (std.posix.getenv("INSH_GITHUB_TOKEN")) |env_token| {
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
    try stdout.print("  1) Copy {s} securely to any other machine you want to share secrets with.\n", .{key_path});
    try stdout.writeAll("  2) Add env vars:      insh add --type env --key NAME --value VALUE\n");
    try stdout.writeAll("  3) Sync to backend:   insh sync\n");
    try stdout.writeAll("  4) Shell integration: echo 'source ~/.inshtaller/env.sh' >> ~/.zshrc\n");
    try stdout.flush();
}

/// Reads a single line of input. If `hide_input` is true, disables tty echo
/// for the duration of the read. Always consumes the trailing newline so that
/// subsequent calls don't see leftover bytes in the buffer.
fn promptLine(
    gpa: std.mem.Allocator,
    reader: *std.io.Reader,
    writer: *std.io.Writer,
    prompt: []const u8,
    hide_input: bool,
) ![]u8 {
    try writer.writeAll(prompt);
    try writer.flush();

    const stdin_fd = std.posix.STDIN_FILENO;
    var original: ?std.posix.termios = null;
    if (hide_input and std.posix.isatty(stdin_fd)) {
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

fn writeFileExclusive(path: []const u8, bytes: []const u8, mode: std.fs.File.Mode) !void {
    var file = try std.fs.cwd().createFile(path, .{
        .exclusive = true,
        .mode = mode,
        .truncate = true,
    });
    defer file.close();
    try file.writeAll(bytes);
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn writeFileSecret(path: []const u8, bytes: []const u8, mode: std.fs.File.Mode) !void {
    var file = try std.fs.cwd().createFile(path, .{
        .mode = mode,
        .truncate = true,
    });
    defer file.close();
    try file.writeAll(bytes);
}

fn writeFile(path: []const u8, bytes: []const u8, mode: std.fs.File.Mode) !void {
    var file = try std.fs.cwd().createFile(path, .{
        .mode = mode,
        .truncate = true,
    });
    defer file.close();
    try file.writeAll(bytes);
}
