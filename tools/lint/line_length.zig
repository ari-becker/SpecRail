//! line_length — a line fits in 100 columns (TigerStyle).
//!
//! Nothing hidden behind a horizontal scrollbar, and two files side by side on one
//! screen. TigerStyle puts the limit at 100 columns; `zig fmt` holds everything but the
//! width, so this is the one rule of formatting it leaves to a linter. The fix is a
//! trailing comma, which makes `zig fmt` split the list, or a line break after an
//! operator, or a string split with `++` — never a semantic change.
//!
//! Two kinds of line are read as what they are, not as prose: a `zlinter-disable`
//! directive, which zlinter itself requires on one line, and a multiline string
//! literal line (`\\...`), whose bytes are the value. Both are skipped by shape, not
//! by consent.

/// The rule's options, as set in `build.zig`.
pub const Config = struct {
    severity: zlinter.rules.LintProblemSeverity = .warning,
    /// The most columns a line may hold, counted in Unicode codepoints.
    columns_max: u32 = 100,
};

/// Builds the rule for zlinter's `addRule`.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return .{ .rule_id = "line_length", .run = &run };
}

fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    const session_arena = session.runtime.sessionArena();
    var problems = std.ArrayList(zlinter.results.LintProblem).empty;
    errdefer problems.deinit(session_arena);

    const source = doc.source(session);
    var start: usize = 0;
    while (start < source.len) {
        const end = std.mem.findScalarPos(u8, source, start, '\n') orelse source.len;
        const line = source[start..end];
        const columns = std.unicode.utf8CountCodepoints(line) catch line.len;
        if (columns > config.columns_max and !exempt(line)) {
            try problems.append(session_arena, .{
                .rule_id = rule.rule_id,
                .severity = config.severity,
                .start = .{ .byte_offset = start },
                .end = .{ .byte_offset = end - 1 },
                .message = try session_arena.print(
                    "{d} columns; a line fits in {d} — a trailing comma, a break after an operator, or `++`",
                    .{ columns, config.columns_max },
                ),
            });
        }
        start = end + 1;
    }

    return if (problems.items.len > 0)
        try zlinter.results.LintResult.init(doc.file_id, problems.items)
    else
        null;
}

/// A line whose width is not the author's to choose: a zlinter directive, or the
/// content of a multiline string literal.
fn exempt(line: []const u8) bool {
    if (std.mem.find(u8, line, "zlinter-disable") != null) return true;
    return std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "\\\\");
}

test "a long line is flagged with its width; a directive and a string literal line are not" {
    const rule = buildRule(.{});
    const source =
        \\const a = 1; // a comment that runs on and on and on and on and on and on and on and on and on and on and on
        \\const b = 2;
        \\// zlinter-disable-next-line no_unsafe_undefined - a reason that runs on and on and on and on and on and on and on and on
        \\const s =
        \\    \\a string literal line that runs on and on and on and on and on and on and on and on and on and on and on
        \\;
    ;
    const long = "const a = 1; // a comment that runs on and on and on and on and on and on and on and on and on and on and on";
    try zlinter.testing.testRunRule(rule, source, .{ .filename = "src/example.zig" }, Config{}, &.{
        .{ .rule_id = "line_length", .severity = .warning, .slice = long, .message = "108 columns; a line fits in 100 — a trailing comma, a break after an operator, or `++`" },
    });
    try zlinter.testing.testRunRule(rule, source, .{ .filename = "src/example.zig" }, Config{ .columns_max = 120 }, &.{});
    try zlinter.testing.testRunRule(rule, source, .{ .filename = "src/example.zig" }, Config{ .severity = .off }, &.{});
}

const std = @import("std");
const zlinter = @import("zlinter");
