//! fn_length — a function fits on a screen: 70 lines (TigerStyle).
//!
//! A function that fits on a screen is one whose control flow can be checked in one
//! look, with nothing scrolled out of sight. Past that, a reader holds part of it in
//! memory, and what is held in memory is what is misremembered. TigerStyle puts the
//! limit at 70 lines and makes it hard: no carve-outs, because the functions that
//! want one are the ones that need splitting most.
//!
//! The count is every line from the `fn` keyword to the closing brace of the body,
//! comments and blank lines included: they are on the screen too. Doc comments above
//! the `fn` are not counted.

/// The rule's options, as set in `build.zig`.
pub const Config = struct {
    severity: zlinter.rules.LintProblemSeverity = .warning,
    /// The most lines a function may span, `fn` to closing brace inclusive.
    lines_max: u32 = 70,
    /// Skip functions declared inside `test { ... }` blocks.
    exclude_tests: bool = false,
};

/// Builds the rule for zlinter's `addRule`.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return .{ .rule_id = "fn_length", .run = &run };
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

    const tree = doc.tree(session);
    var it = try doc.nodeLineageIterator(.root, session.runtime.ruleArena());
    defer it.deinit();
    while (try it.next()) |tuple| {
        const node, _ = tuple;
        if (tree.nodeTag(node) != .fn_decl) continue;
        if (config.exclude_tests and doc.isEnclosedInTestBlock(session, node)) continue;
        const proto, _ = tree.nodeData(node).node_and_node;
        var buffer: [1]Ast.Node.Index = undefined;
        const full = tree.fullFnProto(&buffer, proto) orelse continue;
        const first = tree.tokenLocation(0, full.ast.fn_token).line;
        const last = tree.tokenLocation(0, tree.lastToken(node)).line;
        const lines: u32 = @intCast(last - first + 1);
        if (lines <= config.lines_max) continue;
        const name = if (full.name_token) |t| tree.tokenSlice(t) else "(anonymous)";
        try problems.append(session_arena, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfToken(tree, full.ast.fn_token),
            .end = .endOfNode(tree, proto),
            .message = try session_arena.print(
                "`{s}` is {d} lines; a function fits on a screen ({d}): split it",
                .{ name, lines, config.lines_max },
            ),
        });
    }

    return if (problems.items.len > 0)
        try zlinter.results.LintResult.init(doc.file_id, problems.items)
    else
        null;
}

test "a function over the limit is flagged with its length; at the limit it is not" {
    const rule = buildRule(.{});
    const source =
        \\/// Doc comments are not counted.
        \\fn long() void {
        \\    // one
        \\    // two
        \\
        \\    // four
        \\}
        \\fn exact() void {
        \\    // one
        \\}
        \\test {
        \\    const T = struct {
        \\        fn inner() void {
        \\            // one
        \\            // two
        \\        }
        \\    };
        \\}
    ;
    // zlinter's lineage iterator hands nodes back last-first: reverse source order.
    try zlinter.testing.testRunRule(rule, source, .{
        .filename = "src/example.zig",
    }, Config{ .lines_max = 3 }, &.{
        .{
            .rule_id = "fn_length",
            .severity = .warning,
            .slice = "fn inner() void",
            .message = "`inner` is 4 lines; a function fits on a screen (3): split it",
        },
        .{
            .rule_id = "fn_length",
            .severity = .warning,
            .slice = "fn long() void",
            .message = "`long` is 6 lines; a function fits on a screen (3): split it",
        },
    });
    try zlinter.testing.testRunRule(rule, source, .{
        .filename = "src/example.zig",
    }, Config{ .lines_max = 3, .exclude_tests = true }, &.{
        .{
            .rule_id = "fn_length",
            .severity = .warning,
            .slice = "fn long() void",
            .message = "`long` is 6 lines; a function fits on a screen (3): split it",
        },
    });
    try zlinter.testing.testRunRule(
        rule,
        source,
        .{ .filename = "src/example.zig" },
        Config{ .lines_max = 6 },
        &.{},
    );
    try zlinter.testing.testRunRule(
        rule,
        source,
        .{ .filename = "src/example.zig" },
        Config{ .severity = .off },
        &.{},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
