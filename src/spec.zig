//! Spec files: context, the `---` separator, numbered sections, metadata
//! blocks, and the checks that need only one file.

const std = @import("std");
const Allocator = std.mem.Allocator;

const date = @import("date.zig");
const diag = @import("diag.zig");
const refs = @import("refs.zig");
const toml = @import("toml.zig");

/// Where a section is in its lifecycle. A section with no status is done.
pub const Status = enum {
    done,
    in_progress,
    planned,

    /// The status as written in metadata blocks.
    pub fn name(s: Status) []const u8 {
        return switch (s) {
            .done => "done",
            .in_progress => "in-progress",
            .planned => "planned",
        };
    }

    /// Reads a status as written in metadata blocks; null for anything else.
    pub fn parse(s: []const u8) ?Status {
        if (std.mem.eql(u8, s, "planned")) return .planned;
        if (std.mem.eql(u8, s, "in-progress")) return .in_progress;
        if (std.mem.eql(u8, s, "done")) return .done;
        return null;
    }
};

/// One entry of a section's `dependencies`.
pub const Dependency = struct {
    form: refs.Form,
    line: u32,
    column: u32,
};

/// The contents of a section's metadata block.
pub const Metadata = struct {
    /// Line of the opening fence.
    line: u32,
    status: ?Status = null,
    due: ?date.Date = null,
    assigned: ?[]const u8 = null,
    assigned_until: ?toml.DateTime = null,
    dependencies: []const Dependency = &.{},
};

/// A numbered section of a spec file.
pub const Section = struct {
    number: []const u8,
    title: []const u8,
    level: u8,
    /// 1-based line of the heading.
    line: u32,
    parent: ?usize = null,
    is_leaf: bool = true,
    metadata: ?Metadata = null,
    /// Own prose holds at least one requirement keyword.
    has_keyword: bool = false,
    effective: Status = .done,
    /// Number of references naming this section; filled in by `check`.
    references: u32 = 0,
};

/// A parsed spec file.
pub const SpecFile = struct {
    path: []const u8,
    sections: []Section,
};

/// Parses a spec file and reports into `out` every problem that can be found
/// in that file alone.
pub fn parse(arena: Allocator, path: []const u8, content: []const u8, out: *diag.List) Allocator.Error!SpecFile {
    var p: Parser = .{ .arena = arena, .path = path, .out = out, .lines = try splitLines(arena, content) };
    return p.run();
}

// ---------------------------------------------------------------- lines

const LineKind = enum { blank, fence, heading, in_fence, text };

const Line = struct {
    text: []const u8,
    kind: LineKind,
    level: u8 = 0,
    /// Heading text after the `#` characters, trimmed.
    heading: []const u8 = "",
    fence_open: bool = false,
    fence_info: []const u8 = "",
};

const Fence = struct {
    char: u8,
    len: usize,
    info: []const u8,
};

fn leadingSpaces(text: []const u8) usize {
    var i: usize = 0;
    while (i < text.len and text[i] == ' ') i += 1;
    return i;
}

fn openFence(text: []const u8) ?Fence {
    const i = leadingSpaces(text);
    if (i > 3 or i >= text.len) return null;
    const c = text[i];
    if (c != '`' and c != '~') return null;
    var n: usize = 0;
    while (i + n < text.len and text[i + n] == c) n += 1;
    if (n < 3) return null;
    const info = std.mem.trim(u8, text[i + n ..], " \t");
    if (c == '`' and std.mem.findScalar(u8, info, '`') != null) return null;
    return .{ .char = c, .len = n, .info = info };
}

fn closesFence(text: []const u8, f: Fence) bool {
    const i = leadingSpaces(text);
    if (i > 3) return false;
    var n: usize = 0;
    while (i + n < text.len and text[i + n] == f.char) n += 1;
    if (n < f.len) return false;
    return std.mem.trim(u8, text[i + n ..], " \t").len == 0;
}

fn headingLevel(text: []const u8) ?u8 {
    var n: usize = 0;
    while (n < text.len and text[n] == '#') n += 1;
    if (n == 0 or n > 6 or n >= text.len or text[n] != ' ') return null;
    return @intCast(n);
}

fn splitLines(arena: Allocator, content: []const u8) Allocator.Error![]Line {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(arena);
    var it = std.mem.splitScalar(u8, content, '\n');
    var fence: ?Fence = null;
    while (it.next()) |raw| {
        if (it.index == null and raw.len == 0) break;
        const text = std.mem.trimEnd(u8, raw, "\r");
        var line: Line = .{ .text = text, .kind = .text };
        if (fence) |f| {
            if (closesFence(text, f)) {
                line.kind = .fence;
                fence = null;
            } else line.kind = .in_fence;
        } else if (openFence(text)) |f| {
            line.kind = .fence;
            line.fence_open = true;
            line.fence_info = f.info;
            fence = f;
        } else if (std.mem.trim(u8, text, " \t").len == 0) {
            line.kind = .blank;
        } else if (headingLevel(text)) |lvl| {
            line.kind = .heading;
            line.level = lvl;
            line.heading = std.mem.trim(u8, text[lvl + 1 ..], " \t");
        }
        try lines.append(arena, line);
    }
    return lines.toOwnedSlice(arena);
}

fn isSeparator(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "---") and std.mem.trim(u8, text[3..], " \t").len == 0;
}

fn isSetextUnderline(text: []const u8) bool {
    const i = leadingSpaces(text);
    if (i > 3) return false;
    const t = std.mem.trimEnd(u8, text[i..], " \t");
    if (t.len == 0 or (t[0] != '=' and t[0] != '-')) return false;
    for (t) |c| if (c != t[0]) return false;
    return true;
}

fn isThematicBreak(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0 or (t[0] != '-' and t[0] != '*' and t[0] != '_')) return false;
    var n: usize = 0;
    for (t) |c| {
        if (c == t[0]) n += 1 else if (c != ' ' and c != '\t') return false;
    }
    return n >= 3;
}

fn isListItem(text: []const u8) bool {
    const t = text[leadingSpaces(text)..];
    if (t.len >= 2 and (t[0] == '-' or t[0] == '*' or t[0] == '+') and (t[1] == ' ' or t[1] == '\t')) return true;
    var i: usize = 0;
    while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
    return i > 0 and i + 1 < t.len and (t[i] == '.' or t[i] == ')') and (t[i + 1] == ' ' or t[i + 1] == '\t');
}

/// Approximates CommonMark's "line of a paragraph", which a setext underline
/// turns into a heading.
fn isParagraphLine(line: Line) bool {
    if (line.kind != .text) return false;
    const t = line.text;
    if (leadingSpaces(t) >= 4) return false;
    const s = std.mem.trimStart(u8, t, " ");
    if (s.len > 0 and (s[0] == '>' or s[0] == '<' or s[0] == '|')) return false;
    return !isListItem(t) and !isThematicBreak(t) and !isSetextUnderline(t);
}

// ---------------------------------------------------------------- keywords

/// The RFC 2119 requirement keywords specrail recognizes. Each negated form,
/// such as `MUST NOT`, contains one of them.
pub const keywords = [_][]const u8{ "MUST", "REQUIRED", "SHALL", "SHOULD", "RECOMMENDED", "MAY", "OPTIONAL" };

const Hit = struct {
    line: usize,
    column: u32,
    word: []const u8,
};

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Blanks out inline code spans, keeping newlines and byte offsets.
fn maskCodeSpans(buf: []u8) void {
    var i: usize = 0;
    while (i < buf.len) {
        if (buf[i] != '`') {
            i += 1;
            continue;
        }
        var run: usize = 0;
        while (i + run < buf.len and buf[i + run] == '`') run += 1;
        var j = i + run;
        const close: ?usize = scan: while (j < buf.len) {
            if (buf[j] != '`') {
                j += 1;
                continue :scan;
            }
            var r: usize = 0;
            while (j + r < buf.len and buf[j + r] == '`') r += 1;
            if (r == run) break :scan j;
            j += r;
        } else null;
        if (close) |c| {
            for (buf[i .. c + run]) |*b| {
                if (b.* != '\n') b.* = ' ';
            }
            i = c + run;
        } else i += run;
    }
}

fn scanWords(arena: Allocator, text: []const u8, line: usize, hits: *std.ArrayList(Hit)) Allocator.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        if (!std.ascii.isUpper(text[i]) or (i > 0 and isWordChar(text[i - 1]))) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < text.len and std.ascii.isUpper(text[j])) j += 1;
        if (j >= text.len or !isWordChar(text[j])) {
            for (keywords) |k| {
                if (std.mem.eql(u8, k, text[i..j])) {
                    try hits.append(arena, .{ .line = line, .column = @intCast(i + 1), .word = k });
                    break;
                }
            }
        }
        i = j;
    }
}

// ---------------------------------------------------------------- parser

const Range = struct { start: usize, end: usize };

const Parser = struct {
    arena: Allocator,
    path: []const u8,
    out: *diag.List,
    lines: []Line,
    sections: std.ArrayList(Section) = .empty,
    /// Own prose of each section, as a range of line indices.
    prose: std.ArrayList(Range) = .empty,

    fn report(p: *Parser, severity: diag.Severity, at: diag.Position, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try p.out.append(p.arena, .{
            .path = p.path,
            .line = at.line,
            .column = at.column,
            .severity = severity,
            .message = try p.arena.print(fmt, args),
        });
    }

    /// Reports an error at a 0-based line index.
    fn err(p: *Parser, index: usize, column: u32, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try p.report(.err, .{ .line = @intCast(index + 1), .column = column }, fmt, args);
    }

    fn findKeywords(p: *Parser, lines: Range) Allocator.Error![]const Hit {
        const start = lines.start;
        const end = lines.end;
        var hits: std.ArrayList(Hit) = .empty;
        errdefer hits.deinit(p.arena);
        var i = start;
        while (i < end) {
            if (p.lines[i].kind != .text) {
                i += 1;
                continue;
            }
            var j = i;
            while (j < end and p.lines[j].kind == .text) j += 1;
            // Masked text; hits do not point into it.
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(p.arena);
            for (p.lines[i..j], 0..) |l, k| {
                if (k > 0) try buf.append(p.arena, '\n');
                try buf.appendSlice(p.arena, l.text);
            }
            maskCodeSpans(buf.items);
            var it = std.mem.splitScalar(u8, buf.items, '\n');
            var line = i;
            while (it.next()) |text| : (line += 1) try scanWords(p.arena, text, line, &hits);
            i = j;
        }
        return hits.toOwnedSlice(p.arena);
    }

    fn run(p: *Parser) Allocator.Error!SpecFile {
        const lines = p.lines;
        const n = lines.len;

        var sep: ?usize = null;
        for (lines, 0..) |l, i| {
            if (i > 0 and l.kind == .text and isSeparator(l.text) and lines[i - 1].kind == .blank) {
                sep = i;
                break;
            }
        }
        var has_sections = false;
        for (lines) |l| {
            if (l.kind == .heading and refs.startsWithSign(l.heading)) has_sections = true;
        }
        const ctx_end: usize, const sec_start: usize = if (sep) |s|
            .{ s, s + 1 }
        else if (has_sections)
            .{ 0, 0 }
        else
            .{ n, n };

        if (sep) |s| {
            const empty = for (lines[0..s]) |l| {
                if (l.kind != .blank) break false;
            } else true;
            if (empty) try p.err(s, 1, "separator with no context before it; remove it", .{});
        }

        for (lines, 0..) |l, i| {
            if (i == 0 or l.kind != .text or (sep != null and sep.? == i)) continue;
            if (isSetextUnderline(l.text) and isParagraphLine(lines[i - 1])) {
                try p.err(i, 1, "this underline makes the line above a heading that specrail does not recognize; use a '#' heading", .{});
            }
        }

        for (lines[0..ctx_end], 0..) |l, i| {
            if (l.kind == .heading and refs.startsWithSign(l.heading)) {
                try p.err(i, 1, "section heading in the context; move it below the '---' separator", .{});
            }
        }
        for (try p.findKeywords(.{ .start = 0, .end = ctx_end })) |h| {
            try p.err(h.line, h.column, "requirement keyword '{s}' in context; requirements belong in leaf sections", .{h.word});
        }

        try p.readSections(sec_start);
        try p.buildTree();

        const secs = p.sections.items;
        for (secs, 0..) |*s, idx| {
            const r = p.prose.items[idx];
            const hits = try p.findKeywords(r);
            if (!s.is_leaf) {
                for (hits) |h| try p.err(h.line, h.column, "requirement keyword '{s}' in the prose of parent section § {s}; requirements belong in leaf sections", .{ h.word, s.number });
                continue;
            }
            s.has_keyword = hits.len > 0;
            if (s.has_keyword) continue;
            const msg = "leaf § {s} {s} states no requirement; state it with a requirement keyword (MUST, SHOULD, MAY, ...) or move the text into context";
            if (s.effective == .done) {
                try p.report(.err, .{ .line = s.line, .column = 1 }, msg, .{ s.number, s.title });
            } else {
                try p.report(.warning, .{ .line = s.line, .column = 1 }, msg, .{ s.number, s.title });
            }
        }
        return .{ .path = p.path, .sections = secs };
    }

    fn readSections(p: *Parser, start: usize) Allocator.Error!void {
        const lines = p.lines;
        const n = lines.len;
        var cur: ?usize = null;
        var seen_heading = false;
        var preamble_reported = false;
        var i = start;
        while (i < n) : (i += 1) {
            const l = lines[i];
            if (l.kind != .heading) {
                if (!seen_heading and l.kind != .blank and !preamble_reported) {
                    preamble_reported = true;
                    try p.err(i, 1, "content before the first section heading; a '---' separator is missing or misplaced", .{});
                }
                continue;
            }
            seen_heading = true;
            if (cur) |c| p.prose.items[c].end = i;
            cur = null;
            const a = switch (refs.parseAddress(l.heading, .required)) {
                .ok => |a| a,
                .err => |msg| {
                    try p.err(i, 1, "not a section heading: {s}; section headings look like '# § 1 Title'", .{msg});
                    continue;
                },
            };
            try p.sections.append(p.arena, .{ .number = a.number, .title = a.title, .level = l.level, .line = @intCast(i + 1) });
            var prose_start = i + 1;
            var j = i + 1;
            while (j < n and lines[j].kind == .blank) j += 1;
            if (j < n and lines[j].kind == .fence and lines[j].fence_open and std.mem.eql(u8, lines[j].fence_info, "toml")) {
                var k = j + 1;
                while (k < n and lines[k].kind == .in_fence) k += 1;
                p.sections.items[p.sections.items.len - 1].metadata = try p.readMetadata(.{ .start = j, .end = k });
                prose_start = @min(k + 1, n);
                i = prose_start - 1;
            }
            try p.prose.append(p.arena, .{ .start = prose_start, .end = n });
            cur = p.sections.items.len - 1;
        }
    }

    fn buildTree(p: *Parser) Allocator.Error!void {
        const secs = p.sections.items;
        var stack: [7]?usize = @splat(null);
        var counters: [7]u32 = @splat(0);
        var prev_level: u8 = 0;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(p.arena);
        for (secs, 0..) |*s, idx| {
            const li = s.line - 1;
            if (idx == 0 and s.level != 1) {
                try p.err(li, 1, "the first section heading is level {d}; it must be level 1 ('#')", .{s.level});
            }
            if (idx > 0 and s.level > prev_level + 1) {
                try p.err(li, 1, "heading jumps from level {d} to level {d}; levels go down one at a time", .{ prev_level, s.level });
            }

            var lvl: usize = s.level - 1;
            while (lvl > 0) : (lvl -= 1) {
                if (stack[lvl]) |parent| {
                    s.parent = parent;
                    secs[parent].is_leaf = false;
                    break;
                }
            }
            stack[s.level] = idx;
            for (s.level + 1..7) |d| stack[d] = null;

            counters[s.level] += 1;
            for (s.level + 1..7) |d| counters[d] = 0;
            const gap = for (1..s.level) |d| {
                if (counters[d] == 0) break true;
            } else false;
            if (!gap) {
                var buf: std.ArrayList(u8) = .empty;
                for (counters[1 .. s.level + 1], 0..) |c, k| {
                    if (k > 0) try buf.append(p.arena, '.');
                    try buf.print(p.arena, "{d}", .{c});
                }
                if (!std.mem.eql(u8, buf.items, s.number)) {
                    try p.err(li, 1, "§ {s} is out of order; by its position it is § {s}", .{ s.number, buf.items });
                }
            }
            if (refs.depth(s.number) != s.level) {
                try p.err(li, 1, "heading level {d} does not match § {s}, which has {d} components", .{ s.level, s.number, refs.depth(s.number) });
            }

            const key = try p.arena.print("{s}\x00{s}", .{ s.number, s.title });
            const gop = try seen.getOrPut(p.arena, key);
            if (gop.found_existing) {
                try p.err(li, 1, "duplicate section § {s} {s}; references cannot tell the two apart", .{ s.number, s.title });
            }
            prev_level = s.level;
        }
        for (secs) |*s| {
            const inherited: Status = if (s.parent) |parent| secs[parent].effective else .done;
            s.effective = if (s.metadata) |m| m.status orelse inherited else inherited;
        }
    }

    /// Reads the metadata block whose fences are the lines `fences.start` and
    /// `fences.end`.
    fn readMetadata(p: *Parser, fences: Range) Allocator.Error!Metadata {
        const open = fences.start;
        const close = fences.end;
        var m: Metadata = .{ .line = @intCast(open + 1) };
        // The parsed document borrows keys and strings from this text, and the
        // metadata borrows from the document, so it is freed only on error.
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(p.arena);
        for (p.lines[open + 1 .. close], 0..) |l, k| {
            if (k > 0) try buf.append(p.arena, '\n');
            try buf.appendSlice(p.arena, l.text);
        }
        // TOML line 1 is the line after the opening fence.
        const base: u32 = @intCast(open + 1);
        const doc = switch (try toml.parse(p.arena, buf.items)) {
            .ok => |doc| doc,
            .err => |e| {
                try p.report(.err, .{ .line = base + e.line, .column = e.column }, "invalid metadata: {s}", .{e.message});
                return m;
            },
        };
        for (doc.comment_lines) |cl| {
            try p.report(.err, .{ .line = base + cl, .column = 1 }, "comments are not allowed in metadata blocks, because 'specrail fmt' reorders keys; use an x- key instead", .{});
        }
        var until_line: u32 = 0;
        var deps: std.ArrayList(Dependency) = .empty;
        errdefer deps.deinit(p.arena);
        for (doc.entries) |e| {
            const line = base + e.line;
            if (std.mem.eql(u8, e.key, "status")) {
                if (e.value != .string) {
                    try p.wrongType(line, e, "a string");
                } else if (Status.parse(e.value.string)) |s| {
                    m.status = s;
                } else {
                    try p.report(.err, .{ .line = line, .column = e.column }, "'{s}' is not a status; use planned, in-progress or done", .{e.value.string});
                }
            } else if (std.mem.eql(u8, e.key, "due")) {
                if (e.value == .date) m.due = e.value.date else try p.wrongType(line, e, "a local date such as 2027-06-29");
            } else if (std.mem.eql(u8, e.key, "assigned")) {
                if (e.value == .string) m.assigned = e.value.string else try p.wrongType(line, e, "a string");
            } else if (std.mem.eql(u8, e.key, "assigned-until")) {
                until_line = line;
                if (e.value == .datetime) m.assigned_until = e.value.datetime else try p.wrongType(line, e, "an offset date-time such as 2026-11-17T16:00:00Z");
            } else if (std.mem.eql(u8, e.key, "dependencies")) {
                if (e.value != .array) {
                    try p.wrongType(line, e, "an array of strings");
                    continue;
                }
                items: for (e.value.array) |item| {
                    const item_line = base + item.line;
                    if (item.value != .string) {
                        try p.report(.err, .{ .line = item_line, .column = item.column }, "dependency entries must be strings, not {s}", .{item.value.kind()});
                        continue :items;
                    }
                    switch (refs.parseForm(item.value.string, .required)) {
                        .ok => |f| try deps.append(p.arena, .{ .form = f, .line = item_line, .column = item.column }),
                        .err => |msg| try p.report(.err, .{ .line = item_line, .column = item.column }, "invalid dependency entry: {s}", .{msg}),
                    }
                }
            } else if (!std.mem.startsWith(u8, e.key, "x-")) {
                try p.report(.err, .{ .line = line, .column = e.column }, "unknown metadata key '{s}'; the keys are status, due, assigned, assigned-until and dependencies, and extension keys start with 'x-'", .{e.key});
            }
        }
        if (m.assigned_until != null and m.assigned == null) {
            try p.report(.err, .{ .line = until_line, .column = 1 }, "'assigned-until' needs an 'assigned' key naming who holds the claim", .{});
        }
        m.dependencies = try deps.toOwnedSlice(p.arena);
        return m;
    }

    fn wrongType(p: *Parser, line: u32, e: toml.Entry, expected: []const u8) Allocator.Error!void {
        try p.report(.err, .{ .line = line, .column = e.column }, "'{s}' must be {s}, not {s}", .{ e.key, expected, e.value.kind() });
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    file: SpecFile,
    diags: diag.List,

    fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }

    fn expect(self: *const Parsed, line: u32, severity: diag.Severity, needle: []const u8) !void {
        for (self.diags.items) |d| {
            if (d.line == line and d.severity == severity and std.mem.find(u8, d.message, needle) != null) return;
        }
        std.debug.print("no {s} containing '{s}' on line {d}; got:\n", .{ severity.name(), needle, line });
        for (self.diags.items) |d| std.debug.print("  {d}:{d}: {s}: {s}\n", .{ d.line, d.column, d.severity.name(), d.message });
        return error.TestUnexpectedResult;
    }

    fn expectClean(self: *const Parsed) !void {
        if (self.diags.items.len == 0) return;
        for (self.diags.items) |d| std.debug.print("  {d}:{d}: {s}: {s}\n", .{ d.line, d.column, d.severity.name(), d.message });
        return error.TestUnexpectedResult;
    }

    fn count(self: *const Parsed) usize {
        return self.diags.items.len;
    }
};

fn parseTest(content: []const u8) !Parsed {
    var r: Parsed = .{ .arena = .init(testing.allocator), .file = undefined, .diags = .empty };
    r.file = try parse(r.arena.allocator(), "specs/t.spec.md", content, &r.diags);
    return r;
}

// specrail: specs/format/spec-files.spec.md § 2.1 Separator
// specrail: specs/format/spec-files.spec.md § 2.5 Later thematic breaks
test "the first --- after a blank line separates context from sections" {
    var r = try parseTest(
        \\Context that explains.
        \\
        \\## Context may have headings
        \\
        \\---
        \\
        \\# § 1 First
        \\
        \\The tool MUST work.
        \\
        \\---
        \\
        \\More prose for § 1, after a thematic break.
        \\
    );
    defer r.deinit();
    try r.expectClean();
    try testing.expectEqual(@as(usize, 1), r.file.sections.len);
    try testing.expectEqualStrings("First", r.file.sections[0].title);
}

// specrail: specs/format/spec-files.spec.md § 2.2 Files without a separator
test "a file without a separator is all context or all sections" {
    var context_only = try parseTest("# Title\n\nJust context, with a heading.\n");
    defer context_only.deinit();
    try context_only.expectClean();
    try testing.expectEqual(@as(usize, 0), context_only.file.sections.len);

    var sections_only = try parseTest("# § 1 One\n\nIt MUST work.\n");
    defer sections_only.deinit();
    try sections_only.expectClean();
    try testing.expectEqual(@as(usize, 1), sections_only.file.sections.len);
}

// specrail: specs/format/spec-files.spec.md § 2.3 Content before the first section
test "content before the first section heading is an error" {
    var missing = try parseTest("Some intro.\n# § 1 One\n\nIt MUST work.\n");
    defer missing.deinit();
    try missing.expect(1, .err, "separator is missing or misplaced");

    var misplaced = try parseTest("Intro.\n\n---\n\nMore intro.\n\n# § 1 One\n\nIt MUST work.\n");
    defer misplaced.deinit();
    try misplaced.expect(5, .err, "separator is missing or misplaced");
}

// specrail: specs/format/spec-files.spec.md § 2.4 Empty context
test "a separator with nothing before it is an error" {
    var r = try parseTest("\n---\n\n# § 1 One\n\nIt MUST work.\n");
    defer r.deinit();
    try r.expect(2, .err, "no context before it");
}

// specrail: specs/format/spec-files.spec.md § 2.6 Section headings in context
test "a section heading on the context side of the separator is an error" {
    var r = try parseTest("# § 1 Wrong side\n\n## % 2 Also wrong\n\n## 50% of users\n\n---\n\n# § 1 Right\n\nIt MUST work.\n");
    defer r.deinit();
    try r.expect(1, .err, "section heading in the context");
    try r.expect(3, .err, "section heading in the context");
    try testing.expectEqual(@as(usize, 2), r.count());
}

// specrail: specs/format/spec-files.spec.md § 3.1 Fenced code blocks
test "headings, separators, metadata and keywords inside fences are ignored" {
    var r = try parseTest(
        \\Context.
        \\
        \\````markdown
        \\# § 9 Not a section
        \\
        \\---
        \\
        \\It MUST be ignored.
        \\```toml
        \\status = 1
        \\```
        \\````
        \\
        \\---
        \\
        \\# § 1 One
        \\
        \\~~~
        \\## § 1.1 Also not a section
        \\~~~
        \\It MUST work.
        \\
    );
    defer r.deinit();
    try r.expectClean();
    try testing.expectEqual(@as(usize, 1), r.file.sections.len);
}

// specrail: specs/format/spec-files.spec.md § 3.2 Heading lines
// specrail: specs/format/spec-files.spec.md § 3.4 Section heading syntax
test "every heading among the sections must be a section heading" {
    var r = try parseTest(
        \\# § 1 One
        \\
        \\It MUST work.
        \\
        \\## Not numbered
        \\
        \\#### § 1.0 Bad number
        \\
        \\####### seven hashes is text, and so is
        \\#no-space
        \\
    );
    defer r.deinit();
    try r.expect(5, .err, "not a section heading");
    try r.expect(7, .err, "not a section heading");
    try testing.expectEqual(@as(usize, 2), r.count());
}

// specrail: specs/format/spec-files.spec.md § 3.3 Setext headings
test "setext heading underlines are errors" {
    var r = try parseTest(
        \\Context line
        \\===
        \\
        \\- a list item
        \\---
        \\
        \\***
        \\---
        \\
        \\Another paragraph
        \\---
        \\
        \\---
        \\
        \\# § 1 One
        \\
        \\It MUST work.
        \\
    );
    defer r.deinit();
    try r.expect(2, .err, "underline");
    try r.expect(11, .err, "underline");
    try testing.expectEqual(@as(usize, 2), r.count());
}

// specrail: specs/format/spec-files.spec.md § 3.5 Heading level equals depth
test "the heading level must equal the number of components" {
    var r = try parseTest("# § 1 One\n\nIt MUST work.\n\n## § 1.1.1 Deep\n\nIt MUST work.\n");
    defer r.deinit();
    try r.expect(5, .err, "does not match § 1.1.1");
}

// specrail: specs/format/spec-files.spec.md § 3.6 Section tree
test "the tree follows heading levels" {
    var r = try parseTest(
        \\# § 1 One
        \\## § 1.1 Child
        \\
        \\It MUST work.
        \\
        \\## § 1.2 Second child
        \\
        \\It MUST work.
        \\
        \\# § 2 Two
        \\
        \\It MUST work.
        \\
    );
    defer r.deinit();
    try r.expectClean();
    const s = r.file.sections;
    try testing.expectEqual(@as(?usize, null), s[0].parent);
    try testing.expectEqual(@as(?usize, 0), s[1].parent);
    try testing.expectEqual(@as(?usize, 0), s[2].parent);
    try testing.expect(!s[0].is_leaf and s[1].is_leaf and s[3].is_leaf);

    var bad = try parseTest("## § 1 Starts deep\n\nIt MUST work.\n\n#### § 1.1.1 Skips\n\nIt MUST work.\n");
    defer bad.deinit();
    try bad.expect(1, .err, "must be level 1");
    try bad.expect(5, .err, "jumps from level 2 to level 4");
}

// specrail: specs/format/spec-files.spec.md § 4.1 Contiguous numbering
test "numbers must follow position" {
    var r = try parseTest(
        \\# § 1 One
        \\## § 1.1 A
        \\
        \\It MUST work.
        \\
        \\## § 1.3 B
        \\
        \\It MUST work.
        \\
        \\# § 3 Two
        \\
        \\It MUST work.
        \\
    );
    defer r.deinit();
    try r.expect(6, .err, "by its position it is § 1.2");
    try r.expect(10, .err, "by its position it is § 2");
    try testing.expectEqual(@as(usize, 2), r.count());
}

// specrail: specs/format/spec-files.spec.md § 4.2 Duplicate headings
test "the same number and title twice is an error" {
    var r = try parseTest("# § 1 One\n\nIt MUST work.\n\n# § 1 One\n\nIt MUST work.\n");
    defer r.deinit();
    try r.expect(5, .err, "duplicate section § 1 One");
}

// specrail: specs/format/spec-files.spec.md § 5.1 Requirements only in leaves
test "requirement keywords in context prose are errors" {
    var r = try parseTest(
        \\The context MUST NOT demand.
        \\
        \\---
        \\
        \\# § 1 Parent
        \\
        \\Parent prose SHOULD NOT demand either.
        \\
        \\## § 1.1 Leaf
        \\
        \\The leaf MUST demand.
        \\
    );
    defer r.deinit();
    try r.expect(1, .err, "'MUST' in context");
    try r.expect(7, .err, "'SHOULD' in the prose of parent section § 1");
    try testing.expectEqual(@as(usize, 2), r.count());
}

// specrail: specs/format/spec-files.spec.md § 5.2 Keyword recognition
test "keywords are uppercase whole words outside code" {
    var r = try parseTest(
        \\Lowercase must and should are plain English, as are MUSTARD,
        \\MAYBE and RECOMMENDED_X. Code like `MUST` or ``a `MAY` b`` is
        \\ignored, and so is this span that crosses `a line
        \\break SHALL`.
        \\
        \\```
        \\REQUIRED inside a fence
        \\```
        \\
        \\## OPTIONAL in a heading
    );
    defer r.deinit();
    try r.expectClean();

    var hit = try parseTest("Context saying OPTIONAL.\n");
    defer hit.deinit();
    try hit.expect(1, .err, "'OPTIONAL' in context");
}

// specrail: specs/format/spec-files.spec.md § 5.3 Leaves state requirements
// specrail: specs/format/spec-files.spec.md § 5.4 Unfinished leaves without requirements
test "leaves without a keyword are errors when done and warnings otherwise" {
    var r = try parseTest(
        \\# § 1 Done
        \\
        \\Just a description.
        \\
        \\# § 2 Planned
        \\```toml
        \\status = "planned"
        \\```
        \\
        \\TBD.
        \\
    );
    defer r.deinit();
    try r.expect(1, .err, "leaf § 1 Done states no requirement");
    try r.expect(5, .warning, "leaf § 2 Planned states no requirement");
}

// specrail: specs/format/spec-files.spec.md § 6.1 Alternate section sign
test "percent stands in for the section sign in headings" {
    var r = try parseTest("# % 1 One\n\nIt MUST work.\n");
    defer r.deinit();
    try r.expectClean();
    try testing.expectEqualStrings("1", r.file.sections[0].number);
}

// specrail: specs/format/metadata.spec.md § 1.1 Recognizing a block
test "only a toml block first after the heading is metadata" {
    var r = try parseTest(
        \\# § 1 One
        \\
        \\```toml
        \\status = "planned"
        \\```
        \\
        \\It MUST work.
        \\
        \\```toml
        \\status = "nonsense, but only an example"
        \\```
        \\
        \\# § 2 Two
        \\```yaml
        \\status: planned
        \\```
        \\It MUST work.
        \\
    );
    defer r.deinit();
    try r.expectClean();
    try testing.expectEqual(Status.planned, r.file.sections[0].metadata.?.status.?);
    try testing.expectEqual(@as(?Metadata, null), r.file.sections[1].metadata);
}

// specrail: specs/format/metadata.spec.md § 2.4 No comments in metadata blocks
test "comments in metadata blocks are errors" {
    var r = try parseTest("# § 1 One\n```toml\n# why\nstatus = \"planned\" # because\n```\nIt MUST work.\n");
    defer r.deinit();
    try r.expect(3, .err, "comments are not allowed");
    try r.expect(4, .err, "comments are not allowed");
}

// specrail: specs/format/metadata.spec.md § 3.1 Known keys
test "known keys must have the right types" {
    var r = try parseTest(
        \\# § 1 One
        \\```toml
        \\status         = "planned"
        \\due            = 2027-06-29
        \\assigned       = "agent-7"
        \\assigned-until = 2026-11-17T16:00:00Z
        \\dependencies   = ["specs/t.spec.md § 2 Two"]
        \\```
        \\It MUST work.
        \\
        \\# § 2 Two
        \\```toml
        \\status         = 1
        \\due            = "tomorrow"
        \\assigned       = true
        \\assigned-until = 2026-11-17
        \\dependencies   = "specs/t.spec.md § 1 One"
        \\```
        \\It MUST work.
        \\
    );
    defer r.deinit();
    const m = r.file.sections[0].metadata.?;
    try testing.expectEqualStrings("agent-7", m.assigned.?);
    try testing.expectEqual(@as(u8, 29), m.due.?.day);
    try testing.expectEqualStrings("2", m.dependencies[0].form.number);
    for (13..18) |line| try r.expect(@intCast(line), .err, "must be");
}

// specrail: specs/format/metadata.spec.md § 3.2 Extension keys
// specrail: specs/format/metadata.spec.md § 3.3 Unknown keys
test "x- keys are accepted and other unknown keys are errors" {
    var r = try parseTest("# § 1 One\n```toml\nx-jira = \"ABC-1\"\nx-n = [1, 2]\nstauts = \"planned\"\n```\nIt MUST work.\n");
    defer r.deinit();
    try r.expect(5, .err, "unknown metadata key 'stauts'");
    try testing.expectEqual(@as(usize, 1), r.count());
}

// specrail: specs/format/metadata.spec.md § 4.1 Status values
test "status must be planned, in-progress or done" {
    var r = try parseTest("# § 1 One\n```toml\nstatus = \"wip\"\n```\nIt MUST work.\n# § 2 Two\n```toml\nstatus = \"in-progress\"\n```\nIt MUST work.\n");
    defer r.deinit();
    try r.expect(3, .err, "'wip' is not a status");
    try testing.expectEqual(Status.in_progress, r.file.sections[1].effective);
}

// specrail: specs/format/metadata.spec.md § 4.2 Effective status
test "status is inherited from the nearest ancestor that sets one" {
    var r = try parseTest(
        \\# § 1 Parent
        \\```toml
        \\status = "planned"
        \\```
        \\## § 1.1 Inherits
        \\
        \\It MUST work.
        \\
        \\## § 1.2 Overrides
        \\```toml
        \\status = "done"
        \\```
        \\It MUST work.
        \\
        \\# § 2 Default
        \\
        \\It MUST work.
        \\
    );
    defer r.deinit();
    try r.expectClean();
    const s = r.file.sections;
    try testing.expectEqual(Status.planned, s[1].effective);
    try testing.expectEqual(Status.done, s[2].effective);
    try testing.expectEqual(Status.done, s[3].effective);
}

// specrail: specs/format/metadata.spec.md § 5.1 Expiry needs an assignee
test "assigned-until without assigned is an error" {
    var r = try parseTest("# § 1 One\n```toml\nassigned-until = 2026-11-17T16:00:00Z\n```\nIt MUST work.\n");
    defer r.deinit();
    try r.expect(3, .err, "needs an 'assigned' key");
}

// specrail: specs/format/metadata.spec.md § 6.1 Entry syntax
test "dependency entries are in reference form" {
    var r = try parseTest(
        \\# § 1 One
        \\```toml
        \\dependencies = [
        \\  "specs/other.spec.md % 2.1 Two",
        \\  "specs/other.spec.md two",
        \\  3,
        \\]
        \\```
        \\It MUST work.
        \\
    );
    defer r.deinit();
    try testing.expectEqualStrings("Two", r.file.sections[0].metadata.?.dependencies[0].form.title);
    try r.expect(5, .err, "invalid dependency entry");
    try r.expect(6, .err, "must be strings");
}
