//! no_twin_int_params — two parameters of one integer type are an options struct
//! (TigerStyle).
//!
//! `f(offset, len)` and `f(len, offset)` are the same call to the compiler. A struct
//! parameter with named fields — `f(.{ .offset = o, .len = n })` — makes the transposed
//! call a compile error, which is the only kind of error a transposition should be.
//! TigerStyle puts it as: when two arguments share a type, use an options struct.
//!
//! The rule reads types as written: two parameters whose type text is the same integer
//! type (`u8`, `u32`, `usize`, `i64`, `c_int`, …) flag the function, at the second of
//! them. Two carve-outs. The flat C ABI cannot take a struct, and `(ptr, len)` is its
//! convention, so `export` and `extern` functions and `callconv(.c)` prototypes are not
//! read. And a function whose parameter order is safe for a reason — `min(a, b)`
//! commutes, `seqLess(a, b)` reads as `a < b` — says so on the line of its `fn`:
//! `// order: <reason>` is the consent, and the reason.

/// The rule's options, as set in `build.zig`.
pub const Config = struct {
    severity: zlinter.rules.LintProblemSeverity = .warning,
    /// Skip functions declared inside `test { ... }` blocks.
    exclude_tests: bool = true,
};

/// Builds the rule for zlinter's `addRule`.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return .{ .rule_id = "no_twin_int_params", .run = &run };
}

const consent = "// order:";
const message = "two parameters of one integer type transpose silently: take a struct with named fields, or say why the order is safe (`// order: ...`)";

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
            .fn_proto_simple, .fn_proto_multi, .fn_proto_one, .fn_proto => {},
            else => continue,
        }
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, node) orelse continue;
        if (config.exclude_tests and doc.isEnclosedInTestBlock(session, node)) continue;
        const proto_end = tree.tokenStart(tree.lastToken(proto.ast.proto_node));
        const proto_span: Span = .{ .start = tree.tokenStart(proto.ast.fn_token), .end = proto_end };
        if (markedNear(tree.source, proto_span, consent)) continue;
        if (isCAbi(tree, proto)) continue;

        // Compare every integer-typed parameter against the ones before it; the first
        // pair that matches names the finding, and one finding per function is enough.
        var seen: [32][]const u8 = undefined;
        var n: usize = 0;
        var params = proto.iterate(&tree);
        param_loop: while (params.next()) |param| {
            const type_expr = param.type_expr orelse continue :param_loop;
            const type_text = tree.getNodeSource(type_expr);
            if (!isIntType(type_text)) continue :param_loop;
            var twin = false;
            for (seen[0..n]) |earlier| {
                if (std.mem.eql(u8, earlier, type_text)) twin = true;
            }
            if (twin) {
                try problems.append(session_arena, .{
                    .rule_id = rule.rule_id,
                    .severity = config.severity,
                    .start = if (param.name_token) |t| .startOfToken(tree, t) else .startOfNode(tree, type_expr),
                    .end = .endOfNode(tree, type_expr),
                    .message = try session_arena.dupe(u8, message),
                });
                break;
            }
            if (n < seen.len) {
                seen[n] = type_text;
                n += 1;
            }
        }
    }

    return if (problems.items.len > 0)
        try zlinter.results.LintResult.init(doc.file_id, problems.items)
    else
        null;
}

/// Whether a type, as written, is an integer type: `uN`, `iN`, `usize`, `isize`, or one
/// of the C integer types.
fn isIntType(text: []const u8) bool {
    if (text.len < 2) return false;
    if (std.mem.eql(u8, text, "usize") or std.mem.eql(u8, text, "isize")) return true;
    if (std.mem.startsWith(u8, text, "c_")) {
        for ([_][]const u8{ "c_char", "c_short", "c_ushort", "c_int", "c_uint", "c_long", "c_ulong", "c_longlong", "c_ulonglong" }) |c| {
            if (std.mem.eql(u8, text, c)) return true;
        }
        return false;
    }
    if (text[0] != 'u' and text[0] != 'i') return false;
    for (text[1..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Whether a prototype is the C ABI's: `export`, `extern`, or `callconv(.c)`.
fn isCAbi(tree: Ast, proto: Ast.full.FnProto) bool {
    if (proto.extern_export_inline_token) |t| {
        const tag = tree.tokenTag(t);
        if (tag == .keyword_export or tag == .keyword_extern) return true;
    }
    if (proto.ast.callconv_expr.unwrap()) |cc| {
        if (std.mem.eql(u8, tree.getNodeSource(cc), ".c")) return true;
    }
    return false;
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

test "two parameters of one integer type are flagged at the second; distinct types, structs and consent are not" {
    const rule = buildRule(.{});
    const source =
        \\fn copy(src: []const u8, offset: usize, len: usize) void {}
        \\fn mixed(a: u32, b: u64, c: usize) void {}
        \\fn options(src: []const u8, o: struct { offset: usize, len: usize }) void {}
        \\fn min(a: u32, b: u32) u32 {} // order: commutes
        \\fn three(a: u8, b: u16, c: u8) void {}
        \\fn ints(a: c_int, b: c_int) void {}
        \\fn names(a: Offset, b: Offset) void {}
        \\export fn lib_x(ptr: [*]const u8, len: usize, cap: usize) callconv(.c) usize {}
        \\fn cb(_: ?*anyopaque, a: usize, b: usize) callconv(.c) usize {}
        \\const Cb = *const fn (a: usize, b: usize) callconv(.c) void;
        \\extern fn c_thing(a: c_int, b: c_int) c_int;
        \\test {
        \\    const T = struct {
        \\        fn f(x: u8, y: u8) void {}
        \\    };
        \\}
    ;
    // zlinter's lineage iterator hands nodes back last-first: reverse source order.
    try zlinter.testing.testRunRule(rule, source, .{ .filename = "src/example.zig" }, Config{}, &.{
        .{ .rule_id = "no_twin_int_params", .severity = .warning, .slice = "b: c_int", .message = message },
        .{ .rule_id = "no_twin_int_params", .severity = .warning, .slice = "c: u8", .message = message },
        .{ .rule_id = "no_twin_int_params", .severity = .warning, .slice = "len: usize", .message = message },
    });
    try zlinter.testing.testRunRule(rule, source, .{ .filename = "src/example.zig" }, Config{ .exclude_tests = false }, &.{
        .{ .rule_id = "no_twin_int_params", .severity = .warning, .slice = "y: u8", .message = message },
        .{ .rule_id = "no_twin_int_params", .severity = .warning, .slice = "b: c_int", .message = message },
        .{ .rule_id = "no_twin_int_params", .severity = .warning, .slice = "c: u8", .message = message },
        .{ .rule_id = "no_twin_int_params", .severity = .warning, .slice = "len: usize", .message = message },
    });
    try zlinter.testing.testRunRule(rule, source, .{ .filename = "src/example.zig" }, Config{ .severity = .off }, &.{});
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
