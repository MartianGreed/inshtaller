//! Two-way sync between the local machine and the backend git repo.
//!
//! Pipeline (each step runs sequentially, order matters):
//!   1. network — git clone or fetch+reset the backend repo into `.state/`
//!   2. guard   — refuse to continue if the repo holds files we don't recognize
//!   3. decrypt — load remote `secrets.enc` into an in-memory key/value map
//!   4. merge   — drain `pending/*.enc` (locally staged by `insh add`) into the map
//!   5. encrypt — write the merged map back to `secrets.enc` (atomic rename)
//!   6. push    — commit + push; only after this succeeds are pending files deleted
//!   7. render  — emit one env file per registered shell provider (atomic, mode 0600)
//!   8. hint    — print source-this-file commands to stdout for every shell
//!
//! Invariants this file upholds:
//!   - The master key never leaves memory — it is loaded from disk, used, and dropped.
//!   - Pending files are removed only after `git push` succeeds. A crash or network
//!     failure leaves them on disk so the next `insh sync` retries from the same state.
//!   - Every file write to `~/.inshtaller/` goes through `atomicWriteFile` so a
//!     concurrent shell sourcing `env.sh` never sees a half-written file.
//!   - env files are mode 0600 because they contain plaintext secrets. The
//!     backend blob is mode 0644 because it's ciphertext.

const std = @import("std");
const paths_mod = @import("../paths.zig");
const crypto_mod = @import("../crypto.zig");
const config_mod = @import("../config.zig");
const git_mod = @import("../git.zig");
const log = @import("../log.zig");
const provider = @import("../provider.zig");

/// Entry point for `insh sync`. Runs the full pipeline documented at the top
/// of this file. Returns an error on any unrecoverable failure (bad config,
/// wrong-repo guard, git failure, crypto auth failure, I/O error); all paths
/// already log a human-readable reason before returning.
pub fn run(gpa: std.mem.Allocator) !void {
    var p = try paths_mod.Paths.init(gpa);
    defer p.deinit();

    const key_path = try p.masterKey();
    defer gpa.free(key_path);
    const master = try readMasterKey(key_path);

    const cfg_path = try p.config();
    defer gpa.free(cfg_path);
    const cfg_src = try std.fs.cwd().readFileAlloc(gpa, cfg_path, 1 * 1024 * 1024);
    defer gpa.free(cfg_src);
    var cfg = try config_mod.parse(gpa, cfg_src);
    defer cfg.deinit();

    const state_dir = try p.state();
    defer gpa.free(state_dir);

    const self_exe = try std.fs.selfExePathAlloc(gpa);
    defer gpa.free(self_exe);

    // Step 1 — network. Idempotent: clones on first run, fetches + resets on later runs.
    log.info("fetching backend repo", .{});
    try git_mod.cloneOrFetch(gpa, cfg.repo, state_dir, self_exe);

    // Step 2 — guard. Runs BEFORE decrypt so a misconfigured repo URL can't
    // clobber state. If this passes we trust the repo for the rest of the run.
    try checkRepoSafety(state_dir);

    var map = Map.init(gpa);
    defer map.deinit();

    // Step 3 — decrypt remote. Missing blob = first sync against a fresh repo,
    // not an error. Every other read/crypto failure IS an error.
    const blob_path = try p.secretsBlob();
    defer gpa.free(blob_path);
    if (std.fs.cwd().readFileAlloc(gpa, blob_path, 16 * 1024 * 1024)) |blob| {
        defer gpa.free(blob);
        const pt = try crypto_mod.decrypt(gpa, blob, master);
        defer gpa.free(pt);
        try parseEnvLines(&map, pt);
        log.info("decrypted backend: {d} key(s)", .{map.count()});
    } else |e| switch (e) {
        error.FileNotFound => log.info("no existing backend secrets (first sync)", .{}),
        else => return e,
    }

    // Step 4 — merge pending. Must happen AFTER the remote decrypt so local
    // `insh add` stages override/extend remote values (last-write-wins by key).
    const pending_dir = try p.pending();
    defer gpa.free(pending_dir);
    std.fs.cwd().makePath(pending_dir) catch {};
    const drained = try drainPending(gpa, pending_dir, master, &map);
    defer {
        for (drained.items) |path| gpa.free(path);
        var d = drained;
        d.deinit(gpa);
    }
    if (drained.items.len > 0) log.info("merged {d} pending key(s)", .{drained.items.len});

    // Step 5 — re-encrypt the full merged map and write it back to the repo.
    // atomicWriteFile → tmp + rename so a concurrent reader never sees a torn blob.
    const merged = try emitEnvLines(gpa, &map);
    defer gpa.free(merged);

    const new_blob = try crypto_mod.encrypt(gpa, merged, master);
    defer gpa.free(new_blob);

    try atomicWriteFile(gpa, blob_path, new_blob, 0o644);

    // Step 6 — push. No-op commit (when stdout of `git status` is empty) is
    // handled inside commitAndPush; only a real push error bubbles up here.
    log.info("pushing to backend", .{});
    const msg = try std.fmt.allocPrint(gpa, "chore: insh sync", .{});
    defer gpa.free(msg);
    try git_mod.commitAndPush(gpa, state_dir, msg, self_exe);

    // Pending cleanup runs AFTER the push succeeds — crash safety. If the
    // push failed above, we already returned, pending files are intact, and
    // the next `insh sync` replays them.
    for (drained.items) |path| {
        std.fs.cwd().deleteFile(path) catch |e| {
            log.warn("could not delete {s}: {s}", .{ path, @errorName(e) });
        };
    }

    // Step 7 — render one env file per registered shell provider. Each file
    // is mode 0600 because it contains plaintext values.
    const envs = try collectEnvs(gpa, &map);
    defer gpa.free(envs);
    for (provider.all) |pv| {
        const path = try p.envFile(pv.file_extension);
        defer gpa.free(path);
        const body = try renderProviderFile(gpa, pv, envs);
        defer gpa.free(body);
        try atomicWriteFile(gpa, path, body, 0o600);
        log.info("wrote {s} ({s})", .{ path, pv.shell.displayName() });
    }

    // Step 8 — tell the user how to source the file matching their shell.
    log.info("sync complete: {d} key(s) available", .{map.count()});
    try printSourceHints(p);
}

/// Sorted by key, dedicated storage so the slice stays valid while we hand it
/// to every provider in turn.
fn collectEnvs(gpa: std.mem.Allocator, map: *const Map) ![]provider.Env {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(gpa);
    var it = map.inner.iterator();
    while (it.next()) |e| try keys.append(gpa, e.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, lessThan);

    const out = try gpa.alloc(provider.Env, keys.items.len);
    for (keys.items, 0..) |k, i| {
        out[i] = .{ .key = k, .value = map.inner.get(k).? };
    }
    return out;
}

/// Render the full env file (header + one export per env) for a specific
/// provider into an owned byte buffer. Caller frees.
fn renderProviderFile(gpa: std.mem.Allocator, pv: provider.Provider, envs: []const provider.Env) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try pv.writeFile(&aw.writer, envs);
    return aw.toOwnedSlice();
}

/// Write per-shell `source …` commands to stdout after a successful sync so
/// the user doesn't have to remember which env file matches their shell.
fn printSourceHints(p: paths_mod.Paths) !void {
    var buf: [2048]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&buf);
    const out = &stdout_w.interface;
    try out.writeAll("\nTo make these available in your shell, add one of these to your rc:\n");
    for (provider.all) |pv| {
        const path = try p.envFile(pv.file_extension);
        defer p.gpa.free(path);
        try out.print("  {s:<8}  ", .{pv.shell.displayName()});
        try pv.writeSourceCommand(out, path);
        try out.writeByte('\n');
    }
    try out.flush();
}

/// In-memory merged view of all env vars (remote + locally staged). Owns
/// both the keys and the values it holds — `put` always dupes, so callers
/// can free their inputs immediately.
const Map = struct {
    gpa: std.mem.Allocator,
    inner: std.StringHashMap([]u8),

    fn init(gpa: std.mem.Allocator) Map {
        return .{ .gpa = gpa, .inner = std.StringHashMap([]u8).init(gpa) };
    }

    fn deinit(self: *Map) void {
        var it = self.inner.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.inner.deinit();
    }

    /// Insert or overwrite. Last-write-wins — used by the merge step so
    /// pending keys can shadow remote values with the same name.
    fn put(self: *Map, key: []const u8, value: []const u8) !void {
        const gop = try self.inner.getOrPut(try self.gpa.dupe(u8, key));
        if (gop.found_existing) {
            self.gpa.free(gop.key_ptr.*);
            gop.key_ptr.* = try self.gpa.dupe(u8, key);
            self.gpa.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = try self.gpa.dupe(u8, value);
    }

    fn count(self: Map) usize {
        return self.inner.count();
    }
};

/// Read the 32-byte master key from disk. Rejects truncated/corrupt files.
fn readMasterKey(path: []const u8) !crypto_mod.Key {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var key: crypto_mod.Key = undefined;
    const n = try file.readAll(&key);
    if (n != key.len) return error.InvalidKeyFile;
    return key;
}

/// Fail fast if the backend repo holds anything other than insh-managed files.
/// Prevents `insh sync` from pointing at an unrelated repo and clobbering it
/// on the first push. Allowed entries: `.git`, `secrets.enc`, any `README*`,
/// `.gitignore`.
fn checkRepoSafety(state_dir: []const u8) !void {
    var dir = try std.fs.cwd().openDir(state_dir, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.eql(u8, entry.name, ".git")) continue;
        if (std.mem.eql(u8, entry.name, "secrets.enc")) continue;
        if (std.mem.startsWith(u8, entry.name, "README")) continue;
        if (std.mem.eql(u8, entry.name, ".gitignore")) continue;
        log.err("refusing to sync: backend repo contains unexpected file '{s}'. Point insh at an empty repo (or one that only has secrets.enc + README).", .{entry.name});
        return error.UnsafeRepo;
    }
}

/// Parse the decrypted backend payload (one `KEY=VALUE` per line, no quoting)
/// into the in-memory map. This is the internal on-the-wire format we store
/// inside `secrets.enc` — NOT a shell env file.
fn parseEnvLines(map: *Map, src: []const u8) !void {
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const value = line[eq + 1 ..];
        try map.put(key, value);
    }
}

/// Inverse of `parseEnvLines`. Keys are emitted in sorted order so the
/// ciphertext (and thus the git diff) is stable across runs with identical
/// content.
fn emitEnvLines(gpa: std.mem.Allocator, map: *const Map) ![]u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(gpa);

    var it = map.inner.iterator();
    while (it.next()) |e| try keys.append(gpa, e.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, lessThan);

    var aw: std.io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    for (keys.items) |k| {
        const v = map.inner.get(k).?;
        try w.print("{s}={s}\n", .{ k, v });
    }
    return aw.toOwnedSlice();
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const PendingList = std.ArrayList([]u8);

/// Decrypt every `KEY.enc` file in `pending/` and merge it into the map.
/// Returns the list of absolute paths that were consumed, so the caller can
/// delete them AFTER a successful push (not before — see step 6 in the
/// module header).
fn drainPending(
    gpa: std.mem.Allocator,
    pending_dir: []const u8,
    master: crypto_mod.Key,
    map: *Map,
) !PendingList {
    var drained: PendingList = .empty;
    errdefer {
        for (drained.items) |p| gpa.free(p);
        drained.deinit(gpa);
    }

    var dir = std.fs.cwd().openDir(pending_dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return drained,
        else => return e,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".enc")) continue;
        const key = entry.name[0 .. entry.name.len - 4];

        const full = try std.fs.path.join(gpa, &.{ pending_dir, entry.name });
        errdefer gpa.free(full);

        const blob = try std.fs.cwd().readFileAlloc(gpa, full, 1 * 1024 * 1024);
        defer gpa.free(blob);

        const plaintext = try crypto_mod.decrypt(gpa, blob, master);
        defer gpa.free(plaintext);

        try map.put(key, plaintext);
        try drained.append(gpa, full);
    }
    return drained;
}

/// Write `bytes` to `path` atomically: write to `path.tmp`, fsync, then
/// rename over `path`. A concurrent shell sourcing the target file always
/// sees either the old or the new contents — never a half-written file.
fn atomicWriteFile(gpa: std.mem.Allocator, path: []const u8, bytes: []const u8, mode: std.fs.File.Mode) !void {
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp_path);

    {
        var file = try std.fs.cwd().createFile(tmp_path, .{
            .mode = mode,
            .truncate = true,
        });
        defer file.close();
        try file.writeAll(bytes);
        try file.sync();
    }
    try std.fs.cwd().rename(tmp_path, path);
}

test "parseEnvLines + emitEnvLines roundtrip" {
    const gpa = std.testing.allocator;
    var map = Map.init(gpa);
    defer map.deinit();
    try parseEnvLines(&map, "FOO=bar\nBAZ=qux\n");
    const out = try emitEnvLines(gpa, &map);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("BAZ=qux\nFOO=bar\n", out);
}
