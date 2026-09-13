//! Profile-scoped sync. Only explicit pending operations mutate backend entries.
const std = @import("std");
const paths_mod = @import("../paths.zig");
const crypto = @import("../crypto.zig");
const config = @import("../config.zig");
const git = @import("../git.zig");
const log = @import("../log.zig");
const runtime = @import("../runtime.zig");
const secrets = @import("../secrets.zig");
const fs = @import("../storage_io.zig");
const provider = @import("../provider.zig");

pub fn run(gpa: std.mem.Allocator, p: paths_mod.Paths, io: std.Io, environ: *const std.process.Environ.Map) !void {
    const master = try secrets.masterKey(p);
    const cfg_path = try p.config();
    defer gpa.free(cfg_path);
    const src = try fs.read(gpa, cfg_path);
    defer gpa.free(src);
    var cfg = try config.parse(gpa, src);
    defer cfg.deinit();
    try git.ensureSafeRepoUrl(cfg.repo);
    const state_dir = try p.state();
    defer gpa.free(state_dir);
    const exe = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe);
    log.info("fetching backend repo", .{});
    try git.cloneOrFetch(gpa, io, environ, cfg.repo, state_dir, exe);
    try checkRepoSafety(state_dir);
    var store = secrets.Store.init(gpa);
    defer store.deinit();
    const blob_path = try p.secretsBlob();
    defer gpa.free(blob_path);
    try secrets.loadFile(&store, blob_path, master);
    const pending = try secrets.loadPending(p, master, &store);
    defer {
        for (pending) |path| gpa.free(path);
        gpa.free(pending);
    }
    const pt = try store.encode();
    defer gpa.free(pt);
    const blob = try crypto.encryptV2(gpa, pt, master);
    defer gpa.free(blob);
    try fs.write(gpa, blob_path, blob, 0o600);
    try git.commitAndPush(gpa, io, environ, state_dir, "chore: insh sync", exe);
    const cache = try p.join(&.{"cache.enc"});
    defer gpa.free(cache);
    try fs.write(gpa, cache, blob, 0o600);
    for (pending) |path| try std.Io.Dir.cwd().deleteFile(io, path);

    // Compatibility exports contain globals only; terminal activation is
    // explicit and never changes in response to another process syncing.
    const resolved = try store.resolve(&.{});
    defer gpa.free(resolved);
    const envs = try gpa.alloc(provider.Env, resolved.len);
    defer gpa.free(envs);
    for (resolved, 0..) |e, i| envs[i] = .{ .key = e.key, .value = e.value };
    for (provider.all) |pv| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try pv.writeFile(&out.writer, envs);
        const path = try p.envFile(pv.file_extension);
        defer gpa.free(path);
        try fs.write(gpa, path, out.writer.buffered(), 0o600);
    }
    log.info("sync complete; reactivate to refresh this terminal", .{});
}

fn checkRepoSafety(state_dir: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(runtime.io(), state_dir, .{ .iterate = true });
    defer dir.close(runtime.io());
    var it = dir.iterate();
    while (try it.next(runtime.io())) |entry| {
        if (std.mem.eql(u8, entry.name, ".git")) continue;
        if (std.mem.eql(u8, entry.name, "secrets.enc")) continue;
        if (std.mem.startsWith(u8, entry.name, "README")) continue;
        if (std.mem.eql(u8, entry.name, ".gitignore")) continue;
        log.err("refusing to sync: backend repo contains unexpected file '{s}'. Point insh at an empty repo (or one that only has secrets.enc + README).", .{entry.name});
        return error.UnsafeRepo;
    }
}
