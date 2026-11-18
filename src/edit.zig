//! The engine behind `specrail mv` and `specrail swap`. Spec files become
//! outlines whose sections can be taken out and put back elsewhere, and every
//! reference and dependency entry that names a section or spec file that
//! changed is rewritten to match. The result is written through
//! `changes.zig`, safely.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const changes = @import("changes.zig");
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

const Write = changes.Write;

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

/// Whether any dependency entry of `file` names something `rw` changes.
fn namesChange(rw: rewrite.Rewriter, file: *const spec.SpecFile) bool {
    for (file.sections) |s| {
        const m = s.metadata orelse continue;
        for (m.dependencies) |d| {
            if (rw.replaceFn(rw.context, d.form) != null) return true;
        }
    }
    return false;
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
    /// The moves and writes planned so far.
    pending: changes.Changes,
    /// The new address of each moved section, printed before the paths.
    addresses: std.ArrayList([]const u8) = .empty,
    /// The exit status, once the command has stopped.
    status: u8 = 0,

    /// Opens and parses the project; null once that has failed and been
    /// reported, which is exit status 2.
    pub fn open(ctx: *cli.Ctx, command: []const u8) cli.Error!?Editor {
        const proj = (try project.open(ctx)) orelse return null;
        return try fromProject(ctx, command, proj);
    }

    /// Parses a project already read, as `open` does once it has read it.
    pub fn fromProject(
        ctx: *cli.Ctx,
        command: []const u8,
        proj: project.Project,
    ) Allocator.Error!Editor {
        const n = proj.spec_files.len;
        var e: Editor = .{
            .ctx = ctx,
            .command = command,
            .proj = proj,
            .specs = try ctx.arena.alloc(spec.SpecFile, n),
            .found = try ctx.arena.alloc(diag.List, n),
            .pending = .{ .ctx = ctx, .root = proj.root, .command = command },
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
    /// rewritten. A file that ends inside an unclosed code block cannot be:
    /// a section moved out of it would carry the block along, and one moved
    /// in after it would be buried in it.
    pub fn rewritable(e: *const Editor, index: usize) bool {
        const file = &e.specs[index];
        return !file.broken and !file.duplicate and file.open_fence == null;
    }

    /// The outline of the spec file at `index`.
    pub fn outline(e: *const Editor, index: usize) Allocator.Error!Outline {
        return Outline.init(e.ctx.arena, &e.specs[index], e.proj.spec_files[index].content);
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

    /// Whether the section at `inner` lies in the subtree of the section at
    /// `outer`. The heading levels decide, not the numbers, which a file
    /// numbered out of order does not keep in step with them.
    pub fn contains(e: *const Editor, outer: Place, inner: Place) bool {
        if (outer.file != inner.file or inner.index <= outer.index) return false;
        const sections = e.specs[outer.file].sections;
        const level = sections[outer.index].level;
        for (sections[outer.index + 1 .. inner.index + 1]) |s| {
            if (s.level <= level) return false;
        }
        return true;
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
            const final = try e.pending.finalPath(f.path);
            const w: Write = .{ .origin = f.path, .path = final, .content = after };
            try e.pending.writes.append(arena, w);
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
        // The rewriting skips a metadata block that is never closed or does
        // not parse, though check still reads its dependency entries; a file
        // with one that names a change is refused rather than left stale.
        if (e.by_path.get(path)) |i| {
            if (!e.rewritable(i) and namesChange(rw, &file)) return e.refuse(i);
        }
        const raw = try rewrite.splitLines(arena, content);
        const after = (try rewrite.rewriteDependencies(arena, rw, &file, raw)) orelse content;
        if (std.mem.eql(u8, after, original)) return;
        if (e.by_path.get(path)) |i| {
            if (!e.rewritable(i)) return e.refuse(i);
        }
        const final = try e.pending.finalPath(path);
        try e.pending.writes.append(arena, .{ .origin = path, .path = final, .content = after });
    }

    /// Makes the planned changes, then prints what changed.
    fn commit(e: *Editor) Error!void {
        const status = try e.pending.make();
        if (status != 0) {
            e.status = status;
            return error.Stopped;
        }
        try e.report();
    }

    /// Prints the new address of each moved section, then, sorted, the new
    /// path of each file that was moved or written, whatever it holds.
    fn report(e: *Editor) Error!void {
        const arena = e.ctx.arena;
        for (e.addresses.items) |a| try e.ctx.stdout.print("{s}\n", .{a});
        var touched: std.ArrayList([]const u8) = .empty;
        defer touched.deinit(arena);
        try touched.appendSlice(arena, e.pending.moved.items);
        for (e.pending.writes.items) |w| try touched.append(arena, w.path);
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

/// What the fuzz tests of the commands built on this engine share: a made-up
/// project held in memory, an editor for it, and the properties every edit
/// keeps.
pub const fuzzed = struct {
    const fmt = @import("fmt.zig");
    const fuzzing = @import("fuzzing.zig");
    const testing = std.testing;
    const ExpectError = error{ TestExpectedEqual, TestUnexpectedResult };

    /// The project root: a directory that does not exist, so that the one
    /// thing planning asks of the disk, whether a path exists, finds nothing.
    const root = "/nonexistent/specrail-fuzz";

    /// A command's context, its output kept in memory.
    pub fn context(arena: Allocator) Allocator.Error!*cli.Ctx {
        const out = try arena.create(Io.Writer.Allocating);
        out.* = .init(arena);
        const err = try arena.create(Io.Writer.Allocating);
        err.* = .init(arena);
        const ctx = try arena.create(cli.Ctx);
        ctx.* = .{
            .arena = arena,
            .io = testing.io,
            .stdout = &out.writer,
            .stderr = &err.writer,
            .cwd = root,
            .now = 20774 * 86400,
        };
        return ctx;
    }

    /// A made-up project: two spec files, and a source file that references
    /// them.
    pub fn madeUp(smith: *testing.Smith, arena: Allocator) Allocator.Error!project.Project {
        const specs = try arena.alloc(project.SourceFile, fuzzing.spec_paths.len);
        for (specs, fuzzing.spec_paths) |*f, path| {
            f.* = .{ .path = path, .content = try fuzzing.specText(smith, arena) };
        }
        const sources = try arena.alloc(project.SourceFile, 1);
        sources[0] = .{ .path = "src/t.zig", .content = try fuzzing.sourceText(smith, arena) };
        return .{
            .root = root,
            .config = .{ .spec_root = "specs" },
            .spec_files = specs,
            .source_files = sources,
        };
    }

    /// A section of a spec file the editor can rewrite, in reference form;
    /// null when there is none.
    pub fn pickSection(
        smith: *testing.Smith,
        arena: Allocator,
        e: *const Editor,
    ) Allocator.Error!?[]const u8 {
        const fi = smith.index(e.specs.len);
        const file = &e.specs[fi];
        if (!e.rewritable(fi) or file.sections.len == 0) return null;
        const s = file.sections[smith.index(file.sections.len)];
        const parts = .{ file.path, refs.section_sign, s.number, s.title };
        return try arena.print("{s} {s} {s} {s}", parts);
    }

    /// The project once the changes `e` planned are made.
    pub fn applied(arena: Allocator, e: *const Editor) Allocator.Error!project.Project {
        var specs: std.ArrayList(project.SourceFile) = .empty;
        errdefer specs.deinit(arena);
        var sources: std.ArrayList(project.SourceFile) = .empty;
        errdefer sources.deinit(arena);
        for (e.proj.spec_files) |f| {
            const path = try e.pending.finalPath(f.path);
            try specs.append(arena, .{ .path = path, .content = f.content });
        }
        for (e.proj.source_files) |f| {
            const path = try e.pending.finalPath(f.path);
            try sources.append(arena, .{ .path = path, .content = f.content });
        }
        writes: for (e.pending.writes.items) |w| {
            for ([_]*std.ArrayList(project.SourceFile){ &specs, &sources }) |list| {
                files: for (list.items) |*f| {
                    if (!std.mem.eql(u8, f.path, w.path)) continue :files;
                    f.content = w.content;
                    continue :writes;
                }
            }
            // Only spec files are created.
            try specs.append(arena, .{ .path = w.path, .content = w.content });
        }
        return .{
            .root = root,
            .config = e.proj.config,
            .spec_files = try specs.toOwnedSlice(arena),
            .source_files = try sources.toOwnedSlice(arena),
        };
    }

    fn parsed(arena: Allocator, proj: project.Project) Allocator.Error![]spec.SpecFile {
        var found: diag.List = .empty;
        defer found.deinit(arena);
        const out = try arena.alloc(spec.SpecFile, proj.spec_files.len);
        for (proj.spec_files, out) |f, *file| {
            file.* = try spec.parse(arena, f.path, f.content, &found);
        }
        return out;
    }

    /// Whether `form` names a section of `specs` exactly.
    fn namesExactly(specs: []const spec.SpecFile, form: refs.Form) bool {
        for (specs) |file| {
            if (!std.mem.eql(u8, file.path, form.path)) continue;
            for (file.sections) |s| {
                const same_title = std.mem.eql(u8, s.title, form.title);
                if (same_title and std.mem.eql(u8, s.number, form.number)) return true;
            }
        }
        return false;
    }

    /// How many reference lines and dependency entries in `proj` name a
    /// section exactly.
    pub fn exactNames(arena: Allocator, proj: project.Project) Allocator.Error!usize {
        const specs = try parsed(arena, proj);
        var count: usize = 0;
        for (proj.source_files) |f| {
            found: for (try refs.scanText(arena, f.content)) |found| {
                const form = switch (found.ref.result) {
                    .ok => |form| form,
                    .err => continue :found,
                };
                if (namesExactly(specs, form)) count += 1;
            }
        }
        for (specs) |file| {
            sections: for (file.sections) |s| {
                const m = s.metadata orelse continue :sections;
                for (m.dependencies) |d| {
                    if (namesExactly(specs, d.form)) count += 1;
                }
            }
        }
        return count;
    }

    fn lessThanText(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }

    /// Every section title in `proj`, sorted, to compare as a multiset.
    pub fn titles(arena: Allocator, proj: project.Project) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(arena);
        for (try parsed(arena, proj)) |file| {
            for (file.sections) |s| try out.append(arena, s.title);
        }
        std.mem.sort([]const u8, out.items, {}, lessThanText);
        return out.toOwnedSlice(arena);
    }

    /// Every heading in `proj`, file by file: its path, level and title.
    pub fn outlineOf(arena: Allocator, proj: project.Project) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(arena);
        for (try parsed(arena, proj)) |file| {
            for (file.sections) |s| {
                try out.print(arena, "{s} {d} {s}\n", .{ file.path, s.level, s.title });
            }
        }
        return out.toOwnedSlice(arena);
    }

    /// How many non-blank lines the spec files of `proj` hold, other than
    /// headings and separators: the prose, metadata and context that an edit
    /// moves, and never adds or drops.
    pub fn proseLines(arena: Allocator, proj: project.Project) Allocator.Error!usize {
        var count: usize = 0;
        for (proj.spec_files, try parsed(arena, proj)) |f, file| {
            var lines = std.mem.splitScalar(u8, f.content, '\n');
            while (lines.next()) |l| {
                if (!isBlank(l)) count += 1;
            }
            count -= file.sections.len + @intFromBool(file.separator != null);
        }
        return count;
    }

    /// Expects what every edit keeps: the references and dependency entries
    /// that named a section exactly still do, and no prose is lost.
    pub fn expectKept(
        arena: Allocator,
        before: project.Project,
        after: project.Project,
    ) (Allocator.Error || ExpectError)!void {
        try testing.expect(try exactNames(arena, after) >= try exactNames(arena, before));
        try testing.expectEqual(try proseLines(arena, before), try proseLines(arena, after));
    }

    /// Expects `address` to name a section of `proj` exactly, and that
    /// section's spec file to be numbered in order and rewritable.
    pub fn expectLanded(
        arena: Allocator,
        proj: project.Project,
        address: []const u8,
    ) (Allocator.Error || ExpectError)!void {
        const form = switch (refs.parseForm(address, .required)) {
            .ok => |f| f,
            .err => return error.TestUnexpectedResult,
        };
        const specs = try parsed(arena, proj);
        try testing.expect(namesExactly(specs, form));
        for (specs) |*file| {
            if (!std.mem.eql(u8, file.path, form.path)) continue;
            try testing.expect(!file.broken);
            try testing.expect(!file.duplicate);
            try testing.expect(!try fmt.outOfOrder(arena, file));
        }
    }

    /// Shows the project before and after an edit, for a failure.
    pub fn show(before: project.Project, after: project.Project) void {
        for ([_]project.Project{ before, after }, [_][]const u8{ "before", "after" }) |p, when| {
            const all = [_][]const project.SourceFile{ p.spec_files, p.source_files };
            for (all) |list| {
                for (list) |f| std.debug.print("--- {s} {s}\n{s}\n", .{ when, f.path, f.content });
            }
        }
    }
};
