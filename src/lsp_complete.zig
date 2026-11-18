//! Completion for the language server: spec file paths, and then the headings
//! of the file named, wherever a section is written in reference form: on a
//! reference line, after `specrail:`, and inside a `dependencies` entry.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const nav = @import("lsp_nav.zig");
const refs = @import("refs.zig");
const rewrite = @import("rewrite.zig");
const text = @import("lsp_text.zig");

/// LSP's kinds for the two sorts of completion.
const file_kind = 17;
const reference_kind = 18;

/// One completion: what to show, and the edit that inserts it.
pub const Item = struct {
    label: []const u8,
    kind: u8,
    /// What the editor filters by, which is what was typed as written.
    filter: []const u8,
    range: nav.Range,
    insert: []const u8,

    /// Writes the item with the names LSP gives these fields.
    pub fn jsonStringify(item: Item, w: *json.Stringify) json.Stringify.Error!void {
        try w.write(.{
            .label = item.label,
            .kind = item.kind,
            .filterText = item.filter,
            .textEdit = .{ .range = item.range, .newText = item.insert },
        });
    }
};

/// Characters that may come before `specrail:` on a reference line.
const prefix_chars = " \t/*#-;%!<({";

/// Where the reference form starts on a reference line, given the line up to
/// the cursor; null when the line is not a reference line there.
fn referenceStart(before: []const u8) ?usize {
    const at = std.mem.find(u8, before, refs.marker) orelse return null;
    for (before[0..at]) |c| {
        if (std.mem.findScalar(u8, prefix_chars, c) == null) return null;
    }
    var start = at + refs.marker.len;
    while (start < before.len and (before[start] == ' ' or before[start] == '\t')) start += 1;
    return start;
}

/// The key of a `key = value` line, when the line is one.
fn keyOf(line: []const u8) ?[]const u8 {
    const eq = std.mem.findScalar(u8, line, '=') orelse return null;
    const key = std.mem.trim(u8, line[0..eq], " \t");
    if (key.len == 0) return null;
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return null;
    }
    return key;
}

fn isHeading(line: []const u8) bool {
    const t = std.mem.trimStart(u8, line, " ");
    const signed = std.mem.find(u8, t, refs.section_sign) != null or
        std.mem.findScalar(u8, t, '%') != null;
    return t.len > 0 and t[0] == '#' and signed;
}

/// Whether line `index` of `lines` lies in the `dependencies` value of a
/// metadata block. The lines are read as written, since a block being edited
/// may not parse.
fn inDependencies(lines: []const []const u8, index: usize) bool {
    var dependencies: ?bool = null;
    var i = index + 1;
    // Each step moves one line up, so the loop ends at the top of the file.
    while (i > 0) {
        i -= 1;
        const l = std.mem.trim(u8, rewrite.body(lines[i]), " \t");
        if (std.mem.startsWith(u8, l, "```")) {
            if (!std.mem.eql(u8, l, "```toml") or dependencies != true) return false;
            // The block is a metadata block: the first thing after a heading.
            var above = i;
            while (above > 0) {
                above -= 1;
                const prev = std.mem.trim(u8, rewrite.body(lines[above]), " \t");
                if (prev.len > 0) return isHeading(prev);
            }
            return false;
        }
        if (dependencies == null) {
            if (keyOf(l)) |key| dependencies = std.mem.eql(u8, key, "dependencies");
        }
    }
    return false;
}

/// Where the reference form starts in a dependency entry, given the line up
/// to the cursor: just after the quote that opens the string the cursor is
/// in. Null when the cursor is not in a string.
fn entryStart(before: []const u8) ?usize {
    var open: ?usize = null;
    for (before, 0..) |c, i| {
        if (c != '"' and c != '\'') continue;
        open = if (open == null) i + 1 else null;
    }
    return open;
}

/// The completions at byte `byte` of line `index`, counted from 0, of the
/// file at `path`.
pub fn complete(
    ix: *const nav.Index,
    arena: Allocator,
    path: []const u8,
    index: u32,
    byte: usize,
) Allocator.Error![]const Item {
    const content = ix.contents.get(path) orelse return &.{};
    const line = text.lineAt(content, index);
    const before = line[0..@min(byte, line.len)];
    const start = if (ix.analysis.file(path) != null) spec: {
        const lines = try rewrite.splitLines(arena, content);
        if (index >= lines.len or !inDependencies(lines, index)) return &.{};
        break :spec entryStart(before);
    } else referenceStart(before);
    const from = start orelse return &.{};
    return forms(ix, arena, line, index, .{ .start = from, .end = before.len });
}

/// The part of a line being completed, in bytes.
const Span = struct {
    start: usize,
    end: usize,
};

/// Spec file paths, or, once a section sign follows the path, the headings
/// of that spec file.
fn forms(
    ix: *const nav.Index,
    arena: Allocator,
    line: []const u8,
    index: u32,
    span: Span,
) Allocator.Error![]const Item {
    const typed = line[span.start..span.end];
    var out: std.ArrayList(Item) = .empty;
    errdefer out.deinit(arena);
    const sign = std.mem.find(u8, typed, refs.section_sign) orelse
        std.mem.findScalar(u8, typed, '%');
    if (sign) |at| {
        const file = ix.analysis.file(std.mem.trim(u8, typed[0..at], " \t")) orelse return &.{};
        const written = if (typed[at] == '%') "%" else refs.section_sign;
        const range = rangeOf(ix, line, index, .{ .start = span.start + at, .end = span.end });
        for (file.sections) |s| {
            try out.append(arena, .{
                .label = try arena.print("{s} {s} {s}", .{ refs.section_sign, s.number, s.title }),
                .kind = reference_kind,
                .filter = try arena.print("{s} {s} {s}", .{ written, s.number, s.title }),
                .range = range,
                .insert = try arena.print("{s} {s} {s}", .{ refs.section_sign, s.number, s.title }),
            });
        }
        return out.toOwnedSlice(arena);
    }
    const range = rangeOf(ix, line, index, span);
    for (ix.analysis.specs) |file| {
        const item: Item = .{
            .label = file.path,
            .kind = file_kind,
            .filter = file.path,
            .range = range,
            .insert = file.path,
        };
        try out.append(arena, item);
    }
    return out.toOwnedSlice(arena);
}

fn rangeOf(ix: *const nav.Index, line: []const u8, index: u32, span: Span) nav.Range {
    return .{
        .start = .{ .line = index, .character = text.column(line, span.start, ix.encoding) },
        .end = .{ .line = index, .character = text.column(line, span.end, ix.encoding) },
    };
}

test "a reference form starts after specrail: and blanks, behind comment markers only" {
    try std.testing.expectEqual(@as(?usize, 13), referenceStart("// specrail: specs/a"));
    try std.testing.expectEqual(@as(?usize, 15), referenceStart("<!-- specrail: "));
    try std.testing.expectEqual(@as(?usize, null), referenceStart("const x = \"specrail: "));
    try std.testing.expectEqual(@as(?usize, null), referenceStart("// a note"));
}

test "a dependency entry is found by the lines above it, even unparsed" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const content =
        \\## § 1.1 Waits
        \\```toml
        \\status       = "planned"
        \\dependencies = [
        \\  "specs/a.spec.md § 1
        \\x-note = "specs
        \\```
        \\```toml
        \\dependencies = ["specs
    ;
    const lines = try rewrite.splitLines(arena_state.allocator(), content);
    try std.testing.expect(inDependencies(lines, 3));
    try std.testing.expect(inDependencies(lines, 4));
    try std.testing.expect(!inDependencies(lines, 5));
    try std.testing.expect(!inDependencies(lines, 2));
    // A toml block that does not follow a heading is not metadata.
    try std.testing.expect(!inDependencies(lines, 8));
    try std.testing.expectEqual(@as(?usize, 3), entryStart("  \"spe"));
    try std.testing.expectEqual(@as(?usize, null), entryStart("  \"specs/a.spec.md § 1 One\","));
}
