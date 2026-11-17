//! Which files belong to the project, and which of them hold specs or
//! references.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Config = @import("config.zig").Config;

/// The project's files, or the reason git could not list them.
pub const ListResult = union(enum) {
    err: []const u8,
    ok: []const []const u8,
};

/// Lists tracked files and untracked files that are not ignored, as
/// `git ls-files --cached --others --exclude-standard` does.
pub fn list(
    arena: Allocator,
    io: Io,
    root: []const u8,
    env: ?*const std.process.Environ.Map,
) Allocator.Error!ListResult {
    const result = std.process.run(arena, io, .{
        .argv = &.{ "git", "ls-files", "--cached", "--others", "--exclude-standard", "-z" },
        .cwd = .{ .path = root },
        .environ_map = env,
    }) catch |e| return .{
        .err = try arena.print(
            "cannot run git ({s}); specrail needs git to list the project's files",
            .{@errorName(e)},
        ),
    };
    if (!result.term.success()) {
        const msg = std.mem.trim(u8, result.stderr, " \t\r\n");
        return .{
            .err = try arena.print(
                "git ls-files failed in {s}: {s}",
                .{ root, if (msg.len > 0) msg else "no message" },
            ),
        };
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(arena);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(arena);
    var it = std.mem.splitScalar(u8, result.stdout, 0);
    while (it.next()) |path| {
        if (path.len == 0) continue;
        const gop = try seen.getOrPut(arena, path);
        if (!gop.found_existing) try out.append(arena, path);
    }
    return .{ .ok = try out.toOwnedSlice(arena) };
}

/// The first part of `path`, a project path, that is a symbolic link: for
/// `specs/linked/a.spec.md`, `specs/linked` when that is a link. Null when no
/// part is one. Parts that do not exist are not links, and neither is anything
/// below them.
pub fn symlinkOn(
    arena: Allocator,
    io: Io,
    root: []const u8,
    path: []const u8,
) Allocator.Error!?[]const u8 {
    var parts = std.mem.splitScalar(u8, path, '/');
    var end: usize = 0;
    while (parts.next()) |part| {
        end += part.len;
        const prefix = path[0..end];
        const at = try Io.Dir.path.join(arena, &.{ root, prefix });
        const options: Io.Dir.StatFileOptions = .{ .follow_symlinks = false };
        const st = Io.Dir.cwd().statFile(io, at, options) catch return null;
        if (st.kind == .sym_link) return prefix;
        // The separator before the next part.
        end += 1;
    }
    return null;
}

/// True when `path` is `dir` or below it. "" is the project root.
pub fn isUnder(path: []const u8, dir: []const u8) bool {
    if (dir.len == 0) return true;
    return std.mem.startsWith(u8, path, dir) and (path.len == dir.len or path[dir.len] == '/');
}

/// `*` matches within one path segment, `**` across segments, `?` one
/// character other than `/`. Each call recurses on a shorter pattern, so the
/// recursion is no deeper than the pattern is long.
pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0) return path.len == 0;
    if (std.mem.startsWith(u8, pattern, "**")) {
        for (0..path.len + 1) |i| {
            // bound: the pattern loses its leading `**`.
            if (globMatch(pattern[2..], path[i..])) return true;
        }
        return false;
    }
    switch (pattern[0]) {
        '*' => {
            for (0..path.len + 1) |i| {
                // bound: the pattern loses its leading `*`.
                if (globMatch(pattern[1..], path[i..])) return true;
                if (i < path.len and path[i] == '/') return false;
            }
            return false;
        },
        // bound: the pattern loses its first byte.
        '?' => return path.len > 0 and path[0] != '/' and globMatch(pattern[1..], path[1..]),
        // bound: the pattern loses its first byte.
        else => return path.len > 0 and path[0] == pattern[0] and globMatch(
            pattern[1..],
            path[1..],
        ),
    }
}

/// True when `path` matches any of the `exclude` patterns.
pub fn isExcluded(path: []const u8, patterns: []const []const u8) bool {
    for (patterns) |p| if (globMatch(p, path)) return true;
    return false;
}

/// git's heuristic: a NUL byte in the first 8000 bytes.
pub fn isBinary(content: []const u8) bool {
    return std.mem.findScalar(u8, content[0..@min(content.len, 8000)], 0) != null;
}

/// The parent files above a spec file, outermost first: `root.spec.md` in the
/// spec root, then, for each directory between the spec root and the file, the
/// spec file named after that directory beside it. Only paths in `specs` count;
/// the file itself is left out, and each parent file is listed once.
pub fn ancestorFiles(
    arena: Allocator,
    spec_root: []const u8,
    path: []const u8,
    specs: *const std.StringHashMapUnmanaged(usize),
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(arena);
    if (!isUnder(path, spec_root)) return out.toOwnedSlice(arena);
    const prefix = if (spec_root.len == 0) "" else try arena.print("{s}/", .{spec_root});
    const ancestry: Ancestry = .{ .arena = arena, .out = &out, .specs = specs, .path = path };
    try ancestry.add(try arena.print("{s}root.spec.md", .{prefix}));
    const rel = path[prefix.len..];
    var start: usize = 0;
    while (std.mem.findScalarPos(u8, rel, start, '/')) |slash| {
        try ancestry.add(try arena.print("{s}{s}.spec.md", .{ prefix, rel[0..slash] }));
        start = slash + 1;
    }
    return out.toOwnedSlice(arena);
}

/// Collects the parent files of the spec file at `path`.
const Ancestry = struct {
    arena: Allocator,
    out: *std.ArrayList([]const u8),
    specs: *const std.StringHashMapUnmanaged(usize),
    path: []const u8,

    fn add(a: Ancestry, candidate: []const u8) Allocator.Error!void {
        if (std.mem.eql(u8, candidate, a.path) or !a.specs.contains(candidate)) return;
        for (a.out.items) |listed| {
            if (std.mem.eql(u8, listed, candidate)) return;
        }
        try a.out.append(a.arena, candidate);
    }
};

/// Listed files, split by what `check` does with them.
pub const Partition = struct {
    spec_paths: []const []const u8,
    source_paths: []const []const u8,
};

/// Splits listed files into spec files and files to scan for references.
pub fn partition(
    arena: Allocator,
    paths: []const []const u8,
    cfg: Config,
) Allocator.Error!Partition {
    var specs: std.ArrayList([]const u8) = .empty;
    errdefer specs.deinit(arena);
    var sources: std.ArrayList([]const u8) = .empty;
    errdefer sources.deinit(arena);
    for (paths) |p| {
        if (isUnder(p, cfg.spec_root)) {
            if (std.mem.endsWith(u8, p, ".spec.md")) try specs.append(arena, p);
        } else if (!isExcluded(p, cfg.exclude)) {
            try sources.append(arena, p);
        }
    }
    return .{
        .spec_paths = try specs.toOwnedSlice(arena),
        .source_paths = try sources.toOwnedSlice(arena),
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

// specrail: specs/config.spec.md § 2.3 Glob syntax
test "glob patterns" {
    try testing.expect(globMatch("notes.md", "notes.md"));
    try testing.expect(!globMatch("notes.md", "a/notes.md"));
    try testing.expect(globMatch("*.md", "notes.md"));
    try testing.expect(!globMatch("*.md", "docs/notes.md"));
    try testing.expect(globMatch("docs/**", "docs/a/b.md"));
    try testing.expect(globMatch("**/*.md", "a/b/c.md"));
    try testing.expect(globMatch("src/?.zig", "src/a.zig"));
    try testing.expect(!globMatch("src/?.zig", "src/ab.zig"));
    try testing.expect(!globMatch("a?b", "a/b"));
}

// specrail: specs/format/spec-files.spec.md § 1.1 Spec files
// specrail: specs/format/spec-files.spec.md § 1.4 Other files under the spec root
// specrail: specs/format/references.spec.md § 2.1 Scanned files
test "listed files split into spec files and files to scan" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const p = try partition(arena_state.allocator(), &.{
        "specs/root.spec.md",
        "specs/auth/login.spec.md",
        "specs/diagram.png",
        "specs/notes.md",
        "specsx/not-a-spec.spec.md",
        "elsewhere.spec.md",
        "src/main.zig",
        "notes.md",
        "docs/a/b.md",
    }, .{ .spec_root = "specs", .exclude = &.{ "notes.md", "docs/**" } });
    try testing.expectEqual(@as(usize, 2), p.spec_paths.len);
    try testing.expectEqualStrings("specs/auth/login.spec.md", p.spec_paths[1]);
    try testing.expectEqual(@as(usize, 3), p.source_paths.len);
    try testing.expectEqualStrings("specsx/not-a-spec.spec.md", p.source_paths[0]);
    try testing.expectEqualStrings("elsewhere.spec.md", p.source_paths[1]);
    try testing.expectEqualStrings("src/main.zig", p.source_paths[2]);
}

// specrail: specs/format/references.spec.md § 2.2 Binary files
test "a NUL byte in the first 8000 bytes makes a file binary" {
    try testing.expect(isBinary("abc\x00def"));
    try testing.expect(!isBinary("plain text"));
    const late = @as([8000]u8, @splat('a')) ++ [_]u8{0};
    try testing.expect(!isBinary(&late));
}

fn specSet(arena: Allocator, paths: []const []const u8) !std.StringHashMapUnmanaged(usize) {
    var set: std.StringHashMapUnmanaged(usize) = .empty;
    errdefer set.deinit(arena);
    for (paths, 0..) |path, i| try set.put(arena, path, i);
    return set;
}

// specrail: specs/format/spec-files.spec.md § 1.2 Parent files
// specrail: specs/format/spec-files.spec.md § 1.3 Ancestor files
test "the ancestor files are the parent files of the directories above a spec" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const set = try specSet(arena, &.{
        "specs/root.spec.md",
        "specs/auth.spec.md",
        "specs/auth/login.spec.md",
        "specs/auth/oauth/google.spec.md",
        "specs/root/odd.spec.md",
    });
    const deep = try ancestorFiles(arena, "specs", "specs/auth/oauth/google.spec.md", &set);
    try testing.expectEqual(@as(usize, 2), deep.len);
    try testing.expectEqualStrings("specs/root.spec.md", deep[0]);
    try testing.expectEqualStrings("specs/auth.spec.md", deep[1]);
    const root = try ancestorFiles(arena, "specs", "specs/root.spec.md", &set);
    try testing.expectEqual(@as(usize, 0), root.len);
    const odd = try ancestorFiles(arena, "specs", "specs/root/odd.spec.md", &set);
    try testing.expectEqual(@as(usize, 1), odd.len);
    const top = try specSet(arena, &.{ "root.spec.md", "auth.spec.md", "auth/login.spec.md" });
    const at_top = try ancestorFiles(arena, "", "auth/login.spec.md", &top);
    try testing.expectEqualStrings("auth.spec.md", at_top[1]);
}
