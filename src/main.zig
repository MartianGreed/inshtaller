const std = @import("std");
const paths_mod = @import("paths.zig");
const log = @import("log.zig");
const git = @import("git.zig");

const cli_init = @import("cli/init.zig");
const cli_sync = @import("cli/sync.zig");
const cli_edit = @import("cli/edit.zig");
const cli_add = @import("cli/add.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    if (std.posix.getenv(git.askpass_env) != null) {
        try runAskpass(gpa);
        return;
    }

    const argv = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, argv);

    if (argv.len < 2) {
        try printUsage();
        return;
    }

    const cmd = argv[1];

    if (std.mem.eql(u8, cmd, "init")) {
        try cli_init.run(gpa);
    } else if (std.mem.eql(u8, cmd, "sync")) {
        try cli_sync.run(gpa);
    } else if (std.mem.eql(u8, cmd, "edit")) {
        try cli_edit.run(gpa);
    } else if (std.mem.eql(u8, cmd, "add")) {
        try cli_add.run(gpa, argv[2..]);
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try printUsage();
    } else if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) {
        try printVersion();
    } else {
        log.err("unknown command: {s}", .{cmd});
        try printUsage();
        return error.UnknownCommand;
    }
}

fn runAskpass(gpa: std.mem.Allocator) !void {
    var p = try paths_mod.Paths.init(gpa);
    defer p.deinit();

    const token_path = try p.token();
    defer gpa.free(token_path);

    const token = std.fs.cwd().readFileAlloc(gpa, token_path, 64 * 1024) catch {
        std.process.exit(1);
    };
    defer gpa.free(token);

    const trimmed = std.mem.trim(u8, token, " \t\r\n");

    var out_buf: [8192]u8 = undefined;
    var out_w = std.fs.File.stdout().writer(&out_buf);
    try out_w.interface.writeAll(trimmed);
    try out_w.interface.writeByte('\n');
    try out_w.interface.flush();
}

fn printUsage() !void {
    var buf: [2048]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;
    try out.writeAll(
        \\insh — encrypted env var sync for servers you call home
        \\
        \\USAGE
        \\  insh <command> [options]
        \\
        \\COMMANDS
        \\  init                              Create ~/.inshtaller/, generate a private master key,
        \\                                    prompt for GitHub PAT + private backend repo URL.
        \\  add --type env --key K [--stdin]  Stage an env var. The value comes from a hidden
        \\                                    prompt by default, or stdin when --stdin is set;
        \\                                    only the key name touches the config file.
        \\  sync                              Two-way sync with the backend repo. Decrypts remote
        \\                                    env vars and writes one env file per supported
        \\                                    shell (bash/zsh, fish, nushell); pushes any
        \\                                    locally staged keys to the backend.
        \\  edit                              Open $EDITOR on the config file (never has values).
        \\  help                              Show this help.
        \\  version                           Show version.
        \\
        \\SHELL INTEGRATION
        \\  After `insh sync`, source the file matching your shell:
        \\    bash    source ~/.inshtaller/env.sh    (add to ~/.bashrc)
        \\    zsh     source ~/.inshtaller/env.sh    (add to ~/.zshrc)
        \\    fish    source ~/.inshtaller/env.fish  (add to ~/.config/fish/config.fish)
        \\    nu      source ~/.inshtaller/env.nu    (add to $nu.config-path)
        \\
        \\SECURITY
        \\  Master key lives at ~/.inshtaller/master.key (mode 0600) and never leaves the device.
        \\  It is NOT pushed to the backend repo. Copy it out-of-band to new machines.
        \\
    );
    try out.flush();
}

fn printVersion() !void {
    var buf: [64]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.writeAll("insh 0.1.0\n");
    try w.interface.flush();
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
