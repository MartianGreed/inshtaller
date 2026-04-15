const std = @import("std");
const log = @import("log.zig");

pub const askpass_env = "INSH_ASKPASS";

pub const RunError = error{
    GitFailed,
} || std.process.Child.RunError || std.mem.Allocator.Error;

pub const Result = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Result) void {
        self.gpa.free(self.stdout);
        self.gpa.free(self.stderr);
        self.* = undefined;
    }

    pub fn ok(self: Result) bool {
        return self.exit_code == 0;
    }
};

pub fn run(
    gpa: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    self_exe: []const u8,
) !Result {
    return runOpts(gpa, argv, cwd, self_exe, .{});
}

pub const RunOptions = struct {
    /// If true, suppress the log.err output when the command exits non-zero.
    /// Use for probes where failure is a normal signal, not an error.
    quiet_on_failure: bool = false,
};

pub fn runOpts(
    gpa: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    self_exe: []const u8,
    opts: RunOptions,
) !Result {
    var env = try std.process.getEnvMap(gpa);
    defer env.deinit();
    try env.put("GIT_ASKPASS", self_exe);
    try env.put(askpass_env, "1");
    try env.put("GIT_TERMINAL_PROMPT", "0");

    const result = try std.process.Child.run(.{
        .allocator = gpa,
        .argv = argv,
        .cwd = cwd,
        .env_map = &env,
        .max_output_bytes = 4 * 1024 * 1024,
    });

    const code: u8 = switch (result.term) {
        .Exited => |c| c,
        else => 255,
    };

    if (code != 0 and !opts.quiet_on_failure) {
        // Surface what git actually said. PAT is injected via GIT_ASKPASS, never
        // in argv/URL, so stderr is safe to log.
        log.err("git command failed (exit {d}): {f}", .{ code, argvForLog(argv) });
        const stderr_trimmed = std.mem.trim(u8, result.stderr, " \t\r\n");
        if (stderr_trimmed.len > 0) {
            log.err("git stderr:\n{s}", .{stderr_trimmed});
        }
        const stdout_trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (stdout_trimmed.len > 0) {
            log.err("git stdout:\n{s}", .{stdout_trimmed});
        }
    }

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = code,
        .gpa = gpa,
    };
}

fn argvForLog(argv: []const []const u8) ArgvFormatter {
    return .{ .argv = argv };
}

const ArgvFormatter = struct {
    argv: []const []const u8,

    pub fn format(self: ArgvFormatter, w: *std.io.Writer) std.io.Writer.Error!void {
        for (self.argv, 0..) |arg, i| {
            if (i > 0) try w.writeByte(' ');
            try w.writeAll(arg);
        }
    }
};

pub fn injectUsername(gpa: std.mem.Allocator, url: []const u8) ![]u8 {
    const https_prefix = "https://";
    if (std.mem.startsWith(u8, url, https_prefix)) {
        const rest = url[https_prefix.len..];
        if (std.mem.indexOfScalar(u8, rest, '@') == null) {
            return std.fmt.allocPrint(gpa, "https://oauth2@{s}", .{rest});
        }
    }
    return gpa.dupe(u8, url);
}

pub fn isRepoInitialized(state_dir: []const u8, gpa: std.mem.Allocator) !bool {
    const git_dir = try std.fs.path.join(gpa, &.{ state_dir, ".git" });
    defer gpa.free(git_dir);
    std.fs.cwd().access(git_dir, .{}) catch return false;
    return true;
}

pub fn cloneOrFetch(
    gpa: std.mem.Allocator,
    repo_url: []const u8,
    dest: []const u8,
    self_exe: []const u8,
) !void {
    const auth_url = try injectUsername(gpa, repo_url);
    defer gpa.free(auth_url);

    if (try isRepoInitialized(dest, gpa)) {
        var r1 = try run(gpa, &.{ "git", "-C", dest, "fetch", "--prune", "origin" }, null, self_exe);
        defer r1.deinit();
        if (!r1.ok()) return error.GitFailed;

        if (try hasRemoteHead(gpa, dest, self_exe)) {
            var r2 = try run(gpa, &.{ "git", "-C", dest, "reset", "--hard", "origin/HEAD" }, null, self_exe);
            defer r2.deinit();
            if (!r2.ok()) return error.GitFailed;
        } else {
            log.info("remote has no commits yet; local state will be the first push", .{});
        }
    } else {
        std.fs.cwd().makePath(dest) catch {};
        var r = try run(gpa, &.{ "git", "clone", auth_url, dest }, null, self_exe);
        defer r.deinit();
        if (!r.ok()) return error.GitFailed;
    }
}

fn hasRemoteHead(gpa: std.mem.Allocator, dest: []const u8, self_exe: []const u8) !bool {
    var r = try runOpts(
        gpa,
        &.{ "git", "-C", dest, "rev-parse", "--verify", "--quiet", "origin/HEAD" },
        null,
        self_exe,
        .{ .quiet_on_failure = true },
    );
    defer r.deinit();
    return r.ok();
}

pub fn commitAndPush(
    gpa: std.mem.Allocator,
    dest: []const u8,
    message: []const u8,
    self_exe: []const u8,
) !void {
    var r1 = try run(gpa, &.{ "git", "-C", dest, "add", "-A" }, null, self_exe);
    defer r1.deinit();
    if (!r1.ok()) return error.GitFailed;

    var r_status = try run(gpa, &.{ "git", "-C", dest, "status", "--porcelain" }, null, self_exe);
    defer r_status.deinit();
    if (!r_status.ok()) return error.GitFailed;
    if (std.mem.trim(u8, r_status.stdout, " \t\r\n").len == 0) {
        return;
    }

    var r2 = try run(gpa, &.{ "git", "-C", dest, "-c", "user.email=insh@localhost", "-c", "user.name=insh", "commit", "-m", message }, null, self_exe);
    defer r2.deinit();
    if (!r2.ok()) return error.GitFailed;

    var r3 = try run(gpa, &.{ "git", "-C", dest, "push", "origin", "HEAD" }, null, self_exe);
    defer r3.deinit();
    if (!r3.ok()) return error.GitFailed;
}

test "injectUsername adds oauth2 to bare https url" {
    const gpa = std.testing.allocator;
    const out = try injectUsername(gpa, "https://github.com/me/repo.git");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("https://oauth2@github.com/me/repo.git", out);
}

test "injectUsername leaves url with @ unchanged" {
    const gpa = std.testing.allocator;
    const out = try injectUsername(gpa, "https://user@github.com/me/repo.git");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("https://user@github.com/me/repo.git", out);
}

test "injectUsername leaves ssh url unchanged" {
    const gpa = std.testing.allocator;
    const out = try injectUsername(gpa, "git@github.com:me/repo.git");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("git@github.com:me/repo.git", out);
}
