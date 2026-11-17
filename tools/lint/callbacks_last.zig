//! callbacks_last — a callback parameter is the last parameter (TigerStyle).
//!
//! A function that takes a callback hands control to it, and a reader follows control
//! flow: the callback belongs where the call's own body ends, last in the parameter
//! list, the way a trailing block reads. A callback in the middle is read past on the
//! way to the arguments that come after it. TigerStyle puts it as "callbacks go last".
//!
//! A parameter is a callback when its type is a function type, or a pointer to one, or
//! an optional of either. Every function-typed parameter must come after every
//! parameter that is not, so `f(a, cb, b)` is flagged at `cb` and `f(a, b, cb)` and
//! `f(a, cb1, cb2)` are not. An `anytype` parameter is not a function type to the
//! rule, since it is not one to the compiler either.

/// The rule's options, as set in `build.zig`.
pub const Config = struct {
    severity: zlinter.rules.LintProblemSeverity = .warning,
    /// Skip functions declared inside `test { ... }` blocks.
    exclude_tests: bool = false,
};

/// Builds the rule for zlinter's `addRule`.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return .{ .rule_id = "callbacks_last", .run = &run };
}

const message = "a callback parameter goes last, where the control flow it takes over begins";

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
            // Not `fn_decl`: its prototype is visited on its own, and once is enough.
            .fn_proto_simple, .fn_proto_multi, .fn_proto_one, .fn_proto => {},
            else => continue,
        }
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, node) orelse continue;
        if (config.exclude_tests and doc.isEnclosedInTestBlock(session, node)) continue;

        // Walk the parameters, remembering the last callback seen; a non-callback after
        // it is what makes that callback a finding.
        var pending: ?Ast.full.FnProto.Param = null;
        var params = proto.iterate(&tree);
        param_loop: while (params.next()) |param| {
            const type_expr = param.type_expr orelse continue :param_loop;
            if (isFnType(tree, type_expr)) {
                pending = param;
            } else if (pending) |cb| {
                try problems.append(session_arena, .{
                    .rule_id = rule.rule_id,
                    .severity = config.severity,
                    .start = if (cb.name_token) |t| .startOfToken(tree, t) else .startOfNode(tree, cb.type_expr.?),
                    .end = .endOfNode(tree, cb.type_expr.?),
                    .message = try session_arena.dupe(u8, message),
                });
                pending = null;
            }
        }
    }

    return if (problems.items.len > 0)
        try zlinter.results.LintResult.init(doc.file_id, problems.items)
    else
        null;
}

/// Whether a type expression is a function type, through any pointers and optionals.
fn isFnType(tree: Ast, type_expr: Ast.Node.Index) bool {
    var node = type_expr;
    // Each step goes one node deeper into the type, so there are fewer steps than nodes.
    for (0..tree.nodes.len) |_| {
        const tag = tree.nodeTag(node);
        if (tag == .fn_proto_simple or tag == .fn_proto_multi or tag == .fn_proto_one or tag == .fn_proto) {
            return true;
        }
        if (tag == .optional_type) {
            node = tree.nodeData(node).node;
        } else {
            // `fullPtrType` is null for anything that is not a pointer type.
            node = (tree.fullPtrType(node) orelse return false).ast.child_type;
        }
    }
    return false;
}

test "a callback followed by a plain parameter is flagged; last, or followed only by callbacks, is not" {
    const rule = buildRule(.{});
    const source =
        \\const Cb = *const fn (x: u32) void;
        \\fn last(ctx: *anyopaque, cb: *const fn (x: u32) void) void {}
        \\fn first(cb: *const fn (x: u32) void, ctx: *anyopaque) void {}
        \\fn middle(a: u32, done: ?fn (u32) void, b: u32) void {}
        \\fn two(a: u32, cb1: fn () void, cb2: *const fn () void) void {}
        \\fn named(a: u32, cb: Cb, b: u32) void {}
        \\fn none(a: u32, b: anytype) void {}
        \\const V = struct { f: *const fn (a: u32, b: u32) void };
        \\test {
        \\    const inner = struct {
        \\        fn f(cb: fn () void, x: u32) void {}
        \\    };
        \\}
    ;
    // zlinter's lineage iterator hands nodes back last-first: reverse source order.
    // `named` passes: `Cb` is a name, and the rule reads types, not what they resolve to.
    try zlinter.testing.testRunRule(rule, source, .{ .filename = "src/example.zig" }, Config{}, &.{
        .{ .rule_id = "callbacks_last", .severity = .warning, .slice = "cb: fn () void", .message = message },
        .{ .rule_id = "callbacks_last", .severity = .warning, .slice = "done: ?fn (u32) void", .message = message },
        .{ .rule_id = "callbacks_last", .severity = .warning, .slice = "cb: *const fn (x: u32) void", .message = message },
    });
    try zlinter.testing.testRunRule(rule, source, .{ .filename = "src/example.zig" }, Config{ .exclude_tests = true }, &.{
        .{ .rule_id = "callbacks_last", .severity = .warning, .slice = "done: ?fn (u32) void", .message = message },
        .{ .rule_id = "callbacks_last", .severity = .warning, .slice = "cb: *const fn (x: u32) void", .message = message },
    });
    try zlinter.testing.testRunRule(rule, source, .{ .filename = "src/example.zig" }, Config{ .severity = .off }, &.{});
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
