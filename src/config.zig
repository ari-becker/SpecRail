//! `specrail.toml` and the project root.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const toml = @import("toml.zig");

/// The file that marks the project root.
pub const file_name = "specrail.toml";

/// The settings in `specrail.toml`.
pub const Config = struct {
    /// Relative to the project root, without a trailing slash. "" means the
    /// project root itself.
    spec_root: []const u8,
    exclude: []const []const u8 = &.{},
    claim_branch: []const u8 = "main",
    claim_remote: []const u8 = "origin",
    claim_max_hours: ?i64 = null,
};

/// The nearest directory, from `start` up through its parents, that holds a
/// `specrail.toml`. The search does not go above `ceiling`, when given.
pub fn findProjectRoot(arena: Allocator, io: Io, start: []const u8, ceiling: ?[]const u8) Allocator.Error!?[]const u8 {
    var next: ?[]const u8 = start;
    while (next) |dir| {
        const candidate = try std.Io.Dir.path.join(arena, &.{ dir, file_name });
        // Any failure, such as a missing file or a directory we may not
        // read, means the root is not here, and the search goes on upward.
        const found = if (Io.Dir.cwd().access(io, candidate, .{})) |_| true else |_| false;
        if (found) return dir;
        if (ceiling) |c| if (std.mem.eql(u8, dir, c)) return null;
        const parent = std.Io.Dir.path.dirname(dir) orelse return null;
        next = if (std.mem.eql(u8, parent, dir)) null else parent;
    }
    return null;
}

/// A parsed configuration, or a message saying why it is invalid.
pub const Result = union(enum) {
    /// A complete message, ready to print.
    err: []const u8,
    ok: Config,
};

fn fail(arena: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!Result {
    return .{ .err = try arena.print(file_name ++ ":" ++ fmt, args) };
}

fn wrongType(arena: Allocator, e: toml.Entry, expected: []const u8) Allocator.Error!Result {
    return fail(arena, "{d}:{d}: error: '{s}' must be {s}, not {s}", .{ e.line, e.column, e.key, expected, e.value.kind() });
}

/// Normalizes a relative directory path; null when it is absolute or leaves
/// the project root.
fn normalizeDir(s: []const u8) ?[]const u8 {
    if (std.Io.Dir.path.isAbsolute(s)) return null;
    var t = s;
    while (std.mem.startsWith(u8, t, "./")) t = t[2..];
    t = std.mem.trimEnd(u8, t, "/");
    if (t.len == 0 or std.mem.eql(u8, t, ".")) return "";
    var it = std.mem.splitScalar(u8, t, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return null;
    }
    return t;
}

/// Parses the text of `specrail.toml` for the project at `root`.
pub fn parse(arena: Allocator, io: Io, root: []const u8, text: []const u8) Allocator.Error!Result {
    const doc = switch (try toml.parse(arena, text)) {
        .ok => |d| d,
        .err => |e| return fail(arena, "{d}:{d}: error: {s}", .{ e.line, e.column, e.message }),
    };
    var cfg: Config = .{ .spec_root = "" };
    var have_root = false;
    for (doc.entries) |e| {
        if (std.mem.eql(u8, e.key, "spec_root")) {
            if (e.value != .string) return wrongType(arena, e, "a string");
            cfg.spec_root = normalizeDir(e.value.string) orelse
                return fail(arena, "{d}:{d}: error: 'spec_root' must name a directory inside the project root, not '{s}'", .{ e.line, e.column, e.value.string });
            have_root = true;
        } else if (std.mem.eql(u8, e.key, "exclude")) {
            if (e.value != .array) return wrongType(arena, e, "an array of glob patterns");
            var patterns: std.ArrayList([]const u8) = .empty;
            for (e.value.array) |item| {
                if (item.value != .string) {
                    return fail(arena, "{d}:{d}: error: 'exclude' patterns must be strings, not {s}", .{ item.line, item.column, item.value.kind() });
                }
                try patterns.append(arena, item.value.string);
            }
            cfg.exclude = patterns.items;
        } else if (std.mem.eql(u8, e.key, "claim_branch")) {
            if (e.value != .string) return wrongType(arena, e, "a string");
            cfg.claim_branch = e.value.string;
        } else if (std.mem.eql(u8, e.key, "claim_remote")) {
            if (e.value != .string) return wrongType(arena, e, "a string");
            cfg.claim_remote = e.value.string;
        } else if (std.mem.eql(u8, e.key, "claim_max_hours")) {
            if (e.value != .integer or e.value.integer <= 0) {
                return fail(arena, "{d}:{d}: error: 'claim_max_hours' must be a positive integer", .{ e.line, e.column });
            }
            cfg.claim_max_hours = e.value.integer;
        } else {
            return fail(arena, "{d}:{d}: error: unknown key '{s}'; the keys are spec_root, exclude, claim_branch, claim_remote and claim_max_hours", .{ e.line, e.column, e.key });
        }
    }
    if (!have_root) {
        return fail(arena, " error: 'spec_root' is missing; set it to the directory that holds the specs, such as \"specs\"", .{});
    }
    const abs = if (cfg.spec_root.len == 0) root else try std.Io.Dir.path.join(arena, &.{ root, cfg.spec_root });
    const st = Io.Dir.cwd().statFile(io, abs, .{}) catch
        return fail(arena, " error: spec_root '{s}' does not exist", .{cfg.spec_root});
    if (st.kind != .directory) return fail(arena, " error: spec_root '{s}' is not a directory", .{cfg.spec_root});
    return .{ .ok = cfg };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testRoot(arena: Allocator, tmp: *testing.TmpDir) ![]const u8 {
    try tmp.dir.createDirPath(testing.io, "specs");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a-file", .data = "" });
    return tmp.dir.realPathFileAlloc(testing.io, ".", arena);
}

fn expectErr(r: Result, needle: []const u8) !void {
    switch (r) {
        .ok => return error.TestUnexpectedResult,
        .err => |msg| if (std.mem.find(u8, msg, needle) == null) {
            std.debug.print("expected '{s}' in '{s}'\n", .{ needle, msg });
            return error.TestUnexpectedResult;
        },
    }
}

// specrail: specs/config.spec.md § 1.1 Finding the project root
test "the project root is the nearest directory up with specrail.toml" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "outer/inner/deeper");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "outer/specrail.toml", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "outer/inner/specrail.toml", .data = "" });
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const deeper = try std.Io.Dir.path.join(arena, &.{ base, "outer/inner/deeper" });
    const found = (try findProjectRoot(arena, testing.io, deeper, null)).?;
    try testing.expectEqualStrings(try std.Io.Dir.path.join(arena, &.{ base, "outer/inner" }), found);
}

// specrail: specs/config.spec.md § 2.1 Spec root
test "spec_root must name an existing directory inside the project" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(arena, &tmp);
    try testing.expectEqualStrings("specs", (try parse(arena, testing.io, root, "spec_root = \"./specs/\"")).ok.spec_root);
    try expectErr(try parse(arena, testing.io, root, ""), "'spec_root' is missing");
    try expectErr(try parse(arena, testing.io, root, "spec_root = 3"), "must be a string");
    try expectErr(try parse(arena, testing.io, root, "spec_root = \"../elsewhere\""), "inside the project root");
    try expectErr(try parse(arena, testing.io, root, "spec_root = \"/abs\""), "inside the project root");
    try expectErr(try parse(arena, testing.io, root, "spec_root = \"missing\""), "does not exist");
    try expectErr(try parse(arena, testing.io, root, "spec_root = \"a-file\""), "not a directory");
}

// specrail: specs/config.spec.md § 2.2 Exclude patterns
// specrail: specs/config.spec.md § 2.4 Claim branch
// specrail: specs/config.spec.md § 2.5 Claim remote
test "exclude and the claim keys are read, with defaults" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(arena, &tmp);
    const defaults = (try parse(arena, testing.io, root, "spec_root = \"specs\"")).ok;
    try testing.expectEqualStrings("main", defaults.claim_branch);
    try testing.expectEqualStrings("origin", defaults.claim_remote);
    try testing.expectEqual(@as(?i64, null), defaults.claim_max_hours);
    const set = (try parse(arena, testing.io, root,
        \\spec_root       = "specs"
        \\exclude         = ["notes.md", "docs/**"]
        \\claim_branch    = "trunk"
        \\claim_remote    = "upstream"
        \\claim_max_hours = 8
    )).ok;
    try testing.expectEqualStrings("docs/**", set.exclude[1]);
    try testing.expectEqualStrings("trunk", set.claim_branch);
    try testing.expectEqualStrings("upstream", set.claim_remote);
    try testing.expectEqual(@as(?i64, 8), set.claim_max_hours);
    try expectErr(try parse(arena, testing.io, root, "spec_root = \"specs\"\nexclude = [1]"), "patterns must be strings");
    try expectErr(try parse(arena, testing.io, root, "spec_root = \"specs\"\nclaim_branch = 1"), "must be a string");
}

// specrail: specs/config.spec.md § 2.6 Maximum claim duration
test "claim_max_hours must be a positive integer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(arena, &tmp);
    try expectErr(try parse(arena, testing.io, root, "spec_root = \"specs\"\nclaim_max_hours = 0"), "positive integer");
    try expectErr(try parse(arena, testing.io, root, "spec_root = \"specs\"\nclaim_max_hours = \"8\""), "positive integer");
}

// specrail: specs/config.spec.md § 2.7 Unknown keys
test "unknown keys in specrail.toml are errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(arena, &tmp);
    try expectErr(try parse(arena, testing.io, root, "spec_root = \"specs\"\nspecroot = \"specs\""), "unknown key 'specroot'");
}
