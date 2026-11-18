//! Changing the project's files safely, for `fmt`, `mv` and `swap`. Nothing
//! is written through a symbolic link, which could reach outside the
//! project. Nothing is moved or replaced until the new content of every file
//! has been written to a temporary file near it; when one cannot be, the
//! temporary files are removed and nothing has changed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const cli = @import("cli.zig");
const files = @import("files.zig");

/// A file or directory to move, by project path.
pub const Move = struct {
    old: []const u8,
    new: []const u8,
};

/// A file to write: where it is now, where it will be once the moves are
/// made, and its new content.
pub const Write = struct {
    /// Where the file is now; for a file being created, where it will be.
    origin: []const u8,
    path: []const u8,
    content: []const u8,
};

/// `error.Stopped` means a change could not be made, and why was reported.
const Error = cli.Error || error{Stopped};

/// The moves and writes a command makes to the project.
pub const Changes = struct {
    ctx: *cli.Ctx,
    /// The absolute path of the project root.
    root: []const u8,
    /// The command making the changes, for its messages.
    command: []const u8,
    /// The files and directories to move, in order.
    moves: std.ArrayList(Move) = .empty,
    /// The files to write once the moves are made.
    writes: std.ArrayList(Write) = .empty,
    /// Where each file the moves take now is, filled in as the changes are
    /// made: every file under a moved directory, whatever it holds.
    moved: std.ArrayList([]const u8) = .empty,

    /// Makes every change, and returns 0; or, having reported why it could
    /// not, returns exit status 2. Every path is checked for symbolic links
    /// and every new file content staged before anything changes.
    pub fn make(c: *Changes) cli.Error!u8 {
        c.makeOrStop() catch |err| switch (err) {
            error.Stopped => return 2,
            else => |other| return other,
        };
        return 0;
    }

    fn makeOrStop(c: *Changes) Error!void {
        try c.guard();
        try c.listMoved();
        const temps = try c.stage();
        try c.apply(temps);
    }

    fn stop(c: *Changes, comptime format: []const u8, args: anytype) Error {
        c.ctx.stderr.print("specrail: " ++ format ++ "\n", args) catch |err| return err;
        return error.Stopped;
    }

    /// The absolute path of the project path `path`.
    pub fn abs(c: *const Changes, path: []const u8) Allocator.Error![]const u8 {
        return Io.Dir.path.join(c.ctx.arena, &.{ c.root, path });
    }

    /// Whether anything is at the project path `path`.
    pub fn exists(c: *const Changes, path: []const u8) Allocator.Error!bool {
        const at = try c.abs(path);
        _ = Io.Dir.cwd().statFile(c.ctx.io, at, .{}) catch return false;
        return true;
    }

    /// Whether the project path `path` is a directory.
    pub fn isDirectory(c: *const Changes, path: []const u8) Allocator.Error!bool {
        const at = try c.abs(path);
        const st = Io.Dir.cwd().statFile(c.ctx.io, at, .{}) catch return false;
        return st.kind == .directory;
    }

    /// Where the file at `path` is once the moves are made.
    pub fn finalPath(c: *const Changes, path: []const u8) Allocator.Error![]const u8 {
        for (c.moves.items) |mv| {
            if (files.isUnder(path, mv.old)) {
                return std.mem.concat(c.ctx.arena, u8, &.{ mv.new, path[mv.old.len..] });
            }
        }
        return path;
    }

    /// Stops before anything changes when any part of a path to move, create
    /// or write is a symbolic link: following one could change files outside
    /// the project.
    fn guard(c: *Changes) Error!void {
        for (c.moves.items) |mv| {
            try c.refuseLink(mv.old);
            try c.refuseLink(mv.new);
        }
        for (c.writes.items) |w| {
            try c.refuseLink(w.origin);
            try c.refuseLink(w.path);
        }
    }

    fn refuseLink(c: *Changes, path: []const u8) Error!void {
        const link = (try files.symlinkOn(c.ctx.arena, c.ctx.io, c.root, path)) orelse return;
        const msg = "{s} is a symbolic link, and {s} does not follow symbolic links";
        return c.stop(msg, .{ link, c.command });
    }

    /// Lists where each file the moves take will be. Directories are walked
    /// before anything is staged, so the staged files are not among them, and
    /// symbolic links are listed, not followed.
    fn listMoved(c: *Changes) Error!void {
        const arena = c.ctx.arena;
        for (c.moves.items) |mv| {
            if (!try c.isDirectory(mv.old)) {
                try c.moved.append(arena, try c.finalPath(mv.old));
                continue;
            }
            c.walkMoved(mv) catch |err| switch (err) {
                error.OutOfMemory, error.Stopped, error.WriteFailed => |e| return e,
                else => |e| {
                    const msg = "cannot list the files in {s}: {s}; nothing was changed";
                    return c.stop(msg, .{ mv.old, @errorName(e) });
                },
            };
        }
    }

    fn walkMoved(c: *Changes, mv: Move) (Error || Io.Dir.OpenError || Io.Dir.Iterator.Error)!void {
        const arena = c.ctx.arena;
        const io = c.ctx.io;
        var dir = try Io.Dir.cwd().openDir(io, try c.abs(mv.old), .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind == .directory) continue;
            const old = try Io.Dir.path.join(arena, &.{ mv.old, entry.path });
            try c.moved.append(arena, try c.finalPath(old));
        }
    }

    /// Writes the new content of every file to a new temporary file near
    /// where the file is now, and returns their paths. When one cannot be
    /// written, removes those already written and stops, so that nothing has
    /// changed.
    fn stage(c: *Changes) Error![]const []const u8 {
        const temps = try c.ctx.arena.alloc([]const u8, c.writes.items.len);
        for (c.writes.items, temps, 0..) |w, *t, i| {
            t.* = try c.tempPath(w.origin, i);
            const flags: Io.Dir.CreateFileOptions = .{
                .exclusive = true,
                .permissions = try c.permissionsOf(w.origin),
            };
            const options: Io.Dir.WriteFileOptions = .{
                .sub_path = try c.abs(t.*),
                .data = w.content,
                .flags = flags,
            };
            Io.Dir.cwd().writeFile(c.ctx.io, options) catch |err| {
                // A file already at the temporary path is not this command's.
                const created = if (err == error.PathAlreadyExists) i else i + 1;
                try c.discard(temps[0..created]);
                const msg = "cannot write {s}: {s}; nothing was changed";
                return c.stop(msg, .{ w.path, @errorName(err) });
            };
        }
        return temps;
    }

    /// A temporary file for the `i`th write, in the nearest directory at or
    /// above the directory of `origin` that exists, so that staging creates no
    /// directories.
    fn tempPath(c: *const Changes, origin: []const u8, i: usize) Allocator.Error![]const u8 {
        var dir = Io.Dir.path.dirname(origin) orelse "";
        // Each step drops one component from `dir`, so the loop ends.
        while (dir.len > 0 and !try c.isDirectory(dir)) dir = Io.Dir.path.dirname(dir) orelse "";
        const base = Io.Dir.path.basename(origin);
        const name = try c.ctx.arena.print(".{s}.{d}.specrail-tmp", .{ base, i });
        return Io.Dir.path.join(c.ctx.arena, &.{ dir, name });
    }

    /// The permissions of the file at `path`, or the default for a new file.
    fn permissionsOf(c: *const Changes, path: []const u8) Allocator.Error!Io.File.Permissions {
        const at = try c.abs(path);
        const st = Io.Dir.cwd().statFile(c.ctx.io, at, .{}) catch return .default_file;
        return st.permissions;
    }

    /// Removes the temporary files `temps`.
    fn discard(c: *Changes, temps: []const []const u8) Error!void {
        for (temps) |t| {
            const at = try c.abs(t);
            Io.Dir.cwd().deleteFile(c.ctx.io, at) catch |err| {
                const msg = "specrail: cannot remove {s}: {s}\n";
                try c.ctx.stderr.print(msg, .{ t, @errorName(err) });
            };
        }
    }

    /// Makes the moves, then puts each staged file in place. Renames are all
    /// that is left to fail here.
    fn apply(c: *Changes, temps: []const []const u8) Error!void {
        const io = c.ctx.io;
        const cwd = Io.Dir.cwd();
        for (c.moves.items) |mv| {
            const new = try c.abs(mv.new);
            try c.makeParent(new);
            cwd.rename(try c.abs(mv.old), cwd, new, io) catch |err| {
                const msg = "cannot move {s} to {s}: {s}; the project is partly changed";
                return c.stop(msg, .{ mv.old, mv.new, @errorName(err) });
            };
        }
        for (c.writes.items, temps) |w, t| {
            const to = try c.abs(w.path);
            try c.makeParent(to);
            // A staged file inside a moved directory moved with it.
            const from = try c.abs(try c.finalPath(t));
            cwd.rename(from, cwd, to, io) catch |err| {
                const msg = "cannot replace {s}: {s}; the project is partly changed";
                return c.stop(msg, .{ w.path, @errorName(err) });
            };
        }
    }

    /// Creates the directory that `at`, an absolute path, will be in.
    fn makeParent(c: *Changes, at: []const u8) Error!void {
        const dir = Io.Dir.path.dirname(at) orelse return;
        Io.Dir.cwd().createDirPath(c.ctx.io, dir) catch |err| {
            return c.stop("cannot create {s}: {s}", .{ dir, @errorName(err) });
        };
    }
};
