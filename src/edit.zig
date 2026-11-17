//! The engine behind `specrail mv` and `specrail swap`. Spec files become
//! outlines whose sections can be taken out and put back elsewhere; every
//! reference and dependency entry that names a section or spec file that
//! changed is rewritten to match; and the result is written safely: nothing
//! changes until every new file content is written, and nothing is ever
//! written through a symbolic link.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const cli = @import("cli.zig");
const config = @import("config.zig");
const diag = @import("diag.zig");
const files = @import("files.zig");
const project = @import("project.zig");
const refs = @import("refs.zig");
const rewrite = @import("rewrite.zig");
const spec = @import("spec.zig");

/// `error.Stopped` means the command reported why it stopped, and
/// `Editor.status` holds its exit status.
pub const Error = cli.Error || error{Stopped};

/// A file or directory to move, by project path.
pub const Move = struct {
    old: []const u8,
    new: []const u8,
};

/// A file to write: where it is now, where it will be once the moves are
/// made, and its new content.
pub const Write = struct {
    /// Where the file is now; for a spec file being created, where it will be.
    origin: []const u8,
    path: []const u8,
    content: []const u8,
};

/// What a reference names: a spec file, and a section in it.
pub const Name = struct {
    path: []const u8,
    number: []const u8,
    title: []const u8,

    /// The name a reference form gives.
    pub fn of(form: refs.Form) Name {
        return .{ .path = form.path, .number = form.number, .title = form.title };
    }

    /// Whether two names are the same, byte for byte.
    pub fn eql(a: Name, b: Name) bool {
        const same_path = std.mem.eql(u8, a.path, b.path);
        return same_path and std.mem.eql(u8, a.number, b.number) and
            std.mem.eql(u8, a.title, b.title);
    }
};

/// A section whose name changes.
const Rename = struct {
    old: Name,
    new: Name,
};

/// Rewrites what names a renamed section so it names the section as it is now.
const Renames = struct {
    items: []const Rename,

    fn replace(context: *const anyopaque, form: refs.Form) ?rewrite.Replacement {
        const r: *const Renames = @ptrCast(@alignCast(context));
        for (r.items) |rn| {
            if (!rn.old.eql(Name.of(form))) continue;
            return .{ .path = rn.new.path, .number = rn.new.number, .title = rn.new.title };
        }
        return null;
    }

    fn rewriter(r: *const Renames) rewrite.Rewriter {
        return .{ .context = r, .replaceFn = replace };
    }
};

/// Rewrites what names a moved spec file so it names the file's new path.
pub const Paths = struct {
    /// The new path of each moved spec file, by old path.
    moved: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn replace(context: *const anyopaque, form: refs.Form) ?rewrite.Replacement {
        const ps: *const Paths = @ptrCast(@alignCast(context));
        return .{ .path = ps.moved.get(form.path) orelse return null };
    }

    /// The rewriter that applies these moves.
    pub fn rewriter(ps: *const Paths) rewrite.Rewriter {
        return .{ .context = ps, .replaceFn = replace };
    }
};

/// Which block of moving sections an entry is in. Each block is set off from
/// what is around it by blank lines.
pub const Group = enum { first, none, second };

/// One section in an outline: its heading and its own lines.
pub const Entry = struct {
    /// What the section's heading said before the change.
    old: Name,
    old_level: u8,
    level: u8,
    title: []const u8,
    /// The heading line as written.
    heading: []const u8,
    /// The lines after the heading up to the next heading: the section's
    /// metadata block and its own prose.
    body: []const []const u8,
    group: Group = .none,
};

/// Where a section is: the index of its spec file, and its index there.
pub const Place = struct {
    file: usize,
    index: usize,
};

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t\r\n").len == 0;
}

fn allBlank(lines: []const []const u8) bool {
    for (lines) |l| {
        if (!isBlank(l)) return false;
    }
    return true;
}

/// Whether `number` lies inside the subtree of the section numbered `top`.
pub fn isBelow(number: []const u8, top: []const u8) bool {
    const prefixed = number.len > top.len and std.mem.startsWith(u8, number, top);
    return prefixed and number[top.len] == '.';
}

/// Whether an argument names a section rather than a path. Reference form
/// always has a space between the path and the section sign.
pub fn isSection(arg: []const u8) bool {
    return std.mem.findAny(u8, arg, " \t") != null;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// A spec file being edited: the lines before its first section, then its
/// sections in order.
pub const Outline = struct {
    path: []const u8,
    /// The lines before the first section: the context and the separator.
    preamble: []const []const u8,
    entries: std.ArrayList(Entry) = .empty,
    /// The line ending of the lines written anew.
    newline: []const u8,
    /// The preamble is context without a separator, so sections placed after
    /// it need one.
    needs_separator: bool = false,
    /// The file ended with a blank line.
    trailing_blank: bool = false,
    /// The number of each entry, set by `renumber`.
    numbers: []const []const u8 = &.{},

    fn init(
        arena: Allocator,
        file: *const spec.SpecFile,
        content: []const u8,
    ) Allocator.Error!Outline {
        const raw = try rewrite.splitLines(arena, content);
        const sections = file.sections;
        const first = if (sections.len > 0) sections[0].line - 1 else raw.len;
        var o: Outline = .{
            .path = file.path,
            .preamble = raw[0..first],
            .newline = rewrite.fileEnding(raw),
            .needs_separator = sections.len == 0 and file.separator == null and !allBlank(raw),
            .trailing_blank = raw.len > 0 and isBlank(raw[raw.len - 1]),
        };
        for (sections) |s| {
            try o.entries.append(arena, .{
                .old = .{ .path = file.path, .number = s.number, .title = s.title },
                .old_level = s.level,
                .level = s.level,
                .title = s.title,
                .heading = raw[s.line - 1],
                .body = raw[s.line..s.own_end],
            });
        }
        return o;
    }

    /// The outline of a spec file being created.
    pub fn empty(path: []const u8, newline: []const u8) Outline {
        return .{ .path = path, .preamble = &.{}, .newline = newline };
    }

    /// The index after the subtree of the entry at `i`.
    pub fn subtreeEnd(o: *const Outline, i: usize) usize {
        const level = o.entries.items[i].level;
        for (o.entries.items[i + 1 ..], i + 1..) |e, k| {
            if (e.level <= level) return k;
        }
        return o.entries.items.len;
    }

    /// Removes the entry at `i` and its subtree, and returns them.
    pub fn take(o: *Outline, arena: Allocator, i: usize) Allocator.Error![]Entry {
        const end = o.subtreeEnd(i);
        const taken = try arena.dupe(Entry, o.entries.items[i..end]);
        try o.entries.replaceRange(arena, i, end - i, &.{});
        return taken;
    }

    /// The number of each entry by its position.
    pub fn positions(o: *const Outline, arena: Allocator) Allocator.Error![]const []const u8 {
        const out = try arena.alloc([]const u8, o.entries.items.len);
        errdefer arena.free(out);
        var numbering: spec.Numbering = .{};
        for (o.entries.items, out) |e, *n| n.* = try numbering.next(arena, e.level);
        return out;
    }

    /// Numbers the entries by position, and records each one whose name
    /// changes.
    fn renumber(
        o: *Outline,
        arena: Allocator,
        renames: *std.ArrayList(Rename),
    ) Allocator.Error!void {
        o.numbers = try o.positions(arena);
        for (o.entries.items, o.numbers) |e, n| {
            const new: Name = .{ .path = o.path, .number = n, .title = e.title };
            if (!e.old.eql(new)) try renames.append(arena, .{ .old = e.old, .new = new });
        }
    }

    /// The file's new content. Lines that are not rewritten keep their bytes,
    /// except that lines moved in from another file take this file's line
    /// ending. Each block of moved sections is set off by blank lines.
    fn render(o: *const Outline, arena: Allocator) Allocator.Error![]const u8 {
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(arena);
        try lines.appendSlice(arena, o.preamble);
        if (o.needs_separator and o.entries.items.len > 0) {
            try o.blankLine(arena, &lines);
            try o.push(arena, &lines, try std.mem.concat(arena, u8, &.{ "---", o.newline }));
        }
        var group: Group = .none;
        for (o.entries.items, o.numbers) |e, n| {
            if (e.group != group) try o.blankLine(arena, &lines);
            group = e.group;
            try o.push(arena, &lines, try o.heading(arena, e, n));
            const foreign = !std.mem.eql(u8, e.old.path, o.path);
            for (e.body) |l| try o.push(arena, &lines, if (foreign) try o.adopt(arena, l) else l);
        }
        if (!o.trailing_blank) {
            while (lines.items.len > 1 and isBlank(lines.items[lines.items.len - 1])) {
                _ = lines.pop();
            }
        }
        return std.mem.concat(arena, u8, lines.items);
    }

    /// The heading line of `e` once numbered `number`; as written when
    /// nothing in it changes.
    fn heading(
        o: *const Outline,
        arena: Allocator,
        e: Entry,
        number: []const u8,
    ) Allocator.Error![]const u8 {
        const new: Name = .{ .path = o.path, .number = number, .title = e.title };
        if (e.old.eql(new) and e.level == e.old_level) return e.heading;
        const hashes = "######"[0..e.level];
        const parts = .{ hashes, refs.section_sign, number, e.title, o.newline };
        return arena.print("{s} {s} {s} {s}{s}", parts);
    }

    /// `line` with this file's line ending in place of its own.
    fn adopt(o: *const Outline, arena: Allocator, line: []const u8) Allocator.Error![]const u8 {
        const end = rewrite.ending(line);
        if (end.len == 0 or std.mem.eql(u8, end, o.newline)) return line;
        return std.mem.concat(arena, u8, &.{ rewrite.body(line), o.newline });
    }

    /// Appends `line`, first ending the line before it if that has no ending.
    fn push(
        o: *const Outline,
        arena: Allocator,
        lines: *std.ArrayList([]const u8),
        line: []const u8,
    ) Allocator.Error!void {
        if (lines.items.len > 0) {
            const last = &lines.items[lines.items.len - 1];
            if (rewrite.ending(last.*).len == 0) {
                last.* = try std.mem.concat(arena, u8, &.{ last.*, o.newline });
            }
        }
        try lines.append(arena, line);
    }

    /// Appends a blank line, unless there are no lines or the last is blank.
    fn blankLine(
        o: *const Outline,
        arena: Allocator,
        lines: *std.ArrayList([]const u8),
    ) Allocator.Error!void {
        if (lines.items.len == 0 or isBlank(lines.items[lines.items.len - 1])) return;
        try o.push(arena, lines, o.newline);
    }

    /// The address, in reference form, of the entry whose heading was `name`.
    fn addressOf(o: *const Outline, arena: Allocator, name: Name) Allocator.Error!?[]const u8 {
        for (o.entries.items, o.numbers) |e, n| {
            if (!e.old.eql(name)) continue;
            const parts = .{ o.path, refs.section_sign, n, e.title };
            return try arena.print("{s} {s} {s} {s}", parts);
        }
        return null;
    }
};

/// One run of a command that edits the project: what it read, and what it
/// will change.
pub const Editor = struct {
    ctx: *cli.Ctx,
    /// The command's name, for usage errors.
    command: []const u8,
    proj: project.Project,
    /// Each spec file parsed, in the order of `proj.spec_files`.
    specs: []spec.SpecFile,
    /// The diagnostics from parsing each spec file.
    found: []diag.List,
    /// The index of each spec file, by path.
    by_path: std.StringHashMapUnmanaged(usize) = .empty,
    /// The files and directories to move, in order.
    moves: std.ArrayList(Move) = .empty,
    /// The files to write once the moves are made.
    writes: std.ArrayList(Write) = .empty,
    /// The new address of each moved section, printed before the paths.
    addresses: std.ArrayList([]const u8) = .empty,
    /// The exit status, once the command has stopped.
    status: u8 = 0,

    /// Opens and parses the project; null once that has failed and been
    /// reported, which is exit status 2.
    pub fn open(ctx: *cli.Ctx, command: []const u8) cli.Error!?Editor {
        const proj = (try project.open(ctx)) orelse return null;
        const n = proj.spec_files.len;
        var e: Editor = .{
            .ctx = ctx,
            .command = command,
            .proj = proj,
            .specs = try ctx.arena.alloc(spec.SpecFile, n),
            .found = try ctx.arena.alloc(diag.List, n),
        };
        for (proj.spec_files, 0..) |f, i| {
            e.found[i] = .empty;
            e.specs[i] = try spec.parse(ctx.arena, f.path, f.content, &e.found[i]);
            try e.by_path.put(ctx.arena, f.path, i);
        }
        return e;
    }

    /// Carries out what was planned, unless planning stopped, and returns
    /// the exit status.
    pub fn conclude(e: *Editor, planned: Error!void) cli.Error!u8 {
        planned catch |err| return e.statusOf(err);
        e.commit() catch |err| return e.statusOf(err);
        return 0;
    }

    fn statusOf(e: *const Editor, err: Error) cli.Error!u8 {
        switch (err) {
            error.Stopped => return e.status,
            else => |other| return other,
        }
    }

    /// Reports why the command stops, and stops it with `status`.
    pub fn stop(e: *Editor, status: u8, comptime format: []const u8, args: anytype) Error {
        e.ctx.stderr.print("specrail: " ++ format ++ "\n", args) catch |err| return err;
        e.status = status;
        return error.Stopped;
    }

    /// Reports a usage error, and stops the command with status 2.
    pub fn misuse(e: *Editor, comptime format: []const u8, args: anytype) Error {
        e.status = cli.usageError(e.ctx, e.command, format, args) catch |err| return err;
        return error.Stopped;
    }

    /// Reports the errors in a spec file that keep it from being rewritten
    /// safely, and stops the command with status 1.
    pub fn refuse(e: *Editor, index: usize) Error {
        const intro = "specrail: {s} has errors that keep {s} from rewriting it:\n";
        e.ctx.stderr.print(intro, .{ e.specs[index].path, e.command }) catch |err| return err;
        for (e.found[index].items) |d| {
            if (d.severity != .err) continue;
            diag.write(e.ctx.stderr, d, e.ctx.color) catch |err| return err;
        }
        e.status = 1;
        return error.Stopped;
    }

    /// Whether the spec file at `index` has a section tree that can be
    /// rewritten.
    pub fn rewritable(e: *const Editor, index: usize) bool {
        return !e.specs[index].broken and !e.specs[index].duplicate;
    }

    /// The outline of the spec file at `index`.
    pub fn outline(e: *const Editor, index: usize) Allocator.Error!Outline {
        return Outline.init(e.ctx.arena, &e.specs[index], e.proj.spec_files[index].content);
    }

    fn abs(e: *const Editor, path: []const u8) Allocator.Error![]const u8 {
        return Io.Dir.path.join(e.ctx.arena, &.{ e.proj.root, path });
    }

    /// Whether anything is at the project path `path`.
    pub fn exists(e: *const Editor, path: []const u8) Allocator.Error!bool {
        const at = try e.abs(path);
        _ = Io.Dir.cwd().statFile(e.ctx.io, at, .{}) catch return false;
        return true;
    }

    /// Whether the project path `path` is a directory.
    pub fn isDirectory(e: *const Editor, path: []const u8) Allocator.Error!bool {
        const at = try e.abs(path);
        const st = Io.Dir.cwd().statFile(e.ctx.io, at, .{}) catch return false;
        return st.kind == .directory;
    }

    /// Where the file at `path` is once the moves are made.
    pub fn finalPath(e: *const Editor, path: []const u8) Allocator.Error![]const u8 {
        for (e.moves.items) |mv| {
            if (files.isUnder(path, mv.old)) {
                return std.mem.concat(e.ctx.arena, u8, &.{ mv.new, path[mv.old.len..] });
            }
        }
        return path;
    }

    /// `text` parsed as a section in reference form, with its path
    /// normalized and below the spec root.
    pub fn section(e: *Editor, text: []const u8) Error!refs.Form {
        var form = switch (refs.parseForm(text, .required)) {
            .ok => |f| f,
            .err => |msg| return e.misuse("'{s}' is not a section: {s}", .{ text, msg }),
        };
        form.path = try e.specPath(form.path);
        return form;
    }

    /// `arg` as a project path below the spec root. Absolute paths, and paths
    /// with a `..` component, are refused before they can leave it.
    pub fn specPath(e: *Editor, arg: []const u8) Error![]const u8 {
        const root = e.proj.config.spec_root;
        const path = config.normalizeDir(arg) orelse "";
        const below = path.len > 0 and !std.mem.eql(u8, path, root) and files.isUnder(path, root);
        if (!below) return e.misuse("'{s}' is not a path below the spec root", .{arg});
        return path;
    }

    /// Finds the section `form` names, which must match it exactly. `role`
    /// says which argument it is, for the error when it does not.
    pub fn find(e: *Editor, form: refs.Form, role: []const u8) Error!Place {
        const fi = e.by_path.get(form.path) orelse {
            return e.stop(1, "dangling {s}: there is no spec file {s}", .{ role, form.path });
        };
        if (!e.rewritable(fi)) return e.refuse(fi);
        const sections = e.specs[fi].sections;
        for (sections, 0..) |s, i| {
            const same_number = std.mem.eql(u8, s.number, form.number);
            if (same_number and std.mem.eql(u8, s.title, form.title)) {
                return .{ .file = fi, .index = i };
            }
        }
        for (sections) |s| {
            const same_number = std.mem.eql(u8, s.number, form.number);
            if (!same_number and !std.mem.eql(u8, s.title, form.title)) continue;
            const msg = "stale {s} § {s} {s}: {s} has § {s} {s}";
            const args = .{ role, form.number, form.title, form.path, s.number, s.title };
            return e.stop(1, msg, args);
        }
        const msg = "dangling {s}: {s} has no § {s} and no section titled '{s}'";
        return e.stop(1, msg, .{ role, form.path, form.number, form.title });
    }

    /// Sets the heading levels of a block of sections so that its first is at
    /// `level`, and puts the block in `group`.
    pub fn relevel(e: *Editor, block: []Entry, level: usize, group: Group) Error!void {
        const shift = @as(isize, @intCast(level)) - @as(isize, block[0].level);
        for (block) |*x| {
            const new = @as(isize, x.level) + shift;
            if (new < 1 or new > 6) {
                const msg = "§ {s} {s} would need heading level {d}, and the deepest is 6";
                return e.stop(2, msg, .{ x.old.number, x.old.title, new });
            }
            x.level = @intCast(new);
            x.group = group;
        }
    }

    /// Renumbers the edited outlines, records the new address of each
    /// section in `moved`, and plans writing the outlines and rewriting what
    /// names a section whose heading changed.
    pub fn finishSections(e: *Editor, outlines: []const *Outline, moved: []const Name) Error!void {
        const arena = e.ctx.arena;
        var renames: std.ArrayList(Rename) = .empty;
        defer renames.deinit(arena);
        var edited: std.ArrayList(Write) = .empty;
        defer edited.deinit(arena);
        for (outlines) |o| {
            try o.renumber(arena, &renames);
            const content = try o.render(arena);
            try edited.append(arena, .{ .origin = o.path, .path = o.path, .content = content });
        }
        for (moved) |name| {
            outlines: for (outlines) |o| {
                const address = (try o.addressOf(arena, name)) orelse continue :outlines;
                try e.addresses.append(arena, address);
            }
        }
        const list: Renames = .{ .items = renames.items };
        try e.rewriteAll(list.rewriter(), edited.items);
    }

    /// Rewrites, with `rw`, the dependency entries of every spec file and the
    /// references in every source file, and plans writing each file that
    /// changes. `edited` holds the new content of the spec files the command
    /// edits itself; one with a path no spec file has is a file it creates.
    pub fn rewriteAll(e: *Editor, rw: rewrite.Rewriter, edited: []const Write) Error!void {
        const arena = e.ctx.arena;
        for (e.proj.spec_files) |f| {
            const content = for (edited) |w| {
                if (std.mem.eql(u8, w.path, f.path)) break w.content;
            } else f.content;
            try e.rewriteSpec(rw, f.path, f.content, content);
        }
        for (edited) |w| {
            if (e.by_path.get(w.path) == null) try e.rewriteSpec(rw, w.path, "", w.content);
        }
        for (e.proj.source_files) |f| {
            const after = (try rewrite.rewriteReferences(arena, rw, f.content)) orelse continue;
            const final = try e.finalPath(f.path);
            try e.writes.append(arena, .{ .origin = f.path, .path = final, .content = after });
        }
    }

    /// Rewrites the dependency entries of the spec file at `path`, which will
    /// hold `content`, and plans writing it when that differs from `original`.
    fn rewriteSpec(
        e: *Editor,
        rw: rewrite.Rewriter,
        path: []const u8,
        original: []const u8,
        content: []const u8,
    ) Error!void {
        const arena = e.ctx.arena;
        var found: diag.List = .empty;
        defer found.deinit(arena);
        const file = try spec.parse(arena, path, content, &found);
        const raw = try rewrite.splitLines(arena, content);
        const after = (try rewrite.rewriteDependencies(arena, rw, &file, raw)) orelse content;
        if (std.mem.eql(u8, after, original)) return;
        if (e.by_path.get(path)) |i| {
            if (!e.rewritable(i)) return e.refuse(i);
        }
        const final = try e.finalPath(path);
        try e.writes.append(arena, .{ .origin = path, .path = final, .content = after });
    }

    /// Stops the command when any part of a path it would move, create or
    /// write is a symbolic link, before anything changes: following one could
    /// change files outside the project.
    fn guard(e: *Editor) Error!void {
        for (e.moves.items) |mv| {
            try e.refuseLink(mv.old);
            try e.refuseLink(mv.new);
        }
        for (e.writes.items) |w| {
            try e.refuseLink(w.origin);
            try e.refuseLink(w.path);
        }
    }

    fn refuseLink(e: *Editor, path: []const u8) Error!void {
        const link = (try files.symlinkOn(e.ctx.arena, e.ctx.io, e.proj.root, path)) orelse return;
        const msg = "{s} is a symbolic link, and {s} does not follow symbolic links";
        return e.stop(2, msg, .{ link, e.command });
    }

    /// Checks every path, stages every new file content, makes the moves,
    /// puts the staged files in place, and prints what changed.
    fn commit(e: *Editor) Error!void {
        try e.guard();
        const temps = try e.stage();
        try e.apply(temps);
        try e.report();
    }

    /// Writes the new content of every file to a new temporary file near
    /// where the file is now, and returns their paths. When one cannot be
    /// written, removes those already written and stops, so that nothing has
    /// changed.
    fn stage(e: *Editor) Error![]const []const u8 {
        const temps = try e.ctx.arena.alloc([]const u8, e.writes.items.len);
        for (e.writes.items, temps, 0..) |w, *t, i| {
            t.* = try e.tempPath(w.origin, i);
            const flags: Io.Dir.CreateFileOptions = .{
                .exclusive = true,
                .permissions = try e.permissionsOf(w.origin),
            };
            const options: Io.Dir.WriteFileOptions = .{
                .sub_path = try e.abs(t.*),
                .data = w.content,
                .flags = flags,
            };
            Io.Dir.cwd().writeFile(e.ctx.io, options) catch |err| {
                // A file already at the temporary path is not this command's.
                const created = if (err == error.PathAlreadyExists) i else i + 1;
                try e.discard(temps[0..created]);
                const msg = "cannot write {s}: {s}; nothing was changed";
                return e.stop(2, msg, .{ w.path, @errorName(err) });
            };
        }
        return temps;
    }

    /// A temporary file for the `i`th write, in the nearest directory at or
    /// above the directory of `origin` that exists, so that staging creates no
    /// directories.
    fn tempPath(e: *const Editor, origin: []const u8, i: usize) Allocator.Error![]const u8 {
        var dir = Io.Dir.path.dirname(origin) orelse "";
        // Each step drops one component from `dir`, so the loop ends.
        while (dir.len > 0 and !try e.isDirectory(dir)) dir = Io.Dir.path.dirname(dir) orelse "";
        const base = Io.Dir.path.basename(origin);
        const name = try e.ctx.arena.print(".{s}.{d}.specrail-tmp", .{ base, i });
        return Io.Dir.path.join(e.ctx.arena, &.{ dir, name });
    }

    /// The permissions of the file at `path`, or the default for a new file.
    fn permissionsOf(e: *const Editor, path: []const u8) Allocator.Error!Io.File.Permissions {
        const at = try e.abs(path);
        const st = Io.Dir.cwd().statFile(e.ctx.io, at, .{}) catch return .default_file;
        return st.permissions;
    }

    /// Removes the temporary files `temps`.
    fn discard(e: *Editor, temps: []const []const u8) Error!void {
        for (temps) |t| {
            const at = try e.abs(t);
            Io.Dir.cwd().deleteFile(e.ctx.io, at) catch |err| {
                const msg = "specrail: cannot remove {s}: {s}\n";
                try e.ctx.stderr.print(msg, .{ t, @errorName(err) });
            };
        }
    }

    /// Makes the moves, then puts each staged file in place. Renames are all
    /// that is left to fail here.
    fn apply(e: *Editor, temps: []const []const u8) Error!void {
        const io = e.ctx.io;
        const cwd = Io.Dir.cwd();
        for (e.moves.items) |mv| {
            const new = try e.abs(mv.new);
            try e.makeParent(new);
            cwd.rename(try e.abs(mv.old), cwd, new, io) catch |err| {
                const msg = "cannot move {s} to {s}: {s}; the project is partly changed";
                return e.stop(2, msg, .{ mv.old, mv.new, @errorName(err) });
            };
        }
        for (e.writes.items, temps) |w, t| {
            const to = try e.abs(w.path);
            try e.makeParent(to);
            // A staged file inside a moved directory moved with it.
            const from = try e.abs(try e.finalPath(t));
            cwd.rename(from, cwd, to, io) catch |err| {
                const msg = "cannot replace {s}: {s}; the project is partly changed";
                return e.stop(2, msg, .{ w.path, @errorName(err) });
            };
        }
    }

    /// Creates the directory that `at`, an absolute path, will be in.
    fn makeParent(e: *Editor, at: []const u8) Error!void {
        const dir = Io.Dir.path.dirname(at) orelse return;
        Io.Dir.cwd().createDirPath(e.ctx.io, dir) catch |err| {
            return e.stop(2, "cannot create {s}: {s}", .{ dir, @errorName(err) });
        };
    }

    /// Prints the new address of each moved section, then, sorted, the new
    /// path of each project file that was moved or written.
    fn report(e: *Editor) Error!void {
        const arena = e.ctx.arena;
        for (e.addresses.items) |a| try e.ctx.stdout.print("{s}\n", .{a});
        var touched: std.ArrayList([]const u8) = .empty;
        defer touched.deinit(arena);
        const lists = [_][]const project.SourceFile{ e.proj.spec_files, e.proj.source_files };
        for (lists) |list| {
            for (list) |f| {
                const now = try e.finalPath(f.path);
                if (now.ptr != f.path.ptr) try touched.append(arena, now);
            }
        }
        for (e.writes.items) |w| try touched.append(arena, w.path);
        std.mem.sort([]const u8, touched.items, {}, lessThan);
        for (touched.items, 0..) |path, i| {
            const repeat = i > 0 and std.mem.eql(u8, path, touched.items[i - 1]);
            if (!repeat) try e.ctx.stdout.print("{s}\n", .{path});
        }
    }
};

/// A small project for the tests of the commands built on this engine.
pub const fixture = struct {
    const sandbox = @import("sandbox.zig");
    const testing = std.testing;
    const WriteError = Io.Dir.CreateDirPathError || Io.Dir.WriteFileError;
    const ExpectError = error{ TestExpectedEqual, TestUnexpectedResult };

    /// The spec file most tests edit.
    pub const login_path = "specs/auth/login.spec.md";

    /// Its content.
    pub const login =
        \\# § 1 Login
        \\
        \\## § 1.1 Password
        \\
        \\It MUST accept a password.
        \\
        \\## § 1.2 Google
        \\
        \\It MUST accept Google.
        \\
        \\# § 2 Logout
        \\
        \\It MUST log out.
        \\
    ;

    /// A project with a root file, a parent file and its directory, a
    /// dependency entry and references.
    pub fn authProject(s: *sandbox.Sandbox) WriteError!void {
        try s.write("specrail.toml", "spec_root = \"specs\"\n");
        try s.write("specs/root.spec.md", "Root context.\n");
        try s.write("specs/auth.spec.md", "Auth context.\n");
        try s.write(login_path, login);
        try s.write("specs/other.spec.md",
            \\# § 1 Waits
            \\```toml
            \\dependencies = ["specs/auth/login.spec.md § 1.2 Google"]
            \\```
            \\It MUST wait.
            \\
        );
        try s.write("src/t.zig",
            \\// specrail: specs/auth/login.spec.md § 1.1 Password
            \\// specrail: specs/auth/login.spec.md § 1.2 Google
            \\// specrail: specs/auth/login.spec.md § 2 Logout
            \\// specrail: specs/other.spec.md § 1 Waits
            \\
        );
    }

    /// Expects `specrail check` to pass, and shows its output when it does
    /// not.
    pub fn expectChecks(s: *sandbox.Sandbox) (Allocator.Error || ExpectError)!void {
        const o = try s.runAtRoot(&.{"check"});
        if (o.code != 0) std.debug.print("{s}{s}", .{ o.stdout, o.stderr });
        try testing.expectEqual(@as(u8, 0), o.code);
    }

    /// Expects the project `authProject` made to be as it was.
    pub fn expectUnchanged(s: *sandbox.Sandbox) (Io.Dir.ReadFileAllocError || ExpectError)!void {
        try testing.expectEqualStrings(login, try s.read(login_path));
        try testing.expectEqualStrings("Auth context.\n", try s.read("specs/auth.spec.md"));
        const t = try s.read("src/t.zig");
        try sandbox.expectContains(t, "// specrail: specs/auth/login.spec.md § 2 Logout\n");
        try sandbox.expectContains(t, "// specrail: specs/other.spec.md § 1 Waits\n");
    }
};
