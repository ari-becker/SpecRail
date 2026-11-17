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

/// Opens the project around the working directory. On failure, prints the
/// reason to stderr and returns null; the command then exits with status 2.
pub fn open(ctx: *cli.Ctx) cli.Error!?Project {
    const arena = ctx.arena;
    const root = (try config.findProjectRoot(arena, ctx.io, ctx.cwd, ctx.root_ceiling)) orelse {
        try ctx.stderr.print("specrail: no {s} in {s} or any parent directory; run 'specrail init' to create one\n", .{ config.file_name, ctx.cwd });
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
pub fn projectPath(arena: Allocator, cwd: []const u8, root: []const u8, arg: []const u8) Allocator.Error!?[]const u8 {
    const joined = if (std.Io.Dir.path.isAbsolute(arg)) arg else try std.Io.Dir.path.join(arena, &.{ cwd, arg });
    const abs = try normalizeAbsolute(arena, joined);
    if (std.mem.eql(u8, abs, root)) return "";
    if (!std.mem.startsWith(u8, abs, root) or abs.len <= root.len or abs[root.len] != '/') return null;
    return abs[root.len + 1 ..];
}

test "command-line paths become project paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("specs/a.spec.md", (try projectPath(arena, "/p", "/p", "specs/a.spec.md")).?);
    try std.testing.expectEqualStrings("specs/a.spec.md", (try projectPath(arena, "/p/src", "/p", "../specs/./a.spec.md")).?);
    try std.testing.expectEqualStrings("", (try projectPath(arena, "/p/specs", "/p", "..")).?);
    try std.testing.expect((try projectPath(arena, "/p", "/p", "../q")) == null);
    try std.testing.expect((try projectPath(arena, "/p", "/p", "/px/a")) == null);
}
