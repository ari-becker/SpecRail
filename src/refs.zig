//! Reference form (`<path> § <number> <title>`) and reference lines in source
//! files. References are found by a plain line scan, the way `rg` finds them.

const std = @import("std");

/// The section sign, U+00A7, as UTF-8.
pub const section_sign = "§";

/// A section address: the part of reference form after the path.
pub const Address = struct {
    number: []const u8,
    title: []const u8,
    /// True when `%` stood in for `§`.
    alt_sign: bool,
};

/// A parsed section address, or why it does not parse.
pub const AddressResult = union(enum) {
    err: []const u8,
    ok: Address,
};

/// A section in reference form: a spec file's path, then the section's
/// number and title.
pub const Form = struct {
    path: []const u8,
    number: []const u8,
    title: []const u8,
    alt_sign: bool,
};

/// A parsed reference form, or why it does not parse.
pub const FormResult = union(enum) {
    err: []const u8,
    ok: Form,
};

/// Whether a section address must include a title.
pub const TitleRule = enum {
    /// The title may be left out, as in `specrail context <path> § 1.2`.
    optional,
    /// The title must be present, as in references and dependency entries.
    required,
};

const blanks = " \t";

/// One or more positive decimal integers without leading zeros, joined by `.`.
pub fn isValidNumber(s: []const u8) bool {
    if (s.len == 0) return false;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |part| {
        if (part.len == 0 or part[0] == '0') return false;
        for (part) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Number of components in a section number.
pub fn depth(number: []const u8) usize {
    return std.mem.count(u8, number, ".") + 1;
}

/// True when `text` starts with a section sign: `§`, or `%` followed by a
/// space and a digit.
pub fn startsWithSign(text: []const u8) bool {
    if (std.mem.startsWith(u8, text, section_sign)) return true;
    if (text.len < 2 or text[0] != '%') return false;
    const rest = std.mem.trimStart(u8, text[1..], blanks);
    return rest.len < text.len - 1 and rest.len > 0 and std.ascii.isDigit(rest[0]);
}

/// Parses `§ <number> <title>`. `%` may stand in for `§`.
pub fn parseAddress(text: []const u8, title_rule: TitleRule) AddressResult {
    var rest = std.mem.trimStart(u8, text, blanks);
    var alt = false;
    if (std.mem.startsWith(u8, rest, section_sign)) {
        rest = rest[section_sign.len..];
    } else if (std.mem.startsWith(u8, rest, "%")) {
        rest = rest[1..];
        alt = true;
    } else return .{ .err = "expected '§' (or '%') and a section number" };
    if (rest.len == 0 or (rest[0] != ' ' and rest[0] != '\t')) {
        return .{ .err = "expected a space and a section number after the section sign" };
    }
    rest = std.mem.trimStart(u8, rest, blanks);
    const end = std.mem.findAny(u8, rest, blanks) orelse rest.len;
    const number = rest[0..end];
    if (!isValidNumber(number)) {
        return .{ .err = "expected a section number made of positive integers joined by '.', such as 1.2" };
    }
    const title = std.mem.trim(u8, rest[end..], blanks);
    if (title.len == 0 and title_rule == .required) return .{ .err = "expected a section title after the number" };
    return .{ .ok = .{ .number = number, .title = title, .alt_sign = alt } };
}

/// Parses reference form, `<path> § <number> <title>`.
pub fn parseForm(text: []const u8, title_rule: TitleRule) FormResult {
    const t = std.mem.trim(u8, text, blanks);
    if (t.len == 0) return .{ .err = "expected a spec file path" };
    const end = std.mem.findAny(u8, t, blanks) orelse t.len;
    return switch (parseAddress(t[end..], title_rule)) {
        .err => |e| .{ .err = e },
        .ok => |a| .{ .ok = .{ .path = t[0..end], .number = a.number, .title = a.title, .alt_sign = a.alt_sign } },
    };
}

/// The text that starts a reference in a source file.
pub const marker = "specrail:";
const prefix_chars = " \t/*#-;%!<({";
const closers = [_][]const u8{ "*/", "-->", "*)", "-}" };

/// A reference line found in a source file; it may still be malformed.
pub const LineRef = struct {
    /// 1-based column of the marker.
    column: u32,
    result: FormResult,
};

/// Recognizes a reference line. Returns null for lines that are not
/// references at all, such as lines where the marker follows code or a string.
pub fn scanLine(raw: []const u8) ?LineRef {
    const line = std.mem.trimEnd(u8, raw, "\r");
    const idx = std.mem.find(u8, line, marker) orelse return null;
    for (line[0..idx]) |c| {
        if (std.mem.findScalar(u8, prefix_chars, c) == null) return null;
    }
    const col: u32 = @intCast(idx + 1);
    var rest = std.mem.trimEnd(u8, line[idx + marker.len ..], blanks);
    for (closers) |closer| {
        if (std.mem.endsWith(u8, rest, closer)) {
            rest = std.mem.trimEnd(u8, rest[0 .. rest.len - closer.len], blanks);
            break;
        }
    }
    if (rest.len == 0 or (rest[0] != ' ' and rest[0] != '\t')) {
        return .{ .column = col, .result = .{ .err = "expected a space and a section in reference form after 'specrail:'" } };
    }
    return .{ .column = col, .result = parseForm(rest, .required) };
}

/// A reference line and the 1-based number of the line it is on.
pub const Found = struct {
    line: u32,
    ref: LineRef,
};

/// Scans a whole file for reference lines.
pub fn scanText(arena: std.mem.Allocator, content: []const u8) std.mem.Allocator.Error![]const Found {
    if (std.mem.find(u8, content, marker) == null) return &.{};
    var out: std.ArrayList(Found) = .empty;
    errdefer out.deinit(arena);
    var it = std.mem.splitScalar(u8, content, '\n');
    var n: u32 = 0;
    while (it.next()) |line| {
        n += 1;
        if (scanLine(line)) |r| try out.append(arena, .{ .line = n, .ref = r });
    }
    return out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectRef(line: []const u8, path: []const u8, number: []const u8, title: []const u8) !void {
    const r = scanLine(line) orelse return error.TestUnexpectedResult;
    switch (r.result) {
        .err => |e| {
            std.debug.print("unexpected error for '{s}': {s}\n", .{ line, e });
            return error.TestUnexpectedResult;
        },
        .ok => |f| {
            try testing.expectEqualStrings(path, f.path);
            try testing.expectEqualStrings(number, f.number);
            try testing.expectEqualStrings(title, f.title);
        },
    }
}

// specrail: specs/format/references.spec.md § 1.1 Reference line
test "a reference line names a spec file and a section" {
    try expectRef("// specrail: specs/auth/login.spec.md § 1.1.2 Accept password login", "specs/auth/login.spec.md", "1.1.2", "Accept password login");
    try expectRef("specrail: specs/a.spec.md § 3 Title with  inner  spaces ", "specs/a.spec.md", "3", "Title with  inner  spaces");
    try testing.expectEqual(@as(u32, 4), scanLine("// specrail: specs/a.spec.md § 1 T").?.column);
}

// specrail: specs/format/references.spec.md § 1.2 Comment prefix
test "only comment markers may come before the marker" {
    try expectRef("    # specrail: specs/a.spec.md § 1 T", "specs/a.spec.md", "1", "T");
    try expectRef("-- specrail: specs/a.spec.md § 1 T", "specs/a.spec.md", "1", "T");
    try expectRef(";; specrail: specs/a.spec.md § 1 T", "specs/a.spec.md", "1", "T");
    try expectRef("% specrail: specs/a.spec.md § 1 T", "specs/a.spec.md", "1", "T");
    try expectRef("<!-- specrail: specs/a.spec.md § 1 T", "specs/a.spec.md", "1", "T");
    try expectRef("(* specrail: specs/a.spec.md § 1 T", "specs/a.spec.md", "1", "T");
    try expectRef("{- specrail: specs/a.spec.md § 1 T", "specs/a.spec.md", "1", "T");
    try testing.expect(scanLine("const s = \"// specrail: specs/a.spec.md § 1 T\";") == null);
    try testing.expect(scanLine("    \\\\// specrail: specs/a.spec.md § 1 T") == null);
    try testing.expect(scanLine("x // specrail: specs/a.spec.md § 1 T") == null);
}

// specrail: specs/format/references.spec.md § 1.3 Block comment closers
test "a trailing block comment closer is not part of the title" {
    try expectRef("/* specrail: specs/a.spec.md § 1 Title */", "specs/a.spec.md", "1", "Title");
    try expectRef("<!-- specrail: specs/a.spec.md § 1 Title -->", "specs/a.spec.md", "1", "Title");
    try expectRef("(* specrail: specs/a.spec.md § 1 Title *)", "specs/a.spec.md", "1", "Title");
    try expectRef("{- specrail: specs/a.spec.md § 1 Title -}", "specs/a.spec.md", "1", "Title");
}

// specrail: specs/format/references.spec.md § 1.4 Malformed references
test "a marker after a valid prefix that does not parse is malformed" {
    for ([_][]const u8{
        "// specrail:",
        "// specrail:specs/a.spec.md § 1 T",
        "// specrail: specs/a.spec.md",
        "// specrail: specs/a.spec.md 1 T",
        "// specrail: specs/a.spec.md § 01 T",
        "// specrail: specs/a.spec.md § 1.",
        "// specrail: specs/a.spec.md § 1",
    }) |line| {
        const r = scanLine(line) orelse return error.TestUnexpectedResult;
        try testing.expect(r.result == .err);
    }
}

// specrail: specs/format/references.spec.md § 2.3 Line endings
test "CRLF line endings do not leak into titles" {
    try expectRef("// specrail: specs/a.spec.md § 1 Title\r", "specs/a.spec.md", "1", "Title");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const found = try scanText(arena_state.allocator(), "x\r\n// specrail: specs/a.spec.md § 2 Two\r\n");
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(u32, 2), found[0].line);
    try testing.expectEqualStrings("Two", found[0].ref.result.ok.title);
}

// specrail: specs/format/spec-files.spec.md § 6.1 Alternate section sign
test "percent stands in for the section sign in reference form" {
    try expectRef("// specrail: specs/a.spec.md % 1.2 Title", "specs/a.spec.md", "1.2", "Title");
    try testing.expect(scanLine("// specrail: specs/a.spec.md % 1.2 Title").?.result.ok.alt_sign);
    const form = parseForm("specs/a.spec.md % 3 Three", .required).ok;
    try testing.expectEqualStrings("3", form.number);
}

// specrail: specs/format/spec-files.spec.md § 6.2 Only in the marker position
test "percent elsewhere is text" {
    try expectRef("// specrail: specs/a.spec.md § 2.1 Cap at 50% CPU", "specs/a.spec.md", "2.1", "Cap at 50% CPU");
    try testing.expect(startsWithSign("% 1 Section"));
    try testing.expect(!startsWithSign("%1 of users"));
    try testing.expect(!startsWithSign("% of users"));
    try testing.expect(startsWithSign("§1 typo"));
}
