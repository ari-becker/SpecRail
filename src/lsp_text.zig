//! Positions and URIs as the Language Server Protocol has them: columns
//! counted in UTF-8 bytes or in UTF-16 code units, and `file:` URIs for paths.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// How columns are counted: by UTF-8 byte or by UTF-16 code unit.
pub const Encoding = enum { utf16, utf8 };

/// The length in bytes of the UTF-8 sequence that starts with `first`; 1 for
/// a byte that cannot start one, so that broken text still advances.
fn sequenceLength(first: u8) usize {
    return std.unicode.utf8ByteSequenceLength(first) catch 1;
}

/// The LSP column of byte offset `byte` in `line`.
pub fn column(line: []const u8, byte: usize, encoding: Encoding) u32 {
    const end = @min(byte, line.len);
    if (encoding == .utf8) return @intCast(end);
    var units: u32 = 0;
    var i: usize = 0;
    while (i < end) {
        const n = sequenceLength(line[i]);
        // Characters outside the Basic Multilingual Plane take two units.
        units += if (n == 4) 2 else 1;
        i += n;
    }
    return units;
}

/// The byte offset in `line` of LSP column `col`; the end of the line when
/// `col` is past it.
pub fn byteOffset(line: []const u8, col: u32, encoding: Encoding) usize {
    if (encoding == .utf8) return @min(col, line.len);
    var units: u32 = 0;
    var i: usize = 0;
    while (i < line.len and units < col) {
        const n = sequenceLength(line[i]);
        units += if (n == 4) 2 else 1;
        i += n;
    }
    return @min(i, line.len);
}

/// Line `index`, counted from 0, of `content`, without its line ending; empty
/// past the last line.
pub fn lineAt(content: []const u8, index: usize) []const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var n: usize = 0;
    while (lines.next()) |l| : (n += 1) {
        if (n == index) return std.mem.trimEnd(u8, l, "\r");
    }
    return "";
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

/// The `file:` URI of the absolute path `path`.
pub fn pathToUri(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    try out.appendSlice(arena, "file://");
    for (path) |c| {
        if (isUnreserved(c) or c == '/') {
            try out.append(arena, c);
        } else {
            try out.print(arena, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(arena);
}

/// The path of a `file:` URI; null for any other URI.
pub fn uriToPath(arena: Allocator, uri: []const u8) Allocator.Error!?[]const u8 {
    const scheme = "file://";
    if (!std.mem.startsWith(u8, uri, scheme)) return null;
    // A host, which file URIs rarely have, ends at the path's first slash.
    const rest = uri[scheme.len..];
    const start = std.mem.findScalar(u8, rest, '/') orelse return null;
    const encoded = rest[start..];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        const c = encoded[i];
        const escape = c == '%' and i + 2 < encoded.len;
        const hex = if (escape) encoded[i + 1 .. i + 3] else "";
        const byte = if (escape) std.fmt.parseInt(u8, hex, 16) catch null else null;
        if (byte) |b| {
            try out.append(arena, b);
            i += 2;
        } else {
            try out.append(arena, c);
        }
    }
    return try out.toOwnedSlice(arena);
}

test "columns count bytes in UTF-8 and code units in UTF-16" {
    const l = "// specrail: a.spec.md § 1 Café 😀 done";
    const sign = std.mem.find(u8, l, "§").?;
    try std.testing.expectEqual(@as(u32, @intCast(sign)), column(l, sign, .utf8));
    try std.testing.expectEqual(@as(u32, @intCast(sign)), column(l, sign, .utf16));
    const after = sign + "§".len;
    try std.testing.expectEqual(@as(u32, @intCast(after)), column(l, after, .utf8));
    try std.testing.expectEqual(@as(u32, @intCast(after - 1)), column(l, after, .utf16));
    const emoji_end = std.mem.find(u8, l, " done").?;
    // § and é take one unit fewer than their bytes, and 😀 two fewer.
    try std.testing.expectEqual(@as(u32, @intCast(emoji_end - 4)), column(l, emoji_end, .utf16));
    try std.testing.expectEqual(emoji_end, byteOffset(l, column(l, emoji_end, .utf16), .utf16));
    try std.testing.expectEqual(after, byteOffset(l, column(l, after, .utf16), .utf16));
    try std.testing.expectEqual(l.len, byteOffset(l, 1000, .utf16));
}

test "file URIs round-trip paths, escaping what URIs cannot hold" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = "/tmp/my specs/a§b.spec.md";
    const uri = try pathToUri(arena, path);
    try std.testing.expectEqualStrings("file:///tmp/my%20specs/a%C2%A7b.spec.md", uri);
    try std.testing.expectEqualStrings(path, (try uriToPath(arena, uri)).?);
    try std.testing.expectEqualStrings("/a/b", (try uriToPath(arena, "file://host/a/b")).?);
    try std.testing.expect((try uriToPath(arena, "untitled:Untitled-1")) == null);
}

test "lines come without their endings" {
    try std.testing.expectEqualStrings("b", lineAt("a\r\nb\r\nc", 1));
    try std.testing.expectEqualStrings("c", lineAt("a\nb\nc", 2));
    try std.testing.expectEqualStrings("", lineAt("a\n", 5));
}

// ---------------------------------------------------------------- fuzz tests

const fuzzing = @import("fuzzing.zig");

/// In both encodings, the byte offset of each character's column is where the
/// character starts, even in text that is not valid UTF-8.
fn columnsAgree(_: void, smith: *std.testing.Smith) !void {
    var buf: [256]u8 = undefined;
    const l = fuzzing.bytes(smith, &buf);
    for ([_]Encoding{ .utf8, .utf16 }) |encoding| {
        var previous: u32 = 0;
        var i: usize = 0;
        // Each step moves past one character, so the loop ends.
        while (i <= l.len) : (i += sequenceLength(l[i])) {
            const col = column(l, i, encoding);
            try std.testing.expect(col >= previous);
            try std.testing.expectEqual(i, byteOffset(l, col, encoding));
            previous = col;
            if (i == l.len) break;
        }
        try std.testing.expectEqual(l.len, byteOffset(l, std.math.maxInt(u32), encoding));
    }
}

// specrail: specs/lsp.spec.md § 1.4 Position encoding
test "fuzz: columns and byte offsets agree in both encodings" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const extra = [_][]const u8{
        fuzzing.sliceSeed("// specrail: a.spec.md § 1 Café 😀 done"),
        fuzzing.sliceSeed("\xf0\x9f\x98"),
        fuzzing.sliceSeed("a\xff\xc3"),
    };
    const corpus = try fuzzing.seeds(arena_state.allocator(), &extra);
    try std.testing.fuzz({}, columnsAgree, .{ .corpus = corpus });
}

/// Any absolute path survives the trip to a URI and back.
fn urisRoundTrip(_: void, smith: *std.testing.Smith) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [128]u8 = undefined;
    const path = try std.mem.concat(arena, u8, &.{ "/", fuzzing.bytes(smith, &buf) });
    const uri = try pathToUri(arena, path);
    try std.testing.expectEqualStrings(path, (try uriToPath(arena, uri)).?);
}

test "fuzz: file URIs round-trip any path" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const extra = [_][]const u8{
        fuzzing.sliceSeed("tmp/my specs/a§b.spec.md"),
        fuzzing.sliceSeed("100%25/%zz/%"),
    };
    const corpus = try fuzzing.seeds(arena_state.allocator(), &extra);
    try std.testing.fuzz({}, urisRoundTrip, .{ .corpus = corpus });
}
