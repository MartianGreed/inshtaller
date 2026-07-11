const std = @import("std");
const paths_mod = @import("../paths.zig");
const config_mod = @import("../config.zig");
const git_mod = @import("../git.zig");
const log = @import("../log.zig");

pub fn run(gpa: std.mem.Allocator, home: []const u8, editor: []const u8, io: std.Io) !void {
    var p = try paths_mod.Paths.init(gpa, home);
    defer p.deinit();

    const cfg_path = try p.config();
    defer gpa.free(cfg_path);

    std.Io.Dir.cwd().access(io, cfg_path, .{}) catch |e| {
        log.err("config not found at {s}: {s}. Run `insh init` first.", .{ cfg_path, @errorName(e) });
        return error.NotInitialized;
    };

    var child = try std.process.spawn(io, .{
        .argv = &.{ editor, cfg_path },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer child.kill(io);
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            log.warn("editor exited with code {d}", .{code});
            return;
        },
        else => {
            log.warn("editor terminated abnormally", .{});
            return;
        },
    }

    const src = try std.Io.Dir.cwd().readFileAlloc(io, cfg_path, gpa, .limited(1 * 1024 * 1024));
    defer gpa.free(src);
    var cfg = parseEditedConfig(gpa, src) catch |e| switch (e) {
        error.CredentialedRepoUrl => {
            log.err("config contains a backend repo URL with embedded credentials; remove the userinfo before running other commands", .{});
            return error.InvalidConfigAfterEdit;
        },
        else => {
            log.err("config failed to parse after edit: {s}", .{@errorName(e)});
            return error.InvalidConfigAfterEdit;
        },
    };
    defer cfg.deinit();

    log.info("config valid: {d} key(s), repo={f}", .{ cfg.keys.items.len, git_mod.redactUrl(cfg.repo) });
}

fn parseEditedConfig(gpa: std.mem.Allocator, src: []const u8) !config_mod.Config {
    var cfg = try config_mod.parse(gpa, src);
    errdefer cfg.deinit();

    try git_mod.ensureSafeRepoUrl(cfg.repo);
    return cfg;
}

test "parseEditedConfig rejects embedded credentials in backend repo url" {
    const gpa = std.testing.allocator;
    const src =
        \\version: 1
        \\backend:
        \\  repo: https://user:secret@github.com/me/repo.git
        \\env:
        \\  - FOO
        \\
    ;

    try std.testing.expectError(error.CredentialedRepoUrl, parseEditedConfig(gpa, src));
}
