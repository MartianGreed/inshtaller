const std = @import("std");
const paths_mod = @import("../paths.zig");
const config_mod = @import("../config.zig");
const git_mod = @import("../git.zig");
const log = @import("../log.zig");

pub fn run(gpa: std.mem.Allocator) !void {
    var p = try paths_mod.Paths.init(gpa);
    defer p.deinit();

    const cfg_path = try p.config();
    defer gpa.free(cfg_path);

    std.fs.cwd().access(cfg_path, .{}) catch |e| {
        log.err("config not found at {s}: {s}. Run `insh init` first.", .{ cfg_path, @errorName(e) });
        return error.NotInitialized;
    };

    const editor = std.posix.getenv("EDITOR") orelse "vi";

    var child = std.process.Child.init(&.{ editor, cfg_path }, gpa);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code != 0) {
            log.warn("editor exited with code {d}", .{code});
            return;
        },
        else => {
            log.warn("editor terminated abnormally", .{});
            return;
        },
    }

    const src = try std.fs.cwd().readFileAlloc(gpa, cfg_path, 1 * 1024 * 1024);
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
