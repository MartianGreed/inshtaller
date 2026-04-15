const std = @import("std");

pub const Config = struct {
    gpa: std.mem.Allocator,
    version: u32 = 1,
    repo: []u8,
    keys: std.ArrayList([]u8),

    pub fn deinit(self: *Config) void {
        self.gpa.free(self.repo);
        for (self.keys.items) |k| self.gpa.free(k);
        self.keys.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn hasKey(self: Config, key: []const u8) bool {
        for (self.keys.items) |k| {
            if (std.mem.eql(u8, k, key)) return true;
        }
        return false;
    }

    pub fn addKey(self: *Config, key: []const u8) !void {
        if (self.hasKey(key)) return;
        try self.keys.append(self.gpa, try self.gpa.dupe(u8, key));
    }
};

pub fn initEmpty(gpa: std.mem.Allocator, repo: []const u8) !Config {
    return .{
        .gpa = gpa,
        .version = 1,
        .repo = try gpa.dupe(u8, repo),
        .keys = .empty,
    };
}

pub fn parse(gpa: std.mem.Allocator, src: []const u8) !Config {
    var cfg: Config = .{
        .gpa = gpa,
        .version = 1,
        .repo = try gpa.dupe(u8, ""),
        .keys = .empty,
    };
    errdefer cfg.deinit();

    const Section = enum { root, backend, env };
    var section: Section = .root;

    var line_iter = std.mem.splitScalar(u8, src, '\n');
    while (line_iter.next()) |raw_line| {
        const line = stripComment(raw_line);
        if (std.mem.indexOfNone(u8, line, " \t\r") == null) continue;

        const indent = countLeadingSpaces(line);
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (indent == 0) {
            if (stripPrefix(trimmed, "version:")) |rest| {
                const v = std.mem.trim(u8, rest, " \t\r");
                cfg.version = try std.fmt.parseInt(u32, v, 10);
                section = .root;
            } else if (std.mem.eql(u8, trimmed, "backend:")) {
                section = .backend;
            } else if (std.mem.eql(u8, trimmed, "env:")) {
                section = .env;
            } else {
                section = .root;
            }
        } else {
            switch (section) {
                .backend => {
                    if (stripPrefix(trimmed, "repo:")) |rest| {
                        const v = trimQuotes(std.mem.trim(u8, rest, " \t\r"));
                        gpa.free(cfg.repo);
                        cfg.repo = try gpa.dupe(u8, v);
                    }
                },
                .env => {
                    if (stripPrefix(trimmed, "-")) |rest| {
                        const key = trimQuotes(std.mem.trim(u8, rest, " \t\r"));
                        if (key.len > 0) try cfg.addKey(key);
                    }
                },
                .root => {},
            }
        }
    }
    return cfg;
}

pub fn emit(w: *std.io.Writer, cfg: Config) !void {
    try w.print("version: {d}\n", .{cfg.version});
    try w.writeAll("backend:\n");
    try w.print("  repo: {s}\n", .{cfg.repo});
    try w.writeAll("env:\n");
    for (cfg.keys.items) |k| {
        try w.print("  - {s}\n", .{k});
    }
}

pub fn emitToOwnedSlice(gpa: std.mem.Allocator, cfg: Config) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try emit(&aw.writer, cfg);
    return aw.toOwnedSlice();
}

fn stripComment(line: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, line, '#')) |idx| return line[0..idx];
    return line;
}

fn countLeadingSpaces(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') : (i += 1) {}
    return i;
}

fn stripPrefix(s: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, s, prefix)) return s[prefix.len..];
    return null;
}

fn trimQuotes(s: []const u8) []const u8 {
    if (s.len >= 2) {
        const c = s[0];
        if ((c == '"' or c == '\'') and s[s.len - 1] == c) {
            return s[1 .. s.len - 1];
        }
    }
    return s;
}

test "parse minimal config" {
    const gpa = std.testing.allocator;
    const src =
        \\version: 1
        \\backend:
        \\  repo: https://github.com/me/secrets.git
        \\env:
        \\  - FOO
        \\  - BAR_BAZ
        \\
    ;
    var cfg = try parse(gpa, src);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 1), cfg.version);
    try std.testing.expectEqualStrings("https://github.com/me/secrets.git", cfg.repo);
    try std.testing.expectEqual(@as(usize, 2), cfg.keys.items.len);
    try std.testing.expectEqualStrings("FOO", cfg.keys.items[0]);
    try std.testing.expectEqualStrings("BAR_BAZ", cfg.keys.items[1]);
}

test "parse skips comments and blanks" {
    const gpa = std.testing.allocator;
    const src =
        \\# header comment
        \\version: 1
        \\
        \\backend:
        \\  # nested comment
        \\  repo: "quoted"
        \\env:
        \\  - A # trailing
        \\
    ;
    var cfg = try parse(gpa, src);
    defer cfg.deinit();
    try std.testing.expectEqualStrings("quoted", cfg.repo);
    try std.testing.expectEqual(@as(usize, 1), cfg.keys.items.len);
    try std.testing.expectEqualStrings("A", cfg.keys.items[0]);
}

test "emit + parse roundtrip" {
    const gpa = std.testing.allocator;
    var cfg = try initEmpty(gpa, "https://example.com/repo.git");
    defer cfg.deinit();
    try cfg.addKey("ALPHA");
    try cfg.addKey("BETA");

    const emitted = try emitToOwnedSlice(gpa, cfg);
    defer gpa.free(emitted);

    var parsed = try parse(gpa, emitted);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("https://example.com/repo.git", parsed.repo);
    try std.testing.expectEqual(@as(usize, 2), parsed.keys.items.len);
    try std.testing.expectEqualStrings("ALPHA", parsed.keys.items[0]);
}

test "addKey dedups" {
    const gpa = std.testing.allocator;
    var cfg = try initEmpty(gpa, "r");
    defer cfg.deinit();
    try cfg.addKey("X");
    try cfg.addKey("X");
    try std.testing.expectEqual(@as(usize, 1), cfg.keys.items.len);
}
