//! div_intent — a division says how it rounds (TigerStyle).
//!
//! `a / b` on integers rounds, and the operator does not say which way, nor whether
//! the author knew it would. `@divExact` says it does not round and traps when it
//! would; `@divFloor`, `@divCeil` and `@divTrunc` say which way — down, up, or toward
//! zero, which is not down on a negative operand. TigerStyle puts it as: show intent
//! with division. The rule reads every `/` and `/=` as the question, and the builtin as
//! the answer.
//!
//! A float ratio has no builtin to reach for — `@divExact` on a float that does not
//! divide evenly is a trap, and floor, ceil and trunc are not what a ratio means — so a line
//! that divides floats says so, on the line or the one above: `// float`. It is the one thing a syntax rule cannot
//! see, and the only marker this rule accepts.

/// The rule's options, as set in `build.zig`.
pub const Config = struct {
    severity: zlinter.rules.LintProblemSeverity = .warning,
    /// Skip divisions inside `test { ... }` blocks.
    exclude_tests: bool = false,
};

/// Builds the rule for zlinter's `addRule`.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return .{ .rule_id = "div_intent", .run = &run };
}

const marker = "// float";
const message = "`/` does not say how it rounds: `@divExact`, `@divFloor`, `@divCeil` or `@divTrunc` does, and a float ratio says `// float`";

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

    const tree = doc.tree(session);
    var it = try doc.nodeLineageIterator(.root, session.runtime.ruleArena());
    defer it.deinit();
    while (try it.next()) |tuple| {
        const node, _ = tuple;
        switch (tree.nodeTag(node)) {
            .div, .assign_div => {},
            else => continue,
        }
        if (config.exclude_tests and doc.isEnclosedInTestBlock(session, node)) continue;
        const span_start = tree.tokenStart(tree.firstToken(node));
        const span_end = tree.tokenStart(tree.lastToken(node));
        if (markedNear(tree.source, .{ .start = span_start, .end = span_end }, marker)) continue;
        try problems.append(session_arena, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfNode(tree, node),
            .end = .endOfNode(tree, node),
            .message = try session_arena.dupe(u8, message),
        });
    }

    return if (problems.items.len > 0)
        try zlinter.results.LintResult.init(doc.file_id, problems.items)
    else
        null;
}

/// A byte range of the source, start to end.
const Span = struct {
    start: usize,
    end: usize,
};

/// Whether the marker sits on the statement — any line the node spans — or on the line
/// above it, the way `zlinter-disable-next-line` does: wrapping a long line must not
/// separate a marker from what it marks.
fn markedNear(source: []const u8, span: Span, needle: []const u8) bool {
    const node_start = span.start;
    const node_end = span.end;
    const first_line = std.mem.findScalarLast(u8, source[0..node_start], '\n') orelse 0;
    const last_line = std.mem.findScalarPos(u8, source, node_end, '\n') orelse source.len;
    if (std.mem.find(u8, source[first_line..last_line], needle) != null) return true;
    // The line above counts only when it is a comment of its own, not the tail of the
    // previous statement.
    if (first_line == 0) return false;
    const above_start = std.mem.findScalarLast(u8, source[0..first_line], '\n') orelse 0;
    const above = std.mem.trim(u8, source[above_start..first_line], " \t\n");
    return std.mem.startsWith(u8, above, "//") and std.mem.find(u8, above, needle) != null;
}

test "a bare division is flagged; a builtin, and a marked float ratio, are not" {
    const rule = buildRule(.{});
    const source =
        \\fn f(a: u32, b: u32, x: f32, y: f32) u32 {
        \\    const half = a / 2;
        \\    const exact = @divExact(a, b);
        \\    const ratio = x / y; // float
        \\    var acc = a;
        \\    acc /= b;
        \\    return half + exact + acc + @as(u32, @intFromFloat(ratio));
        \\}
        \\test {
        \\    const q = 7 / 2;
        \\}
    ;
    // zlinter's lineage iterator hands nodes back last-first: reverse source order.
    try zlinter.testing.testRunRule(rule, source, .{ .filename = "src/example.zig" }, Config{}, &.{
        .{ .rule_id = "div_intent", .severity = .warning, .slice = "7 / 2", .message = message },
        .{ .rule_id = "div_intent", .severity = .warning, .slice = "acc /= b", .message = message },
        .{ .rule_id = "div_intent", .severity = .warning, .slice = "a / 2", .message = message },
    });
    try zlinter.testing.testRunRule(rule, source, .{ .filename = "src/example.zig" }, Config{ .exclude_tests = true }, &.{
        .{ .rule_id = "div_intent", .severity = .warning, .slice = "acc /= b", .message = message },
        .{ .rule_id = "div_intent", .severity = .warning, .slice = "a / 2", .message = message },
    });
    try zlinter.testing.testRunRule(rule, source, .{ .filename = "src/example.zig" }, Config{ .severity = .off }, &.{});
}

const std = @import("std");
const zlinter = @import("zlinter");
