//! comment_sentences — a comment is a sentence (TigerStyle).
//!
//! A comment that is prose has been thought about; a scribble has not. TigerStyle asks
//! for a capital letter and a period, and this holds the parts of that a rule can read:
//! a comment block begins like a sentence and ends like one. What it says in between
//! is the reviewer's.
//!
//! A block is the run of comment lines of one kind (`//`, `///` or `//!`). Its first
//! prose line must open with a capital letter, a digit, a quote, a bracket, a backtick,
//! or a code-shaped word — an identifier, a path, a `key = value`, a `name — what it
//! is` title — because `pumpInbound` cannot be capitalised. Its last prose line must
//! close with `.`, `:`, `?`, `!`, a closing bracket, a quote, a backtick or an ellipsis.
//!
//! Not prose, and not read: zlinter directives, specrail references (whose section
//! titles end without a period) and consent markers, banner lines of
//! dashes (a banner's title stands alone), and an indented line after a blank comment
//! line — a diagram, a table, a command — whose shape is the point. An indented line
//! straight after prose is that prose's hanging indent, and continues it.

/// The rule's options, as set in `build.zig`.
pub const Config = struct {
    severity: zlinter.rules.LintProblemSeverity = .warning,
};

/// Builds the rule for zlinter's `addRule`.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return .{ .rule_id = "comment_sentences", .run = &run };
}

const open_message = "a comment is a sentence: this one does not begin like one (a capital, a digit, a quote, a backtick, or an identifier)";
const close_message = "a comment is a sentence: this one does not end like one (`.`, `:`, `?`, `!`, a closing bracket, quote or backtick)";

const Block = struct { start: usize, end: usize, first: ?[]const u8, last: ?[]const u8, banner: bool };

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
    var pos: usize = 0;
    while (pos < source.len) {
        const block = nextBlock(source, &pos) orelse break;
        if (block.first) |first| if (!opensLikeASentence(first)) {
            const found = try problem(rule, config, block, open_message, session_arena);
            try problems.append(session_arena, found);
        };
        if (block.last) |last| if (!block.banner and !closesLikeASentence(last)) {
            const found = try problem(rule, config, block, close_message, session_arena);
            try problems.append(session_arena, found);
        };
    }

    return if (problems.items.len > 0)
        try zlinter.results.LintResult.init(doc.file_id, problems.items)
    else
        null;
}

fn problem(
    rule: zlinter.rules.LintRule,
    config: Config,
    block: Block,
    message: []const u8,
    session_arena: std.mem.Allocator,
) error{OutOfMemory}!zlinter.results.LintProblem {
    return .{
        .rule_id = rule.rule_id,
        .severity = config.severity,
        .start = .{ .byte_offset = block.start },
        .end = .{ .byte_offset = block.end - 1 },
        .message = try session_arena.dupe(u8, message),
    };
}

/// The comment content of a line (after `//`, `///` or `//!`), or null for a line that
/// is not a whole-line comment. `prefix` receives the kind, to keep a block to one kind.
fn commentContent(line: []const u8, prefix: *[]const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, "//")) return null;
    const kind: []const u8 = if (std.mem.startsWith(u8, trimmed, "//!")) "//!" else if (std.mem.startsWith(u8, trimmed, "///") and !std.mem.startsWith(u8, trimmed, "////")) "///" else "//";
    prefix.* = kind;
    return trimmed[kind.len..];
}

/// Whether a content line is prose: not a directive, a marker, a banner, or a diagram —
/// an indented line that does not continue the prose line before it.
fn isProse(content: []const u8, after_prose: bool) bool {
    const t = std.mem.trim(u8, content, " \t");
    if (t.len == 0) return false;
    if (std.mem.startsWith(u8, content, "  ") and !after_prose) return false;
    for ([_][]const u8{ "zlinter-", "specrail:", "bound:", "float", "order:" }) |m| {
        if (std.mem.startsWith(u8, t, m)) return false;
    }
    return !isBanner(t);
}

/// `---`, `===`, or `--- a title ---`.
fn isBanner(t: []const u8) bool {
    if (t.len < 3) return false;
    const c = t[0];
    if (c != '-' and c != '=') return false;
    return t[1] == c and t[2] == c;
}

/// The next comment block at or after `pos`, advancing `pos` past it.
fn nextBlock(source: []const u8, pos: *usize) ?Block {
    var kind: []const u8 = "";
    // Find the first whole-line comment.
    var line_start = pos.*;
    while (line_start < source.len) {
        const line_end = std.mem.findScalarPos(u8, source, line_start, '\n') orelse source.len;
        if (commentContent(source[line_start..line_end], &kind) != null) break;
        line_start = line_end + 1;
    }
    if (line_start >= source.len) return null;
    var block: Block = .{ .start = line_start, .end = line_start, .first = null, .last = null, .banner = false };
    var first_line = true;
    var after_prose = false;
    var at = line_start;
    while (at < source.len) {
        const line_end = std.mem.findScalarPos(u8, source, at, '\n') orelse source.len;
        var this_kind: []const u8 = "";
        const content = commentContent(source[at..line_end], &this_kind) orelse break;
        if (!std.mem.eql(u8, this_kind, kind)) break;
        if (first_line) {
            block.banner = isBanner(std.mem.trim(u8, content, " \t"));
            first_line = false;
        }
        if (isProse(content, after_prose)) {
            const t = std.mem.trim(u8, content, " \t");
            if (block.first == null) block.first = t;
            block.last = t;
            after_prose = true;
        } else {
            after_prose = false;
        }
        block.end = line_end;
        at = line_end + 1;
    }
    pos.* = at;
    return block;
}

fn opensLikeASentence(t: []const u8) bool {
    const c = t[0];
    if (c >= 'A' and c <= 'Z') return true;
    if (c >= '0' and c <= '9') return true;
    if (c >= 0x80) return true; // `§`, `…`, and every other non-ASCII opening
    if (std.mem.findScalar(u8, "`*(\"[", c) != null) return true;
    if (std.mem.startsWith(u8, t, "...")) return true;
    // A code-shaped first word: an identifier, a path, `key = value`, `a → b`.
    const word_end = std.mem.findScalar(u8, t, ' ') orelse t.len;
    const word = t[0..word_end];
    for (word) |w| {
        if (std.mem.findScalar(u8, "_./#=:(){}[]<>'\"`", w) != null) return true;
        if ((w >= 'A' and w <= 'Z') or (w >= '0' and w <= '9') or w >= 0x80) return true;
    }
    // `name — what it is`: a title.
    return std.mem.startsWith(u8, t[word_end..], " — ");
}

fn closesLikeASentence(t: []const u8) bool {
    const c = t[t.len - 1];
    if (std.mem.findScalar(u8, ".:?!)]`\"", c) != null) return true;
    return std.mem.endsWith(u8, t, "…");
}

test "a block that opens or closes unlike a sentence is flagged; identifiers, banners, diagrams and references are not" {
    const rule = buildRule(.{});
    const source =
        \\// A sentence, with a period.
        \\const a = 1;
        \\// lowercase start, and no end
        \\const b = 2;
        \\// pumpInbound may end sessions; so may `x`.
        \\const c = 3;
        \\/// name — what it is:
        \\///
        \\///   a diagram   with   columns
        \\const d = 4;
        \\// --- Tests ---
        \\// -----------------
        \\// A title
        \\// -----------------
        \\// zlinter-disable-next-line no_unsafe_undefined - a directive is not prose
        \\const e = 5;
        \\// Ends with a colon:
        \\//
        \\//   $ a command
        \\const f = 6;
        \\// 1. A hanging indent continues the sentence, so the period is
        \\//    on the second line.
        \\const g = 7;
        \\// specrail: specs/a.spec.md § 1.2 A section title without a period
        \\// specrail: specs/a.spec.md § 1.3 Another title
        \\const h = 8;
    ;
    // zlinter's rules report in source order here: one block, two problems, in order.
    try zlinter.testing.testRunRule(rule, source, .{ .filename = "src/example.zig" }, Config{}, &.{
        .{ .rule_id = "comment_sentences", .severity = .warning, .slice = "// lowercase start, and no end", .message = open_message },
        .{ .rule_id = "comment_sentences", .severity = .warning, .slice = "// lowercase start, and no end", .message = close_message },
    });
    try zlinter.testing.testRunRule(rule, source, .{ .filename = "src/example.zig" }, Config{ .severity = .off }, &.{});
}

const std = @import("std");
const zlinter = @import("zlinter");
