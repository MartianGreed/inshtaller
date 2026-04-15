const std = @import("std");
const paths_mod = @import("../paths.zig");
const config_mod = @import("../config.zig");
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
    var cfg = config_mod.parse(gpa, src) catch |e| {
        log.err("config failed to parse after edit: {s}", .{@errorName(e)});
        return error.InvalidConfigAfterEdit;
    };
    defer cfg.deinit();

    log.info("config valid: {d} key(s), repo={s}", .{ cfg.keys.items.len, cfg.repo });
}
