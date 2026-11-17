//! `specrail skill`: prints the agent skill compiled into the binary.

const std = @import("std");

const cli = @import("cli.zig");
const refs = @import("refs.zig");

/// The skill, as agent skills are written: YAML front matter, then Markdown.
pub const text = @embedFile("skill.md");

/// Help text for `specrail skill --help`.
pub const usage =
    \\Usage: specrail skill
    \\
    \\Print the agent skill that teaches the specrail workflow, to install
    \\wherever an agent looks for skills, such as .claude/skills/specrail/SKILL.md.
    \\
    \\Options:
    \\  --help   Show this help
    \\
;

/// Runs `specrail skill` and returns its exit status.
pub fn run(ctx: *cli.Ctx) cli.Error!u8 {
    try ctx.stdout.writeAll(text);
    return 0;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const sandbox = @import("sandbox.zig");

fn expectSays(needle: []const u8) !void {
    if (std.mem.find(u8, text, needle) == null) {
        std.debug.print("the skill does not say '{s}'\n", .{needle});
        return error.TestUnexpectedResult;
    }
}

// specrail: specs/cli/skill.spec.md § 1.1 Output
test "the skill starts with front matter that names it and says when to use it" {
    try testing.expect(std.mem.startsWith(u8, text, "---\nname: specrail\ndescription: "));
    const front_matter_end = std.mem.find(u8, text[4..], "\n---\n");
    try testing.expect(front_matter_end != null);
}

// specrail: specs/cli/skill.spec.md § 1.2 Workflow
test "the skill covers references and running check" {
    try expectSays("Run `specrail context <path> § <number>`");
    try expectSays("// specrail: <path> § <number> <title>");
    try expectSays("Run `specrail check`");
    try expectSays("until it passes");
}

// specrail: specs/cli/skill.spec.md § 1.6 Writing specs
test "the skill explains the spec format" {
    try expectSays("parent file");
    try expectSays("a line holding only `---`");
    try expectSays("`## § 1.1 Providers`");
    try expectSays("Requirements live only in leaves");
    try expectSays("uppercase keywords of RFC 2119");
    try expectSays("A metadata block is a fenced `toml` block");
}

// specrail: specs/cli/skill.spec.md § 1.7 Safe to install
test "no line of the skill reads as a reference" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const found = try refs.scanText(arena_state.allocator(), text);
    try testing.expectEqual(@as(usize, 0), found.len);
}

// specrail: specs/cli/skill.spec.md § 1.1 Output
test "skill prints the embedded skill, with or without a project" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    const o = try s.runAtRoot(&.{"skill"});
    try testing.expectEqual(@as(u8, 0), o.code);
    try testing.expectEqualStrings(text, o.stdout);
}
