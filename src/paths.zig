const std = @import("std");
const runtime = @import("runtime.zig");

pub const root_dir_name = ".inshtaller";

pub const Paths = struct {
    gpa: std.mem.Allocator,
    home: []u8,
    root: []u8,

    pub fn init(gpa: std.mem.Allocator, home: []const u8) !Paths {
        const home_copy = try gpa.dupe(u8, home);
        errdefer gpa.free(home_copy);
        const root = try std.fs.path.join(gpa, &.{ home_copy, root_dir_name });
        return .{ .gpa = gpa, .home = home_copy, .root = root };
    }

    pub fn deinit(self: *Paths) void {
        self.gpa.free(self.home);
        self.gpa.free(self.root);
        self.* = undefined;
    }

    pub fn join(self: Paths, parts: []const []const u8) ![]u8 {
        var list: std.ArrayList([]const u8) = .empty;
        defer list.deinit(self.gpa);
        try list.append(self.gpa, self.root);
        for (parts) |p| try list.append(self.gpa, p);
        return std.fs.path.join(self.gpa, list.items);
    }

    pub fn config(self: Paths) ![]u8 {
        return self.join(&.{"config.yaml"});
    }

    pub fn masterKey(self: Paths) ![]u8 {
        return self.join(&.{"master.key"});
    }

    pub fn token(self: Paths) ![]u8 {
        return self.join(&.{"github_token"});
    }

    pub fn state(self: Paths) ![]u8 {
        return self.join(&.{".state"});
    }

    pub fn pending(self: Paths) ![]u8 {
        return self.join(&.{"pending"});
    }

    pub fn envSh(self: Paths) ![]u8 {
        return self.envFile(".sh");
    }

    /// Path to the generated env file for a given extension (e.g. ".sh",
    /// ".fish", ".nu"). Caller owns the returned slice.
    pub fn envFile(self: Paths, ext: []const u8) ![]u8 {
        const name = try std.fmt.allocPrint(self.gpa, "env{s}", .{ext});
        defer self.gpa.free(name);
        return self.join(&.{name});
    }

    pub fn secretsBlob(self: Paths) ![]u8 {
        return self.join(&.{ ".state", "secrets.enc" });
    }

    pub fn ensureRoot(self: Paths) !void {
        try std.Io.Dir.cwd().createDirPath(runtime.io(), self.root);
    }
};
