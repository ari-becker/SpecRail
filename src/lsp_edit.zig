//! Editing for the language server: rename, document formatting, the
//! renumber action and file moves. Each works out new file contents with the
//! code `specrail fmt` and `specrail mv` use, so that the editor and the
//! command line never disagree, and turns them into LSP edits.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const edit = @import("edit.zig");
const files = @import("files.zig");
const fmt = @import("fmt.zig");
const nav = @import("lsp_nav.zig");
const refs = @import("refs.zig");
const rewrite = @import("rewrite.zig");
const text = @import("lsp_text.zig");

/// An edit to a document, as LSP has it.
pub const TextEdit = struct {
    range: nav.Range,
    insert: []const u8,

    /// Writes the edit with the names LSP gives its fields.
    pub fn jsonStringify(e: TextEdit, w: *json.Stringify) json.Stringify.Error!void {
        try w.write(.{ .range = e.range, .newText = e.insert });
    }
};

/// The edits to one document.
pub const FileEdit = struct {
    uri: []const u8,
    edits: []const TextEdit,
};

/// Edits across the workspace, as LSP's `WorkspaceEdit` with `changes`.
pub const WorkspaceEdit = struct {
    files: []const FileEdit,

    /// Writes the edits as an object of edit lists by URI.
    pub fn jsonStringify(we: WorkspaceEdit, w: *json.Stringify) json.Stringify.Error!void {
        try w.beginObject();
        try w.objectField("changes");
        try w.beginObject();
        for (we.files) |f| {
            try w.objectField(f.uri);
            try w.write(f.edits);
        }
        try w.endObject();
        try w.endObject();
    }
};

/// What an edit request comes to: the edits, or why there are none.
pub const Outcome = union(enum) {
    edit: WorkspaceEdit,
    refused: []const u8,
};

/// Where line `i` of `lines` starts; past the last line, the end of the
/// document.
fn lineStart(lines: []const []const u8, i: usize, encoding: text.Encoding) nav.Position {
    if (i < lines.len) return .{ .line = @intCast(i), .character = 0 };
    if (lines.len == 0) return .{ .line = 0, .character = 0 };
    const last = lines[lines.len - 1];
    if (rewrite.ending(last).len > 0) return .{ .line = @intCast(lines.len), .character = 0 };
    const end = text.column(last, last.len, encoding);
    return .{ .line = @intCast(lines.len - 1), .character = end };
}

/// The edits that turn `old` into `new`. When the number of lines stays, each
/// changed line is replaced; otherwise the stretch between the lines both
/// share at either end is replaced as one.
pub fn diff(
    arena: Allocator,
    old: []const u8,
    new: []const u8,
    encoding: text.Encoding,
) Allocator.Error![]const TextEdit {
    const a = try rewrite.splitLines(arena, old);
    const b = try rewrite.splitLines(arena, new);
    var out: std.ArrayList(TextEdit) = .empty;
    errdefer out.deinit(arena);
    if (a.len == b.len) {
        for (a, b, 0..) |x, y, i| {
            if (std.mem.eql(u8, x, y)) continue;
            const range: nav.Range = .{
                .start = lineStart(a, i, encoding),
                .end = lineStart(a, i + 1, encoding),
            };
            try out.append(arena, .{ .range = range, .insert = y });
        }
        return out.toOwnedSlice(arena);
    }
    var p: usize = 0;
    while (p < a.len and p < b.len and std.mem.eql(u8, a[p], b[p])) p += 1;
    var q: usize = 0;
    while (q < a.len - p and q < b.len - p) : (q += 1) {
        if (!std.mem.eql(u8, a[a.len - 1 - q], b[b.len - 1 - q])) break;
    }
    const range: nav.Range = .{
        .start = lineStart(a, p, encoding),
        .end = lineStart(a, a.len - q, encoding),
    };
    const replacement = try std.mem.concat(arena, u8, b[p .. b.len - q]);
    try out.append(arena, .{ .range = range, .insert = replacement });
    return out.toOwnedSlice(arena);
}

fn fileEdit(
    ix: *const nav.Index,
    arena: Allocator,
    path: []const u8,
    old: []const u8,
    new: []const u8,
) Allocator.Error!FileEdit {
    return .{ .uri = try ix.uri(arena, path), .edits = try diff(arena, old, new, ix.encoding) };
}

fn broken(arena: Allocator, path: []const u8) Allocator.Error!Outcome {
    const msg = "{s} has errors that keep specrail from rewriting it; check shows them";
    return .{ .refused = try arena.print(msg, .{path}) };
}

/// A heading to write anew while rewriting: which one, and its new title.
const Heading = struct {
    section: nav.SectionRef,
    title: []const u8,
};

/// Rewrites, with `rw`, the references in every source file and the
/// dependency entries in every spec file, and `heading` when given. Refuses
/// when a spec file that would change has errors, as `specrail mv` does.
fn rewriteAll(
    ix: *const nav.Index,
    arena: Allocator,
    rw: rewrite.Rewriter,
    heading: ?Heading,
) Allocator.Error!Outcome {
    var out: std.ArrayList(FileEdit) = .empty;
    errdefer out.deinit(arena);
    for (ix.source_files) |f| {
        const after = (try rewrite.rewriteReferences(arena, rw, f.content)) orelse continue;
        try out.append(arena, try fileEdit(ix, arena, f.path, f.content, after));
    }
    for (ix.analysis.specs) |*file| {
        if (!file.rewritable() and edit.namesChange(rw, file)) return broken(arena, file.path);
        const content = ix.contents.get(file.path) orelse continue;
        const lines = try rewrite.splitLines(arena, content);
        var changed = (try rewrite.rewriteDependencies(arena, rw, file, lines)) != null;
        if (heading) |h| {
            if (h.section.file == file) {
                const s = file.sections[h.section.index];
                const line = &lines[s.line - 1];
                const hashes = "######"[0..s.level];
                const ending = rewrite.ending(line.*);
                const parts = .{ hashes, refs.section_sign, s.number, h.title, ending };
                line.* = try arena.print("{s} {s} {s} {s}{s}", parts);
                changed = true;
            }
        }
        if (!changed) continue;
        if (!file.rewritable()) return broken(arena, file.path);
        const after = try std.mem.concat(arena, u8, lines);
        try out.append(arena, try fileEdit(ix, arena, file.path, content, after));
    }
    return .{ .edit = .{ .files = try out.toOwnedSlice(arena) } };
}

/// The section a rename starts from: the one whose heading the target is,
/// or that a reference or dependency entry names exactly.
fn sectionFor(ix: *const nav.Index, target: nav.Target) ?nav.SectionRef {
    const form = switch (target) {
        .heading => |h| return h,
        .named => |f| f,
    };
    const file = ix.analysis.file(form.path) orelse return null;
    for (file.sections, 0..) |s, i| {
        const same_number = std.mem.eql(u8, s.number, form.number);
        if (same_number and std.mem.eql(u8, s.title, form.title)) {
            return .{ .file = file, .index = i };
        }
    }
    return null;
}

/// Rewrites what names one section so that it names it by a new title.
const Retitle = struct {
    path: []const u8,
    number: []const u8,
    old_title: []const u8,
    title: []const u8,

    fn replace(context: *const anyopaque, form: refs.Form) ?rewrite.Replacement {
        const r: *const Retitle = @ptrCast(@alignCast(context));
        const same = std.mem.eql(u8, form.path, r.path) and
            std.mem.eql(u8, form.number, r.number) and std.mem.eql(u8, form.title, r.old_title);
        return if (same) .{ .title = r.title } else null;
    }

    fn rewriter(r: *const Retitle) rewrite.Rewriter {
        return .{ .context = r, .replaceFn = replace };
    }
};

/// Renames the section `target` is on or names exactly to `new_name`, and
/// rewrites everything naming it, as `specrail mv` would.
pub fn rename(
    ix: *const nav.Index,
    arena: Allocator,
    target: nav.Target,
    new_name: []const u8,
) Allocator.Error!Outcome {
    const sr = sectionFor(ix, target) orelse return .{
        .refused = "this does not match a heading exactly; check shows what it should say",
    };
    const title = std.mem.trim(u8, new_name, " \t");
    if (title.len == 0 or std.mem.findAny(u8, title, "\r\n") != null) {
        return .{ .refused = "a title is one line of text" };
    }
    if (!sr.file.rewritable()) return broken(arena, sr.file.path);
    const s = sr.file.sections[sr.index];
    // The same title changes nothing, as with `specrail mv`.
    if (std.mem.eql(u8, title, s.title)) return .{ .edit = .{ .files = &.{} } };
    if (sr.file.titleTaken(sr.index, s.number, title)) {
        return .{ .refused = "another section has this number and title already" };
    }
    const retitle: Retitle = .{
        .path = sr.file.path,
        .number = s.number,
        .old_title = s.title,
        .title = title,
    };
    return rewriteAll(ix, arena, retitle.rewriter(), .{ .section = sr, .title = title });
}

/// What the editor shows when a rename starts: the title, and where it is.
pub const Prepared = struct {
    range: nav.Range,
    placeholder: []const u8,
};

/// The title a rename at line `index` of the file at `path` would change;
/// null when there is no section to rename there.
pub fn prepare(ix: *const nav.Index, target: nav.Target, path: []const u8, index: u32) ?Prepared {
    const sr = sectionFor(ix, target) orelse return null;
    const title = sr.file.sections[sr.index].title;
    const line = text.lineAt(ix.contents.get(path) orelse return null, index);
    const at = std.mem.findLast(u8, line, title) orelse return null;
    return .{
        .range = .{
            .start = .{ .line = index, .character = text.column(line, at, ix.encoding) },
            .end = .{ .line = index, .character = text.column(line, at + title.len, ix.encoding) },
        },
        .placeholder = title,
    };
}

/// What document formatting comes to: the edits, or why there are none.
pub const Formatting = union(enum) {
    edits: []const TextEdit,
    refused: []const u8,
};

/// The edits `specrail fmt` would make to the spec file at `path`, except
/// renumbering; none for any other file.
pub fn format(ix: *const nav.Index, arena: Allocator, path: []const u8) Allocator.Error!Formatting {
    const file = ix.analysis.file(path) orelse return .{ .edits = &.{} };
    const content = ix.contents.get(path) orelse return .{ .edits = &.{} };
    const after = (try fmt.formatKeepingNumbers(arena, file, content)) orelse {
        return .{ .refused = (try broken(arena, path)).refused };
    };
    return .{ .edits = try diff(arena, content, after, ix.encoding) };
}

/// The edits that renumber the spec file at `path` by position and rewrite
/// what names its sections, as `specrail fmt` would; null when its numbering
/// is in order, or it cannot be rewritten.
pub fn renumber(
    ix: *const nav.Index,
    arena: Allocator,
    path: []const u8,
) Allocator.Error!?WorkspaceEdit {
    const file = ix.analysis.file(path) orelse return null;
    if (file.broken or file.duplicate) return null;
    if (!try fmt.outOfOrder(arena, file)) return null;
    const outcome = try fmt.plan(arena, ix.spec_files, ix.source_files, &.{path});
    var out: std.ArrayList(FileEdit) = .empty;
    errdefer out.deinit(arena);
    for (outcome.changes) |c| {
        try out.append(arena, try fileEdit(ix, arena, c.path, c.before, c.after));
    }
    return .{ .files = try out.toOwnedSlice(arena) };
}

/// A file or directory the editor is about to move, by project path.
pub const Move = struct {
    old: []const u8,
    new: []const u8,
};

/// The edits that make every reference and dependency entry naming a spec
/// file that `moves` move name its new path, as `specrail mv` would.
pub fn moveFiles(
    ix: *const nav.Index,
    arena: Allocator,
    moves: []const Move,
) Allocator.Error!Outcome {
    var paths: edit.Paths = .{};
    for (ix.analysis.specs) |file| {
        each: for (moves) |m| {
            if (!files.isUnder(file.path, m.old)) continue :each;
            const new = try std.mem.concat(arena, u8, &.{ m.new, file.path[m.old.len..] });
            try paths.moved.put(arena, file.path, new);
        }
    }
    if (paths.moved.count() == 0) return .{ .edit = .{ .files = &.{} } };
    return rewriteAll(ix, arena, paths.rewriter(), null);
}

test "a diff replaces changed lines, or the stretch between shared ends" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const same = try diff(arena, "a\nb\nc\n", "a\nB\nc\n", .utf8);
    try std.testing.expectEqual(@as(usize, 1), same.len);
    try std.testing.expectEqual(@as(u32, 1), same[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 2), same[0].range.end.line);
    try std.testing.expectEqualStrings("B\n", same[0].insert);
    const fewer = try diff(arena, "a\n\nb\nc\n", "a\nb\nc\n", .utf8);
    try std.testing.expectEqual(@as(usize, 1), fewer.len);
    try std.testing.expectEqual(@as(u32, 1), fewer[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 2), fewer[0].range.end.line);
    try std.testing.expectEqualStrings("", fewer[0].insert);
    const tail = try diff(arena, "a\nb", "a\nb\nc", .utf8);
    try std.testing.expectEqual(nav.Position{ .line = 1, .character = 0 }, tail[0].range.start);
    try std.testing.expectEqual(nav.Position{ .line = 1, .character = 1 }, tail[0].range.end);
    try std.testing.expectEqualStrings("b\nc", tail[0].insert);
}

// ---------------------------------------------------------------- fuzz tests

const testing = std.testing;

const check = @import("check.zig");
const diag = @import("diag.zig");
const fuzzing = @import("fuzzing.zig");
const mv = @import("mv.zig");
const project = @import("project.zig");
const spec = @import("spec.zig");

const fuzzed = edit.fuzzed;

/// The server's index of a project held in memory.
fn indexOf(arena: Allocator, proj: project.Project, encoding: text.Encoding) !nav.Index {
    var contents: std.StringHashMapUnmanaged([]const u8) = .empty;
    errdefer contents.deinit(arena);
    for ([_][]const project.SourceFile{ proj.spec_files, proj.source_files }) |list| {
        for (list) |f| try contents.put(arena, f.path, f.content);
    }
    const input: check.Input = .{
        .spec_files = proj.spec_files,
        .source_files = proj.source_files,
    };
    return .{
        .root = proj.root,
        .analysis = try check.analyze(arena, input, 20774 * 86400),
        .spec_files = proj.spec_files,
        .source_files = proj.source_files,
        .contents = contents,
        .encoding = encoding,
    };
}

/// The byte offset in `content` of the LSP position `at`.
fn offsetOf(content: []const u8, at: nav.Position, encoding: text.Encoding) usize {
    var start: usize = 0;
    var line: u32 = 0;
    // Each step passes one line.
    while (line < at.line) : (line += 1) {
        const newline = std.mem.findScalarPos(u8, content, start, '\n') orelse return content.len;
        start = newline + 1;
    }
    return start + text.byteOffset(text.lineAt(content[start..], 0), at.character, encoding);
}

fn startsBefore(_: void, a: TextEdit, b: TextEdit) bool {
    if (a.range.start.line != b.range.start.line) return a.range.start.line < b.range.start.line;
    return a.range.start.character < b.range.start.character;
}

/// `content` with `edits` made, as an editor makes them: the ranges counted
/// in `encoding` against the text before any edit, and none overlapping.
fn apply(
    arena: Allocator,
    content: []const u8,
    edits: []const TextEdit,
    encoding: text.Encoding,
) ![]const u8 {
    const order = try arena.dupe(TextEdit, edits);
    std.mem.sort(TextEdit, order, {}, startsBefore);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    var at: usize = 0;
    for (order) |e| {
        const start = offsetOf(content, e.range.start, encoding);
        const end = offsetOf(content, e.range.end, encoding);
        try testing.expect(start >= at);
        try testing.expect(end >= start);
        try out.appendSlice(arena, content[at..start]);
        try out.appendSlice(arena, e.insert);
        at = end;
    }
    try out.appendSlice(arena, content[at..]);
    return out.toOwnedSlice(arena);
}

/// Where a rename starts: a file, a line counted from 0, and a byte in it.
const Spot = struct {
    path: []const u8,
    line: u32,
    byte: usize,
};

/// A spot on a heading, a reference line or a dependency entry, or anywhere.
fn madeUpSpot(smith: *testing.Smith, arena: Allocator, ix: *const nav.Index) !?Spot {
    switch (smith.valueRangeAtMost(u8, 0, 3)) {
        0 => {
            const file = &ix.analysis.specs[smith.index(ix.analysis.specs.len)];
            if (file.sections.len == 0) return null;
            const s = file.sections[smith.index(file.sections.len)];
            const byte = smith.index(file.lines[s.line - 1].len + 1);
            return .{ .path = file.path, .line = s.line - 1, .byte = byte };
        },
        1 => {
            const f = ix.source_files[smith.index(ix.source_files.len)];
            const found = try refs.scanText(arena, f.content);
            if (found.len == 0) return null;
            const r = found[smith.index(found.len)];
            const byte = r.ref.column - 1 + smith.valueRangeAtMost(u8, 0, 40);
            return .{ .path = f.path, .line = r.line - 1, .byte = byte };
        },
        2 => {
            const file = &ix.analysis.specs[smith.index(ix.analysis.specs.len)];
            var entries: std.ArrayList(spec.Dependency) = .empty;
            for (file.sections) |s| {
                if (s.metadata) |m| try entries.appendSlice(arena, m.dependencies);
            }
            if (entries.items.len == 0) return null;
            const d = entries.items[smith.index(entries.items.len)];
            const byte = d.column - 1 + smith.valueRangeAtMost(u8, 0, 40);
            return .{ .path = file.path, .line = d.line - 1, .byte = byte };
        },
        else => {
            const path = fuzzing.pick(smith, &(fuzzing.spec_paths ++ [_][]const u8{"src/t.zig"}));
            const line = smith.valueRangeAtMost(u32, 0, 40);
            return .{ .path = path, .line = line, .byte = smith.valueRangeAtMost(u8, 0, 80) };
        },
    }
}

/// The content of the file at `path` in `proj`.
fn contentOf(proj: project.Project, path: []const u8) ?[]const u8 {
    for ([_][]const project.SourceFile{ proj.spec_files, proj.source_files }) |list| {
        for (list) |f| {
            if (std.mem.eql(u8, f.path, path)) return f.content;
        }
    }
    return null;
}

/// Expects each file of `before`, with the edits `we` makes to it, to read
/// as in `after`.
fn expectEdited(
    arena: Allocator,
    ix: *const nav.Index,
    we: WorkspaceEdit,
    after: project.Project,
) !void {
    for ([_][]const project.SourceFile{ ix.spec_files, ix.source_files }) |list| {
        for (list) |f| {
            const uri = try ix.uri(arena, f.path);
            const edits = for (we.files) |fe| {
                if (std.mem.eql(u8, fe.uri, uri)) break fe.edits;
            } else &[_]TextEdit{};
            const got = try apply(arena, f.content, edits, ix.encoding);
            const want = contentOf(after, f.path) orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings(want, got);
        }
    }
}

/// A rename anywhere does what `specrail mv` does with the same retitle:
/// both refuse, or the server's edits, made as an editor makes them, leave
/// every file as mv leaves it.
fn renameAsMvWould(_: void, smith: *testing.Smith) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = try fuzzed.madeUp(smith, arena);
    const encoding: text.Encoding = if (smith.value(bool)) .utf16 else .utf8;
    const ix = try indexOf(arena, before, encoding);
    const spot = (try madeUpSpot(smith, arena, &ix)) orelse return;
    const target = nav.targetAt(&ix, spot.path, spot.line, spot.byte) orelse return;
    // A seed read back picks the first: a title no made-up section has.
    const title = fuzzing.pick(smith, &([_][]const u8{"Renamed"} ++ fuzzing.titles));
    const outcome = try rename(&ix, arena, target, title);
    const sr = sectionFor(&ix, target) orelse return testing.expect(outcome == .refused);
    const s = sr.file.sections[sr.index];
    const sign = refs.section_sign;
    const from = try arena.print("{s} {s} {s} {s}", .{ sr.file.path, sign, s.number, s.title });
    const to = try arena.print("{s} {s} {s} {s}", .{ sr.file.path, sign, s.number, title });
    var e = try edit.Editor.fromProject(try fuzzed.context(arena), "mv", before);
    const moved = if (mv.planMove(&e, from, to)) true else |err| switch (err) {
        error.Stopped => false,
        else => |other| return other,
    };
    errdefer {
        const said = switch (outcome) {
            .refused => |why| why,
            .edit => "edits",
        };
        std.debug.print("rename at {s}:{d}:{d} to '{s}': {s}; mv '{s}' '{s}': {}\n", .{
            spot.path, spot.line, spot.byte, title, said, from, to, moved,
        });
        fuzzed.show(before, before);
    }
    switch (outcome) {
        .refused => try testing.expect(!moved),
        .edit => |we| {
            try testing.expect(moved);
            try expectEdited(arena, &ix, we, try fuzzed.applied(arena, &e));
        },
    }
}

// specrail: specs/lsp.spec.md § 3.2 Rename
test "a rename to the title a section has already changes nothing" {
    // Found by fuzzing: the heading was rewritten anyway, its % as §.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a: project.SourceFile = .{
        .path = "specs/a.spec.md",
        .content = "# % 1 One\n\nIt MUST work.\n",
    };
    const t: project.SourceFile = .{
        .path = "src/t.zig",
        .content = "// specrail: specs/a.spec.md % 1 One\n",
    };
    const proj: project.Project = .{
        .root = "/nonexistent/specrail-test",
        .config = .{ .spec_root = "specs" },
        .spec_files = &.{a},
        .source_files = &.{t},
    };
    const ix = try indexOf(arena, proj, .utf16);
    const target = nav.targetAt(&ix, "specs/a.spec.md", 0, 3).?;
    const same = try rename(&ix, arena, target, "One");
    try testing.expectEqual(@as(usize, 0), same.edit.files.len);
    const other = try rename(&ix, arena, target, "First");
    try testing.expectEqual(@as(usize, 2), other.edit.files.len);
}

/// A project of the spec files `specs` and no source files.
fn specsOnly(specs: []const project.SourceFile) project.Project {
    return .{
        .root = "/nonexistent/specrail-test",
        .config = .{ .spec_root = "specs" },
        .spec_files = specs,
        .source_files = &.{},
    };
}

// specrail: specs/lsp.spec.md § 3.2 Rename
test "a rename refuses what mv refuses: an open block, an entry it cannot rewrite, a duplicate" {
    // Found by fuzzing: mv refused both, and the rename went ahead.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const open: project.SourceFile = .{
        .path = "specs/a.spec.md",
        .content = "# § 1 One\n\nIt MUST work.\n\n```zig\nconst a = 1;\n",
    };
    const in_open = try indexOf(arena, specsOnly(&.{open}), .utf8);
    const at_one = nav.targetAt(&in_open, "specs/a.spec.md", 0, 2).?;
    try testing.expect((try rename(&in_open, arena, at_one, "First")) == .refused);
    const fine: project.SourceFile = .{
        .path = "specs/a.spec.md",
        .content = "# § 1 One\n\nIt MUST work.\n",
    };
    const stale: project.SourceFile = .{
        .path = "specs/b.spec.md",
        .content = "# § 1 Waits\n```toml\ndependencies = [\"specs/a.spec.md § 1 One\"]\n",
    };
    const in_stale = try indexOf(arena, specsOnly(&.{ fine, stale }), .utf8);
    const at_fine = nav.targetAt(&in_stale, "specs/a.spec.md", 0, 2).?;
    try testing.expect((try rename(&in_stale, arena, at_fine, "First")) == .refused);
    const twice: project.SourceFile = .{
        .path = "specs/a.spec.md",
        .content = "# § 1 Two\n\nIt MUST work.\n\n# § 1 One\n\nIt MUST work.\n",
    };
    const in_twice = try indexOf(arena, specsOnly(&.{twice}), .utf8);
    const at_two = nav.targetAt(&in_twice, "specs/a.spec.md", 0, 2).?;
    try testing.expect((try rename(&in_twice, arena, at_two, "One")) == .refused);
}

// specrail: specs/lsp.spec.md § 1.4 Position encoding
// specrail: specs/lsp.spec.md § 3.2 Rename
test "fuzz: a rename anywhere does what mv does" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const corpus = try fuzzing.seeds(arena_state.allocator(), &.{});
    try testing.fuzz({}, renameAsMvWould, .{ .corpus = corpus });
}

/// The section numbers of `content`, the spec file at `path`, in order.
fn numbersOf(arena: Allocator, path: []const u8, content: []const u8) ![]const []const u8 {
    var found: diag.List = .empty;
    defer found.deinit(arena);
    const file = try spec.parse(arena, path, content, &found);
    const out = try arena.alloc([]const u8, file.sections.len);
    for (file.sections, out) |s, *n| n.* = s.number;
    return out;
}

/// `specs` with extra spaces in headings and around `=`, which fmt takes out.
fn loosened(arena: Allocator, specs: []const project.SourceFile) ![]const project.SourceFile {
    const out = try arena.alloc(project.SourceFile, specs.len);
    for (specs, out) |f, *g| {
        const headings = try std.mem.replaceOwned(u8, arena, f.content, "§ ", "§  ");
        const keys = try std.mem.replaceOwned(u8, arena, headings, " = ", "=");
        g.* = .{ .path = f.path, .content = keys };
    }
    return out;
}

/// Formatting a spec file makes, as an editor makes them, the edits fmt
/// would make to it except renumbering, and changes nothing the second time.
fn formatAsFmtWould(_: void, smith: *testing.Smith) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var before = try fuzzed.madeUp(smith, arena);
    // Half the time, and always for a seed read back, the files are made
    // loose first, so that even tidy ones have something to format.
    if (!smith.value(bool)) before.spec_files = try loosened(arena, before.spec_files);
    const encoding: text.Encoding = if (smith.value(bool)) .utf16 else .utf8;
    const ix = try indexOf(arena, before, encoding);
    const path = fuzzing.pick(smith, &fuzzing.spec_paths);
    const file = ix.analysis.file(path).?;
    const content = ix.contents.get(path).?;
    const edits = switch (try format(&ix, arena, path)) {
        .edits => |x| x,
        .refused => return testing.expect(file.broken or file.duplicate),
    };
    const formatted = try apply(arena, content, edits, encoding);
    errdefer std.debug.print("--- {s}\n{s}\n--- formatted\n{s}\n", .{ path, content, formatted });
    const by_fmt = (try fmt.formatKeepingNumbers(arena, file, content)).?;
    try testing.expectEqualStrings(by_fmt, formatted);
    const numbers = try numbersOf(arena, path, formatted);
    try testing.expectEqual(file.sections.len, numbers.len);
    for (file.sections, numbers) |s, n| try testing.expectEqualStrings(s.number, n);
    if (!try fmt.outOfOrder(arena, file)) {
        const planned = try fmt.plan(arena, before.spec_files, before.source_files, &.{path});
        const want = for (planned.changes) |c| {
            if (std.mem.eql(u8, c.path, path)) break c.after;
        } else content;
        try testing.expectEqualStrings(want, formatted);
    }
    const again_specs = try arena.dupe(project.SourceFile, before.spec_files);
    for (again_specs) |*f| {
        if (std.mem.eql(u8, f.path, path)) f.content = formatted;
    }
    var again = before;
    again.spec_files = again_specs;
    const again_ix = try indexOf(arena, again, encoding);
    switch (try format(&again_ix, arena, path)) {
        .edits => |x| try testing.expectEqual(@as(usize, 0), x.len),
        .refused => return error.TestUnexpectedResult,
    }
}

// specrail: specs/lsp.spec.md § 1.4 Position encoding
// specrail: specs/lsp.spec.md § 3.3 Formatting
test "fuzz: formatting makes fmt's edits, once" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const corpus = try fuzzing.seeds(arena_state.allocator(), &.{});
    try testing.fuzz({}, formatAsFmtWould, .{ .corpus = corpus });
}
