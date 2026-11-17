//! no_compound_assert — `assert(a and b)` is two assertions (TigerStyle).
//!
//! When a compound assertion fails, the trace names the line, and the line names both
//! halves; which one was false is the first thing anybody wants to know and the one
//! thing the line cannot say. Two `assert`s, one per condition, say it. TigerStyle
//! puts it as "split compound assertions", and there is no reason to keep one:
//! splitting is a pure rewrite, so the rule has no consent comment.
//!
//! A call is an assertion when its callee ends in `assert` — `std.debug.assert`, a
//! local `assert`, or an `assert` reached through any other path — and its single
//! argument is a top-level `and`. An `or` is one condition and passes.

/// The rule's options, as set in `build.zig`.
pub const Config = struct {
    severity: zlinter.rules.LintProblemSeverity = .warning,
    /// Skip assertions inside `test { ... }` blocks.
    exclude_tests: bool = false,
};

/// Builds the rule for zlinter's `addRule`.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return .{ .rule_id = "no_compound_assert", .run = &run };
}

const message = "a compound assertion cannot say which half failed: one `assert` per condition";

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
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (call.ast.params.len != 1) continue;
        if (!isAssert(tree.getNodeSource(call.ast.fn_expr))) continue;
        if (tree.nodeTag(call.ast.params[0]) != .bool_and) continue;
        if (config.exclude_tests and doc.isEnclosedInTestBlock(session, node)) continue;
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

/// Whether a callee is an assertion: its last path component is `assert`.
fn isAssert(callee: []const u8) bool {
    const last = if (std.mem.findScalarLast(u8, callee, '.')) |dot| callee[dot + 1 ..] else callee;
    return std.mem.eql(u8, std.mem.trim(u8, last, " \t\n"), "assert");
}

test "an assert of an `and` is flagged; one condition, an `or`, and other calls are not" {
    const rule = buildRule(.{});
    // The source leaves `std` unimported: zlinter's test session has no Zig lib directory
    // to find it in, and logs an error for each declaration it fails to resolve through it.
    const source =
        \\const assert = std.debug.assert;
        \\fn f(len: usize, out: []u8) void {
        \\    std.debug.assert(len >= 1 and len <= 4);
        \\    assert(out.len >= len and len > 0);
        \\    std.debug.assert(len <= 4);
        \\    std.debug.assert(len == 0 or out.len > 0);
        \\    std.debug.assert((len >= 1 and len <= 4) == true);
        \\    check(len >= 1 and len <= 4);
        \\}
        \\test {
        \\    std.debug.assert(true and true);
        \\}
    ;
    // zlinter's lineage iterator hands nodes back last-first: reverse source order.
    try zlinter.testing.testRunRule(rule, source, .{ .filename = "src/example.zig" }, Config{}, &.{
        .{ .rule_id = "no_compound_assert", .severity = .warning, .slice = "std.debug.assert(true and true)", .message = message },
        .{ .rule_id = "no_compound_assert", .severity = .warning, .slice = "assert(out.len >= len and len > 0)", .message = message },
        .{ .rule_id = "no_compound_assert", .severity = .warning, .slice = "std.debug.assert(len >= 1 and len <= 4)", .message = message },
    });
    try zlinter.testing.testRunRule(rule, source, .{ .filename = "src/example.zig" }, Config{ .exclude_tests = true }, &.{
        .{ .rule_id = "no_compound_assert", .severity = .warning, .slice = "assert(out.len >= len and len > 0)", .message = message },
        .{ .rule_id = "no_compound_assert", .severity = .warning, .slice = "std.debug.assert(len >= 1 and len <= 4)", .message = message },
    });
    try zlinter.testing.testRunRule(rule, source, .{ .filename = "src/example.zig" }, Config{ .severity = .off }, &.{});
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
