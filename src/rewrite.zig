//! Rewriting what names sections: reference lines in source files, and
//! dependency entries in spec files. `fmt` uses it to follow renumbered
//! sections, and `mv` to follow moved and retitled ones.

const std = @import("std");
const Allocator = std.mem.Allocator;

const refs = @import("refs.zig");
const spec = @import("spec.zig");
const toml = @import("toml.zig");

/// What a reference or dependency entry should say instead. A null field
/// keeps what is written.
pub const Replacement = struct {
    path: ?[]const u8 = null,
    number: ?[]const u8 = null,
    title: ?[]const u8 = null,
};

/// Decides, for each reference or dependency entry, what it should say.
pub const Rewriter = struct {
    context: *const anyopaque,
    /// The replacement for `form`; null leaves it as it is.
    replaceFn: *const fn (context: *const anyopaque, form: refs.Form) ?Replacement,

    /// `raw`, the text `form` was parsed from, rewritten; null when it is
    /// already right.
    pub fn rewrite(
        r: Rewriter,
        arena: Allocator,
        raw: []const u8,
        form: refs.Form,
    ) Allocator.Error!?[]const u8 {
        const replacement = r.replaceFn(r.context, form) orelse return null;
        return splice(arena, raw, form, replacement);
    }
};

/// Where `part`, a slice of `base`, starts in it.
fn offset(base: []const u8, part: []const u8) usize {
    return @intFromPtr(part.ptr) - @intFromPtr(base.ptr);
}

/// `raw` with the path, number and title of `form` replaced, and its section
/// sign written as `§`; nothing else on it changes. Null when nothing would.
pub fn splice(
    arena: Allocator,
    raw: []const u8,
    form: refs.Form,
    with: Replacement,
) Allocator.Error!?[]const u8 {
    const path = with.path orelse form.path;
    const number = with.number orelse form.number;
    const title = with.title orelse form.title;
    const same = std.mem.eql(u8, path, form.path) and std.mem.eql(u8, number, form.number) and
        std.mem.eql(u8, title, form.title);
    if (same and !form.alt_sign) return null;
    const path_at = offset(raw, form.path);
    const sign_at = offset(raw, form.sign);
    const number_at = offset(raw, form.number);
    const title_at = offset(raw, form.title);
    return try std.mem.concat(arena, u8, &.{
        raw[0..path_at],
        path,
        raw[path_at + form.path.len .. sign_at],
        refs.section_sign,
        raw[sign_at + form.sign.len .. number_at],
        number,
        raw[number_at + form.number.len .. title_at],
        title,
        raw[title_at + form.title.len ..],
    });
}

/// Splits `content` into lines that keep their line endings.
pub fn splitLines(arena: Allocator, content: []const u8) Allocator.Error![][]const u8 {
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

/// The line ending of `line`: `\r\n`, `\n`, or nothing on a last line.
pub fn ending(line: []const u8) []const u8 {
    if (std.mem.endsWith(u8, line, "\r\n")) return "\r\n";
    if (std.mem.endsWith(u8, line, "\n")) return "\n";
    return "";
}

/// `line` without its line ending.
pub fn body(line: []const u8) []const u8 {
    return line[0 .. line.len - ending(line).len];
}

/// The line ending a file uses, judged by its first line.
pub fn fileEnding(lines: []const []const u8) []const u8 {
    if (lines.len > 0 and std.mem.eql(u8, ending(lines[0]), "\r\n")) return "\r\n";
    return "\n";
}

/// `s` as a TOML basic string.
pub fn basicString(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
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

/// A dependency entry's string, as written, rewritten; null when it is
/// already right. Without escapes it is edited inside its quotes, and with
/// them it is written anew as a basic string.
fn rewriteToken(arena: Allocator, r: Rewriter, item: toml.Item) Allocator.Error!?[]const u8 {
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

/// A spec file, from its lines, with its dependency entries rewritten in
/// place; null when none change.
pub fn rewriteDependencies(
    arena: Allocator,
    r: Rewriter,
    file: *const spec.SpecFile,
    raw: [][]const u8,
) Allocator.Error!?[]const u8 {
    var changed = false;
    for (file.sections) |s| {
        const m = s.metadata orelse continue;
        if (m.close_line == 0) continue;
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
            const end = at + item.text.len;
            const fits = end <= line_body.len;
            if (!fits or !std.mem.eql(u8, line_body[at..end], item.text)) continue :items;
            const token = (try rewriteToken(arena, r, item)) orelse continue :items;
            raw[idx] = try std.mem.concat(arena, u8, &.{
                line_body[0..at],
                token,
                line_body[end..],
                ending(raw[idx]),
            });
            changed = true;
        }
    }
    return if (changed) try std.mem.concat(arena, u8, raw) else null;
}

/// A source file with its reference lines rewritten; null when none change.
pub fn rewriteReferences(
    arena: Allocator,
    r: Rewriter,
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
