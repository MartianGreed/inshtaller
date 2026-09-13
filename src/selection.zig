//! Shared argument extraction and ordered per-profile default layers.
const std = @import("std");
const fs = @import("storage_io.zig");
const Paths = @import("paths.zig").Paths;
const secrets = @import("secrets.zig");
pub const Args = struct {
    profile: ?[]const u8 = null,
    namespaces: std.ArrayList([]const u8) = .empty,
    args: std.ArrayList([]const u8) = .empty,
    pub fn deinit(self: *Args, gpa: std.mem.Allocator) void {
        self.namespaces.deinit(gpa);
        self.args.deinit(gpa);
    }
};
pub fn parse(gpa: std.mem.Allocator, args: []const []const u8) !Args {
    var result: Args = .{};
    errdefer result.deinit(gpa);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--profile") or std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--namespace")) {
            i += 1;
            if (i == args.len) return error.MissingValue;
            if (std.mem.eql(u8, arg, "--profile")) {
                if (result.profile != null) return error.DuplicateArgument;
                if (!@import("profiles.zig").validName(args[i])) return error.InvalidProfile;
                result.profile = args[i];
            } else {
                if (!secrets.validNamespace(args[i])) return error.InvalidNamespace;
                try result.namespaces.append(gpa, args[i]);
            }
        } else try result.args.append(gpa, arg);
    }
    return result;
}
pub fn defaults(p: Paths) ![][]const u8 {
    const path = try p.join(&.{"default-layers.json"});
    defer p.gpa.free(path);
    const src = fs.read(p.gpa, path) catch |e| switch (e) {
        error.FileNotFound => return p.gpa.alloc([]const u8, 0),
        else => return e,
    };
    defer p.gpa.free(src);
    const parsed = try std.json.parseFromSlice([][]const u8, p.gpa, src, .{});
    defer parsed.deinit();
    const result = try p.gpa.alloc([]const u8, parsed.value.len);
    for (parsed.value, 0..) |name, i| {
        if (!secrets.validNamespace(name)) return error.InvalidNamespace;
        result[i] = try p.gpa.dupe(u8, name);
    }
    return result;
}
pub fn saveDefaults(p: Paths, layers: []const []const u8) !void {
    const key = try secrets.masterKey(p);
    var store = try secrets.loadLocal(p, key);
    defer store.deinit();
    const resolved = try store.resolve(layers);
    defer p.gpa.free(resolved);
    const path = try p.join(&.{"default-layers.json"});
    defer p.gpa.free(path);
    const json = try std.json.Stringify.valueAlloc(p.gpa, layers, .{});
    defer p.gpa.free(json);
    try fs.write(p.gpa, path, json, 0o600);
}
