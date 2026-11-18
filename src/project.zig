//! Loading a project: root, configuration, and the contents of its files.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const cli = @import("cli.zig");
const config = @import("config.zig");
const files = @import("files.zig");

/// A project file and its contents.
pub const SourceFile = struct {
    /// Relative to the project root.
    path: []const u8,
    content: []const u8,
};

/// An opened project: its root, its configuration and its files.
pub const Project = struct {
    root: []const u8,
    config: config.Config,
    spec_files: []const SourceFile,
    /// Files scanned for references.
    source_files: []const SourceFile,
};

/// Reads a project file; null when it no longer exists or is not a file.
fn readFile(arena: Allocator, io: Io, root: []const u8, path: []const u8) !?[]const u8 {
    const abs = try std.Io.Dir.path.join(arena, &.{ root, path });
    return Io.Dir.cwd().readFileAlloc(io, abs, arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound, error.IsDir, error.NotDir => null,
        else => return e,
    };
}

/// The project root and its settings.
pub const Settings = struct {
    root: []const u8,
    config: config.Config,
};

/// Finds the project root and reads `specrail.toml`, without listing files.
/// When either fails, it prints the reason to stderr and returns null; the
/// command then exits with status 2.
pub fn openConfig(ctx: *cli.Ctx) cli.Error!?Settings {
    const arena = ctx.arena;
    const root = (try config.findProjectRoot(arena, ctx.io, ctx.cwd, ctx.root_ceiling)) orelse {
        try ctx.stderr.print(
            "specrail: no {s} in {s} or any parent directory; run 'specrail init' to create one\n",
            .{ config.file_name, ctx.cwd },
        );
        return null;
    };
    const toml_path = try std.Io.Dir.path.join(arena, &.{ root, config.file_name });
    const text = Io.Dir.cwd().readFileAlloc(ctx.io, toml_path, arena, .unlimited) catch |e| {
        try ctx.stderr.print("specrail: cannot read {s}: {s}\n", .{ toml_path, @errorName(e) });
        return null;
    };
    const cfg = switch (try config.parse(arena, ctx.io, root, text)) {
        .ok => |c| c,
        .err => |msg| {
            try ctx.stderr.print("{s}\n", .{msg});
            return null;
        },
    };
    return .{ .root = root, .config = cfg };
}

/// Opens the project around the working directory. On failure, prints the
/// reason to stderr and returns null; the command then exits with status 2.
pub fn open(ctx: *cli.Ctx) cli.Error!?Project {
    const arena = ctx.arena;
    const settings = (try openConfig(ctx)) orelse return null;
    const root = settings.root;
    const cfg = settings.config;
    const listed = switch (try files.list(arena, ctx.io, root, ctx.git_env)) {
        .ok => |l| l,
        .err => |msg| {
            try ctx.stderr.print("specrail: {s}\n", .{msg});
            return null;
        },
    };
    const parts = try files.partition(arena, listed, cfg);
    var specs: std.ArrayList(SourceFile) = .empty;
    errdefer specs.deinit(arena);
    var sources: std.ArrayList(SourceFile) = .empty;
    errdefer sources.deinit(arena);
    for (parts.spec_paths) |p| {
        const content = readFile(arena, ctx.io, root, p) catch |e| {
            try ctx.stderr.print("specrail: cannot read {s}: {s}\n", .{ p, @errorName(e) });
            return null;
        } orelse continue;
        try specs.append(arena, .{ .path = p, .content = content });
    }
    for (parts.source_paths) |p| {
        const content = readFile(arena, ctx.io, root, p) catch |e| {
            try ctx.stderr.print("specrail: cannot read {s}: {s}\n", .{ p, @errorName(e) });
            return null;
        } orelse continue;
        if (files.isBinary(content)) continue;
        try sources.append(arena, .{ .path = p, .content = content });
    }
    return .{
        .root = root,
        .config = cfg,
        .spec_files = try specs.toOwnedSlice(arena),
        .source_files = try sources.toOwnedSlice(arena),
    };
}

/// The spec files a command was given.
pub const Selection = union(enum) {
    /// Every spec file: the command was given no paths.
    all,
    /// A path named no spec file; the usage error has been printed.
    refused,
    /// The spec files at or under the paths the command was given.
    some: []const []const u8,
};

/// Resolves command-line paths, relative to the working directory, to the spec
/// files at them or under them.
pub fn selectSpecs(
    ctx: *cli.Ctx,
    p: Project,
    paths: []const []const u8,
    command: []const u8,
) cli.Error!Selection {
    if (paths.len == 0) return .all;
    var selected: std.ArrayList([]const u8) = .empty;
    errdefer selected.deinit(ctx.arena);
    for (paths) |arg| {
        const rel = (try projectPath(ctx.arena, ctx.cwd, p.root, arg)) orelse {
            _ = try cli.usageError(ctx, command, "'{s}' is outside the project", .{arg});
            return .refused;
        };
        var matched = false;
        specs: for (p.spec_files) |f| {
            if (!std.mem.eql(u8, f.path, rel) and !files.isUnder(f.path, rel)) continue :specs;
            matched = true;
            for (selected.items) |already| {
                if (std.mem.eql(u8, already, f.path)) break;
            } else try selected.append(ctx.arena, f.path);
        }
        if (!matched) {
            const msg = "'{s}' is not a spec file or a directory of spec files";
            _ = try cli.usageError(ctx, command, msg, .{arg});
            return .refused;
        }
    }
    return .{ .some = try selected.toOwnedSlice(ctx.arena) };
}

/// Resolves `.` and `..` in an absolute path.
pub fn normalizeAbsolute(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(arena);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            _ = parts.pop();
        } else try parts.append(arena, part);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    for (parts.items) |part| {
        try out.append(arena, '/');
        try out.appendSlice(arena, part);
    }
    if (out.items.len == 0) try out.append(arena, '/');
    return out.toOwnedSlice(arena);
}

/// Turns a command-line path, relative to the working directory, into a path
/// relative to the project root; null when it is outside the project.
pub fn projectPath(
    arena: Allocator,
    cwd: []const u8,
    root: []const u8,
    arg: []const u8,
) Allocator.Error!?[]const u8 {
    const joined = if (std.Io.Dir.path.isAbsolute(arg))
        arg
    else
        try std.Io.Dir.path.join(arena, &.{ cwd, arg });
    const abs = try normalizeAbsolute(arena, joined);
    if (std.mem.eql(u8, abs, root)) return "";
    const inside = std.mem.startsWith(u8, abs, root) and
        abs.len > root.len and abs[root.len] == '/';
    return if (inside) abs[root.len + 1 ..] else null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const sandbox = @import("sandbox.zig");

test "command-line paths become project paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "specs/a.spec.md",
        (try projectPath(arena, "/p", "/p", "specs/a.spec.md")).?,
    );
    try std.testing.expectEqualStrings(
        "specs/a.spec.md",
        (try projectPath(arena, "/p/src", "/p", "../specs/./a.spec.md")).?,
    );
    try std.testing.expectEqualStrings("", (try projectPath(arena, "/p/specs", "/p", "..")).?);
    try std.testing.expect((try projectPath(arena, "/p", "/p", "../q")) == null);
    try std.testing.expect((try projectPath(arena, "/p", "/p", "/px/a")) == null);
}

// specrail: specs/config.spec.md § 1.2 No project root
test "without specrail.toml, commands exit 2 and suggest init" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    const o = try s.runAtRoot(&.{"check"});
    try testing.expectEqual(@as(u8, 2), o.code);
    try sandbox.expectContains(o.stderr, "specrail init");
}

// specrail: specs/config.spec.md § 1.1 Finding the project root
test "commands find the project root from a subdirectory" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try s.passing();
    const o = try s.runIn("src", &.{ "check", "../specs/a.spec.md" }, .{});
    try testing.expectEqual(@as(u8, 0), o.code);
    try sandbox.expectContains(o.stdout, "1/1 done leaves covered");
}

// specrail: specs/config.spec.md § 3.1 Listed files
test "only files git lists are scanned" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try s.write("specrail.toml", "spec_root = \"specs\"\n");
    try s.write("specs/a.spec.md", "# § 1 One\n\nIt MUST work.\n# § 2 Two\n\nIt MUST work.\n");
    try s.write(".gitignore", "ignored/\n");
    try s.write("tracked.zig", "// specrail: specs/a.spec.md § 1 One\n");
    try s.git(&.{ "git", "add", "tracked.zig" });
    try s.write("ignored/t.zig", "// specrail: specs/a.spec.md § 2 Two\n");
    const o = try s.runAtRoot(&.{"check"});
    try testing.expectEqual(@as(u8, 1), o.code);
    try sandbox.expectContains(o.stdout, "§ 2 Two is not covered");
    try sandbox.expectContains(o.stdout, "1/2 done leaves covered");
}

// specrail: specs/config.spec.md § 3.2 Without git
test "outside a git work tree, commands exit 2 with git's reason" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try s.passing();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("GIT_DIR", "/nonexistent/specrail-test");
    const o = try s.runIn("", &.{"check"}, .{ .git_env = &env });
    try testing.expectEqual(@as(u8, 2), o.code);
    try sandbox.expectContains(o.stderr, "not a git repository");
}

// specrail: specs/format/references.spec.md § 2.1 Scanned files
// specrail: specs/format/references.spec.md § 2.2 Binary files
test "spec files, excluded files and binary files are not scanned" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try s.write("specrail.toml", "spec_root = \"specs\"\nexclude = [\"docs/**\"]\n");
    try s.write(
        "specs/a.spec.md",
        "# § 1 One\n\nIt MUST work.\n\n```\n// specrail: specs/nope.spec.md § 1 Example\n```\n",
    );
    try s.write("docs/guide.md", "// specrail: specs/nope.spec.md § 1 Example\n");
    try s.write("blob.bin", "\x00// specrail: specs/nope.spec.md § 1 Example\n");
    try s.write("t.zig", "// specrail: specs/a.spec.md § 1 One\n");
    const o = try s.runAtRoot(&.{"check"});
    try testing.expectEqual(@as(u8, 0), o.code);
}
