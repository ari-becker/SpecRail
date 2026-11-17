//! qualifier_last — units and qualifiers go last in a name (TigerStyle).
//!
//! `latency_ms_max`, not `max_latency_ms`: the thing first, then its unit, then its
//! qualifier. Related names then line up and sort together — `latency_ms`,
//! `latency_ms_max`, `latency_ms_min` — where a qualifier in front scatters them under
//! `m`. TigerStyle puts it as: place units and qualifiers last, big-endian.
//!
//! The rule reads declarations — a `const` or `var`, a container field, a parameter —
//! whose name begins with one of the qualifiers. A name a protocol's own document
//! spells, `max_data` in RFC 9000's MAX_DATA or `min_rtt` in RFC 9002, is kept as the
//! document spells it and named in `exclude_names`, on the terms `function_naming`
//! keeps the C ABI's names: a reader with the RFC open should find the same words.

/// The rule's options, as set in `build.zig`.
pub const Config = struct {
    severity: zlinter.rules.LintProblemSeverity = .warning,
    /// Qualifiers a name may not begin with.
    prefixes: []const []const u8 = &.{ "max_", "min_", "num_", "count_", "total_", "avg_" },
    /// Names spelled by a protocol's own document, kept as it spells them.
    exclude_names: []const []const u8 = &.{},
    /// Skip declarations inside `test { ... }` blocks.
    exclude_tests: bool = false,
};

/// Builds the rule for zlinter's `addRule`.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return .{ .rule_id = "qualifier_last", .run = &run };
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
    const checker: Checker = .{
        .problems = &problems,
        .session_arena = session_arena,
        .rule = rule,
        .config = config,
        .tree = tree,
    };
    var it = try doc.nodeLineageIterator(.root, session.runtime.ruleArena());
    defer it.deinit();
    while (try it.next()) |tuple| {
        const node, _ = tuple;
        if (config.exclude_tests and doc.isEnclosedInTestBlock(session, node)) continue;
        if (tree.fullVarDecl(node)) |decl| {
            try check(checker, decl.ast.mut_token + 1);
        } else if (tree.fullContainerField(node)) |field| {
            if (!field.ast.tuple_like) {
                try check(checker, field.ast.main_token);
            }
        } else {
            var buffer: [1]Ast.Node.Index = undefined;
            const proto = tree.fullFnProto(&buffer, node) orelse continue;
            switch (tree.nodeTag(node)) {
                .fn_proto_simple, .fn_proto_multi, .fn_proto_one, .fn_proto => {},
                else => continue, // a `fn_decl` is visited again as its prototype
            }
            var params = proto.iterate(&tree);
            param_loop: while (params.next()) |param| {
                const name_token = param.name_token orelse continue :param_loop;
                try check(checker, name_token);
            }
        }
    }

    return if (problems.items.len > 0)
        try zlinter.results.LintResult.init(doc.file_id, problems.items)
    else
        null;
}

/// What `check` needs from the run, besides the name it checks.
const Checker = struct {
    problems: *std.ArrayList(zlinter.results.LintProblem),
    session_arena: std.mem.Allocator,
    rule: zlinter.rules.LintRule,
    config: Config,
    tree: Ast,
};

fn check(c: Checker, name_token: Ast.TokenIndex) !void {
    const problems = c.problems;
    const session_arena = c.session_arena;
    const rule = c.rule;
    const config = c.config;
    const tree = c.tree;
    const name = tree.tokenSlice(name_token);
    const prefix = qualifier(name, config.prefixes) orelse return;
    for (config.exclude_names) |kept| {
        if (std.mem.eql(u8, name, kept)) return;
    }
    try problems.append(session_arena, .{
        .rule_id = rule.rule_id,
        .severity = config.severity,
        .start = .startOfToken(tree, name_token),
        .end = .endOfToken(tree, name_token),
        .message = try session_arena.print(
            "`{s}` puts its qualifier first: units and qualifiers go last (`{s}_{s}`), so " ++
                "related names sort together",
            .{ name, name[prefix.len..], prefix[0 .. prefix.len - 1] },
        ),
    });
}

fn qualifier(name: []const u8, prefixes: []const []const u8) ?[]const u8 {
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, name, p) and name.len > p.len) return p;
    }
    return null;
}

test "qualifier-first consts, fields and parameters are flagged; others and exclusions are not" {
    const rule = buildRule(.{});
    const source =
        \\const max_len = 10;
        \\const len_max = 10;
        \\const S = struct {
        \\    min_rtt: u64,
        \\    num_unacked: u64,
        \\    rtt_min: u64,
        \\};
        \\fn f(total_bytes: usize, bytes_total: usize) void {}
        \\test {
        \\    const avg_ms = 1;
        \\}
    ;
    const kept = Config{ .exclude_names = &.{"min_rtt"} };
    // zlinter's lineage iterator hands nodes back last-first: reverse source order.
    try zlinter.testing.testRunRule(rule, source, .{ .filename = "src/example.zig" }, kept, &.{
        .{
            .rule_id = "qualifier_last",
            .severity = .warning,
            .slice = "avg_ms",
            .message = "`avg_ms` puts its qualifier first: units and qualifiers go last " ++
                "(`ms_avg`), so related names sort together",
        },
        .{
            .rule_id = "qualifier_last",
            .severity = .warning,
            .slice = "total_bytes",
            .message = "`total_bytes` puts its qualifier first: units and qualifiers go last " ++
                "(`bytes_total`), so related names sort together",
        },
        .{
            .rule_id = "qualifier_last",
            .severity = .warning,
            .slice = "num_unacked",
            .message = "`num_unacked` puts its qualifier first: units and qualifiers go last " ++
                "(`unacked_num`), so related names sort together",
        },
        .{
            .rule_id = "qualifier_last",
            .severity = .warning,
            .slice = "max_len",
            .message = "`max_len` puts its qualifier first: units and qualifiers go last " ++
                "(`len_max`), so related names sort together",
        },
    });
    try zlinter.testing.testRunRule(rule, source, .{
        .filename = "src/example.zig",
    }, Config{ .exclude_names = &.{"min_rtt"}, .exclude_tests = true }, &.{
        .{
            .rule_id = "qualifier_last",
            .severity = .warning,
            .slice = "total_bytes",
            .message = "`total_bytes` puts its qualifier first: units and qualifiers go last " ++
                "(`bytes_total`), so related names sort together",
        },
        .{
            .rule_id = "qualifier_last",
            .severity = .warning,
            .slice = "num_unacked",
            .message = "`num_unacked` puts its qualifier first: units and qualifiers go last " ++
                "(`unacked_num`), so related names sort together",
        },
        .{
            .rule_id = "qualifier_last",
            .severity = .warning,
            .slice = "max_len",
            .message = "`max_len` puts its qualifier first: units and qualifiers go last " ++
                "(`len_max`), so related names sort together",
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
const Ast = std.zig.Ast;
