//! Compute a complete terminal transition before emitting any shell commands.
//! Restoration state is authenticated and encrypted, including original values.
const std = @import("std");
const Paths = @import("paths.zig").Paths;
const profiles = @import("profiles.zig");
const secrets = @import("secrets.zig");
const crypto = @import("crypto.zig");
const provider = @import("provider.zig");
const selection = @import("selection.zig");

const Saved = struct { key: []const u8, original: ?[]const u8, applied: []const u8 };
const State = struct { version: u32 = 1, entries: []const Saved };
const max_state = 64 * 1024;

pub fn isChange(args: []const []const u8) bool {
    if (args.len == 0) return false;
    return eql(args[0], "activate") or eql(args[0], "deactivate") or eql(args[0], "_startup") or
        (args.len >= 2 and eql(args[0], "profile") and eql(args[1], "use"));
}

pub fn render(gpa: std.mem.Allocator, home: []const u8, p: Paths, profile: []const u8, shell: provider.Shell, layers: []const []const u8, deactivate: bool, environ: *const std.process.Environ.Map) ![]u8 {
    var base = try environ.clone(gpa);
    defer base.deinit();
    var changes = std.StringHashMap(?[]const u8).init(gpa);
    defer changes.deinit();
    var state_doc: ?std.json.Parsed(State) = null;
    defer if (state_doc) |d| d.deinit();
    if (environ.get("INSH_STATE")) |encoded| {
        if (encoded.len > max_state) return error.InvalidActivationState;
        const old_profile = environ.get("INSH_STATE_PROFILE") orelse return error.InvalidActivationState;
        var old_paths = try Paths.initProfile(gpa, home, old_profile);
        defer old_paths.deinit();
        const key = try secrets.masterKey(old_paths);
        const decoder = std.base64.standard.Decoder;
        const bytes = try gpa.alloc(u8, try decoder.calcSizeForSlice(encoded));
        defer gpa.free(bytes);
        try decoder.decode(bytes, encoded);
        const pt = try crypto.decrypt(gpa, bytes, key);
        defer gpa.free(pt);
        state_doc = try std.json.parseFromSlice(State, gpa, pt, .{ .allocate = .alloc_always });
        if (state_doc.?.value.version != 1) return error.InvalidActivationState;
        for (state_doc.?.value.entries) |e| {
            if (!secrets.validKey(e.key)) return error.InvalidActivationState;
            if (environ.get(e.key)) |current| {
                if (eql(current, e.applied)) {
                    if (e.original) |v| try base.put(e.key, v) else _ = base.swapRemove(e.key);
                    try changes.put(e.key, e.original);
                }
            }
        }
    }
    var next: std.ArrayList(Saved) = .empty;
    defer next.deinit(gpa);
    var store: ?secrets.Store = null;
    defer if (store) |*s| s.deinit();
    var encoded_state: ?[]u8 = null;
    defer if (encoded_state) |s| gpa.free(s);
    if (!deactivate) {
        const key = try secrets.masterKey(p);
        store = try secrets.loadLocal(p, key);
        const resolved = try store.?.resolve(layers);
        defer gpa.free(resolved);
        for (resolved) |e| {
            try next.append(gpa, .{ .key = e.key, .original = base.get(e.key), .applied = e.value });
            try changes.put(e.key, e.value);
        }
        const json = try std.json.Stringify.valueAlloc(gpa, State{ .entries = next.items }, .{});
        defer gpa.free(json);
        const blob = try crypto.encryptV2(gpa, json, key);
        defer gpa.free(blob);
        const encoder = std.base64.standard.Encoder;
        if (encoder.calcSize(blob.len) > max_state) return error.ActivationStateTooLarge;
        encoded_state = try gpa.alloc(u8, encoder.calcSize(blob.len));
        _ = encoder.encode(encoded_state.?, blob);
        try changes.put("INSH_STATE", encoded_state.?);
        try changes.put("INSH_STATE_PROFILE", profile);
    } else {
        try changes.put("INSH_STATE", null);
        try changes.put("INSH_STATE_PROFILE", null);
    }
    const joined = try std.mem.join(gpa, ":", layers);
    defer gpa.free(joined);
    try changes.put("INSH_HOME", home);
    try changes.put("INSH_PROFILE", profile);
    try changes.put("INSH_NAMESPACES", joined);
    return emit(gpa, shell, &changes);
}

fn emit(gpa: std.mem.Allocator, shell: provider.Shell, changes: *std.StringHashMap(?[]const u8)) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(gpa);
    var it = changes.keyIterator();
    while (it.next()) |k| try keys.append(gpa, k.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    if (shell == .nushell) {
        var values: std.json.ObjectMap = .empty;
        defer values.deinit(gpa);
        var unset: std.ArrayList([]const u8) = .empty;
        defer unset.deinit(gpa);
        for (keys.items) |k| {
            if (changes.get(k).?) |v| try values.put(gpa, k, .{ .string = v }) else try unset.append(gpa, k);
        }
        try std.json.Stringify.value(.{ .set = std.json.Value{ .object = values }, .unset = unset.items }, .{}, &out.writer);
    } else {
        for (keys.items) |k| {
            if (changes.get(k).?) |v| {
                var line: std.Io.Writer.Allocating = .init(gpa);
                defer line.deinit();
                try provider.byShell(shell).writeExport(&line.writer, .{ .key = k, .value = v });
                const bytes = line.writer.buffered();
                try out.writer.writeAll(bytes[0 .. bytes.len - 1]);
            } else if (shell == .fish) {
                // Fish returns status 4 for an absent variable. Cleanup is
                // idempotent, but real failures must still abort the transition.
                try out.writer.print("if set -q {s}; set -e {s}; or return 1; end\n", .{ k, k });
                continue;
            } else {
                try out.writer.print("unset {s}", .{k});
            }
            try out.writer.writeAll(if (shell == .fish) "; or return 1\n" else " || return 1\n");
        }
    }
    return out.toOwnedSlice();
}

pub fn shellInit(gpa: std.mem.Allocator, shell: provider.Shell, exe: []const u8) ![]u8 {
    // Use the provider's existing escaping for a command path too.
    var quoted: std.Io.Writer.Allocating = .init(gpa);
    defer quoted.deinit();
    try provider.byShell(shell).writeExport(&quoted.writer, .{ .key = "X", .value = exe });
    const line = quoted.writer.buffered();
    const start: usize = switch (shell) {
        .bash, .zsh => 9,
        .fish => 10,
        .nushell => 9,
    };
    const path = line[start .. line.len - 1];
    const template = switch (shell) {
        .bash, .zsh => @embedFile("shell/posix.sh"),
        .fish => @embedFile("shell/fish.fish"),
        .nushell => @embedFile("shell/nushell.nu"),
    };
    const a = try std.mem.replaceOwned(u8, gpa, template, "@EXE@", path);
    defer gpa.free(a);
    return std.mem.replaceOwned(u8, gpa, a, "@SHELL@", shell.displayName());
}
fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
