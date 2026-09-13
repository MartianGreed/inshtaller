//! The encrypted backend and pending changes own namespace/key identity.
//! Config key lists are informational, never deletion requests.
const std = @import("std");
const crypto = @import("crypto.zig");
const fs = @import("storage_io.zig");
const Paths = @import("paths.zig").Paths;
const runtime = @import("runtime.zig");

pub const Entry = struct { namespace: []const u8 = "", key: []const u8, value: ?[]const u8 };
const Document = struct { version: u32 = 2, entries: []const Entry };
pub const Resolved = struct { key: []const u8, value: []const u8, namespace: []const u8 };

pub fn validNamespace(name: []const u8) bool {
    if (std.mem.eql(u8, name, "global")) return false;
    if (name.len == 0 or name.len > 128) return false;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| if (!@import("profiles.zig").validName(part)) return false;
    return true;
}
pub fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 256) return false;
    if (!(std.ascii.isAlphabetic(key[0]) or key[0] == '_')) return false;
    for (key) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    // Shell integration state and shell execution controls cannot be secrets.
    if (std.mem.startsWith(u8, key, "INSH_") or std.mem.startsWith(u8, key, "__insh_")) return false;
    for ([_][]const u8{ "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "IFS", "ZDOTDIR", "PWD", "OLDPWD", "SHLVL", "UID", "EUID", "PPID", "BASHPID", "BASH_VERSINFO", "status", "pipestatus", "version", "FISH_VERSION", "fish_pid", "history", "argv", "FILE_PWD", "CURRENT_FILE", "LAST_EXIT_CODE", "CMD_DURATION_MS", "ENV_CONVERSIONS", "config" }) |reserved| {
        if (std.mem.eql(u8, key, reserved)) return false;
    }
    return true;
}
fn validate(e: Entry) !void {
    if (e.namespace.len > 0 and !validNamespace(e.namespace)) return error.InvalidNamespace;
    if (!validKey(e.key)) return error.InvalidKey;
    if (e.value) |v| {
        if (std.mem.indexOfScalar(u8, v, 0) != null or !std.unicode.utf8ValidateSlice(v)) return error.InvalidEnvValue;
    }
}

pub const Store = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *Store) void {
        for (self.entries.items) |e| self.freeEntry(e);
        self.entries.deinit(self.gpa);
    }
    fn freeEntry(self: *Store, e: Entry) void {
        self.gpa.free(e.namespace);
        self.gpa.free(e.key);
        if (e.value) |v| self.gpa.free(v);
    }
    pub fn put(self: *Store, e: Entry) !void {
        try validate(e);
        const namespace = try self.gpa.dupe(u8, e.namespace);
        errdefer self.gpa.free(namespace);
        const key = try self.gpa.dupe(u8, e.key);
        errdefer self.gpa.free(key);
        const value = if (e.value) |v| try self.gpa.dupe(u8, v) else null;
        errdefer if (value) |v| self.gpa.free(v);
        const copy: Entry = .{ .namespace = namespace, .key = key, .value = value };
        for (self.entries.items) |*item| {
            if (std.mem.eql(u8, item.namespace, e.namespace) and std.mem.eql(u8, item.key, e.key)) {
                self.freeEntry(item.*);
                item.* = copy;
                return;
            }
        }
        try self.entries.append(self.gpa, copy);
    }
    pub fn hasNamespace(self: *const Store, name: []const u8) bool {
        for (self.entries.items) |e| if (std.mem.eql(u8, e.namespace, name)) return true;
        return false;
    }
    pub fn resolve(self: *const Store, layers: []const []const u8) ![]Resolved {
        for (layers) |name| {
            if (!validNamespace(name)) return error.InvalidNamespace;
            if (!self.hasNamespace(name)) return error.UnknownNamespace;
        }
        var result: std.ArrayList(Resolved) = .empty;
        errdefer result.deinit(self.gpa);
        try self.applyLayer(&result, "");
        for (layers) |name| try self.applyLayer(&result, name);
        std.mem.sort(Resolved, result.items, {}, struct {
            fn less(_: void, a: Resolved, b: Resolved) bool {
                return std.mem.lessThan(u8, a.key, b.key);
            }
        }.less);
        return result.toOwnedSlice(self.gpa);
    }
    fn applyLayer(self: *const Store, result: *std.ArrayList(Resolved), layer: []const u8) !void {
        for (self.entries.items) |e| {
            if (!std.mem.eql(u8, e.namespace, layer)) continue;
            const value = e.value orelse continue;
            const resolved: Resolved = .{ .key = e.key, .value = value, .namespace = layer };
            var found = false;
            for (result.items) |*r| {
                if (std.mem.eql(u8, r.key, e.key)) {
                    r.* = resolved;
                    found = true;
                    break;
                }
            }
            if (!found) try result.append(self.gpa, resolved);
        }
    }
    pub fn parse(self: *Store, src: []const u8, v2: bool) !void {
        if (v2) {
            const doc = try std.json.parseFromSlice(Document, self.gpa, src, .{});
            defer doc.deinit();
            if (doc.value.version != 2) return error.UnsupportedStoreVersion;
            for (doc.value.entries) |e| try self.put(e);
        } else {
            var lines = std.mem.splitScalar(u8, src, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidLegacyPayload;
                try self.put(.{ .key = line[0..eq], .value = line[eq + 1 ..] });
            }
        }
    }
    pub fn encode(self: *const Store) ![]u8 {
        return std.json.Stringify.valueAlloc(self.gpa, Document{ .entries = self.entries.items }, .{});
    }
};

pub fn masterKey(p: Paths) !crypto.Key {
    const path = try p.masterKey();
    defer p.gpa.free(path);
    const bytes = try fs.read(p.gpa, path);
    defer p.gpa.free(bytes);
    if (bytes.len != crypto.key_length) return error.InvalidKeyFile;
    var key: crypto.Key = undefined;
    @memcpy(&key, bytes);
    return key;
}
pub fn loadFile(store: *Store, path: []const u8, key: crypto.Key) !void {
    const blob = fs.read(store.gpa, path) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer store.gpa.free(blob);
    const pt = try crypto.decrypt(store.gpa, blob, key);
    defer store.gpa.free(pt);
    try store.parse(pt, std.mem.startsWith(u8, blob, "INSH2\n"));
}
pub fn loadLocal(p: Paths, key: crypto.Key) !Store {
    var store = Store.init(p.gpa);
    errdefer store.deinit();
    // Cache is only promoted after a successful push; .state may contain a
    // failed push. Migration can fall back to the legacy clone once.
    const cache = try p.join(&.{"cache.enc"});
    defer p.gpa.free(cache);
    const legacy = try p.secretsBlob();
    defer p.gpa.free(legacy);
    try loadFile(&store, if (try fs.exists(cache)) cache else legacy, key);
    const pending = try loadPending(p, key, &store);
    defer {
        for (pending) |path| p.gpa.free(path);
        p.gpa.free(pending);
    }
    return store;
}
pub fn stage(p: Paths, key: crypto.Key, entry: Entry) !void {
    try validate(entry);
    const pending = try p.pending();
    defer p.gpa.free(pending);
    try fs.mkdir(pending);
    // Hash prevents namespace separators and long keys becoming file paths.
    const identity = try std.fmt.allocPrint(p.gpa, "{s}:{s}", .{ entry.namespace, entry.key });
    defer p.gpa.free(identity);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(identity, &digest, .{});
    const name = try std.fmt.allocPrint(p.gpa, "v2_{x}.enc", .{digest});
    defer p.gpa.free(name);
    const path = try std.fs.path.join(p.gpa, &.{ pending, name });
    defer p.gpa.free(path);
    const pt = try std.json.Stringify.valueAlloc(p.gpa, entry, .{});
    defer p.gpa.free(pt);
    const blob = try crypto.encryptV2(p.gpa, pt, key);
    defer p.gpa.free(blob);
    try fs.write(p.gpa, path, blob, 0o600);
    // A new operation supersedes any pre-migration staged global value.
    if (entry.namespace.len == 0) {
        const old_name = try std.fmt.allocPrint(p.gpa, "{s}.enc", .{entry.key});
        defer p.gpa.free(old_name);
        const old_path = try std.fs.path.join(p.gpa, &.{ pending, old_name });
        defer p.gpa.free(old_path);
        std.Io.Dir.cwd().deleteFile(runtime.io(), old_path) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
    }
}
pub fn loadPending(p: Paths, key: crypto.Key, store: *Store) ![][]u8 {
    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |path| p.gpa.free(path);
        paths.deinit(p.gpa);
    }
    const path = try p.pending();
    defer p.gpa.free(path);
    var dir = std.Io.Dir.cwd().openDir(runtime.io(), path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return paths.toOwnedSlice(p.gpa),
        else => return e,
    };
    defer dir.close(runtime.io());
    var it = dir.iterate();
    while (try it.next(runtime.io())) |item| {
        if (item.kind != .file or !std.mem.endsWith(u8, item.name, ".enc")) continue;
        try paths.append(p.gpa, try std.fs.path.join(p.gpa, &.{ path, item.name }));
    }
    // Legacy values first, v2 mutations second, regardless of directory order.
    for ([_]bool{ false, true }) |v2| for (paths.items) |file| {
        const blob = try fs.read(p.gpa, file);
        defer p.gpa.free(blob);
        if (std.mem.startsWith(u8, blob, "INSH2\n") != v2) continue;
        const pt = try crypto.decrypt(p.gpa, blob, key);
        defer p.gpa.free(pt);
        if (v2) {
            const e = try std.json.parseFromSlice(Entry, p.gpa, pt, .{});
            defer e.deinit();
            try store.put(e.value);
        } else {
            const name = std.fs.path.basename(file);
            try store.put(.{ .key = name[0 .. name.len - 4], .value = pt });
        }
    };
    return paths.toOwnedSlice(p.gpa);
}

test "ordered layers override globals and deletion restores fallback" {
    const gpa = std.testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();
    try s.put(.{ .key = "API_KEY", .value = "personal" });
    try s.put(.{ .namespace = "company", .key = "API_KEY", .value = "company" });
    try s.put(.{ .namespace = "project/prod", .key = "API_KEY", .value = "project" });
    var r = try s.resolve(&.{ "company", "project/prod" });
    try std.testing.expectEqualStrings("project", r[0].value);
    gpa.free(r);
    try s.put(.{ .namespace = "project/prod", .key = "API_KEY", .value = null });
    r = try s.resolve(&.{ "company", "project/prod" });
    defer gpa.free(r);
    try std.testing.expectEqualStrings("company", r[0].value);
    try std.testing.expectError(error.UnknownNamespace, s.resolve(&.{"missing"}));
}

test "structured payload preserves multiline values and rejects unsafe keys" {
    const gpa = std.testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();
    try s.put(.{ .namespace = "p", .key = "K", .value = "line\nOTHER=still value\n'\\\"" });
    const encoded = try s.encode();
    defer gpa.free(encoded);
    var other = Store.init(gpa);
    defer other.deinit();
    try other.parse(encoded, true);
    try std.testing.expectEqualStrings(s.entries.items[0].value.?, other.entries.items[0].value.?);
    try std.testing.expectError(error.InvalidKey, s.put(.{ .key = "INSH_PROFILE", .value = "bad" }));
    try std.testing.expectError(error.InvalidNamespace, s.put(.{ .namespace = "../p", .key = "K", .value = "bad" }));
}
