//! Test helpers: a throwaway git repository holding a specrail project, and a
//! way to run specrail in it in-process, as the command line would.

const std = @import("std");
const testing = std.testing;

const cli = @import("cli.zig");

const Dir = std.Io.Dir;
const GitError = std.process.RunError || error{GitFailed};
const WriteError = Dir.CreateDirPathError || Dir.WriteFileError;

/// A throwaway git repository with a specrail project in it.
pub const Sandbox = struct {
    tmp: testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    root: []const u8,

    /// A fresh sandbox: an empty git repository in a temporary directory.
    pub fn init() (Dir.RealPathFileAllocError || GitError)!Sandbox {
        var s: Sandbox = .{
            .tmp = testing.tmpDir(.{}),
            .arena_state = .init(testing.allocator),
            .root = undefined,
        };
        s.root = try s.tmp.dir.realPathFileAlloc(testing.io, ".", s.arena_state.allocator());
        try s.git(&.{ "git", "init", "-q" });
        return s;
    }

    /// Removes the sandbox and everything in it.
    pub fn deinit(s: *Sandbox) void {
        s.tmp.cleanup();
        s.arena_state.deinit();
    }

    /// Runs a git command in the sandbox, failing on a non-zero exit.
    pub fn git(s: *Sandbox, argv: []const []const u8) GitError!void {
        const r = try std.process.run(
            s.arena_state.allocator(),
            testing.io,
            .{ .argv = argv, .cwd = .{ .path = s.root } },
        );
        if (!r.term.success()) return error.GitFailed;
    }

    /// Writes a file, creating the directories it needs.
    pub fn write(s: *Sandbox, path: []const u8, data: []const u8) WriteError!void {
        if (std.Io.Dir.path.dirname(path)) |dir| try s.tmp.dir.createDirPath(testing.io, dir);
        try s.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = data });
    }

    /// Creates a symbolic link at `path` that points to `target`, creating the
    /// directories it needs.
    pub fn symlink(
        s: *Sandbox,
        target: []const u8,
        path: []const u8,
    ) (WriteError || Dir.SymLinkError)!void {
        if (std.Io.Dir.path.dirname(path)) |dir| try s.tmp.dir.createDirPath(testing.io, dir);
        try s.tmp.dir.symLink(testing.io, target, path, .{});
    }

    /// Reads a file.
    pub fn read(s: *Sandbox, path: []const u8) Dir.ReadFileAllocError![]const u8 {
        return s.tmp.dir.readFileAlloc(testing.io, path, s.arena_state.allocator(), .unlimited);
    }

    /// Whether a file or directory exists.
    pub fn exists(s: *Sandbox, path: []const u8) bool {
        return if (s.tmp.dir.access(testing.io, path, .{})) |_| true else |_| false;
    }

    /// What one run of specrail printed, and its exit status.
    pub const Output = struct {
        code: u8,
        stdout: []const u8,
        stderr: []const u8,
    };

    /// Runs specrail in a subdirectory of the sandbox, as the command line would.
    pub fn runIn(s: *Sandbox, sub: []const u8, args: []const []const u8, options: struct {
        tty: bool = false,
        no_color: ?[]const u8 = null,
        git_env: ?*const std.process.Environ.Map = null,
    }) std.mem.Allocator.Error!Output {
        const arena = s.arena_state.allocator();
        var out: std.Io.Writer.Allocating = .init(arena);
        var err: std.Io.Writer.Allocating = .init(arena);
        var ctx: cli.Ctx = .{
            .arena = arena,
            .io = testing.io,
            .stdout = &out.writer,
            .stderr = &err.writer,
            .stdout_is_tty = options.tty,
            .no_color = options.no_color,
            .cwd = try std.Io.Dir.path.join(arena, &.{ s.root, sub }),
            .now = 20774 * 86400,
            .git_env = options.git_env,
            .root_ceiling = s.root,
        };
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        try argv.append(arena, "specrail");
        try argv.appendSlice(arena, args);
        const code = cli.run(&ctx, argv.items);
        return .{ .code = code, .stdout = out.written(), .stderr = err.written() };
    }

    /// Runs specrail at the sandbox's root.
    pub fn runAtRoot(s: *Sandbox, args: []const []const u8) std.mem.Allocator.Error!Output {
        return s.runIn("", args, .{});
    }

    /// A small project that passes check.
    pub fn passing(s: *Sandbox) WriteError!void {
        try s.write("specrail.toml", "spec_root = \"specs\"\n");
        try s.write("specs/a.spec.md", "# § 1 One\n\nIt MUST work.\n");
        try s.write("src/a_test.zig", "// specrail: specs/a.spec.md § 1 One\n");
    }
};

/// Fails the test unless `haystack` contains `needle`.
pub fn expectContains(haystack: []const u8, needle: []const u8) error{TestUnexpectedResult}!void {
    if (std.mem.find(u8, haystack, needle) == null) {
        std.debug.print("expected '{s}' in:\n{s}\n", .{ needle, haystack });
        return error.TestUnexpectedResult;
    }
}
