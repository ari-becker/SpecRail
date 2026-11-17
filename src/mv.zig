//! `specrail mv`: moves and retitles sections, and moves spec files and
//! directories, rewriting every reference and dependency entry to match.

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

/// Help text for `specrail mv --help`.
pub const usage =
    \\Usage: specrail mv <from> <to>
    \\
    \\Move or retitle a section, or move a spec file or a directory of specs,
    \\and rewrite every reference and dependency entry that names what moved.
    \\Sections are given in reference form, each quoted as one argument:
    \\
    \\  specrail mv 'specs/a.spec.md § 1.2 Old title' 'specs/a.spec.md § 1.2 New title'
    \\  specrail mv 'specs/a.spec.md § 1.2 Title' 'specs/b.spec.md § 3 Title'
    \\  specrail mv specs/auth/login.spec.md specs/identity/login.spec.md
    \\
    \\Paths are relative to the project root. A spec file moves together with the
    \\directory it is the parent file of, and a directory with its parent file.
    \\mv prints the path of each file it changed.
    \\
    \\Options:
    \\  --help   Show this help
    \\
;

const spec_suffix = ".spec.md";

/// `error.Stopped` means mv reported why it stopped, and `Mover.status` holds
/// its exit status.
const Error = cli.Error || error{Stopped};

/// A file or directory to move, by project path.
const Move = struct {
    old: []const u8,
    new: []const u8,
};

/// A file to write: its path before and after the moves, and its new content.
const Write = struct {
    /// Where the file is now; for a spec file mv creates, where it will be.
    origin: []const u8,
    path: []const u8,
    content: []const u8,
};

/// What a reference names: a spec file, and a section in it.
const Name = struct {
    path: []const u8,
    number: []const u8,
    title: []const u8,

    fn of(form: refs.Form) Name {
        return .{ .path = form.path, .number = form.number, .title = form.title };
    }

    fn eql(a: Name, b: Name) bool {
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
const Paths = struct {
    /// The new path of each moved spec file, by old path.
    moved: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn replace(context: *const anyopaque, form: refs.Form) ?rewrite.Replacement {
        const ps: *const Paths = @ptrCast(@alignCast(context));
        return .{ .path = ps.moved.get(form.path) orelse return null };
    }

    fn rewriter(ps: *const Paths) rewrite.Rewriter {
        return .{ .context = ps, .replaceFn = replace };
    }
};

/// One section in an outline: its heading and its own lines.
const Entry = struct {
    /// What the section's heading said before the move.
    old: Name,
    old_level: u8,
    level: u8,
    title: []const u8,
    /// The heading line as written.
    heading: []const u8,
    /// The lines after the heading up to the next heading: the section's
    /// metadata block and its own prose.
    body: []const []const u8,
    /// The section is in the block being moved.
    moved: bool = false,
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

/// A spec file being edited: the lines before its first section, then its
/// sections in order.
const Outline = struct {
    path: []const u8,
    /// The lines before the first section: the context and the separator.
    preamble: []const []const u8,
    entries: std.ArrayList(Entry) = .empty,
    /// The line ending of the lines mv writes.
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

    /// The outline of a spec file mv creates.
    fn empty(path: []const u8, newline: []const u8) Outline {
        return .{ .path = path, .preamble = &.{}, .newline = newline };
    }

    /// The index after the subtree of the entry at `i`.
    fn subtreeEnd(o: *const Outline, i: usize) usize {
        const level = o.entries.items[i].level;
        for (o.entries.items[i + 1 ..], i + 1..) |e, k| {
            if (e.level <= level) return k;
        }
        return o.entries.items.len;
    }

    /// Removes the entry at `i` and its subtree, and returns them.
    fn take(o: *Outline, arena: Allocator, i: usize) Allocator.Error![]Entry {
        const end = o.subtreeEnd(i);
        const taken = try arena.dupe(Entry, o.entries.items[i..end]);
        try o.entries.replaceRange(arena, i, end - i, &.{});
        return taken;
    }

    /// The number of each entry by its position.
    fn positions(o: *const Outline, arena: Allocator) Allocator.Error![]const []const u8 {
        const out = try arena.alloc([]const u8, o.entries.items.len);
        errdefer arena.free(out);
        var numbering: spec.Numbering = .{};
        for (o.entries.items, out) |e, *n| n.* = try numbering.next(arena, e.level);
        return out;
    }

    /// Where a section must go to get `number`; null when the number's parent
    /// does not exist, or its last component skips past the parent's last
    /// child.
    fn insertionIndex(
        o: *const Outline,
        arena: Allocator,
        number: []const u8,
    ) Allocator.Error!?usize {
        const dot = std.mem.findScalarLast(u8, number, '.');
        const last = number[if (dot) |d| d + 1 else 0..];
        const k = std.fmt.parseInt(usize, last, 10) catch return null;
        var start: usize = 0;
        var end = o.entries.items.len;
        var child_level: u8 = 1;
        if (dot) |d| {
            const nums = try o.positions(arena);
            const parent = for (nums, 0..) |n, i| {
                if (std.mem.eql(u8, n, number[0..d])) break i;
            } else return null;
            start = parent + 1;
            end = o.subtreeEnd(parent);
            child_level = o.entries.items[parent].level + 1;
        }
        var seen: usize = 0;
        for (o.entries.items[start..end], start..) |e, i| {
            if (e.level != child_level) continue;
            seen += 1;
            if (seen == k) return i;
        }
        return if (k == seen + 1) end else null;
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

    /// The file's new content. Lines mv does not rewrite keep their bytes,
    /// except that lines moved in from another file take this file's line
    /// ending. The moved block is set off from its neighbours by blank lines.
    fn render(o: *const Outline, arena: Allocator) Allocator.Error![]const u8 {
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(arena);
        try lines.appendSlice(arena, o.preamble);
        if (o.needs_separator and o.entries.items.len > 0) {
            try o.blankLine(arena, &lines);
            try o.push(arena, &lines, try std.mem.concat(arena, u8, &.{ "---", o.newline }));
        }
        var in_block = false;
        for (o.entries.items, o.numbers) |e, n| {
            if (e.moved != in_block) try o.blankLine(arena, &lines);
            in_block = e.moved;
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
};

/// Whether `number` lies inside the subtree of the section numbered `top`.
fn isBelow(number: []const u8, top: []const u8) bool {
    const prefixed = number.len > top.len and std.mem.startsWith(u8, number, top);
    return prefixed and number[top.len] == '.';
}

/// Whether an argument names a section rather than a path. Reference form
/// always has a space between the path and the section sign.
fn isSection(arg: []const u8) bool {
    return std.mem.findAny(u8, arg, " \t") != null;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// One run of `specrail mv`: what it read, and what it will change.
const Mover = struct {
    ctx: *cli.Ctx,
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
    /// The exit status, once mv has stopped.
    status: u8 = 0,

    fn init(ctx: *cli.Ctx, proj: project.Project) Allocator.Error!Mover {
        const n = proj.spec_files.len;
        var m: Mover = .{
            .ctx = ctx,
            .proj = proj,
            .specs = try ctx.arena.alloc(spec.SpecFile, n),
            .found = try ctx.arena.alloc(diag.List, n),
        };
        for (proj.spec_files, 0..) |f, i| {
            m.found[i] = .empty;
            m.specs[i] = try spec.parse(ctx.arena, f.path, f.content, &m.found[i]);
            try m.by_path.put(ctx.arena, f.path, i);
        }
        return m;
    }

    /// Reports why mv stops, and stops it with `status`.
    fn stop(m: *Mover, status: u8, comptime format: []const u8, args: anytype) Error {
        m.ctx.stderr.print("specrail: " ++ format ++ "\n", args) catch |e| return e;
        m.status = status;
        return error.Stopped;
    }

    /// Reports a usage error, and stops mv with status 2.
    fn misuse(m: *Mover, comptime format: []const u8, args: anytype) Error {
        m.status = cli.usageError(m.ctx, "mv", format, args) catch |e| return e;
        return error.Stopped;
    }

    /// Reports the errors in a spec file that keep mv from rewriting it
    /// safely, and stops mv with status 1.
    fn refuse(m: *Mover, index: usize) Error {
        const intro = "specrail: {s} has errors that keep mv from rewriting it:\n";
        m.ctx.stderr.print(intro, .{m.specs[index].path}) catch |e| return e;
        for (m.found[index].items) |d| {
            if (d.severity != .err) continue;
            diag.write(m.ctx.stderr, d, m.ctx.color) catch |e| return e;
        }
        m.status = 1;
        return error.Stopped;
    }

    fn rewritable(m: *const Mover, index: usize) bool {
        return !m.specs[index].broken and !m.specs[index].duplicate;
    }

    fn outline(m: *const Mover, index: usize) Allocator.Error!Outline {
        return Outline.init(m.ctx.arena, &m.specs[index], m.proj.spec_files[index].content);
    }

    fn abs(m: *const Mover, path: []const u8) Allocator.Error![]const u8 {
        return Io.Dir.path.join(m.ctx.arena, &.{ m.proj.root, path });
    }

    fn exists(m: *const Mover, path: []const u8) Allocator.Error!bool {
        const at = try m.abs(path);
        _ = Io.Dir.cwd().statFile(m.ctx.io, at, .{}) catch return false;
        return true;
    }

    fn isDirectory(m: *const Mover, path: []const u8) Allocator.Error!bool {
        const at = try m.abs(path);
        const st = Io.Dir.cwd().statFile(m.ctx.io, at, .{}) catch return false;
        return st.kind == .directory;
    }

    /// Where the file at `path` is once the moves are made.
    fn finalPath(m: *const Mover, path: []const u8) Allocator.Error![]const u8 {
        for (m.moves.items) |mv| {
            if (files.isUnder(path, mv.old)) {
                return std.mem.concat(m.ctx.arena, u8, &.{ mv.new, path[mv.old.len..] });
            }
        }
        return path;
    }

    /// Plans the move the two arguments name.
    fn plan(m: *Mover, old_arg: []const u8, new_arg: []const u8) Error!void {
        const old_text = std.mem.trim(u8, old_arg, " \t");
        const new_text = std.mem.trim(u8, new_arg, " \t");
        const section_move = isSection(old_text);
        if (section_move != isSection(new_text)) {
            return m.misuse("a section moves to a section, and a path to a path", .{});
        }
        if (!section_move) return m.movePath(old_text, new_text);
        return m.moveSection(try m.section(old_text), try m.section(new_text));
    }

    /// `text` parsed as a section in reference form, with its path normalized.
    fn section(m: *Mover, text: []const u8) Error!refs.Form {
        var form = switch (refs.parseForm(text, .required)) {
            .ok => |f| f,
            .err => |msg| return m.misuse("'{s}' is not a section: {s}", .{ text, msg }),
        };
        form.path = try m.specPath(form.path);
        return form;
    }

    /// `arg` as a project path below the spec root. Absolute paths, and paths
    /// with a `..` component, are refused before they can leave it.
    fn specPath(m: *Mover, arg: []const u8) Error![]const u8 {
        const root = m.proj.config.spec_root;
        const path = config.normalizeDir(arg) orelse "";
        const below = path.len > 0 and !std.mem.eql(u8, path, root) and files.isUnder(path, root);
        if (!below) return m.misuse("'{s}' is not a path below the spec root", .{arg});
        return path;
    }

    /// Plans the move of a spec file or a directory of specs, and of the
    /// directory or parent file that goes with it, and the rewriting of every
    /// reference and dependency entry that names a moved spec file.
    fn movePath(m: *Mover, old_arg: []const u8, new_arg: []const u8) Error!void {
        const old = try m.specPath(old_arg);
        const new = try m.specPath(new_arg);
        const file = std.mem.endsWith(u8, old, spec_suffix);
        if (file != std.mem.endsWith(u8, new, spec_suffix)) {
            const msg = "a spec file moves to a spec file path, and a directory to a directory";
            return m.misuse(msg, .{});
        }
        if (file) {
            try m.planFile(old, new);
        } else {
            try m.planDirectory(old, new);
        }
        for (m.moves.items) |mv| {
            if (try m.exists(mv.new)) {
                return m.stop(2, "{s} already exists; nothing was moved", .{mv.new});
            }
        }
        var paths: Paths = .{};
        for (m.proj.spec_files) |f| {
            const now = try m.finalPath(f.path);
            if (now.ptr != f.path.ptr) try paths.moved.put(m.ctx.arena, f.path, now);
        }
        try m.rewriteAll(paths.rewriter(), &.{});
    }

    /// Plans the move of a spec file, and of the directory it is the parent
    /// file of when there is one.
    fn planFile(m: *Mover, old: []const u8, new: []const u8) Error!void {
        const arena = m.ctx.arena;
        if (m.by_path.get(old) == null) return m.stop(2, "there is no spec file {s}", .{old});
        try m.moves.append(arena, .{ .old = old, .new = new });
        // The root file's directory is the spec root itself, which never moves.
        const root = m.proj.config.spec_root;
        const root_file = try Io.Dir.path.join(arena, &.{ root, "root.spec.md" });
        if (std.mem.eql(u8, old, root_file)) return;
        const old_dir = old[0 .. old.len - spec_suffix.len];
        if (!try m.isDirectory(old_dir)) return;
        if (files.isUnder(new, old_dir)) {
            return m.misuse("{s} cannot move into {s}, which moves with it", .{ old, old_dir });
        }
        try m.moves.append(arena, .{ .old = old_dir, .new = new[0 .. new.len - spec_suffix.len] });
    }

    /// Plans the move of a directory, and of its parent file when there is one.
    fn planDirectory(m: *Mover, old: []const u8, new: []const u8) Error!void {
        const arena = m.ctx.arena;
        if (!try m.isDirectory(old)) return m.stop(2, "there is no directory {s}", .{old});
        if (files.isUnder(new, old)) return m.misuse("{s} cannot move into itself", .{old});
        try m.moves.append(arena, .{ .old = old, .new = new });
        const old_file = try std.mem.concat(arena, u8, &.{ old, spec_suffix });
        if (m.by_path.get(old_file) == null) return;
        const new_file = try std.mem.concat(arena, u8, &.{ new, spec_suffix });
        try m.moves.append(arena, .{ .old = old_file, .new = new_file });
    }

    /// Finds the section a section move starts from, and returns the index of
    /// its spec file and of the section in that file.
    fn source(m: *Mover, from: refs.Form) Error!struct { usize, usize } {
        const fi = m.by_path.get(from.path) orelse {
            return m.stop(1, "dangling source: there is no spec file {s}", .{from.path});
        };
        if (!m.rewritable(fi)) return m.refuse(fi);
        const sections = m.specs[fi].sections;
        for (sections, 0..) |s, i| {
            const same_number = std.mem.eql(u8, s.number, from.number);
            if (same_number and std.mem.eql(u8, s.title, from.title)) return .{ fi, i };
        }
        for (sections) |s| {
            const same_number = std.mem.eql(u8, s.number, from.number);
            if (!same_number and !std.mem.eql(u8, s.title, from.title)) continue;
            const msg = "stale source § {s} {s}: {s} has § {s} {s}";
            return m.stop(1, msg, .{ from.number, from.title, from.path, s.number, s.title });
        }
        const msg = "dangling source: {s} has no § {s} and no section titled '{s}'";
        return m.stop(1, msg, .{ from.path, from.number, from.title });
    }

    /// Checks the spec file a section moves to, and returns its index; null
    /// for a spec file mv creates.
    fn destination(m: *Mover, to: refs.Form) Error!?usize {
        if (m.by_path.get(to.path)) |d| {
            if (!m.rewritable(d)) return m.refuse(d);
            return d;
        }
        if (!std.mem.endsWith(u8, to.path, spec_suffix)) {
            return m.misuse("{s} is not a spec file path", .{to.path});
        }
        if (try m.exists(to.path)) {
            return m.stop(2, "{s} exists but is not a spec file mv can write", .{to.path});
        }
        if (!std.mem.eql(u8, to.number, "1")) {
            return m.stop(2, "{s} does not exist, so the section must be § 1 there", .{to.path});
        }
        return null;
    }

    /// Plans moving or retitling a section with its subtree, the renumbering
    /// around it, and the rewriting of what names a section that changed.
    fn moveSection(m: *Mover, from: refs.Form, to: refs.Form) Error!void {
        const arena = m.ctx.arena;
        const fi, const si = try m.source(from);
        if (Name.of(from).eql(Name.of(to))) return;
        const same_file = std.mem.eql(u8, from.path, to.path);
        if (same_file and isBelow(to.number, from.number)) {
            return m.stop(2, "§ {s} lies inside the subtree being moved", .{to.number});
        }
        const di = try m.destination(to);
        var src = try m.outline(fi);
        var other: ?Outline = if (same_file)
            null
        else if (di) |d|
            try m.outline(d)
        else
            Outline.empty(to.path, src.newline);
        const dst = if (other) |*o| o else &src;
        const block = try src.take(arena, si);
        // A section retitled in place keeps its surroundings as they are.
        const relocated = !same_file or !std.mem.eql(u8, to.number, from.number);
        try m.relevel(block, to.number, relocated);
        block[0].title = to.title;
        const at = (try dst.insertionIndex(arena, to.number)) orelse {
            const msg = "§ {s} cannot go in {s}: its parent does not exist, or it skips a number";
            return m.stop(2, msg, .{ to.number, to.path });
        };
        try dst.entries.insertSlice(arena, at, block);
        try m.finishSections(&src, if (other) |*o| o else null);
    }

    /// Sets the heading levels of a block of sections so its first is at the
    /// depth of `number`, and marks whether the block moves.
    fn relevel(m: *Mover, block: []Entry, number: []const u8, moves: bool) Error!void {
        const shift = @as(isize, @intCast(refs.depth(number))) - @as(isize, block[0].level);
        for (block) |*e| {
            const level = @as(isize, e.level) + shift;
            if (level > 6) {
                return m.stop(2, "§ {s} would put sections deeper than six levels", .{number});
            }
            e.level = @intCast(level);
            e.moved = moves;
        }
    }

    /// Renumbers the edited outlines, and plans writing them and rewriting
    /// what names a section whose heading changed.
    fn finishSections(m: *Mover, src: *Outline, dst: ?*Outline) Error!void {
        const arena = m.ctx.arena;
        var renames: std.ArrayList(Rename) = .empty;
        defer renames.deinit(arena);
        var edited: std.ArrayList(Write) = .empty;
        defer edited.deinit(arena);
        try src.renumber(arena, &renames);
        const src_content = try src.render(arena);
        try edited.append(arena, .{ .origin = src.path, .path = src.path, .content = src_content });
        if (dst) |o| {
            try o.renumber(arena, &renames);
            const content = try o.render(arena);
            try edited.append(arena, .{ .origin = o.path, .path = o.path, .content = content });
        }
        const list: Renames = .{ .items = renames.items };
        try m.rewriteAll(list.rewriter(), edited.items);
        // The file the section leaves is written last, so a write that fails
        // part way cannot lose the section.
        for (m.writes.items, 0..) |w, i| {
            if (!std.mem.eql(u8, w.path, src.path)) continue;
            const leaving = m.writes.orderedRemove(i);
            try m.writes.append(arena, leaving);
            break;
        }
    }

    /// Rewrites, with `rw`, the dependency entries of every spec file and the
    /// references in every source file, and plans writing each file that
    /// changes. `edited` holds the new content of the spec files mv edits
    /// itself; one with a path no spec file has is a file mv creates.
    fn rewriteAll(m: *Mover, rw: rewrite.Rewriter, edited: []const Write) Error!void {
        const arena = m.ctx.arena;
        for (m.proj.spec_files) |f| {
            const content = for (edited) |e| {
                if (std.mem.eql(u8, e.path, f.path)) break e.content;
            } else f.content;
            try m.rewriteSpec(rw, f.path, f.content, content);
        }
        for (edited) |e| {
            if (m.by_path.get(e.path) == null) try m.rewriteSpec(rw, e.path, "", e.content);
        }
        for (m.proj.source_files) |f| {
            const after = (try rewrite.rewriteReferences(arena, rw, f.content)) orelse continue;
            const final = try m.finalPath(f.path);
            try m.writes.append(arena, .{ .origin = f.path, .path = final, .content = after });
        }
    }

    /// Rewrites the dependency entries of the spec file at `path`, which will
    /// hold `content`, and plans writing it when that differs from `original`.
    fn rewriteSpec(
        m: *Mover,
        rw: rewrite.Rewriter,
        path: []const u8,
        original: []const u8,
        content: []const u8,
    ) Error!void {
        const arena = m.ctx.arena;
        var found: diag.List = .empty;
        defer found.deinit(arena);
        const file = try spec.parse(arena, path, content, &found);
        const raw = try rewrite.splitLines(arena, content);
        const after = (try rewrite.rewriteDependencies(arena, rw, &file, raw)) orelse content;
        if (std.mem.eql(u8, after, original)) return;
        if (m.by_path.get(path)) |i| {
            if (!m.rewritable(i)) return m.refuse(i);
        }
        const final = try m.finalPath(path);
        try m.writes.append(arena, .{ .origin = path, .path = final, .content = after });
    }

    /// Stops mv when any part of a path it would move, create or write is a
    /// symbolic link, before it changes anything: following one could change
    /// files outside the project.
    fn guard(m: *Mover) Error!void {
        for (m.moves.items) |mv| {
            try m.refuseLink(mv.old);
            try m.refuseLink(mv.new);
        }
        for (m.writes.items) |w| {
            try m.refuseLink(w.origin);
            try m.refuseLink(w.path);
        }
    }

    fn refuseLink(m: *Mover, path: []const u8) Error!void {
        const link = (try files.symlinkOn(m.ctx.arena, m.ctx.io, m.proj.root, path)) orelse return;
        return m.stop(2, "{s} is a symbolic link, and mv does not follow symbolic links", .{link});
    }

    /// Makes the moves, writes the files, and prints each file it changed.
    fn commit(m: *Mover) Error!void {
        try m.guard();
        const io = m.ctx.io;
        const cwd = Io.Dir.cwd();
        for (m.moves.items) |mv| {
            const new = try m.abs(mv.new);
            try m.makeParent(new);
            cwd.rename(try m.abs(mv.old), cwd, new, io) catch |e| {
                return m.stop(2, "cannot move {s} to {s}: {s}", .{ mv.old, mv.new, @errorName(e) });
            };
        }
        for (m.writes.items) |w| {
            const at = try m.abs(w.path);
            try m.makeParent(at);
            cwd.writeFile(io, .{ .sub_path = at, .data = w.content }) catch |e| {
                return m.stop(2, "cannot write {s}: {s}", .{ w.path, @errorName(e) });
            };
        }
        try m.report();
    }

    /// Creates the directory that `at`, an absolute path, will be in.
    fn makeParent(m: *Mover, at: []const u8) Error!void {
        const dir = Io.Dir.path.dirname(at) orelse return;
        Io.Dir.cwd().createDirPath(m.ctx.io, dir) catch |e| {
            return m.stop(2, "cannot create {s}: {s}", .{ dir, @errorName(e) });
        };
    }

    /// Prints, sorted, the new path of each project file mv moved or wrote.
    fn report(m: *Mover) Error!void {
        const arena = m.ctx.arena;
        var touched: std.ArrayList([]const u8) = .empty;
        defer touched.deinit(arena);
        const lists = [_][]const project.SourceFile{ m.proj.spec_files, m.proj.source_files };
        for (lists) |list| {
            for (list) |f| {
                const now = try m.finalPath(f.path);
                if (now.ptr != f.path.ptr) try touched.append(arena, now);
            }
        }
        for (m.writes.items) |w| try touched.append(arena, w.path);
        std.mem.sort([]const u8, touched.items, {}, lessThan);
        for (touched.items, 0..) |path, i| {
            const repeat = i > 0 and std.mem.eql(u8, path, touched.items[i - 1]);
            if (!repeat) try m.ctx.stdout.print("{s}\n", .{path});
        }
    }
};

/// Runs `specrail mv` and returns its exit status.
pub fn run(ctx: *cli.Ctx, args: []const []const u8) cli.Error!u8 {
    if (args.len != 2) {
        return cli.usageError(ctx, "mv", "mv takes two arguments: what to move, and where", .{});
    }
    const p = (try project.open(ctx)) orelse return 2;
    var m = try Mover.init(ctx, p);
    m.plan(args[0], args[1]) catch |e| switch (e) {
        error.Stopped => return m.status,
        else => |other| return other,
    };
    m.commit() catch |e| switch (e) {
        error.Stopped => return m.status,
        else => |other| return other,
    };
    return 0;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const sandbox = @import("sandbox.zig");

const login_path = "specs/auth/login.spec.md";

const login =
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
fn authProject(s: *sandbox.Sandbox) !void {
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

/// Runs `specrail mv old new` in the sandbox.
fn runMv(s: *sandbox.Sandbox, old: []const u8, new: []const u8) !sandbox.Sandbox.Output {
    return s.runAtRoot(&.{ "mv", old, new });
}

fn expectChecks(s: *sandbox.Sandbox) !void {
    const o = try s.runAtRoot(&.{"check"});
    if (o.code != 0) std.debug.print("{s}{s}", .{ o.stdout, o.stderr });
    try testing.expectEqual(@as(u8, 0), o.code);
}

fn expectMoved(s: *sandbox.Sandbox) !void {
    try testing.expect(!s.exists("specs/auth.spec.md"));
    try testing.expect(!s.exists("specs/auth"));
    try testing.expectEqualStrings("Auth context.\n", try s.read("specs/identity.spec.md"));
    try testing.expectEqualStrings(login, try s.read("specs/identity/login.spec.md"));
    const dependency = "\"specs/identity/login.spec.md § 1.2 Google\"";
    try sandbox.expectContains(try s.read("specs/other.spec.md"), dependency);
    const reference = "// specrail: specs/identity/login.spec.md § 2 Logout\n";
    try sandbox.expectContains(try s.read("src/t.zig"), reference);
    try expectChecks(s);
}

// specrail: specs/cli/mv.spec.md § 1.1 Move a spec file
// specrail: specs/cli/mv.spec.md § 4.2 Report
test "a spec file moves with the directory it is the parent of" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const o = try runMv(&s, "specs/auth.spec.md", "specs/identity.spec.md");
    try testing.expectEqual(@as(u8, 0), o.code);
    try testing.expectEqualStrings(
        \\specs/identity.spec.md
        \\specs/identity/login.spec.md
        \\specs/other.spec.md
        \\src/t.zig
        \\
    , o.stdout);
    try expectMoved(&s);
}

// specrail: specs/cli/mv.spec.md § 1.2 Move a directory
test "a directory moves with its parent file" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    // Files under the spec root other than spec files move with their
    // directory, and specrail does not read them.
    try s.write("specs/auth/notes.txt", "Notes.\n");
    const o = try runMv(&s, "specs/auth/", "./specs/identity");
    try testing.expectEqual(@as(u8, 0), o.code);
    try testing.expectEqualStrings("Notes.\n", try s.read("specs/identity/notes.txt"));
    try expectMoved(&s);
}

// specrail: specs/cli/mv.spec.md § 1.3 Existing destination
test "mv changes nothing when a destination exists" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    try s.write("specs/identity/notes.md", "In the way.\n");
    const with_dir = try runMv(&s, "specs/auth.spec.md", "specs/identity.spec.md");
    try testing.expectEqual(@as(u8, 2), with_dir.code);
    try testing.expectEqualStrings("", with_dir.stdout);
    try sandbox.expectContains(with_dir.stderr, "specs/identity already exists");
    const file = try runMv(&s, "specs/auth.spec.md", "specs/other.spec.md");
    try testing.expectEqual(@as(u8, 2), file.code);
    try testing.expect(s.exists("specs/auth.spec.md"));
    try testing.expect(s.exists("specs/auth/login.spec.md"));
    try testing.expectEqualStrings("In the way.\n", try s.read("specs/identity/notes.md"));
}

// specrail: specs/cli/mv.spec.md § 1.4 Root file
test "the root file moves alone, never with the spec root" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const o = try runMv(&s, "specs/root.spec.md", "specs/overview.spec.md");
    try testing.expectEqual(@as(u8, 0), o.code);
    try testing.expectEqualStrings("specs/overview.spec.md\n", o.stdout);
    try testing.expectEqualStrings("Root context.\n", try s.read("specs/overview.spec.md"));
    try testing.expect(s.exists(login_path));
}

// specrail: specs/cli/mv.spec.md § 2.1 Source must match
// specrail: specs/cli/mv.spec.md § 4.2 Report
test "a stale or dangling source changes nothing" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const stale = try runMv(&s, login_path ++ " § 1.2 Gogle", login_path ++ " § 1.2 X");
    try testing.expectEqual(@as(u8, 1), stale.code);
    try testing.expectEqualStrings("", stale.stdout);
    try sandbox.expectContains(stale.stderr, "stale source § 1.2 Gogle");
    const dangling = try runMv(&s, login_path ++ " § 9 Nope", login_path ++ " § 2 X");
    try testing.expectEqual(@as(u8, 1), dangling.code);
    try sandbox.expectContains(dangling.stderr, "dangling source");
    try testing.expectEqualStrings(login, try s.read(login_path));
}

// specrail: specs/cli/mv.spec.md § 2.2 Retitle
test "a retitled section takes its references and dependency entries along" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const o = try runMv(&s, login_path ++ " § 1.2 Google", login_path ++ " § 1.2 Google sign-in");
    try testing.expectEqual(@as(u8, 0), o.code);
    const old = "## § 1.2 Google\n";
    const new = "## § 1.2 Google sign-in\n";
    const renamed = try std.mem.replaceOwned(u8, testing.allocator, login, old, new);
    defer testing.allocator.free(renamed);
    try testing.expectEqualStrings(renamed, try s.read(login_path));
    const dependency = "\"specs/auth/login.spec.md § 1.2 Google sign-in\"";
    try sandbox.expectContains(try s.read("specs/other.spec.md"), dependency);
    const reference = "// specrail: specs/auth/login.spec.md § 1.2 Google sign-in\n";
    try sandbox.expectContains(try s.read("src/t.zig"), reference);
    try expectChecks(&s);
}

// specrail: specs/cli/mv.spec.md § 2.3 Move a section
test "a section moves to another file with its subtree, and what names it follows" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const o = try runMv(&s, login_path ++ " § 1 Login", "specs/other.spec.md § 2 Login");
    try testing.expectEqual(@as(u8, 0), o.code);
    try testing.expectEqualStrings("# § 1 Logout\n\nIt MUST log out.\n", try s.read(login_path));
    try testing.expectEqualStrings(
        \\# § 1 Waits
        \\```toml
        \\dependencies = ["specs/other.spec.md § 2.2 Google"]
        \\```
        \\It MUST wait.
        \\
        \\# § 2 Login
        \\
        \\## § 2.1 Password
        \\
        \\It MUST accept a password.
        \\
        \\## § 2.2 Google
        \\
        \\It MUST accept Google.
        \\
    , try s.read("specs/other.spec.md"));
    try testing.expectEqualStrings(
        \\// specrail: specs/other.spec.md § 2.1 Password
        \\// specrail: specs/other.spec.md § 2.2 Google
        \\// specrail: specs/auth/login.spec.md § 1 Logout
        \\// specrail: specs/other.spec.md § 1 Waits
        \\
    , try s.read("src/t.zig"));
    try expectChecks(&s);
}

// specrail: specs/cli/mv.spec.md § 2.3 Move a section
test "a moved section's heading level follows its new depth" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const up = try runMv(&s, login_path ++ " § 1.1 Password", login_path ++ " § 3 Password");
    try testing.expectEqual(@as(u8, 0), up.code);
    const down = try runMv(&s, login_path ++ " § 2 Logout", login_path ++ " § 1.1 Logout");
    try testing.expectEqual(@as(u8, 0), down.code);
    try testing.expectEqualStrings(
        \\# § 1 Login
        \\
        \\## § 1.1 Logout
        \\
        \\It MUST log out.
        \\
        \\## § 1.2 Google
        \\
        \\It MUST accept Google.
        \\
        \\# § 2 Password
        \\
        \\It MUST accept a password.
        \\
    , try s.read(login_path));
    const reference = "// specrail: specs/auth/login.spec.md § 2 Password\n";
    try sandbox.expectContains(try s.read("src/t.zig"), reference);
    try expectChecks(&s);
}

// specrail: specs/cli/mv.spec.md § 2.3 Move a section
test "a section moved into a file of context alone gets a separator before it" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const o = try runMv(&s, login_path ++ " § 2 Logout", "specs/auth.spec.md § 1 Logout");
    try testing.expectEqual(@as(u8, 0), o.code);
    try testing.expectEqualStrings(
        "Auth context.\n\n---\n\n# § 1 Logout\n\nIt MUST log out.\n",
        try s.read("specs/auth.spec.md"),
    );
    const without = login[0 .. std.mem.find(u8, login, "\n\n# § 2").? + 1];
    try testing.expectEqualStrings(without, try s.read(login_path));
    try expectChecks(&s);
}

// specrail: specs/cli/mv.spec.md § 2.5 Valid destination
test "a destination without a parent, past the last child, or inside the move is refused" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const from = login_path ++ " § 1.1 Password";
    const orphan = try runMv(&s, from, login_path ++ " § 9.1 Password");
    try testing.expectEqual(@as(u8, 2), orphan.code);
    const skipping = try runMv(&s, from, login_path ++ " § 4 Password");
    try testing.expectEqual(@as(u8, 2), skipping.code);
    const inside = try runMv(&s, login_path ++ " § 1 Login", login_path ++ " § 1.3 Login");
    try testing.expectEqual(@as(u8, 2), inside.code);
    try sandbox.expectContains(inside.stderr, "inside the subtree being moved");
    try testing.expectEqualStrings(login, try s.read(login_path));
}

// specrail: specs/cli/mv.spec.md § 2.6 Moving to a new file
test "a section can start a new spec file at § 1" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const refused = try runMv(&s, login_path ++ " § 2 Logout", "specs/session.spec.md § 2 Logout");
    try testing.expectEqual(@as(u8, 2), refused.code);
    try testing.expect(!s.exists("specs/session.spec.md"));
    const o = try runMv(&s, login_path ++ " § 2 Logout", "specs/session.spec.md § 1 Logout");
    try testing.expectEqual(@as(u8, 0), o.code);
    const created = try s.read("specs/session.spec.md");
    try testing.expectEqualStrings("# § 1 Logout\n\nIt MUST log out.\n", created);
    const reference = "// specrail: specs/session.spec.md § 1 Logout\n";
    try sandbox.expectContains(try s.read("src/t.zig"), reference);
    try expectChecks(&s);
}

// specrail: specs/cli/mv.spec.md § 4.1 Unparseable files
test "mv refuses to rewrite a spec file whose section tree is broken" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const broken = "## § 1 Deep\n\nIt MUST be deep.\n";
    try s.write("specs/broken.spec.md", broken);
    const deep = "specs/broken.spec.md § 1 Deep";
    const in_source = try runMv(&s, deep, "specs/broken.spec.md § 1 Deeper");
    try testing.expectEqual(@as(u8, 1), in_source.code);
    try sandbox.expectContains(in_source.stderr, "must be level 1");
    const logout = login_path ++ " § 2 Logout";
    const in_destination = try runMv(&s, logout, "specs/broken.spec.md § 2 Logout");
    try testing.expectEqual(@as(u8, 1), in_destination.code);
    const with_dependency = "## § 1 Deep\n```toml\ndependencies = [\"" ++ login_path ++
        " § 2 Logout\"]\n```\nIt MUST be deep.\n";
    try s.write("specs/broken.spec.md", with_dependency);
    const naming = try runMv(&s, logout, login_path ++ " § 2 Sign out");
    try testing.expectEqual(@as(u8, 1), naming.code);
    try testing.expectEqualStrings(with_dependency, try s.read("specs/broken.spec.md"));
    try testing.expectEqualStrings(login, try s.read(login_path));
}

const big =
    \\# § 1 Big
    \\
    \\## § 1.1 Part
    \\
    \\### § 1.1.1 Piece
    \\
    \\#### § 1.1.1.1 Bit
    \\
    \\It MUST be a bit.
    \\
    \\#### § 1.1.1.2 Other bit
    \\
    \\It MUST be another bit.
    \\
    \\## § 1.2 Rest
    \\
    \\It MUST rest.
    \\
;

// specrail: specs/cli/mv.spec.md § 2.4 Whole subtree
test "a section moves with every section below it, at any depth" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try s.write("specrail.toml", "spec_root = \"specs\"\n");
    try s.write("specs/big.spec.md", big);
    try s.write("src/t.zig",
        \\// specrail: specs/big.spec.md § 1.1.1.1 Bit
        \\// specrail: specs/big.spec.md § 1.1.1.2 Other bit
        \\// specrail: specs/big.spec.md § 1.2 Rest
        \\
    );
    const o = try runMv(&s, "specs/big.spec.md § 1.1 Part", "specs/big/part.spec.md § 1 Part");
    try testing.expectEqual(@as(u8, 0), o.code);
    try testing.expectEqualStrings(
        \\# § 1 Part
        \\
        \\## § 1.1 Piece
        \\
        \\### § 1.1.1 Bit
        \\
        \\It MUST be a bit.
        \\
        \\### § 1.1.2 Other bit
        \\
        \\It MUST be another bit.
        \\
    , try s.read("specs/big/part.spec.md"));
    const rest = "# § 1 Big\n\n## § 1.1 Rest\n\nIt MUST rest.\n";
    try testing.expectEqualStrings(rest, try s.read("specs/big.spec.md"));
    try testing.expectEqualStrings(
        \\// specrail: specs/big/part.spec.md § 1.1.1 Bit
        \\// specrail: specs/big/part.spec.md § 1.1.2 Other bit
        \\// specrail: specs/big.spec.md § 1.1 Rest
        \\
    , try s.read("src/t.zig"));
    try expectChecks(&s);
}

// specrail: specs/cli/mv.spec.md § 3.1 Missing directories
test "mv creates the directories a destination needs" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const logout = login_path ++ " § 2 Logout";
    const section = try runMv(&s, logout, "specs/split/deeper/logout.spec.md § 1 Logout");
    try testing.expectEqual(@as(u8, 0), section.code);
    const created = try s.read("specs/split/deeper/logout.spec.md");
    try testing.expectEqualStrings("# § 1 Logout\n\nIt MUST log out.\n", created);
    const file = try runMv(&s, "specs/auth.spec.md", "specs/a/b/identity.spec.md");
    try testing.expectEqual(@as(u8, 0), file.code);
    try testing.expectEqualStrings("Auth context.\n", try s.read("specs/a/b/identity.spec.md"));
    try testing.expect(s.exists("specs/a/b/identity/login.spec.md"));
    const reference = "// specrail: specs/a/b/identity/login.spec.md § 1.1 Password\n";
    try sandbox.expectContains(try s.read("src/t.zig"), reference);
    try expectChecks(&s);
}

/// Expects the project `authProject` made to be as it was.
fn expectUnchanged(s: *sandbox.Sandbox) !void {
    try testing.expectEqualStrings(login, try s.read(login_path));
    try testing.expectEqualStrings("Auth context.\n", try s.read("specs/auth.spec.md"));
    try sandbox.expectContains(try s.read("src/t.zig"), "/login.spec.md § 2 Logout\n");
}

// specrail: specs/cli/mv.spec.md § 3.2 Below the spec root
test "mv refuses paths that are absolute, climb out with .., or leave the spec root" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const logout = login_path ++ " § 2 Logout";
    const refused = [_][2][]const u8{
        .{ logout, "../outside.spec.md § 1 Logout" },
        .{ logout, "specs/../../outside.spec.md § 1 Logout" },
        .{ logout, "/outside.spec.md § 1 Logout" },
        .{ logout, "docs/outside.spec.md § 1 Logout" },
        .{ "specs/../specs/auth/login.spec.md § 2 Logout", logout },
        .{ "specs/auth.spec.md", "../identity.spec.md" },
        .{ "specs/auth.spec.md", "/identity.spec.md" },
        .{ "specs/auth.spec.md", "src/identity.spec.md" },
        .{ "specs/auth", "specs/../../identity" },
        .{ "src", "specs/src" },
    };
    for (refused) |args| {
        const o = try runMv(&s, args[0], args[1]);
        try testing.expectEqual(@as(u8, 2), o.code);
        try testing.expectEqualStrings("", o.stdout);
    }
    try expectUnchanged(&s);
    try testing.expect(!s.exists("docs"));
}

// specrail: specs/cli/mv.spec.md § 3.3 Symbolic links
test "mv refuses to move, create or write through a symbolic link" {
    var outside = try sandbox.Sandbox.init();
    defer outside.deinit();
    try outside.write("linked.zig", "// specrail: specs/auth/login.spec.md § 2 Logout\n");
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    try s.symlink(outside.root, "specs/elsewhere");
    const logout = login_path ++ " § 2 Logout";
    const created = try runMv(&s, logout, "specs/elsewhere/logout.spec.md § 1 Logout");
    try testing.expectEqual(@as(u8, 2), created.code);
    try sandbox.expectContains(created.stderr, "specs/elsewhere is a symbolic link");
    const moved = try runMv(&s, "specs/auth.spec.md", "specs/elsewhere/auth.spec.md");
    try testing.expectEqual(@as(u8, 2), moved.code);
    try testing.expect(!outside.exists("logout.spec.md"));
    try testing.expect(!outside.exists("auth.spec.md"));
    const target = try std.Io.Dir.path.join(testing.allocator, &.{ outside.root, "linked.zig" });
    defer testing.allocator.free(target);
    try s.symlink(target, "src/linked.zig");
    const written = try runMv(&s, logout, login_path ++ " § 2 Sign out");
    try testing.expectEqual(@as(u8, 2), written.code);
    try sandbox.expectContains(written.stderr, "src/linked.zig is a symbolic link");
    const untouched = "// specrail: specs/auth/login.spec.md § 2 Logout\n";
    try testing.expectEqualStrings(untouched, try outside.read("linked.zig"));
    try expectUnchanged(&s);
}
