//! `specrail fmt`: puts spec files into canonical form. It renumbers sections
//! by position, and rewrites the references and dependency entries that name
//! them so that they keep naming the same sections. It never edits prose.

const std = @import("std");
const Allocator = std.mem.Allocator;

const cli = @import("cli.zig");
const diag = @import("diag.zig");
const project = @import("project.zig");
const refs = @import("refs.zig");
const spec = @import("spec.zig");
const toml = @import("toml.zig");

/// Help text for `specrail fmt --help`.
pub const usage =
    \\Usage: specrail fmt [--check [--json]] [<spec file or directory>...]
    \\
    \\Put spec files into canonical form: number sections by position, normalize
    \\headings and metadata blocks, and rewrite the references and dependency
    \\entries that name renumbered sections, anywhere in the project. Given paths,
    \\format only those spec files.
    \\
    \\Options:
    \\  --check   Write nothing; report each file that would change, and fail
    \\  --json    With --check, print one JSON object instead of diagnostic lines
    \\  --help    Show this help
    \\
;

/// Command-line options for `specrail fmt`.
pub const Options = struct {
    check: bool = false,
    json: bool = false,
    paths: []const []const u8 = &.{},
};

/// A file whose content fmt changes.
pub const Change = struct {
    path: []const u8,
    before: []const u8,
    after: []const u8,
};

/// Everything fmt would do, worked out before anything is written.
pub const Outcome = struct {
    changes: []const Change,
    /// The errors of the spec files fmt leaves alone.
    diagnostics: []const diag.Diagnostic,
};

/// How the sections of a spec file that fmt formats are renumbered.
const Plan = struct {
    file: *const spec.SpecFile,
    /// The new number of each section, by index.
    numbers: []const []const u8,
};

/// Works out what references and dependency entries should say.
const Renamer = struct {
    /// The spec files fmt formats, by path.
    plans: std.StringHashMapUnmanaged(Plan) = .empty,

    /// The number `form` should carry; null when it names no formatted file.
    /// A form that matches a heading exactly follows it; a stale one whose
    /// title matches exactly one section follows that section.
    fn number(r: *const Renamer, form: refs.Form) ?[]const u8 {
        const target = r.plans.get(form.path) orelse return null;
        const secs = target.file.sections;
        for (secs, 0..) |s, i| {
            const same_number = std.mem.eql(u8, s.number, form.number);
            if (same_number and std.mem.eql(u8, s.title, form.title)) return target.numbers[i];
        }
        var only: ?usize = null;
        for (secs, 0..) |s, i| {
            if (!std.mem.eql(u8, s.title, form.title)) continue;
            if (only != null) return form.number;
            only = i;
        }
        return if (only) |i| target.numbers[i] else form.number;
    }

    /// `raw`, the text `form` was parsed from, with the section sign and the
    /// number rewritten and nothing else; null when both are already right.
    fn rewrite(
        r: *const Renamer,
        arena: Allocator,
        raw: []const u8,
        form: refs.Form,
    ) Allocator.Error!?[]const u8 {
        const new = r.number(form) orelse return null;
        if (!form.alt_sign and std.mem.eql(u8, new, form.number)) return null;
        const sign_at = offset(raw, form.sign);
        const number_at = offset(raw, form.number);
        return try std.mem.concat(arena, u8, &.{
            raw[0..sign_at],
            refs.section_sign,
            raw[sign_at + form.sign.len .. number_at],
            new,
            raw[number_at + form.number.len ..],
        });
    }
};

/// Where `part`, a slice of `base`, starts in it.
fn offset(base: []const u8, part: []const u8) usize {
    return @intFromPtr(part.ptr) - @intFromPtr(base.ptr);
}

/// Splits `content` into lines that keep their line endings.
fn splitLines(arena: Allocator, content: []const u8) Allocator.Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(arena);
    var start: usize = 0;
    while (start < content.len) {
        const end = if (std.mem.findScalarPos(u8, content, start, '\n')) |i| i + 1 else content.len;
        try out.append(arena, content[start..end]);
        start = end;
    }
    return out.toOwnedSlice(arena);
}

fn ending(line: []const u8) []const u8 {
    if (std.mem.endsWith(u8, line, "\r\n")) return "\r\n";
    if (std.mem.endsWith(u8, line, "\n")) return "\n";
    return "";
}

fn body(line: []const u8) []const u8 {
    return line[0 .. line.len - ending(line).len];
}

/// The line ending a file uses, judged by its first line.
fn fileEnding(lines: []const []const u8) []const u8 {
    if (lines.len > 0 and std.mem.eql(u8, ending(lines[0]), "\r\n")) return "\r\n";
    return "\n";
}

fn allBlank(lines: []const []const u8) bool {
    for (lines) |l| {
        if (std.mem.trim(u8, l, " \t\r\n").len > 0) return false;
    }
    return true;
}

/// The number each section gets from its position.
fn positions(arena: Allocator, file: *const spec.SpecFile) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, file.sections.len);
    errdefer arena.free(out);
    var counters: [7]u32 = @splat(0);
    for (file.sections, 0..) |s, i| {
        counters[s.level] += 1;
        for (s.level + 1..7) |d| counters[d] = 0;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(arena);
        for (counters[1 .. s.level + 1], 0..) |c, k| {
            if (k > 0) try buf.append(arena, '.');
            try buf.print(arena, "{d}", .{c});
        }
        out[i] = try buf.toOwnedSlice(arena);
    }
    return out;
}

/// `s` as a TOML basic string.
fn basicString(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    try out.append(arena, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(arena, "\\\""),
            '\\' => try out.appendSlice(arena, "\\\\"),
            '\n' => try out.appendSlice(arena, "\\n"),
            '\r' => try out.appendSlice(arena, "\\r"),
            '\t' => try out.appendSlice(arena, "\\t"),
            0...8, 11, 12, 14...31, 127 => try out.print(arena, "\\u{x:0>4}", .{c}),
            else => try out.append(arena, c),
        }
    }
    try out.append(arena, '"');
    return out.toOwnedSlice(arena);
}

/// Keys whose values fmt rewrites. Any other key keeps its value as written.
const known_keys = [_][]const u8{ "status", "due", "assigned", "assigned-until", "dependencies" };

fn isKnown(key: []const u8) bool {
    for (known_keys) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

/// Writes one spec file in canonical form.
const Formatter = struct {
    arena: Allocator,
    renamer: *const Renamer,
    plan: Plan,
    /// The line ending the file uses.
    newline: []const u8,
    out: std.ArrayList(u8) = .empty,

    fn file(f: *const Formatter) *const spec.SpecFile {
        return f.plan.file;
    }

    /// The whole file, from its lines.
    fn format(f: *Formatter, raw: []const []const u8) Allocator.Error![]const u8 {
        const secs = f.file().sections;
        const heading_of = try f.arena.alloc(?usize, raw.len);
        defer f.arena.free(heading_of);
        @memset(heading_of, null);
        for (secs, 0..) |s, i| heading_of[s.line - 1] = i;
        const first: ?usize = if (secs.len > 0) secs[0].line - 1 else null;
        const separator = f.file().separator;
        const drop_separator = if (separator) |sep| allBlank(raw[0..sep]) else false;
        const add_separator = separator == null and first != null and !allBlank(raw[0..first.?]);
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (drop_separator and i == separator.?) continue;
            const si = heading_of[i] orelse {
                try f.out.appendSlice(f.arena, raw[i]);
                continue;
            };
            if (add_separator and i == first.?) try f.out.print(
                f.arena,
                "{s}---{s}",
                .{ f.newline, f.newline },
            );
            const s = secs[si];
            try f.out.appendNTimes(f.arena, '#', s.level);
            try f.out.print(
                f.arena,
                " § {s} {s}{s}",
                .{ f.plan.numbers[si], s.title, ending(raw[i]) },
            );
            const m = s.metadata orelse continue;
            // The block starts on the line after its opening fence; blank lines
            // between the heading and the block are dropped with it.
            const close = m.close_line - 1;
            try f.block(si, raw[m.line - 1 .. close + 1]);
            i = close;
        }
        return f.out.toOwnedSlice(f.arena);
    }

    /// Writes a section's metadata block in canonical form, or nothing when it
    /// is left with no keys. `fences` are the block's lines, fences included.
    fn block(f: *Formatter, si: usize, fences: []const []const u8) Allocator.Error!void {
        const lines = fences[1 .. fences.len - 1];
        const last_ending = ending(fences[fences.len - 1]);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(f.arena);
        for (lines, 0..) |l, k| {
            if (k > 0) try text.appendSlice(f.arena, f.newline);
            try text.appendSlice(f.arena, body(l));
        }
        const doc = switch (try toml.parse(f.arena, text.items)) {
            .ok => |d| d,
            // Not expected, since the file is not broken; the block stays as written.
            .err => {
                for (fences) |l| try f.out.appendSlice(f.arena, l);
                return;
            },
        };
        var keys: std.ArrayList(toml.Entry) = .empty;
        defer keys.deinit(f.arena);
        for (known_keys) |k| {
            if (doc.get(k)) |e| try keys.append(f.arena, e);
        }
        for (doc.entries) |e| {
            if (!isKnown(e.key)) try keys.append(f.arena, e);
        }
        if (f.redundantStatus(si, doc)) _ = keys.orderedRemove(0);
        if (keys.items.len == 0) return;
        var width: usize = 0;
        for (keys.items) |e| width = @max(width, e.key.len);
        try f.out.print(f.arena, "```toml{s}", .{f.newline});
        for (keys.items) |e| {
            try f.out.appendSlice(f.arena, e.key);
            try f.out.appendNTimes(f.arena, ' ', width - e.key.len);
            try f.out.print(f.arena, " = {s}{s}", .{ try f.value(e), f.newline });
        }
        try f.out.print(f.arena, "```{s}", .{last_ending});
    }

    /// Whether the section's `status = "done"` changes nothing, because it
    /// would be done without it.
    fn redundantStatus(f: *const Formatter, si: usize, doc: toml.Document) bool {
        const e = doc.get("status") orelse return false;
        if (e.value != .string or !std.mem.eql(u8, e.value.string, "done")) return false;
        const s = f.file().sections[si];
        const inherited: spec.Status = if (s.parent) |p| f.file().sections[p].effective else .done;
        return inherited == .done;
    }

    fn value(f: *const Formatter, e: toml.Entry) Allocator.Error![]const u8 {
        if (std.mem.eql(u8, e.key, "dependencies") and e.value == .array) {
            return f.dependencies(e.value.array);
        }
        if (isKnown(e.key) and e.value == .string) return basicString(f.arena, e.value.string);
        return e.text;
    }

    fn dependencies(f: *const Formatter, items: []const toml.Item) Allocator.Error![]const u8 {
        if (items.len == 0) return "[]";
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(f.arena);
        try out.print(f.arena, "[{s}", .{f.newline});
        for (items) |item| {
            const text = if (item.value == .string)
                try f.dependency(item.value.string)
            else
                item.text;
            try out.print(f.arena, "  {s},{s}", .{ text, f.newline });
        }
        try out.append(f.arena, ']');
        return out.toOwnedSlice(f.arena);
    }

    fn dependency(f: *const Formatter, entry: []const u8) Allocator.Error![]const u8 {
        const rewritten = switch (refs.parseForm(entry, .required)) {
            .ok => |form| (try f.renamer.rewrite(f.arena, entry, form)) orelse entry,
            .err => entry,
        };
        return basicString(f.arena, rewritten);
    }
};

/// A dependency entry's string, as written, with its reference rewritten;
/// null when it is already right.
fn rewriteToken(arena: Allocator, r: *const Renamer, item: toml.Item) Allocator.Error!?[]const u8 {
    const token = item.text;
    const quoted = token.len >= 2 and (token[0] == '"' or token[0] == '\'');
    if (quoted and std.mem.findScalar(u8, token, '\\') == null) {
        const inner = token[1 .. token.len - 1];
        const form = switch (refs.parseForm(inner, .required)) {
            .ok => |form| form,
            .err => return null,
        };
        const new = (try r.rewrite(arena, inner, form)) orelse return null;
        return try std.mem.concat(arena, u8, &.{ token[0..1], new, token[token.len - 1 ..] });
    }
    const form = switch (refs.parseForm(item.value.string, .required)) {
        .ok => |form| form,
        .err => return null,
    };
    const new = (try r.rewrite(arena, item.value.string, form)) orelse return null;
    return try basicString(arena, new);
}

/// A spec file fmt does not format, with the dependency entries that name
/// formatted files rewritten in place; null when none change.
fn rewriteDependencies(
    arena: Allocator,
    r: *const Renamer,
    file: *const spec.SpecFile,
    raw: [][]const u8,
) Allocator.Error!?[]const u8 {
    var changed = false;
    for (file.sections) |s| {
        const m = s.metadata orelse continue;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(arena);
        for (raw[m.line .. m.close_line - 1], 0..) |l, k| {
            if (k > 0) try text.append(arena, '\n');
            try text.appendSlice(arena, body(l));
        }
        const doc = switch (try toml.parse(arena, text.items)) {
            .ok => |d| d,
            .err => continue,
        };
        const deps = doc.get("dependencies") orelse continue;
        if (deps.value != .array) continue;
        items: for (deps.value.array) |item| {
            if (item.value != .string) continue :items;
            // TOML line 1 is the line after the opening fence.
            const idx = m.line - 1 + item.line;
            const at = item.column - 1;
            const line_body = body(raw[idx]);
            const fits = at + item.text.len <= line_body.len;
            if (!fits or !std.mem.eql(
                u8,
                line_body[at..][0..item.text.len],
                item.text,
            )) continue :items;
            const token = (try rewriteToken(arena, r, item)) orelse continue :items;
            raw[idx] = try std.mem.concat(arena, u8, &.{
                line_body[0..at],
                token,
                line_body[at + item.text.len ..],
                ending(raw[idx]),
            });
            changed = true;
        }
    }
    return if (changed) try std.mem.concat(arena, u8, raw) else null;
}

/// A source file with its reference lines rewritten; null when none change.
fn rewriteReferences(
    arena: Allocator,
    r: *const Renamer,
    content: []const u8,
) Allocator.Error!?[]const u8 {
    if (std.mem.find(u8, content, refs.marker) == null) return null;
    const lines = try splitLines(arena, content);
    var changed = false;
    for (lines) |*line| {
        const line_body = body(line.*);
        const found = refs.scanLine(line_body) orelse continue;
        const form = switch (found.result) {
            .ok => |form| form,
            .err => continue,
        };
        const new = (try r.rewrite(arena, line_body, form)) orelse continue;
        line.* = try std.mem.concat(arena, u8, &.{ new, ending(line.*) });
        changed = true;
    }
    return if (changed) try std.mem.concat(arena, u8, lines) else null;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, item)) return true;
    }
    return false;
}

/// Works out every change fmt makes, without writing anything. `selected`
/// lists the spec files to format; null formats all of them.
pub fn plan(
    arena: Allocator,
    spec_files: []const project.SourceFile,
    source_files: []const project.SourceFile,
    selected: ?[]const []const u8,
) Allocator.Error!Outcome {
    var problems: diag.List = .empty;
    errdefer problems.deinit(arena);
    var renamer: Renamer = .{};
    const parsed = try arena.alloc(spec.SpecFile, spec_files.len);
    for (spec_files, 0..) |f, i| {
        var found: diag.List = .empty;
        defer found.deinit(arena);
        parsed[i] = try spec.parse(arena, f.path, f.content, &found);
        const chosen = if (selected) |sel| contains(sel, f.path) else true;
        if (!chosen) continue;
        if (parsed[i].broken or parsed[i].duplicate) {
            for (found.items) |d| {
                if (d.severity == .err) try problems.append(arena, d);
            }
            continue;
        }
        const numbers = try positions(arena, &parsed[i]);
        try renamer.plans.put(arena, f.path, .{ .file = &parsed[i], .numbers = numbers });
    }

    var changes: std.ArrayList(Change) = .empty;
    errdefer changes.deinit(arena);
    for (spec_files, 0..) |f, i| {
        if (parsed[i].broken or parsed[i].duplicate) continue;
        const raw = try splitLines(arena, f.content);
        const after = if (renamer.plans.get(f.path)) |pl| formatted: {
            var formatter: Formatter = .{
                .arena = arena,
                .renamer = &renamer,
                .plan = pl,
                .newline = fileEnding(raw),
            };
            break :formatted try formatter.format(raw);
        } else (try rewriteDependencies(arena, &renamer, &parsed[i], raw)) orelse continue;
        if (std.mem.eql(u8, after, f.content)) continue;
        try changes.append(arena, .{ .path = f.path, .before = f.content, .after = after });
    }
    for (source_files) |f| {
        const after = (try rewriteReferences(arena, &renamer, f.content)) orelse continue;
        try changes.append(arena, .{ .path = f.path, .before = f.content, .after = after });
    }
    return .{
        .changes = try changes.toOwnedSlice(arena),
        .diagnostics = try problems.toOwnedSlice(arena),
    };
}

/// The 1-based line on which `after` first differs from `before`.
fn firstDifference(before: []const u8, after: []const u8) u32 {
    const n = @min(before.len, after.len);
    const at = for (0..n) |k| {
        if (before[k] != after[k]) break k;
    } else n;
    return @intCast(std.mem.count(u8, before[0..at], "\n") + 1);
}

/// Runs `specrail fmt` and returns its exit status.
pub fn run(ctx: *cli.Ctx, opts: Options) cli.Error!u8 {
    const p = (try project.open(ctx)) orelse return 2;
    const selected: ?[]const []const u8 = switch (try project.selectSpecs(
        ctx,
        p,
        opts.paths,
        "fmt",
    )) {
        .refused => return 2,
        .all => null,
        .some => |paths| paths,
    };
    const outcome = try plan(ctx.arena, p.spec_files, p.source_files, selected);
    var report: std.ArrayList(diag.Diagnostic) = .empty;
    defer report.deinit(ctx.arena);
    try report.appendSlice(ctx.arena, outcome.diagnostics);
    for (outcome.changes) |c| {
        try report.append(ctx.arena, .{
            .path = c.path,
            .line = firstDifference(c.before, c.after),
            .column = 1,
            .severity = if (opts.check) .err else .note,
            .message = if (opts.check) "not formatted; run specrail fmt" else "formatted",
        });
        if (opts.check) continue;
        const abs = try std.Io.Dir.path.join(ctx.arena, &.{ p.root, c.path });
        std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = abs, .data = c.after }) catch |e| {
            try ctx.stderr.print("specrail: cannot write {s}: {s}\n", .{ c.path, @errorName(e) });
            return 2;
        };
    }
    diag.sort(report.items);
    var errors: u32 = 0;
    for (report.items) |d| {
        if (d.severity == .err) errors += 1;
    }
    if (opts.json) {
        try ctx.stdout.writeAll("{\"diagnostics\":[");
        for (report.items, 0..) |d, i| {
            if (i > 0) try ctx.stdout.writeAll(",");
            try diag.writeJson(ctx.stdout, d);
        }
        try ctx.stdout.print("],\"summary\":{{\"files\":{d}}}}}\n", .{outcome.changes.len});
    } else {
        for (report.items) |d| try diag.write(ctx.stdout, d, ctx.color);
    }
    return if (errors > 0) 1 else 0;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const sandbox = @import("sandbox.zig");

/// The outcome of formatting files in memory.
const Formatted = struct {
    arena: std.heap.ArenaAllocator,
    outcome: Outcome,

    fn deinit(self: *Formatted) void {
        self.arena.deinit();
    }

    /// The content of `path` after formatting; null when fmt leaves it alone.
    fn after(self: *const Formatted, path: []const u8) ?[]const u8 {
        for (self.outcome.changes) |c| {
            if (std.mem.eql(u8, c.path, path)) return c.after;
        }
        return null;
    }

    fn expectAfter(self: *const Formatted, path: []const u8, expected: []const u8) !void {
        const got = self.after(path) orelse {
            std.debug.print("fmt left {s} unchanged\n", .{path});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualStrings(expected, got);
    }

    fn expectUnchanged(self: *const Formatted, path: []const u8) !void {
        if (self.after(path)) |got| {
            std.debug.print("fmt changed {s} to:\n{s}\n", .{ path, got });
            return error.TestUnexpectedResult;
        }
    }

    fn expectProblem(self: *const Formatted, needle: []const u8) !void {
        for (self.outcome.diagnostics) |d| {
            if (std.mem.find(u8, d.message, needle) != null) return;
        }
        std.debug.print("no problem says '{s}'\n", .{needle});
        return error.TestUnexpectedResult;
    }
};

fn formatTest(
    spec_files: []const project.SourceFile,
    source_files: []const project.SourceFile,
    selected: ?[]const []const u8,
) !Formatted {
    var f: Formatted = .{ .arena = .init(testing.allocator), .outcome = undefined };
    f.outcome = try plan(f.arena.allocator(), spec_files, source_files, selected);
    return f;
}

/// One spec file, `specs/t.spec.md`, returned by value so that it outlives the call.
fn one(content: []const u8) [1]project.SourceFile {
    return .{.{ .path = "specs/t.spec.md", .content = content }};
}

// specrail: specs/cli/fmt.spec.md § 1.1 Heading spacing
test "headings get single spaces and no trailing whitespace" {
    var f = try formatTest(
        &.{.{ .path = "specs/t.spec.md", .content = "#   §  1   Title   \n\nIt MUST work.\n" }},
        &.{},
        null,
    );
    defer f.deinit();
    try f.expectAfter("specs/t.spec.md", "# § 1 Title\n\nIt MUST work.\n");
}

// specrail: specs/cli/fmt.spec.md § 1.2 Missing separator
test "content before the first section gets a separator" {
    var f = try formatTest(
        &.{.{ .path = "specs/t.spec.md", .content = "Intro.\n# § 1 One\n\nIt MUST work.\n" }},
        &.{},
        null,
    );
    defer f.deinit();
    try f.expectAfter("specs/t.spec.md", "Intro.\n\n---\n# § 1 One\n\nIt MUST work.\n");
}

// specrail: specs/cli/fmt.spec.md § 1.3 Empty context
test "a separator with nothing before it is removed" {
    var f = try formatTest(
        &.{.{ .path = "specs/t.spec.md", .content = "\n---\n\n# § 1 One\n\nIt MUST work.\n" }},
        &.{},
        null,
    );
    defer f.deinit();
    try f.expectAfter("specs/t.spec.md", "\n\n# § 1 One\n\nIt MUST work.\n");
}

// specrail: specs/cli/fmt.spec.md § 1.4 Section sign
test "percent becomes the section sign in headings, references and dependencies" {
    var f = try formatTest(&.{
        .{ .path = "specs/t.spec.md", .content = "# % 1 One\n\nIt MUST work.\n" },
        .{ .path = "specs/d.spec.md", .content =
        \\# § 1 Waits
        \\```toml
        \\dependencies = ["specs/t.spec.md % 1 One"]
        \\```
        \\It MUST wait.
        \\
        },
    }, &.{.{ .path = "src/a.zig", .content = "x\n// specrail: specs/t.spec.md % 1 One\n" }}, null);
    defer f.deinit();
    try f.expectAfter("specs/t.spec.md", "# § 1 One\n\nIt MUST work.\n");
    try f.expectAfter("specs/d.spec.md",
        \\# § 1 Waits
        \\```toml
        \\dependencies = [
        \\  "specs/t.spec.md § 1 One",
        \\]
        \\```
        \\It MUST wait.
        \\
    );
    try f.expectAfter("src/a.zig", "x\n// specrail: specs/t.spec.md § 1 One\n");
}

const lettered =
    \\# § 1 A
    \\
    \\It MUST a.
    \\
    \\# § 3 B
    \\## § 3.5 C
    \\
    \\It MUST c.
    \\
;

// specrail: specs/cli/fmt.spec.md § 2.1 Renumber by position
// specrail: specs/cli/fmt.spec.md § 2.2 Rewrite references
test "sections are renumbered, and what named them follows" {
    var f = try formatTest(&.{
        .{ .path = "specs/t.spec.md", .content = lettered },
        .{ .path = "specs/d.spec.md", .content =
        \\# § 1 Waits
        \\```toml
        \\dependencies = [
        \\  "specs/t.spec.md § 3 B",
        \\]
        \\```
        \\It MUST wait.
        \\
        },
    }, &.{.{ .path = "src/a.zig", .content =
        \\/* specrail: specs/t.spec.md § 3.5 C */
        \\// specrail: specs/t.spec.md  §  3.5  C
        \\// specrail: specs/t.spec.md § 1 A
        \\
    }}, null);
    defer f.deinit();
    try f.expectAfter(
        "specs/t.spec.md",
        "# § 1 A\n\nIt MUST a.\n\n# § 2 B\n## § 2.1 C\n\nIt MUST c.\n",
    );
    try f.expectAfter("specs/d.spec.md",
        \\# § 1 Waits
        \\```toml
        \\dependencies = [
        \\  "specs/t.spec.md § 2 B",
        \\]
        \\```
        \\It MUST wait.
        \\
    );
    try f.expectAfter("src/a.zig",
        \\/* specrail: specs/t.spec.md § 2.1 C */
        \\// specrail: specs/t.spec.md  §  2.1  C
        \\// specrail: specs/t.spec.md § 1 A
        \\
    );
}

// specrail: specs/cli/fmt.spec.md § 2.3 Repair number drift
test "a stale reference follows its title when the title is unique" {
    var f = try formatTest(&.{
        .{ .path = "specs/t.spec.md", .content = lettered },
        .{
            .path = "specs/u.spec.md",
            .content = "# § 1 Same\n\nIt MUST one.\n\n# § 2 Same\n\nIt MUST two.\n",
        },
    }, &.{
        .{ .path = "src/a.zig", .content = "// specrail: specs/t.spec.md § 9 C\n" },
        .{ .path = "src/b.zig", .content = "// specrail: specs/u.spec.md § 7 Same\n" },
    }, null);
    defer f.deinit();
    try f.expectAfter("src/a.zig", "// specrail: specs/t.spec.md § 2.1 C\n");
    try f.expectUnchanged("src/b.zig");
}

// specrail: specs/cli/fmt.spec.md § 2.4 Ambiguous headings
test "a file with duplicate headings is left alone, and so are references to it" {
    var f = try formatTest(
        &one("# § 2 One\n\nIt MUST work.\n\n# § 2 One\n\nIt MUST work.\n"),
        &.{.{ .path = "src/a.zig", .content = "// specrail: specs/t.spec.md § 2 One\n" }},
        null,
    );
    defer f.deinit();
    try f.expectUnchanged("specs/t.spec.md");
    try f.expectUnchanged("src/a.zig");
    try f.expectProblem("duplicate section § 2 One");
}

// specrail: specs/cli/fmt.spec.md § 3.1 Placement
test "blank lines between a heading and its metadata block are removed" {
    var f = try formatTest(
        &one("# § 1 One\n\n```toml\nstatus = \"planned\"\n```\nIt MUST work.\n"),
        &.{},
        null,
    );
    defer f.deinit();
    try f.expectAfter(
        "specs/t.spec.md",
        "# § 1 One\n```toml\nstatus = \"planned\"\n```\nIt MUST work.\n",
    );
}

// specrail: specs/cli/fmt.spec.md § 3.2 Key order
// specrail: specs/cli/fmt.spec.md § 3.3 Alignment
// specrail: specs/cli/fmt.spec.md § 3.4 Values
test "metadata keys are ordered, aligned, and written canonically" {
    var f = try formatTest(&one(
        \\# § 1 One
        \\```toml
        \\x-b          = 'kept as written'
        \\dependencies = ['specs/t.spec.md § 2 Two']
        \\assigned = 'someone'
        \\x-a = [1,2]
        \\status = 'planned'
        \\```
        \\It MUST work.
        \\
        \\# § 2 Two
        \\
        \\It MUST work.
        \\
    ), &.{}, null);
    defer f.deinit();
    try f.expectAfter("specs/t.spec.md",
        \\# § 1 One
        \\```toml
        \\status       = "planned"
        \\assigned     = "someone"
        \\dependencies = [
        \\  "specs/t.spec.md § 2 Two",
        \\]
        \\x-b          = 'kept as written'
        \\x-a          = [1,2]
        \\```
        \\It MUST work.
        \\
        \\# § 2 Two
        \\
        \\It MUST work.
        \\
    );
}

// specrail: specs/cli/fmt.spec.md § 3.5 Redundant metadata
test "a done status that changes nothing is removed, and so is an empty block" {
    var f = try formatTest(&one(
        \\# § 1 Done already
        \\```toml
        \\status = "done"
        \\```
        \\It MUST work.
        \\
        \\# § 2 Planned
        \\```toml
        \\status = "planned"
        \\```
        \\## § 2.1 Finished early
        \\```toml
        \\status = "done"
        \\```
        \\It MUST work.
        \\
        \\# § 3 Extension only
        \\```toml
        \\status = "done"
        \\x-note = "kept"
        \\```
        \\It MUST work.
        \\
    ), &.{}, null);
    defer f.deinit();
    try f.expectAfter("specs/t.spec.md",
        \\# § 1 Done already
        \\It MUST work.
        \\
        \\# § 2 Planned
        \\```toml
        \\status = "planned"
        \\```
        \\## § 2.1 Finished early
        \\```toml
        \\status = "done"
        \\```
        \\It MUST work.
        \\
        \\# § 3 Extension only
        \\```toml
        \\x-note = "kept"
        \\```
        \\It MUST work.
        \\
    );
}

// specrail: specs/cli/fmt.spec.md § 4.1 Scope
test "given paths, only those files are formatted, but what names them follows" {
    var f = try formatTest(&.{
        .{ .path = "specs/a.spec.md", .content = "# § 3 A\n\nIt MUST a.\n" },
        .{ .path = "specs/b.spec.md", .content =
        \\#  § 1  B
        \\```toml
        \\dependencies = ["specs/a.spec.md § 3 A"]
        \\```
        \\It MUST b.
        \\
        },
    }, &.{
        .{ .path = "src/a.zig", .content = "// specrail: specs/a.spec.md § 3 A\n" },
    }, &.{"specs/a.spec.md"});
    defer f.deinit();
    try f.expectAfter("specs/a.spec.md", "# § 1 A\n\nIt MUST a.\n");
    try f.expectAfter("specs/b.spec.md",
        \\#  § 1  B
        \\```toml
        \\dependencies = ["specs/a.spec.md § 1 A"]
        \\```
        \\It MUST b.
        \\
    );
    try f.expectAfter("src/a.zig", "// specrail: specs/a.spec.md § 1 A\n");
}

// specrail: specs/cli/fmt.spec.md § 4.3 Untouched lines
test "lines fmt does not rewrite keep their bytes and line endings" {
    var f = try formatTest(&.{
        .{ .path = "specs/t.spec.md", .content = "Intro.\r\n# § 3 One\r\n\r\nIt MUST work.  \r\n" },
        .{
            .path = "specs/u.spec.md",
            .content = "Intro.\n\n---\n\n# § 1 One\n\nIt  MUST  work.\n",
        },
    }, &.{}, null);
    defer f.deinit();
    try f.expectAfter(
        "specs/t.spec.md",
        "Intro.\r\n\r\n---\r\n# § 1 One\r\n\r\nIt MUST work.  \r\n",
    );
    try f.expectUnchanged("specs/u.spec.md");
}

// specrail: specs/cli/fmt.spec.md § 4.4 Idempotence
test "formatting formatted files changes nothing" {
    const messy = [_]project.SourceFile{
        .{ .path = "specs/t.spec.md", .content =
        \\Intro.
        \\#  %  4  One
        \\
        \\```toml
        \\x-z = 1
        \\status = 'planned'
        \\dependencies = ["specs/t.spec.md % 9 Two"]
        \\```
        \\## § 4.7 Two
        \\
        \\It MUST work.
        \\
        },
    };
    const sources = [_]project.SourceFile{
        .{ .path = "src/a.zig", .content = "// specrail: specs/t.spec.md § 4.7 Two\n" },
    };
    var first = try formatTest(&messy, &sources, null);
    defer first.deinit();
    const tidy = [_]project.SourceFile{
        .{ .path = "specs/t.spec.md", .content = first.after("specs/t.spec.md").? },
    };
    const tidy_sources = [_]project.SourceFile{
        .{ .path = "src/a.zig", .content = first.after("src/a.zig").? },
    };
    var second = try formatTest(&tidy, &tidy_sources, null);
    defer second.deinit();
    try testing.expectEqual(@as(usize, 0), second.outcome.changes.len);
}

// specrail: specs/cli/fmt.spec.md § 4.5 Unparseable files
test "files whose tree or metadata cannot be read are left alone and reported" {
    var f = try formatTest(&.{
        .{ .path = "specs/a.spec.md", .content = "## § 3 Starts deep\n\nIt MUST work.\n" },
        .{
            .path = "specs/b.spec.md",
            .content = "# § 3 One\n```toml\nstatus = \n```\nIt MUST work.\n",
        },
        .{
            .path = "specs/c.spec.md",
            .content = "# § 3 One\n```toml\n# why\nstatus = \"planned\"\n```\nIt MUST work.\n",
        },
    }, &.{.{ .path = "src/a.zig", .content = "// specrail: specs/b.spec.md § 3 One\n" }}, null);
    defer f.deinit();
    try f.expectUnchanged("specs/a.spec.md");
    try f.expectUnchanged("specs/b.spec.md");
    try f.expectUnchanged("specs/c.spec.md");
    try f.expectUnchanged("src/a.zig");
    try f.expectProblem("must be level 1");
    try f.expectProblem("invalid metadata");
    try f.expectProblem("comments are not allowed");
}

fn unformattedProject(s: *sandbox.Sandbox) !void {
    try s.write("specrail.toml", "spec_root = \"specs\"\n");
    try s.write("specs/a.spec.md", "# § 2 One\n\nIt MUST work.\n");
    try s.write("src/a_test.zig", "// specrail: specs/a.spec.md § 2 One\n");
}

// specrail: specs/cli/fmt.spec.md § 4.2 Check mode
// specrail: specs/cli/fmt.spec.md § 4.6 Diagnostic lines
test "fmt --check reports what would change, sorted, and writes nothing" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try unformattedProject(&s);
    const checked = try s.runAtRoot(&.{ "fmt", "--check" });
    try testing.expectEqual(@as(u8, 1), checked.code);
    try testing.expectEqualStrings(
        "specs/a.spec.md:1:1: error: not formatted; run specrail fmt\n" ++
            "src/a_test.zig:1:1: error: not formatted; run specrail fmt\n",
        checked.stdout,
    );
    try testing.expectEqualStrings("# § 2 One\n\nIt MUST work.\n", try s.read("specs/a.spec.md"));

    const written = try s.runAtRoot(&.{"fmt"});
    try testing.expectEqual(@as(u8, 0), written.code);
    try testing.expectEqualStrings("# § 1 One\n\nIt MUST work.\n", try s.read("specs/a.spec.md"));
    try testing.expectEqualStrings(
        "// specrail: specs/a.spec.md § 1 One\n",
        try s.read("src/a_test.zig"),
    );
    const clean = try s.runAtRoot(&.{ "fmt", "--check" });
    try testing.expectEqual(@as(u8, 0), clean.code);
    try testing.expectEqualStrings("", clean.stdout);
    try testing.expectEqual(@as(u8, 0), (try s.runAtRoot(&.{"check"})).code);
}

// specrail: specs/cli/fmt.spec.md § 4.7 JSON output
test "fmt --check --json prints one JSON object" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try unformattedProject(&s);
    const o = try s.runAtRoot(&.{ "fmt", "--check", "--json" });
    try testing.expectEqual(@as(u8, 1), o.code);
    try testing.expectEqualStrings(
        "{\"diagnostics\":[" ++
            "{\"path\":\"specs/a.spec.md\",\"line\":1,\"column\":1,\"severity\":\"error\"," ++
            "\"message\":\"not formatted; run specrail fmt\"}," ++
            "{\"path\":\"src/a_test.zig\",\"line\":1,\"column\":1,\"severity\":\"error\"," ++
            "\"message\":\"not formatted; run specrail fmt\"}]," ++
            "\"summary\":{\"files\":2}}\n",
        o.stdout,
    );
    try testing.expectEqual(@as(u8, 2), (try s.runAtRoot(&.{ "fmt", "--json" })).code);
}
