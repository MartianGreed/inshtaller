const std = @import("std");
const paths_mod = @import("paths.zig");
const log = @import("log.zig");
const git = @import("git.zig");
const runtime = @import("runtime.zig");
const profiles = @import("profiles.zig");
const selection = @import("selection.zig");
const secrets = @import("secrets.zig");
const activation = @import("activation.zig");
const provider = @import("provider.zig");
const fs = @import("storage_io.zig");
const cli_init = @import("cli/init.zig");
const cli_sync = @import("cli/sync.zig");
const cli_edit = @import("cli/edit.zig");
const cli_add = @import("cli/add.zig");
const cli_export_key = @import("cli/export_key.zig");

pub fn main(init: std.process.Init) void {
    runtime.init(init.io);
    run(init) catch |e| {
        log.err("{s}", .{@errorName(e)});
        if (e == error.ShellIntegrationRequired) log.err("install shell integration with `insh shell-init <bash|zsh|fish|nu>`; see `insh help`", .{});
        if (e == error.UnknownProfile) log.err("initialize this profile with `insh --profile NAME init`", .{});
        std.process.exit(1);
    };
}
fn run(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const home = init.environ_map.get("INSH_HOME") orelse init.environ_map.get("HOME") orelse return error.NoHomeDir;
    if (init.environ_map.get(git.askpass_env) != null) {
        const name = init.environ_map.get("INSH_ASKPASS_PROFILE") orelse return error.InvalidProfile;
        var p = try paths_mod.Paths.initProfile(gpa, home, name);
        defer p.deinit();
        const token = try fs.read(gpa, try p.token());
        return output(std.mem.trim(u8, token, " \t\r\n"));
    }
    const argv = try init.minimal.args.toSlice(gpa);
    var raw = argv[1..];
    var shell: ?provider.Shell = null;
    if (raw.len > 0 and eql(raw[0], "_shell")) {
        if (raw.len < 3) return error.MissingCommand;
        shell = provider.Shell.fromPath(raw[1]) orelse return error.UnsupportedShell;
        raw = raw[2..];
    }
    if (raw.len > 0 and eql(raw[0], "_is-shell")) {
        var probe = try selection.parse(gpa, raw[1..]);
        defer probe.deinit(gpa);
        std.process.exit(if (activation.isChange(probe.args.items)) 0 else 1);
    }
    var parsed = try selection.parse(gpa, raw);
    defer parsed.deinit(gpa);
    const args = parsed.args.items;
    if (args.len == 0 or eql(args[0], "help") or eql(args[0], "--help") or eql(args[0], "-h")) return output(usage);
    const cmd = args[0];
    if (eql(cmd, "version") or eql(cmd, "--version")) return output("insh 0.2.0\n");
    if (eql(cmd, "shell-init")) {
        if (args.len != 2 or parsed.profile != null or parsed.namespaces.items.len != 0) return error.UnknownArg;
        const sh = provider.Shell.fromPath(args[1]) orelse return error.UnsupportedShell;
        return output(try activation.shellInit(gpa, sh, try std.process.executablePathAlloc(init.io, gpa)));
    }
    if (activation.isChange(args) and shell == null) return error.ShellIntegrationRequired;
    try profiles.migrate(gpa, home);
    var name: []const u8 = try profiles.select(gpa, home, parsed.profile, init.environ_map.get("INSH_PROFILE"));
    const profile_use = args.len >= 2 and eql(cmd, "profile") and eql(args[1], "use");
    const profile_create = args.len >= 2 and eql(cmd, "profile") and eql(args[1], "create");
    if (profile_use or profile_create) {
        if (args.len < 3 or parsed.profile != null or parsed.namespaces.items.len != 0) return error.UnknownArg;
        name = args[2];
    }
    if (eql(cmd, "_startup")) name = try profiles.savedDefault(gpa, home);
    var p = try paths_mod.Paths.initProfile(gpa, home, name);
    defer p.deinit();

    if (eql(cmd, "profile") and args.len >= 2 and eql(args[1], "list")) {
        if (args.len != 2 or parsed.namespaces.items.len > 0) return error.UnknownArg;
        return listProfiles(gpa, home);
    }
    if (eql(cmd, "profile") and args.len >= 2 and eql(args[1], "default")) {
        if (args.len != 3 or parsed.namespaces.items.len > 0) return error.UnknownArg;
        return profiles.setDefault(gpa, home, args[2]);
    }
    if (!eql(cmd, "init") and !profile_create) try profiles.require(p);
    const lock = try fs.lock(gpa, p.root);
    defer lock.close(init.io);
    if (eql(cmd, "init") or profile_create) {
        if (parsed.namespaces.items.len > 0) return error.UnknownArg;
        return cli_init.run(gpa, p, init.environ_map.get("INSH_GITHUB_TOKEN"), if (profile_create) args[3..] else args[1..]);
    }
    if (activation.isChange(args)) {
        const deactivate = eql(cmd, "deactivate");
        var layers: []const []const u8 = &.{};
        if (profile_use or eql(cmd, "_startup")) {
            if (args.len != (if (profile_use) @as(usize, 3) else 1)) return error.UnknownArg;
            layers = try selection.defaults(p);
        } else if (deactivate) {
            if (args.len != 1 or parsed.namespaces.items.len != 0) return error.UnknownArg;
        } else {
            if (parsed.namespaces.items.len > 0 and args.len > 1) return error.UnknownArg;
            layers = if (parsed.namespaces.items.len > 0) parsed.namespaces.items else args[1..];
            // No arguments refresh the current selection. Use --global to
            // deliberately replace it with globals only.
            if (layers.len == 1 and eql(layers[0], "--global")) layers = &.{} else if (layers.len == 0) layers = try currentLayers(gpa, p, name, init.environ_map);
        }
        return output(try activation.render(gpa, home, p, name, shell.?, layers, deactivate, init.environ_map));
    }
    if (eql(cmd, "profile") and args.len >= 2 and eql(args[1], "defaults")) {
        if (parsed.namespaces.items.len != 0) return error.UnknownArg;
        return selection.saveDefaults(p, args[2..]);
    }
    if (eql(cmd, "add") or eql(cmd, "remove")) {
        if (parsed.namespaces.items.len > 1) return error.TooManyNamespaces;
        return cli_add.run(gpa, p, if (parsed.namespaces.items.len > 0) parsed.namespaces.items[0] else "", args[1..], eql(cmd, "remove"));
    }
    if (eql(cmd, "status")) {
        if (args.len != 1) return error.UnknownArg;
        const layers = if (parsed.namespaces.items.len > 0) parsed.namespaces.items else try currentLayers(gpa, p, name, init.environ_map);
        var store = try secrets.loadLocal(p, try secrets.masterKey(p));
        defer store.deinit();
        const resolved = try store.resolve(layers);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try out.writer.print("Profile: {s}\nLayers: global", .{name});
        for (layers) |layer| try out.writer.print(" -> {s}", .{layer});
        try out.writer.writeAll("\nAvailable keys, including pending changes:\n");
        for (resolved) |e| try out.writer.print("  {s} <- {s}\n", .{ e.key, if (e.namespace.len == 0) "global" else e.namespace });
        return output(out.writer.buffered());
    }
    if (eql(cmd, "namespace") and args.len == 2 and eql(args[1], "list")) {
        if (parsed.namespaces.items.len > 0) return error.UnknownArg;
        var store = try secrets.loadLocal(p, try secrets.masterKey(p));
        defer store.deinit();
        var names = std.StringHashMap(void).init(gpa);
        defer names.deinit();
        for (store.entries.items) |entry| if (entry.namespace.len > 0) {
            try names.put(entry.namespace, {});
        };
        var it = names.keyIterator();
        while (it.next()) |n| {
            try output(n.*);
            try output("\n");
        }
        return;
    }
    if (parsed.namespaces.items.len > 0) return error.UnknownArg;
    if (eql(cmd, "sync")) {
        if (args.len != 1) return error.UnknownArg;
        var env = try init.environ_map.clone(gpa);
        defer env.deinit();
        try env.put("INSH_ASKPASS_PROFILE", name);
        return cli_sync.run(gpa, p, init.io, &env);
    }
    if (eql(cmd, "edit")) {
        if (args.len != 1) return error.UnknownArg;
        return cli_edit.run(gpa, p, init.environ_map.get("EDITOR") orelse "vi", init.io);
    }
    if (eql(cmd, "export-key")) return cli_export_key.run(gpa, p, args[1..]);
    return error.UnknownCommand;
}
fn currentLayers(gpa: std.mem.Allocator, p: paths_mod.Paths, name: []const u8, env: *const std.process.Environ.Map) ![][]const u8 {
    if (env.get("INSH_PROFILE")) |active| {
        if (eql(active, name)) if (env.get("INSH_NAMESPACES")) |joined| {
            var result: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, joined, ':');
            while (it.next()) |part| if (part.len > 0) {
                try result.append(gpa, part);
            };
            return result.toOwnedSlice(gpa);
        };
    }
    return selection.defaults(p);
}
fn listProfiles(gpa: std.mem.Allocator, home: []const u8) !void {
    var root = try paths_mod.Paths.init(gpa, home);
    defer root.deinit();
    const path = try root.join(&.{"profiles"});
    var dir = std.Io.Dir.cwd().openDir(runtime.io(), path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer dir.close(runtime.io());
    var it = dir.iterate();
    const default = try profiles.savedDefault(gpa, home);
    while (try it.next(runtime.io())) |entry| {
        if (entry.kind != .directory or !profiles.validName(entry.name)) continue;
        try output(try std.fmt.allocPrint(gpa, "{s}{s}\n", .{ entry.name, if (eql(entry.name, default)) " (default)" else "" }));
    }
}
fn output(bytes: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(runtime.io(), &buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}
fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
const usage =
    \\insh - encrypted profiles and composable environment namespaces
    \\USAGE: insh [--profile NAME] <command> [options]
    \\  init [--key-file PATH | --key-prompt] [--force]
    \\  profile create NAME [init options]  Configure a separate backend and key.
    \\  profile list                       List local profiles.
    \\  profile use NAME                   Switch this terminal to a profile.
    \\  profile default NAME               Set the default for fresh terminals.
    \\  profile defaults [NAMESPACE ...]    Save this profile's default layers.
    \\  add [-n NAMESPACE] --type env --key KEY [--stdin]
    \\  remove [-n NAMESPACE] --type env --key KEY
    \\  activate [NAMESPACE ... | --global] Replace layers; no args refreshes.
    \\  deactivate                         Restore the previous environment.
    \\  status [-n NAMESPACE ...]          Show key sources without values.
    \\  namespace list                     List namespaces, including pending ones.
    \\  sync                               Sync all namespaces in this profile.
    \\  edit                               Edit profile config, never delete secrets.
    \\  export-key                         Print the selected profile's secret key.
    \\  shell-init <bash|zsh|fish|nu>       Print one-time shell integration.
    \\  help | version
    \\
    \\Shell startup setup:
    \\  bash/zsh: eval "$(insh shell-init bash)"  # use zsh for zsh
    \\  fish:     insh shell-init fish | source
    \\  nushell:  insh shell-init nu | save -f ~/.config/nushell/insh.nu
    \\            then source ~/.config/nushell/insh.nu in config.nu
    \\
;
test {
    _ = cli_init;
    _ = cli_sync;
    _ = cli_edit;
    _ = cli_add;
    _ = cli_export_key;
    _ = secrets;
    _ = profiles;
    _ = activation;
}
