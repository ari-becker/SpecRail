//! The small subset of TOML v1.0 that metadata blocks and `specrail.toml` use:
//! bare keys, strings, integers, booleans, local dates, offset date-times and
//! arrays of those. Everything else is reported as unsupported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const date = @import("date.zig");

/// An offset date-time.
pub const DateTime = struct {
    /// Seconds since the epoch.
    seconds: i64,
    /// The value as written.
    text: []const u8,
};

/// An array element and its 1-based position.
pub const Item = struct {
    value: Value,
    line: u32,
    column: u32,
};

/// A value of one of the supported types.
pub const Value = union(enum) {
    array: []const Item,
    boolean: bool,
    date: date.Date,
    datetime: DateTime,
    integer: i64,
    string: []const u8,

    /// The type's name, for error messages.
    pub fn kind(v: Value) []const u8 {
        return switch (v) {
            .array => "an array",
            .boolean => "a boolean",
            .date => "a local date",
            .datetime => "an offset date-time",
            .integer => "an integer",
            .string => "a string",
        };
    }
};

/// A `key = value` line.
pub const Entry = struct {
    key: []const u8,
    value: Value,
    /// 1-based position of the key.
    line: u32,
    column: u32,
};

/// A parsed document.
pub const Document = struct {
    entries: []const Entry,
    /// Lines (1-based) that hold a comment.
    comment_lines: []const u32,

    /// The entry for `key`, if the document has one.
    pub fn get(doc: Document, key: []const u8) ?Entry {
        for (doc.entries) |e| if (std.mem.eql(u8, e.key, key)) return e;
        return null;
    }
};

/// Why a document does not parse, and where.
pub const Error = struct {
    line: u32,
    column: u32,
    message: []const u8,
};

/// A parsed document, or its first error.
pub const Result = union(enum) {
    err: Error,
    ok: Document,
};

/// Parses a document in the supported subset of TOML.
pub fn parse(arena: Allocator, text: []const u8) Allocator.Error!Result {
    var p: Parser = .{ .arena = arena, .text = text };
    p.document() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return .{ .err = p.failure.? },
    };
    return .{ .ok = .{ .entries = p.entries.items, .comment_lines = p.comments.items } };
}

/// A 1-based line and column in the document.
const Position = struct {
    line: u32,
    column: u32,
};

const Parser = struct {
    arena: Allocator,
    text: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    line_start: usize = 0,
    entries: std.ArrayList(Entry) = .empty,
    comments: std.ArrayList(u32) = .empty,
    failure: ?Error = null,

    const Fail = error{ Invalid, OutOfMemory };

    fn column(p: *const Parser) u32 {
        return @intCast(p.pos - p.line_start + 1);
    }

    fn failAt(p: *Parser, at: Position, comptime fmt: []const u8, args: anytype) Fail {
        p.failure = .{
            .line = at.line,
            .column = at.column,
            .message = try p.arena.print(fmt, args),
        };
        return error.Invalid;
    }

    fn fail(p: *Parser, comptime fmt: []const u8, args: anytype) Fail {
        return p.failAt(.{ .line = p.line, .column = p.column() }, fmt, args);
    }

    fn peek(p: *const Parser) ?u8 {
        return if (p.pos < p.text.len) p.text[p.pos] else null;
    }

    fn atLineEnd(p: *const Parser) bool {
        const c = p.peek() orelse return true;
        if (c == '\n') return true;
        return c == '\r' and p.pos + 1 < p.text.len and p.text[p.pos + 1] == '\n';
    }

    fn newline(p: *Parser) void {
        if (p.peek() == '\r') p.pos += 1;
        if (p.peek() == '\n') p.pos += 1;
        p.line += 1;
        p.line_start = p.pos;
    }

    fn skipSpaces(p: *Parser) void {
        while (p.peek()) |c| {
            if (c != ' ' and c != '\t') return;
            p.pos += 1;
        }
    }

    fn comment(p: *Parser) Fail!void {
        try p.comments.append(p.arena, p.line);
        while (!p.atLineEnd()) p.pos += 1;
    }

    fn document(p: *Parser) Fail!void {
        while (p.pos < p.text.len) {
            p.skipSpaces();
            const c = p.peek() orelse return;
            if (p.atLineEnd()) {
                p.newline();
                continue;
            }
            if (c == '#') {
                try p.comment();
                continue;
            }
            if (c == '[') return p.fail("tables are not supported", .{});
            if (c == '"' or c == '\'') return p.fail("quoted keys are not supported", .{});
            const key_at: Position = .{ .line = p.line, .column = p.column() };
            const start = p.pos;
            while (p.peek()) |k| {
                if (!isBareKeyChar(k)) break;
                p.pos += 1;
            }
            if (p.pos == start) return p.fail("expected a key", .{});
            const key = p.text[start..p.pos];
            p.skipSpaces();
            if (p.peek() == '.') return p.fail("dotted keys are not supported", .{});
            if (p.peek() != '=') return p.fail("expected '=' after the key '{s}'", .{key});
            p.pos += 1;
            p.skipSpaces();
            const v = try p.value();
            p.skipSpaces();
            if (p.peek() == '#') try p.comment();
            if (!p.atLineEnd()) return p.fail("unexpected text after the value of '{s}'", .{key});
            for (p.entries.items) |e| {
                if (std.mem.eql(u8, e.key, key)) return p.failAt(
                    key_at,
                    "duplicate key '{s}'",
                    .{key},
                );
            }
            try p.entries.append(
                p.arena,
                .{ .key = key, .value = v, .line = key_at.line, .column = key_at.column },
            );
        }
    }

    fn startsWith(p: *const Parser, s: []const u8) bool {
        return std.mem.startsWith(u8, p.text[p.pos..], s);
    }

    fn value(p: *Parser) Fail!Value {
        if (p.atLineEnd()) return p.fail("expected a value", .{});
        switch (p.peek().?) {
            '"' => {
                if (p.startsWith("\"\"\"")) return p.fail(
                    "multi-line strings are not supported",
                    .{},
                );
                return .{ .string = try p.basicString() };
            },
            '\'' => {
                if (p.startsWith("'''")) return p.fail("multi-line strings are not supported", .{});
                return .{ .string = try p.literalString() };
            },
            '[' => return .{ .array = try p.array() },
            '{' => return p.fail("inline tables are not supported", .{}),
            else => return p.scalar(),
        }
    }

    fn basicString(p: *Parser) Fail![]const u8 {
        p.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(p.arena);
        while (p.pos < p.text.len) {
            if (p.atLineEnd()) return p.fail("unterminated string", .{});
            const c = p.peek().?;
            if (c == '"') {
                p.pos += 1;
                return out.toOwnedSlice(p.arena);
            }
            if (c == '\\') {
                p.pos += 1;
                const e = p.peek() orelse return p.fail("unterminated string", .{});
                p.pos += 1;
                switch (e) {
                    'b' => try out.append(p.arena, 0x08),
                    't' => try out.append(p.arena, '\t'),
                    'n' => try out.append(p.arena, '\n'),
                    'f' => try out.append(p.arena, 0x0c),
                    'r' => try out.append(p.arena, '\r'),
                    '"' => try out.append(p.arena, '"'),
                    '\\' => try out.append(p.arena, '\\'),
                    'u', 'U' => {
                        const n: usize = if (e == 'u') 4 else 8;
                        if (p.pos + n > p.text.len) return p.fail("invalid unicode escape", .{});
                        const cp = std.fmt.parseInt(u21, p.text[p.pos .. p.pos + n], 16) catch
                            return p.fail("invalid unicode escape", .{});
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &buf) catch
                            return p.fail("invalid unicode escape", .{});
                        try out.appendSlice(p.arena, buf[0..len]);
                        p.pos += n;
                    },
                    else => return p.fail("invalid escape sequence '\\{c}'", .{e}),
                }
                continue;
            }
            if (c < 0x20 and c != '\t') return p.fail("control character in string", .{});
            try out.append(p.arena, c);
            p.pos += 1;
        }
        return p.fail("unterminated string", .{});
    }

    fn literalString(p: *Parser) Fail![]const u8 {
        p.pos += 1;
        const start = p.pos;
        while (!p.atLineEnd()) : (p.pos += 1) {
            if (p.peek().? == '\'') break;
        } else return p.fail("unterminated string", .{});
        const s = p.text[start..p.pos];
        p.pos += 1;
        return s;
    }

    fn skipArrayFiller(p: *Parser) Fail!void {
        while (p.pos < p.text.len) {
            p.skipSpaces();
            const c = p.peek() orelse return;
            if (p.atLineEnd()) {
                p.newline();
                continue;
            }
            if (c == '#') {
                try p.comment();
                continue;
            }
            return;
        }
    }

    fn array(p: *Parser) Fail![]const Item {
        p.pos += 1;
        var items: std.ArrayList(Item) = .empty;
        errdefer items.deinit(p.arena);
        while (p.pos < p.text.len) {
            try p.skipArrayFiller();
            const c = p.peek() orelse return p.fail("unterminated array", .{});
            if (c == ']') {
                p.pos += 1;
                return items.toOwnedSlice(p.arena);
            }
            const line = p.line;
            const col = p.column();
            try items.append(p.arena, .{ .value = try p.value(), .line = line, .column = col });
            try p.skipArrayFiller();
            const d = p.peek() orelse return p.fail("unterminated array", .{});
            if (d == ',') {
                p.pos += 1;
            } else if (d == ']') {
                p.pos += 1;
                return items.toOwnedSlice(p.arena);
            } else return p.fail("expected ',' or ']' in the array", .{});
        }
        return p.fail("unterminated array", .{});
    }

    fn scanToken(p: *Parser) void {
        while (p.peek()) |c| {
            if (isScalarEnd(c)) return;
            p.pos += 1;
        }
    }

    fn scalar(p: *Parser) Fail!Value {
        const at: Position = .{ .line = p.line, .column = p.column() };
        const start = p.pos;
        p.scanToken();
        // TOML allows a space instead of `T` between the date and the time.
        const rest = p.text[p.pos..];
        const spaced_time = p.pos - start == 10 and rest.len > 3 and rest[0] == ' ' and
            std.ascii.isDigit(rest[1]) and std.ascii.isDigit(rest[2]) and rest[3] == ':';
        if (spaced_time) {
            p.pos += 1;
            p.scanToken();
        }
        const tok = p.text[start..p.pos];
        if (tok.len == 0) return p.failAt(at, "expected a value", .{});
        if (std.mem.eql(u8, tok, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, tok, "false")) return .{ .boolean = false };
        if (date.looksLikeDate(tok)) {
            if (tok.len == 10) {
                const d = date.parseDate(tok) orelse {
                    return p.failAt(at, "invalid date '{s}'", .{tok});
                };
                return .{ .date = d };
            }
            return switch (date.parseOffsetDateTime(tok)) {
                .ok => |s| .{ .datetime = .{ .seconds = s, .text = tok } },
                .no_offset => p.failAt(at, "date-times without an offset are not supported, " ++
                    "since machines in different time zones would read them differently: '{s}'", .{
                    tok,
                }),
                .invalid => p.failAt(at, "invalid date-time '{s}'", .{tok}),
            };
        }
        if (tok.len >= 3 and std.ascii.isDigit(tok[0]) and tok[2] == ':') {
            return p.failAt(at, "local times are not supported: '{s}'", .{tok});
        }
        if (isFloat(tok)) return p.failAt(at, "floats are not supported: '{s}'", .{tok});
        const n = std.fmt.parseInt(
            i64,
            tok,
            0,
        ) catch return p.failAt(at, "invalid value '{s}'", .{tok});
        return .{ .integer = n };
    }
};

fn isBareKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

fn isScalarEnd(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', ',', ']', '#' => true,
        else => false,
    };
}

fn isFloat(tok: []const u8) bool {
    const t = std.mem.trimStart(u8, tok, "+-");
    if (std.mem.eql(u8, t, "inf") or std.mem.eql(u8, t, "nan")) return true;
    if (std.mem.startsWith(u8, t, "0x") or std.mem.startsWith(u8, t, "0X")) return false;
    return std.mem.findAny(u8, t, ".eE") != null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectOk(arena: Allocator, text: []const u8) !Document {
    return switch (try parse(arena, text)) {
        .ok => |doc| doc,
        .err => |e| {
            std.debug.print(
                "unexpected TOML error {d}:{d}: {s}\n",
                .{ e.line, e.column, e.message },
            );
            return error.TestUnexpectedResult;
        },
    };
}

fn expectErr(arena: Allocator, text: []const u8, needle: []const u8) !Error {
    switch (try parse(arena, text)) {
        .ok => return error.TestUnexpectedResult,
        .err => |e| {
            if (std.mem.find(u8, e.message, needle) == null) {
                std.debug.print("expected '{s}' in '{s}'\n", .{ needle, e.message });
                return error.TestUnexpectedResult;
            }
            return e;
        },
    }
}

// specrail: specs/format/metadata.spec.md § 2.1 Supported syntax
test "the supported subset parses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const doc = try expectOk(arena,
        \\# a comment
        \\
        \\basic   = "a \"quoted\" \u00a7 string" # trailing comment
        \\literal = 'C:\path'
        \\count   = 1_000
        \\hex     = 0x10
        \\flag    = true
        \\due     = 2027-06-29
        \\until   = 2026-11-17T16:00:00Z
        \\list    = [
        \\  "one",
        \\  'two', # comment inside an array
        \\]
        \\empty   = []
    );
    try testing.expectEqualStrings("a \"quoted\" § string", doc.get("basic").?.value.string);
    try testing.expectEqualStrings("C:\\path", doc.get("literal").?.value.string);
    try testing.expectEqual(@as(i64, 1000), doc.get("count").?.value.integer);
    try testing.expectEqual(@as(i64, 16), doc.get("hex").?.value.integer);
    try testing.expect(doc.get("flag").?.value.boolean);
    try testing.expectEqual(@as(u8, 29), doc.get("due").?.value.date.day);
    try testing.expectEqualStrings("2026-11-17T16:00:00Z", doc.get("until").?.value.datetime.text);
    const list = doc.get("list").?.value.array;
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("two", list[1].value.string);
    try testing.expectEqual(@as(u32, 12), list[1].line);
    try testing.expectEqual(@as(usize, 0), doc.get("empty").?.value.array.len);
    try testing.expectEqualSlices(u32, &.{ 1, 3, 12 }, doc.comment_lines);
}

// specrail: specs/format/metadata.spec.md § 2.2 Unsupported syntax
test "constructs outside the subset are errors that name the construct and its line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = try expectErr(arena, "[table]", "tables");
    _ = try expectErr(arena, "a = { b = 1 }", "inline tables");
    _ = try expectErr(arena, "a.b = 1", "dotted keys");
    _ = try expectErr(arena, "\"a\" = 1", "quoted keys");
    _ = try expectErr(arena, "a = \"\"\"x\"\"\"", "multi-line strings");
    _ = try expectErr(arena, "a = 1.5", "floats");
    _ = try expectErr(arena, "a = 07:30:00", "local times");
    const e = try expectErr(arena, "ok = 1\nb = 2026-11-17T16:00:00", "without an offset");
    try testing.expectEqual(@as(u32, 2), e.line);
}

// specrail: specs/format/metadata.spec.md § 2.3 Duplicate keys
test "a key that appears twice is an error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const e = try expectErr(arena_state.allocator(), "a = 1\nb = 2\na = 3", "duplicate key 'a'");
    try testing.expectEqual(@as(u32, 3), e.line);
}
