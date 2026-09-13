//! Machine-local profile selection and resumable legacy installation migration.
const std = @import("std");
const Paths = @import("paths.zig").Paths;
const fs = @import("storage_io.zig");
const runtime = @import("runtime.zig");

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or !std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}

pub fn select(gpa: std.mem.Allocator, home: []const u8, explicit: ?[]const u8, active: ?[]const u8) ![]u8 {
    const name = explicit orelse active orelse return savedDefault(gpa, home);
    if (!validName(name)) return error.InvalidProfile;
    return gpa.dupe(u8, name);
}

pub fn savedDefault(gpa: std.mem.Allocator, home: []const u8) ![]u8 {
    var p = try Paths.init(gpa, home);
    defer p.deinit();
    const path = try p.join(&.{"default-profile"});
    defer gpa.free(path);
    const raw = fs.read(gpa, path) catch |e| switch (e) {
        error.FileNotFound => return gpa.dupe(u8, "default"),
        else => return e,
    };
    defer gpa.free(raw);
    const name = std.mem.trim(u8, raw, "\n\r");
    if (!validName(name)) return error.InvalidDefaultProfile;
    return gpa.dupe(u8, name);
}

pub fn require(p: Paths) !void {
    const path = try p.config();
    defer p.gpa.free(path);
    if (!try fs.exists(path)) return error.UnknownProfile;
}

pub fn setDefault(gpa: std.mem.Allocator, home: []const u8, name: []const u8) !void {
    var p = try Paths.initProfile(gpa, home, name);
    defer p.deinit();
    try require(p);
    var root = try Paths.init(gpa, home);
    defer root.deinit();
    const path = try root.join(&.{"default-profile"});
    defer gpa.free(path);
    try fs.write(gpa, path, name, 0o600);
}

// Moving files preserves key bytes and pending ciphertext. A marker permits a
// restart between any two renames. Never replace an existing default profile.
pub fn migrate(gpa: std.mem.Allocator, home: []const u8) !void {
    var old = try Paths.init(gpa, home);
    defer old.deinit();
    const cfg = try old.config();
    defer gpa.free(cfg);
    const marker = try old.join(&.{".migrating"});
    defer gpa.free(marker);
    if (!try fs.exists(cfg) and !try fs.exists(marker)) return;
    const migration_lock = try fs.lock(gpa, old.root);
    defer migration_lock.close(runtime.io());
    var target = try Paths.initProfile(gpa, home, "default");
    defer target.deinit();
    if (!try fs.exists(marker)) {
        if (try fs.exists(target.root)) return error.MigrationConflict;
        try fs.write(gpa, marker, "1\n", 0o600);
    }
    try fs.mkdir(target.root);
    for ([_][]const u8{ "master.key", "github_token", "pending", ".state", "env.sh", "env.fish", "env.nu", "config.yaml" }) |name| {
        const from = try old.join(&.{name});
        defer gpa.free(from);
        const to = try target.join(&.{name});
        defer gpa.free(to);
        if (try fs.exists(from)) {
            if (try fs.exists(to)) return error.MigrationConflict;
            try std.Io.Dir.cwd().rename(from, std.Io.Dir.cwd(), to, runtime.io());
        }
    }
    try std.Io.Dir.cwd().deleteFile(runtime.io(), marker);
}

test "profile names cannot escape storage or inject shell code" {
    for ([_][]const u8{ "", ".", "..", "work/prod", "a:b", "-work", "$(id)", "a\nb" }) |name| try std.testing.expect(!validName(name));
    try std.testing.expect(validName("work-2_personal"));
}

test "legacy migration preserves master key, backend values and staged overrides" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(home);
    var old = try Paths.init(gpa, home);
    defer old.deinit();
    const pending = try old.pending();
    defer gpa.free(pending);
    try fs.mkdir(pending);
    const state = try old.state();
    defer gpa.free(state);
    try fs.mkdir(state);
    const crypto = @import("crypto.zig");
    const key = crypto.generateKey();
    const key_path = try old.masterKey();
    defer gpa.free(key_path);
    try fs.write(gpa, key_path, &key, 0o600);
    const config = try old.config();
    defer gpa.free(config);
    try fs.write(gpa, config, "version: 1\nbackend:\n  repo: test\nenv:\n", 0o600);
    const backend = try crypto.encrypt(gpa, "API_KEY=remote\nREMOTE_ONLY=keep\n", key);
    defer gpa.free(backend);
    const backend_path = try old.secretsBlob();
    defer gpa.free(backend_path);
    try fs.write(gpa, backend_path, backend, 0o600);
    const staged = try crypto.encrypt(gpa, "pending", key);
    defer gpa.free(staged);
    const staged_path = try old.join(&.{ "pending", "API_KEY.enc" });
    defer gpa.free(staged_path);
    try fs.write(gpa, staged_path, staged, 0o600);
    try migrate(gpa, home);
    try migrate(gpa, home);
    var p = try Paths.initProfile(gpa, home, "default");
    defer p.deinit();
    const secrets = @import("secrets.zig");
    const imported = try secrets.masterKey(p);
    try std.testing.expectEqualSlices(u8, &key, &imported);
    var store = try secrets.loadLocal(p, imported);
    defer store.deinit();
    const resolved = try store.resolve(&.{});
    defer gpa.free(resolved);
    try std.testing.expectEqual(@as(usize, 2), resolved.len);
    try std.testing.expectEqualStrings("pending", resolved[0].value);
    try std.testing.expectEqualStrings("keep", resolved[1].value);
    try std.testing.expect(!try fs.exists(config));
}

test "migration resumes after a partial move" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(home);
    var old = try Paths.init(gpa, home);
    defer old.deinit();
    var target = try Paths.initProfile(gpa, home, "default");
    defer target.deinit();
    try fs.mkdir(target.root);
    const marker = try old.join(&.{".migrating"});
    defer gpa.free(marker);
    try fs.write(gpa, marker, "1\n", 0o600);
    const cfg = try old.config();
    defer gpa.free(cfg);
    try fs.write(gpa, cfg, "version: 1\nbackend:\n  repo: test\nenv:\n", 0o600);
    const key = try target.masterKey();
    defer gpa.free(key);
    try fs.write(gpa, key, &([_]u8{42} ** 32), 0o600);
    try migrate(gpa, home);
    try require(target);
    try std.testing.expect(!try fs.exists(marker));
}
