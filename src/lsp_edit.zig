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
        if (file.broken or file.duplicate) return broken(arena, file.path);
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
    if (sr.file.broken or sr.file.duplicate) return broken(arena, sr.file.path);
    const s = sr.file.sections[sr.index];
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
