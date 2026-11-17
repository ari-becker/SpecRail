//! Diagnostics: `<path>:<line>:<column>: <severity>: <message>`.

const std = @import("std");
const Writer = std.Io.Writer;

/// How serious a diagnostic is. Only errors fail a command.
pub const Severity = enum {
    err,
    note,
    warning,

    /// The word printed in diagnostic lines and JSON.
    pub fn name(s: Severity) []const u8 {
        return switch (s) {
            .err => "error",
            .note => "note",
            .warning => "warning",
        };
    }

    /// Where diagnostics at the same position sort: errors first, then
    /// warnings, then notes.
    pub fn rank(s: Severity) u8 {
        return switch (s) {
            .err => 0,
            .note => 2,
            .warning => 1,
        };
    }

    fn color(s: Severity) []const u8 {
        return switch (s) {
            .err => "\x1b[31m",
            .note => "\x1b[36m",
            .warning => "\x1b[33m",
        };
    }
};

/// A 1-based line and column in a file.
pub const Position = struct {
    line: u32,
    column: u32,
};

/// One problem, located in a file.
pub const Diagnostic = struct {
    /// Relative to the project root.
    path: []const u8,
    line: u32,
    column: u32,
    severity: Severity,
    message: []const u8,
    /// For diagnostics about a reference or dependency entry: the spec file it
    /// names. Used to scope `check` to selected spec files.
    subject: ?[]const u8 = null,
};

/// Diagnostics as they are collected.
pub const List = std.ArrayList(Diagnostic);

fn lessThan(_: void, a: Diagnostic, b: Diagnostic) bool {
    switch (std.mem.order(u8, a.path, b.path)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (a.line != b.line) return a.line < b.line;
    if (a.column != b.column) return a.column < b.column;
    if (a.severity != b.severity) return a.severity.rank() < b.severity.rank();
    return std.mem.order(u8, a.message, b.message) == .lt;
}

/// Sorts by path, then line, then column.
pub fn sort(items: []Diagnostic) void {
    std.mem.sort(Diagnostic, items, {}, lessThan);
}

const bold = "\x1b[1m";
const reset = "\x1b[0m";

/// Writes one diagnostic line, colored when `color` is set.
pub fn write(w: *Writer, d: Diagnostic, color: bool) Writer.Error!void {
    if (color) {
        try w.print(bold ++ "{s}:{d}:{d}:" ++ reset ++ " {s}{s}" ++ reset ++ ": {s}\n", .{
            d.path, d.line, d.column, d.severity.color(), d.severity.name(), d.message,
        });
    } else {
        try w.print("{s}:{d}:{d}: {s}: {s}\n", .{ d.path, d.line, d.column, d.severity.name(), d.message });
    }
}

/// Writes one diagnostic as a JSON object.
pub fn writeJson(w: *Writer, d: Diagnostic) Writer.Error!void {
    try w.writeAll("{\"path\":");
    try std.json.Stringify.encodeJsonString(d.path, .{}, w);
    try w.print(",\"line\":{d},\"column\":{d},\"severity\":\"{s}\",\"message\":", .{ d.line, d.column, d.severity.name() });
    try std.json.Stringify.encodeJsonString(d.message, .{}, w);
    try w.writeAll("}");
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

// specrail: specs/cli/check.spec.md § 3.1 Diagnostic lines
test "a diagnostic line has the shape path:line:column: severity: message" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, .{ .path = "specs/a.spec.md", .line = 3, .column = 1, .severity = .warning, .message = "m" }, false);
    try testing.expectEqualStrings("specs/a.spec.md:3:1: warning: m\n", out.written());
}

// specrail: specs/cli.spec.md § 2.1 Colored diagnostics
test "colored diagnostics put the location in bold and color the severity" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const d: Diagnostic = .{ .path = "p", .line = 1, .column = 2, .severity = .err, .message = "m" };
    try write(&out.writer, d, true);
    try write(&out.writer, .{ .path = "p", .line = 1, .column = 2, .severity = .warning, .message = "m" }, true);
    try write(&out.writer, .{ .path = "p", .line = 1, .column = 2, .severity = .note, .message = "m" }, true);
    try testing.expectEqualStrings(
        "\x1b[1mp:1:2:\x1b[0m \x1b[31merror\x1b[0m: m\n" ++
            "\x1b[1mp:1:2:\x1b[0m \x1b[33mwarning\x1b[0m: m\n" ++
            "\x1b[1mp:1:2:\x1b[0m \x1b[36mnote\x1b[0m: m\n",
        out.written(),
    );
}

// specrail: specs/cli/check.spec.md § 3.2 Stable order
test "diagnostics sort by path, then line, then column" {
    var items = [_]Diagnostic{
        .{ .path = "b", .line = 1, .column = 1, .severity = .err, .message = "6" },
        .{ .path = "a", .line = 2, .column = 1, .severity = .err, .message = "5" },
        .{ .path = "a", .line = 1, .column = 5, .severity = .err, .message = "4" },
        .{ .path = "a", .line = 1, .column = 1, .severity = .note, .message = "3" },
        .{ .path = "a", .line = 1, .column = 1, .severity = .warning, .message = "2" },
        .{ .path = "a", .line = 1, .column = 1, .severity = .err, .message = "1" },
    };
    sort(&items);
    for (items, 0..) |d, i| try testing.expectEqual(@as(u8, '1') + @as(u8, @intCast(i)), d.message[0]);
}
