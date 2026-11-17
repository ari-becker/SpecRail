//! recursion_bound — a recursion says what bounds it (TigerStyle).
//!
//! A loop has a condition on its first line; a recursion has its bound wherever the
//! author left it, which is sometimes nowhere. Every recursion in reality ends — on a
//! depth, on a shrinking input, on the stack — and the one that ends on the stack is a
//! crash with a reader-hostile trace. TigerStyle puts it as: no recursion, or a bound
//! stated where there is one.
//!
//! A call of the enclosing function's own name is the recursion this rule can see
//! without a call graph (mutual recursion needs one, and is out of scope). The
//! bound is consent on the call's line — `// bound: <what shrinks, or the depth>` —
//! which a person reads as the argument that it ends.

/// The rule's options, as set in `build.zig`.
pub const Config = struct {
    severity: zlinter.rules.LintProblemSeverity = .warning,
    /// Skip functions declared inside `test { ... }` blocks.
    exclude_tests: bool = true,
};

/// Builds the rule for zlinter's `addRule`.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return .{ .rule_id = "recursion_bound", .run = &run };
}

const consent = "// bound:";
const message = "a recursion without a stated bound: say what makes it end on the call's line (`// bound: ...`)";

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
        const proto, const body = tree.nodeData(node).node_and_node;
        var buffer: [1]Ast.Node.Index = undefined;
        const full = tree.fullFnProto(&buffer, proto) orelse continue;
        const name = tree.tokenSlice(full.name_token orelse continue);

        var calls = try doc.nodeLineageIterator(body, session.runtime.ruleArena());
        defer calls.deinit();
        call_loop: while (try calls.next()) |inner| {
            const call_node, _ = inner;
            var call_buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&call_buffer, call_node) orelse continue :call_loop;
            if (!callsItself(tree.getNodeSource(call.ast.fn_expr), name)) continue :call_loop;
            const call_start = tree.tokenStart(tree.firstToken(call_node));
            const call_end = tree.tokenStart(tree.lastToken(call_node));
            if (markedNear(tree.source, .{ .start = call_start, .end = call_end }, consent)) continue :call_loop;
            try problems.append(session_arena, .{
                .rule_id = rule.rule_id,
                .severity = config.severity,
                .start = .startOfNode(tree, call_node),
                .end = .endOfNode(tree, call_node),
                .message = try session_arena.dupe(u8, message),
            });
        }
    }

    return if (problems.items.len > 0)
        try zlinter.results.LintResult.init(doc.file_id, problems.items)
    else
        null;
}

/// Whether a callee is the enclosing function: `name(...)`, or `self.name(...)` — the
/// same method on the same receiver. `self.field.name(...)` is another object's `name`
/// (every `deinit` calls its fields' `deinit`s), and is not a recursion.
fn callsItself(callee: []const u8, name: []const u8) bool {
    const c = std.mem.trim(u8, callee, " \t\n");
    if (std.mem.eql(u8, c, name)) return true;
    return std.mem.startsWith(u8, c, "self.") and std.mem.eql(u8, c["self.".len..], name);
}

/// A byte range of the source, start to end.
const Span = struct {
    start: usize,
    end: usize,
};

/// Whether the marker sits on the statement — any line the node spans — or on the line
/// above it, the way `zlinter-disable-next-line` does: wrapping a long line must not
/// separate a marker from what it marks.
fn markedNear(source: []const u8, span: Span, marker: []const u8) bool {
    const node_start = span.start;
    const node_end = span.end;
    const first_line = std.mem.findScalarLast(u8, source[0..node_start], '\n') orelse 0;
    const last_line = std.mem.findScalarPos(u8, source, node_end, '\n') orelse source.len;
    if (std.mem.find(u8, source[first_line..last_line], marker) != null) return true;
    // The line above counts only when it is a comment of its own, not the tail of the
    // previous statement.
    if (first_line == 0) return false;
    const above_start = std.mem.findScalarLast(u8, source[0..first_line], '\n') orelse 0;
    const above = std.mem.trim(u8, source[above_start..first_line], " \t\n");
    return std.mem.startsWith(u8, above, "//") and std.mem.find(u8, above, marker) != null;
}

test "a self-call without a bound is flagged; with one, or of another function, it is not" {
    const rule = buildRule(.{});
    const source =
        \\fn walk(n: usize) usize {
        \\    if (n == 0) return 0;
        \\    return walk(n - 1);
        \\}
        \\fn deinit(self: *T) void {
        \\    self.inner.deinit();
        \\}
        \\fn descend(n: usize, depth: usize) usize {
        \\    if (depth > max_depth) return n;
        \\    return descend(n, depth + 1); // bound: max_depth
        \\}
        \\const T = struct {
        \\    fn reach(self: *T, id: u64) bool {
        \\        return self.reach(id + 1);
        \\    }
        \\    fn other(self: *T) bool {
        \\        return self.reach(0);
        \\    }
        \\};
        \\test {
        \\    const S = struct {
        \\        fn f(n: u8) u8 {
        \\            return f(n);
        \\        }
        \\    };
        \\}
    ;
    // zlinter's lineage iterator hands nodes back last-first: reverse source order.
    try zlinter.testing.testRunRule(rule, source, .{ .filename = "src/example.zig" }, Config{}, &.{
        .{ .rule_id = "recursion_bound", .severity = .warning, .slice = "self.reach(id + 1)", .message = message },
        .{ .rule_id = "recursion_bound", .severity = .warning, .slice = "walk(n - 1)", .message = message },
    });
    try zlinter.testing.testRunRule(rule, source, .{ .filename = "src/example.zig" }, Config{ .exclude_tests = false }, &.{
        .{ .rule_id = "recursion_bound", .severity = .warning, .slice = "f(n)", .message = message },
        .{ .rule_id = "recursion_bound", .severity = .warning, .slice = "self.reach(id + 1)", .message = message },
        .{ .rule_id = "recursion_bound", .severity = .warning, .slice = "walk(n - 1)", .message = message },
    });
    try zlinter.testing.testRunRule(rule, source, .{ .filename = "src/example.zig" }, Config{ .severity = .off }, &.{});
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
