//! loop_bound — no `while (true)` (TigerStyle).
//!
//! Every loop has a limit in reality; the ones written without one are where the tail
//! latency and the hang live. A `for` is bounded by what it walks and a `while (cond)`
//! by its condition, but `while (true)` promises nothing on its first line, and the
//! `break` that ends it may be forty lines down, behind a condition nobody re-read.
//! TigerStyle puts a hard bound on every loop, so that a state nobody foresaw ends
//! the loop rather than the process. This is the subset a rule can hold without
//! proving termination: the loops that declare no bound at all.
//!
//! There is no consent comment. A loop that drains a queue is bounded by the queue's
//! capacity, or by a count it may not exceed per call; a loop that reads a socket is
//! bounded by a deadline or a read count; an event loop runs `while (!stopped)`. Each
//! of those is a condition the loop states on its first line, and breaking early is
//! still allowed.

/// The rule's options, as set in `build.zig`.
pub const Config = struct {
    severity: zlinter.rules.LintProblemSeverity = .warning,
    /// Skip loops inside `test { ... }` blocks.
    exclude_tests: bool = true,
};

/// Builds the rule for zlinter's `addRule`.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return .{ .rule_id = "loop_bound", .run = &run };
}

const message = "`while (true)` declares no bound: loop on a condition, or on a count it may " ++
    "not exceed";

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
        const loop = tree.fullWhile(node) orelse continue;
        if (!std.mem.eql(u8, tree.getNodeSource(loop.ast.cond_expr), "true")) continue;
        if (config.exclude_tests and doc.isEnclosedInTestBlock(session, node)) continue;
        try problems.append(session_arena, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfToken(tree, loop.ast.while_token),
            .end = .endOfToken(tree, tree.lastToken(loop.ast.cond_expr) + 1), // through the `)`
            .message = try session_arena.dupe(u8, message),
        });
    }

    return if (problems.items.len > 0)
        try zlinter.results.LintResult.init(doc.file_id, problems.items)
    else
        null;
}

test "an unbounded loop is flagged; a conditioned one, and a counted one, are not" {
    const rule = buildRule(.{});
    const source =
        \\fn f(n: usize) void {
        \\    while (true) {
        \\        break;
        \\    }
        \\    var i = n;
        \\    while (i > 0) : (i -= 1) {}
        \\    for (0..n) |_| {}
        \\}
        \\test {
        \\    while (true) {}
        \\}
    ;
    // zlinter's lineage iterator hands nodes back last-first: reverse source order.
    try zlinter.testing.testRunRule(rule, source, .{ .filename = "src/example.zig" }, Config{}, &.{
        .{
            .rule_id = "loop_bound",
            .severity = .warning,
            .slice = "while (true)",
            .message = message,
        },
    });
    try zlinter.testing.testRunRule(rule, source, .{
        .filename = "src/example.zig",
    }, Config{ .exclude_tests = false }, &.{
        .{
            .rule_id = "loop_bound",
            .severity = .warning,
            .slice = "while (true)",
            .message = message,
        },
        .{
            .rule_id = "loop_bound",
            .severity = .warning,
            .slice = "while (true)",
            .message = message,
        },
    });
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
