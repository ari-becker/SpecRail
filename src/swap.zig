//! `specrail swap`: exchanges two sections, each with its subtree, and
//! rewrites every reference and dependency entry to match.

const std = @import("std");

const cli = @import("cli.zig");
const edit = @import("edit.zig");

const Editor = edit.Editor;
const Error = edit.Error;

/// Help text for `specrail swap --help`.
pub const usage =
    \\Usage: specrail swap <section> <section>
    \\
    \\Exchange two sections, each with its subsections, so that each takes the
    \\other's place and heading level, and rewrite every reference and dependency
    \\entry that names a section whose number or file changed. Sections are given
    \\in reference form, each quoted as one argument, and may be in different
    \\spec files:
    \\
    \\  specrail swap 'specs/a.spec.md § 2 Title' 'specs/a.spec.md § 3 Other'
    \\
    \\swap prints the new address of each section, then each file it changed.
    \\
    \\Options:
    \\  --help   Show this help
    \\
;

/// Plans exchanging the two sections the arguments name.
fn plan(e: *Editor, first_arg: []const u8, second_arg: []const u8) Error!void {
    const a = try e.section(std.mem.trim(u8, first_arg, " \t"));
    const b = try e.section(std.mem.trim(u8, second_arg, " \t"));
    const pa = try e.find(a, "first section");
    const pb = try e.find(b, "second section");
    if (pa.file != pb.file) return swapAcross(e, pa, pb);
    if (pa.index == pb.index) {
        return e.stop(2, "both arguments name § {s} {s}", .{ a.number, a.title });
    }
    if (e.contains(pa, pb) or e.contains(pb, pa)) {
        const msg = "one of § {s} and § {s} lies inside the other; swap exchanges " ++
            "sections where neither is inside the other";
        return e.stop(2, msg, .{ a.number, b.number });
    }
    return swapWithin(e, pa, pb);
}

/// Exchanges two sections in one spec file.
fn swapWithin(e: *Editor, a: edit.Place, b: edit.Place) Error!void {
    const arena = e.ctx.arena;
    var o = try e.outline(a.file);
    const items = o.entries.items;
    const names = [_]edit.Name{ items[a.index].old, items[b.index].old };
    const first = @min(a.index, b.index);
    const second = @max(a.index, b.index);
    const first_end = o.subtreeEnd(first);
    const second_end = o.subtreeEnd(second);
    const first_block = try arena.dupe(edit.Entry, items[first..first_end]);
    const second_block = try arena.dupe(edit.Entry, items[second..second_end]);
    try e.relevel(second_block, items[first].level, .first);
    try e.relevel(first_block, items[second].level, .second);
    const middle = items[first_end..second];
    const swapped = try std.mem.concat(arena, edit.Entry, &.{ second_block, middle, first_block });
    try o.entries.replaceRange(arena, first, second_end - first, swapped);
    return e.finishSections(&.{&o}, &names, .by_position);
}

/// Exchanges two sections in different spec files.
fn swapAcross(e: *Editor, a: edit.Place, b: edit.Place) Error!void {
    const arena = e.ctx.arena;
    var oa = try e.outline(a.file);
    var ob = try e.outline(b.file);
    const a_entry = oa.entries.items[a.index];
    const b_entry = ob.entries.items[b.index];
    const names = [_]edit.Name{ a_entry.old, b_entry.old };
    const a_block = try oa.take(arena, a.index);
    const b_block = try ob.take(arena, b.index);
    try e.relevel(b_block, a_entry.level, .first);
    try e.relevel(a_block, b_entry.level, .first);
    try oa.entries.insertSlice(arena, a.index, b_block);
    try ob.entries.insertSlice(arena, b.index, a_block);
    return e.finishSections(&.{ &oa, &ob }, &names, .by_position);
}

/// Runs `specrail swap` and returns its exit status.
pub fn run(ctx: *cli.Ctx, args: []const []const u8) cli.Error!u8 {
    if (args.len != 2) {
        return cli.usageError(ctx, "swap", "swap takes two sections", .{});
    }
    var e = (try Editor.open(ctx, "swap")) orelse return 2;
    return e.conclude(plan(&e, args[0], args[1]));
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const sandbox = @import("sandbox.zig");

const fixture = edit.fixture;
const login_path = fixture.login_path;
const authProject = fixture.authProject;
const expectChecks = fixture.expectChecks;
const expectUnchanged = fixture.expectUnchanged;

fn runSwap(s: *sandbox.Sandbox, a: []const u8, b: []const u8) !sandbox.Sandbox.Output {
    return s.runAtRoot(&.{ "swap", a, b });
}

// specrail: specs/cli/swap.spec.md § 1.1 Exchange
// specrail: specs/cli/swap.spec.md § 2.5 Report
test "swap exchanges two sections with their subtrees, and what names them follows" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const o = try runSwap(&s, login_path ++ " § 1 Login", login_path ++ " § 2 Logout");
    try testing.expectEqual(@as(u8, 0), o.code);
    try testing.expectEqualStrings(
        \\specs/auth/login.spec.md § 2 Login
        \\specs/auth/login.spec.md § 1 Logout
        \\specs/auth/login.spec.md
        \\specs/other.spec.md
        \\src/t.zig
        \\
    , o.stdout);
    try testing.expectEqualStrings(
        \\# § 1 Logout
        \\
        \\It MUST log out.
        \\
        \\# § 2 Login
        \\
        \\## § 2.1 Password
        \\
        \\It MUST accept a password.
        \\
        \\## § 2.2 Google
        \\
        \\It MUST accept Google.
        \\
    , try s.read(login_path));
    const dependency = "\"specs/auth/login.spec.md § 2.2 Google\"";
    try sandbox.expectContains(try s.read("specs/other.spec.md"), dependency);
    try testing.expectEqualStrings(
        \\// specrail: specs/auth/login.spec.md § 2.1 Password
        \\// specrail: specs/auth/login.spec.md § 2.2 Google
        \\// specrail: specs/auth/login.spec.md § 1 Logout
        \\// specrail: specs/other.spec.md § 1 Waits
        \\
    , try s.read("src/t.zig"));
    try expectChecks(&s);
}

// specrail: specs/cli/swap.spec.md § 1.1 Exchange
test "swapped sections take each other's heading level" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const o = try runSwap(&s, login_path ++ " § 2 Logout", login_path ++ " § 1.1 Password");
    try testing.expectEqual(@as(u8, 0), o.code);
    try testing.expectEqualStrings(
        \\# § 1 Login
        \\
        \\## § 1.1 Logout
        \\
        \\It MUST log out.
        \\
        \\## § 1.2 Google
        \\
        \\It MUST accept Google.
        \\
        \\# § 2 Password
        \\
        \\It MUST accept a password.
        \\
    , try s.read(login_path));
    try expectChecks(&s);
}

// specrail: specs/cli/swap.spec.md § 1.2 Across files
test "swap exchanges sections in different spec files" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const o = try runSwap(&s, login_path ++ " § 2 Logout", "specs/other.spec.md § 1 Waits");
    try testing.expectEqual(@as(u8, 0), o.code);
    const other = "# § 1 Logout\n\nIt MUST log out.\n";
    try testing.expectEqualStrings(other, try s.read("specs/other.spec.md"));
    try sandbox.expectContains(try s.read(login_path),
        \\# § 2 Waits
        \\```toml
        \\dependencies = ["specs/auth/login.spec.md § 1.2 Google"]
        \\```
        \\It MUST wait.
        \\
    );
    const t = try s.read("src/t.zig");
    try sandbox.expectContains(t, "// specrail: specs/other.spec.md § 1 Logout\n");
    try sandbox.expectContains(t, "// specrail: specs/auth/login.spec.md § 2 Waits\n");
    try expectChecks(&s);
}

// specrail: specs/cli/swap.spec.md § 1.3 Sections must match
test "a stale or dangling section changes nothing" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const logout = login_path ++ " § 2 Logout";
    const stale = try runSwap(&s, login_path ++ " § 1 Logn", logout);
    try testing.expectEqual(@as(u8, 1), stale.code);
    try sandbox.expectContains(stale.stderr, "stale first section § 1 Logn");
    const dangling = try runSwap(&s, logout, login_path ++ " § 7 Nope");
    try testing.expectEqual(@as(u8, 1), dangling.code);
    try sandbox.expectContains(dangling.stderr, "dangling second section");
    try expectUnchanged(&s);
}

// specrail: specs/cli/swap.spec.md § 1.4 Nested sections
test "swap refuses a section and itself, or a section and one inside it" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const top = login_path ++ " § 1 Login";
    try testing.expectEqual(@as(u8, 2), (try runSwap(&s, top, top)).code);
    const nested = try runSwap(&s, login_path ++ " § 1.2 Google", top);
    try testing.expectEqual(@as(u8, 2), nested.code);
    try sandbox.expectContains(nested.stderr, "lies inside the other");
    try expectUnchanged(&s);
}

// specrail: specs/cli/swap.spec.md § 2.6 Sections kept
test "a --- swapped into a file without a separator stops swap" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const ruled = "Context.\n\n---\n\n# § 1 One\n\nIt MUST work.\n\n---\n\nMore.\n";
    try s.write("specs/ruled.spec.md", ruled);
    const o = try runSwap(&s, "specs/ruled.spec.md § 1 One", login_path ++ " § 2 Logout");
    try testing.expectEqual(@as(u8, 2), o.code);
    try sandbox.expectContains(o.stderr, "would become its separator");
    try testing.expectEqualStrings(ruled, try s.read("specs/ruled.spec.md"));
    try expectUnchanged(&s);
}

// specrail: specs/cli/swap.spec.md § 2.3 Unparseable files
test "a spec file that ends inside an unclosed code block is not rewritten" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const open = "# § 1 Open\n\n```zig\nconst a = 1;\n";
    try s.write("specs/open.spec.md", open);
    const o = try runSwap(&s, "specs/open.spec.md § 1 Open", login_path ++ " § 2 Logout");
    try testing.expectEqual(@as(u8, 1), o.code);
    try sandbox.expectContains(o.stderr, "this code block is never closed");
    try testing.expectEqualStrings(open, try s.read("specs/open.spec.md"));
    try expectUnchanged(&s);
}

// specrail: specs/cli/swap.spec.md § 1.4 Nested sections
test "a section is inside another by its heading level, whatever its number" {
    // Found by fuzzing: in a file numbered out of order, swap compared
    // numbers, took two nested sections for separate ones, and crashed.
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const odd = "# § 1.2 One\n\nIt MUST work.\n\n## § 1.1.1 Two\n\nIt MUST work.\n";
    try s.write("specs/odd.spec.md", odd);
    const o = try runSwap(&s, "specs/odd.spec.md § 1.2 One", "specs/odd.spec.md § 1.1.1 Two");
    try testing.expectEqual(@as(u8, 2), o.code);
    try sandbox.expectContains(o.stderr, "lies inside the other");
    try testing.expectEqualStrings(odd, try s.read("specs/odd.spec.md"));
}

// specrail: specs/cli/swap.spec.md § 2.1 Below the spec root
test "swap refuses paths, and sections outside the spec root" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const logout = login_path ++ " § 2 Logout";
    const refused = [_][]const u8{
        "../outside.spec.md § 1 X",
        "/outside.spec.md § 1 X",
        "src/t.spec.md § 1 X",
        "specs/other.spec.md",
    };
    for (refused) |arg| {
        const o = try runSwap(&s, logout, arg);
        try testing.expectEqual(@as(u8, 2), o.code);
        try testing.expectEqualStrings("", o.stdout);
    }
    try expectUnchanged(&s);
}

// specrail: specs/cli/swap.spec.md § 2.2 Symbolic links
test "swap refuses to write through a symbolic link" {
    var outside = try sandbox.Sandbox.init();
    defer outside.deinit();
    const reference = "// specrail: specs/auth/login.spec.md § 2 Logout\n";
    try outside.write("linked.zig", reference);
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const target = try std.Io.Dir.path.join(testing.allocator, &.{ outside.root, "linked.zig" });
    defer testing.allocator.free(target);
    try s.symlink(target, "src/linked.zig");
    const o = try runSwap(&s, login_path ++ " § 1 Login", login_path ++ " § 2 Logout");
    try testing.expectEqual(@as(u8, 2), o.code);
    try sandbox.expectContains(o.stderr, "src/linked.zig is a symbolic link");
    try testing.expectEqualStrings(reference, try outside.read("linked.zig"));
    try expectUnchanged(&s);
}

// specrail: specs/cli/swap.spec.md § 2.3 Unparseable files
test "swap refuses to rewrite a spec file whose section tree is broken" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const broken = "## § 1 Deep\n\nIt MUST be deep.\n";
    try s.write("specs/broken.spec.md", broken);
    const o = try runSwap(&s, login_path ++ " § 2 Logout", "specs/broken.spec.md § 1 Deep");
    try testing.expectEqual(@as(u8, 1), o.code);
    try sandbox.expectContains(o.stderr, "must be level 1");
    try testing.expectEqualStrings(broken, try s.read("specs/broken.spec.md"));
    try expectUnchanged(&s);
}

// specrail: specs/cli/swap.spec.md § 2.4 Failed writes
test "when a file cannot be written, swap changes nothing and cleans up" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    // Across files, swap writes the spec file of the first section, then the
    // other's, then src/t.zig. Something already at the second temporary
    // path makes that write fail after the first is staged.
    try s.write("specs/.other.spec.md.1.specrail-tmp/blocker", "");
    const o = try runSwap(&s, login_path ++ " § 2 Logout", "specs/other.spec.md § 1 Waits");
    try testing.expectEqual(@as(u8, 2), o.code);
    try sandbox.expectContains(o.stderr, "nothing was changed");
    try expectUnchanged(&s);
    const other = try s.read("specs/other.spec.md");
    try sandbox.expectContains(other, "# § 1 Waits\n");
    try testing.expect(!s.exists("specs/auth/.login.spec.md.0.specrail-tmp"));
}

// ---------------------------------------------------------------- fuzz tests

const fuzzing = @import("fuzzing.zig");
const fuzzed = edit.fuzzed;

/// Swapping any two sections keeps every reference and dependency entry that
/// named a section exactly, keeps every title and line of prose, and puts
/// each section where swap says; swapping them back restores every heading.
fn swapAndBack(_: void, smith: *testing.Smith) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = try fuzzed.madeUp(smith, arena);
    var e = try Editor.fromProject(try fuzzed.context(arena), "swap", before);
    const a = (try fuzzed.pickSection(smith, arena, &e)) orelse return;
    const b = (try fuzzed.pickSection(smith, arena, &e)) orelse return;
    plan(&e, a, b) catch |err| switch (err) {
        // A refusal changes nothing; it only has to say so.
        error.Stopped => return testing.expect(e.status != 0),
        else => |other| return other,
    };
    const once = try fuzzed.applied(arena, &e);
    errdefer {
        std.debug.print("swap '{s}' '{s}'\n", .{ a, b });
        fuzzed.show(before, once);
    }
    try fuzzed.expectKept(arena, before, once);
    try testing.expectEqual(@as(usize, 2), e.addresses.items.len);
    for (e.addresses.items) |address| try fuzzed.expectLanded(arena, once, address, .by_position);
    const titles_before = try fuzzed.titles(arena, before);
    const titles_once = try fuzzed.titles(arena, once);
    try testing.expectEqual(titles_before.len, titles_once.len);
    for (titles_before, titles_once) |x, y| try testing.expectEqualStrings(x, y);
    // Swapping the two back, at the addresses swap gave, restores every
    // heading's file, level and title, in order.
    var back = try Editor.fromProject(try fuzzed.context(arena), "swap", once);
    plan(&back, e.addresses.items[0], e.addresses.items[1]) catch |err| switch (err) {
        // A spec file swap cannot rewrite may name, by chance, a section the
        // first swap renamed; swapping back would rename it again, so swap
        // refuses, with status 1. Anything else that stops it is a bug.
        error.Stopped => return testing.expectEqual(@as(u8, 1), back.status),
        else => |other| return other,
    };
    const twice = try fuzzed.applied(arena, &back);
    try fuzzed.expectKept(arena, once, twice);
    const outline_before = try fuzzed.outlineOf(arena, before);
    try testing.expectEqualStrings(outline_before, try fuzzed.outlineOf(arena, twice));
}

// specrail: specs/cli/swap.spec.md § 1.1 Exchange
// specrail: specs/cli/swap.spec.md § 1.2 Across files
// specrail: specs/cli/swap.spec.md § 2.5 Report
test "fuzz: two sections swapped keep what names them, and swap back" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const corpus = try fuzzing.seeds(arena_state.allocator(), &.{});
    try testing.fuzz({}, swapAndBack, .{ .corpus = corpus });
}
