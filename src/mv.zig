//! `specrail mv`: moves and retitles sections, and moves spec files and
//! directories, rewriting every reference and dependency entry to match.
//! mv never overwrites a file or a section; `specrail swap` exchanges two.

const std = @import("std");

const cli = @import("cli.zig");
const edit = @import("edit.zig");
const files = @import("files.zig");
const refs = @import("refs.zig");

const Editor = edit.Editor;
const Error = edit.Error;
const Outline = edit.Outline;

/// Help text for `specrail mv --help`.
pub const usage =
    \\Usage: specrail mv <from> <to>
    \\       specrail mv <section> --before <section>
    \\       specrail mv <section> --after <section>
    \\
    \\Move or retitle a section, or move a spec file or a directory of specs,
    \\and rewrite every reference and dependency entry that names what moved.
    \\Sections are given in reference form, each quoted as one argument:
    \\
    \\  specrail mv 'specs/a.spec.md § 1.2 Old title' 'specs/a.spec.md § 1.2 New title'
    \\  specrail mv 'specs/a.spec.md § 1.2 Title' 'specs/b.spec.md § 4 Title'
    \\  specrail mv 'specs/a.spec.md § 1.2 Title' --before 'specs/a.spec.md § 1.1 Other'
    \\  specrail mv specs/auth/login.spec.md specs/identity/login.spec.md
    \\
    \\mv never overwrites a file or a section. A destination number must be the
    \\next free number under its parent, counted before the move. To put a
    \\section among others, use --before or --after; to exchange two sections,
    \\use specrail swap.
    \\
    \\Paths are relative to the project root. A spec file moves together with the
    \\directory it is the parent file of, and a directory with its parent file.
    \\mv prints the new address of a section it moved, then each file it changed.
    \\
    \\Options:
    \\  --before <section>   Put the section directly before <section>
    \\  --after <section>    Put the section directly after <section> and its subsections
    \\  --help               Show this help
    \\
;

const spec_suffix = ".spec.md";

/// Where `--before` and `--after` put a section, relative to another.
const Placement = enum { after, before };

/// What `specrail mv` was asked to do.
const Request = struct {
    from: []const u8,
    /// The destination, or the section given to `--before` or `--after`.
    target: []const u8,
    placement: ?Placement = null,
};

fn placementOf(option: []const u8) ?Placement {
    if (std.mem.eql(u8, option, "--before")) return .before;
    if (std.mem.eql(u8, option, "--after")) return .after;
    return null;
}

/// Reads the arguments; null once a usage error has been reported.
fn parse(ctx: *cli.Ctx, args: []const []const u8) cli.Error!?Request {
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(ctx.arena);
    var placement: ?Placement = null;
    var anchor: []const u8 = "";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (!std.mem.startsWith(u8, a, "--")) {
            try positional.append(ctx.arena, a);
            continue;
        }
        const eq = std.mem.findScalar(u8, a, '=');
        const p = placementOf(a[0 .. eq orelse a.len]) orelse {
            _ = try cli.usageError(ctx, "mv", "unknown option '{s}'", .{a});
            return null;
        };
        if (placement != null) {
            _ = try cli.usageError(ctx, "mv", "give only one of --before and --after", .{});
            return null;
        }
        placement = p;
        if (eq) |at| {
            anchor = a[at + 1 ..];
        } else if (i + 1 < args.len) {
            i += 1;
            anchor = args[i];
        } else {
            _ = try cli.usageError(ctx, "mv", "{s} takes a section", .{a});
            return null;
        }
    }
    const wanted: usize = if (placement == null) 2 else 1;
    if (positional.items.len != wanted) {
        const msg = "mv takes what to move, and where: a destination, or --before or --after";
        _ = try cli.usageError(ctx, "mv", msg, .{});
        return null;
    }
    const to = if (placement == null) positional.items[1] else anchor;
    return .{ .from = positional.items[0], .target = to, .placement = placement };
}

/// Plans the move a request names.
fn plan(e: *Editor, r: Request) Error!void {
    const from_text = std.mem.trim(u8, r.from, " \t");
    const to_text = std.mem.trim(u8, r.target, " \t");
    const section_move = edit.isSection(from_text);
    if (section_move != edit.isSection(to_text)) {
        return e.misuse("a section moves to a section, and a path to a path", .{});
    }
    if (!section_move) {
        if (r.placement != null) return e.misuse("--before and --after move sections", .{});
        return movePath(e, from_text, to_text);
    }
    const from = try e.section(from_text);
    const to = try e.section(to_text);
    const placement = r.placement orelse return moveSection(e, from, to);
    return placeSection(e, from, to, placement);
}

/// Plans the move of a spec file or a directory of specs, and of the
/// directory or parent file that goes with it, and the rewriting of every
/// reference and dependency entry that names a moved spec file.
fn movePath(e: *Editor, old_arg: []const u8, new_arg: []const u8) Error!void {
    const old = try e.specPath(old_arg);
    const new = try e.specPath(new_arg);
    const file = std.mem.endsWith(u8, old, spec_suffix);
    if (file != std.mem.endsWith(u8, new, spec_suffix)) {
        const msg = "a spec file moves to a spec file path, and a directory to a directory";
        return e.misuse(msg, .{});
    }
    if (file) {
        try planFile(e, old, new);
    } else {
        try planDirectory(e, old, new);
    }
    for (e.pending.moves.items) |mv| {
        if (try e.pending.exists(mv.new)) {
            return e.stop(2, "{s} already exists; nothing was moved", .{mv.new});
        }
    }
    var paths: edit.Paths = .{};
    for (e.proj.spec_files) |f| {
        const now = try e.pending.finalPath(f.path);
        if (now.ptr != f.path.ptr) try paths.moved.put(e.ctx.arena, f.path, now);
    }
    try e.rewriteAll(paths.rewriter(), &.{});
}

/// Plans the move of a spec file, and of the directory it is the parent file
/// of when there is one.
fn planFile(e: *Editor, old: []const u8, new: []const u8) Error!void {
    const arena = e.ctx.arena;
    if (e.by_path.get(old) == null) return e.stop(2, "there is no spec file {s}", .{old});
    try e.pending.moves.append(arena, .{ .old = old, .new = new });
    // The root file's directory is the spec root itself, which never moves.
    const root = e.proj.config.spec_root;
    const root_file = try std.Io.Dir.path.join(arena, &.{ root, "root.spec.md" });
    if (std.mem.eql(u8, old, root_file)) return;
    const old_dir = old[0 .. old.len - spec_suffix.len];
    if (!try e.pending.isDirectory(old_dir)) return;
    if (files.isUnder(new, old_dir)) {
        return e.misuse("{s} cannot move into {s}, which moves with it", .{ old, old_dir });
    }
    const new_dir = new[0 .. new.len - spec_suffix.len];
    try e.pending.moves.append(arena, .{ .old = old_dir, .new = new_dir });
}

/// Plans the move of a directory, and of its parent file when there is one.
fn planDirectory(e: *Editor, old: []const u8, new: []const u8) Error!void {
    const arena = e.ctx.arena;
    if (!try e.pending.isDirectory(old)) return e.stop(2, "there is no directory {s}", .{old});
    if (files.isUnder(new, old)) return e.misuse("{s} cannot move into itself", .{old});
    try e.pending.moves.append(arena, .{ .old = old, .new = new });
    const old_file = try std.mem.concat(arena, u8, &.{ old, spec_suffix });
    if (e.by_path.get(old_file) == null) return;
    const new_file = try std.mem.concat(arena, u8, &.{ new, spec_suffix });
    try e.pending.moves.append(arena, .{ .old = old_file, .new = new_file });
}

/// Checks the spec file a section moves to, and returns its index; null for
/// a spec file mv creates.
fn destination(e: *Editor, to: refs.Form) Error!?usize {
    if (e.by_path.get(to.path)) |d| {
        if (!e.rewritable(d)) return e.refuse(d);
        return d;
    }
    if (!std.mem.endsWith(u8, to.path, spec_suffix)) {
        return e.misuse("{s} is not a spec file path", .{to.path});
    }
    if (try e.pending.exists(to.path)) {
        return e.stop(2, "{s} exists but is not a spec file mv can write", .{to.path});
    }
    return null;
}

/// The number after the last child of the section numbered `parent`, or of
/// the top level when `parent` is empty, which has `children` children.
fn nextNumber(e: *Editor, parent: []const u8, children: usize) Error![]const u8 {
    if (parent.len == 0) return e.ctx.arena.print("{d}", .{children + 1});
    return e.ctx.arena.print("{s}.{d}", .{ parent, children + 1 });
}

/// Where a section numbered `to.number` goes in `o` as it is now: after the
/// last section under its parent. Stops mv when the parent does not exist,
/// when a section has the number already, or when the number skips one.
fn freeSlot(e: *Editor, o: *const Outline, to: refs.Form) Error!usize {
    const number = to.number;
    const dot = std.mem.findScalarLast(u8, number, '.');
    const parent = if (dot) |d| number[0..d] else "";
    var start: usize = 0;
    var end = o.entries.items.len;
    var child_level: u8 = 1;
    if (dot != null) {
        const numbers = try o.positions(e.ctx.arena);
        const index = for (numbers, 0..) |n, i| {
            if (std.mem.eql(u8, n, parent)) break i;
        } else {
            const msg = "§ {s} cannot go in {s}: it has no § {s}";
            return e.stop(2, msg, .{ number, o.path, parent });
        };
        start = index + 1;
        end = o.subtreeEnd(index);
        child_level = o.entries.items[index].level + 1;
    }
    var children: usize = 0;
    for (o.entries.items[start..end]) |x| {
        if (x.level == child_level) children += 1;
    }
    const next = try nextNumber(e, parent, children);
    const last = number[if (dot) |d| d + 1 else 0..];
    const k = std.fmt.parseInt(usize, last, 10) catch 0;
    if (k == 0 or k > children + 1) {
        const msg = "§ {s} cannot go in {s}: the next free number there is § {s}";
        return e.stop(2, msg, .{ number, o.path, next });
    }
    if (k <= children) {
        const msg = "§ {s} already exists in {s}, and mv does not overwrite sections. " ++
            "The next free number there is § {s}; to put a section among others, use " ++
            "--before or --after, and to exchange two, use specrail swap";
        return e.stop(2, msg, .{ number, o.path, next });
    }
    return end;
}

/// Moves or retitles a section, with its subtree, to a destination number no
/// other section has.
fn moveSection(e: *Editor, from: refs.Form, to: refs.Form) Error!void {
    const source = try e.find(from, "source");
    const same_file = std.mem.eql(u8, from.path, to.path);
    if (same_file and std.mem.eql(u8, from.number, to.number)) {
        return retitle(e, source, to.title);
    }
    if (same_file and edit.isBelow(to.number, from.number)) {
        return e.stop(2, "§ {s} lies inside the subtree being moved", .{to.number});
    }
    const di = try destination(e, to);
    var src = try e.outline(source.file);
    var other: ?Outline = if (same_file)
        null
    else if (di) |d|
        try e.outline(d)
    else
        Outline.empty(to.path, src.newline);
    const dst = if (other) |*o| o else &src;
    const at = try freeSlot(e, dst, to);
    const block = try src.take(e.ctx.arena, source.index);
    try e.relevel(block, refs.depth(to.number), .first);
    block[0].title = to.title;
    // The destination was counted before the section was taken out.
    const index = if (same_file and at > source.index) at - block.len else at;
    return land(e, &src, if (other) |*o| o else null, block, index);
}

/// Moves a section, with its subtree and its title, directly before or after
/// another section, at that section's heading level.
fn placeSection(e: *Editor, from: refs.Form, near: refs.Form, placement: Placement) Error!void {
    const source = try e.find(from, "source");
    const role = switch (placement) {
        .after => "--after section",
        .before => "--before section",
    };
    const target = try e.find(near, role);
    const same_file = source.file == target.file;
    const itself = target.index == source.index or edit.isBelow(near.number, from.number);
    if (same_file and itself) {
        return e.stop(2, "§ {s} cannot go next to itself or a section inside it", .{from.number});
    }
    var src = try e.outline(source.file);
    var other: ?Outline = if (same_file) null else try e.outline(target.file);
    const dst = if (other) |*o| o else &src;
    const level = dst.entries.items[target.index].level;
    const at = switch (placement) {
        .after => dst.subtreeEnd(target.index),
        .before => target.index,
    };
    const block = try src.take(e.ctx.arena, source.index);
    try e.relevel(block, level, .first);
    const index = if (same_file and at > source.index) at - block.len else at;
    return land(e, &src, if (other) |*o| o else null, block, index);
}

/// Inserts a moving block at `index` in the destination outline, which is
/// `other`, or `src` when that is null, and finishes the move.
fn land(
    e: *Editor,
    src: *Outline,
    other: ?*Outline,
    block: []edit.Entry,
    index: usize,
) Error!void {
    const dst = other orelse src;
    try dst.entries.insertSlice(e.ctx.arena, index, block);
    const moved = [_]edit.Name{block[0].old};
    if (other) |o| return e.finishSections(&.{ src, o }, &moved);
    return e.finishSections(&.{src}, &moved);
}

/// Changes a section's title in place.
fn retitle(e: *Editor, source: edit.Place, title: []const u8) Error!void {
    var o = try e.outline(source.file);
    const entry = &o.entries.items[source.index];
    const moved = [_]edit.Name{entry.old};
    entry.title = title;
    return e.finishSections(&.{&o}, &moved);
}

/// Runs `specrail mv` and returns its exit status.
pub fn run(ctx: *cli.Ctx, args: []const []const u8) cli.Error!u8 {
    const request = (try parse(ctx, args)) orelse return 2;
    var e = (try Editor.open(ctx, "mv")) orelse return 2;
    return e.conclude(plan(&e, request));
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const sandbox = @import("sandbox.zig");

const fixture = edit.fixture;
const login = fixture.login;
const login_path = fixture.login_path;
const authProject = fixture.authProject;
const expectChecks = fixture.expectChecks;
const expectUnchanged = fixture.expectUnchanged;

/// Runs `specrail mv` with `args` in the sandbox.
fn runMv(s: *sandbox.Sandbox, args: []const []const u8) !sandbox.Sandbox.Output {
    var argv: [4][]const u8 = .{ "mv", "", "", "" };
    for (args, 1..) |a, i| argv[i] = a;
    return s.runAtRoot(argv[0 .. args.len + 1]);
}

fn expectMoved(s: *sandbox.Sandbox) !void {
    try testing.expect(!s.exists("specs/auth.spec.md"));
    try testing.expect(!s.exists("specs/auth"));
    try testing.expectEqualStrings("Auth context.\n", try s.read("specs/identity.spec.md"));
    try testing.expectEqualStrings(login, try s.read("specs/identity/login.spec.md"));
    const dependency = "\"specs/identity/login.spec.md § 1.2 Google\"";
    try sandbox.expectContains(try s.read("specs/other.spec.md"), dependency);
    const reference = "// specrail: specs/identity/login.spec.md § 2 Logout\n";
    try sandbox.expectContains(try s.read("src/t.zig"), reference);
    try expectChecks(s);
}

// specrail: specs/cli/mv.spec.md § 1.1 Move a spec file
// specrail: specs/cli/mv.spec.md § 4.2 Report
test "a spec file moves with the directory it is the parent of" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const o = try runMv(&s, &.{ "specs/auth.spec.md", "specs/identity.spec.md" });
    try testing.expectEqual(@as(u8, 0), o.code);
    try testing.expectEqualStrings(
        \\specs/identity.spec.md
        \\specs/identity/login.spec.md
        \\specs/other.spec.md
        \\src/t.zig
        \\
    , o.stdout);
    try expectMoved(&s);
}

// specrail: specs/cli/mv.spec.md § 1.2 Move a directory
test "a directory moves with its parent file" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    // Files under the spec root other than spec files move with their
    // directory, and specrail does not read them.
    try s.write("specs/auth/notes.txt", "Notes.\n");
    const o = try runMv(&s, &.{ "specs/auth/", "./specs/identity" });
    try testing.expectEqual(@as(u8, 0), o.code);
    try testing.expectEqualStrings("Notes.\n", try s.read("specs/identity/notes.txt"));
    try expectMoved(&s);
}

// specrail: specs/cli/mv.spec.md § 1.3 Existing destination
test "mv changes nothing when a destination path exists" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    try s.write("specs/identity/notes.md", "In the way.\n");
    const with_dir = try runMv(&s, &.{ "specs/auth.spec.md", "specs/identity.spec.md" });
    try testing.expectEqual(@as(u8, 2), with_dir.code);
    try testing.expectEqualStrings("", with_dir.stdout);
    try sandbox.expectContains(with_dir.stderr, "specs/identity already exists");
    const file = try runMv(&s, &.{ "specs/auth.spec.md", "specs/other.spec.md" });
    try testing.expectEqual(@as(u8, 2), file.code);
    try testing.expect(s.exists("specs/auth.spec.md"));
    try testing.expect(s.exists("specs/auth/login.spec.md"));
    try testing.expectEqualStrings("In the way.\n", try s.read("specs/identity/notes.md"));
}

// specrail: specs/cli/mv.spec.md § 1.4 Root file
test "the root file moves alone, never with the spec root" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const o = try runMv(&s, &.{ "specs/root.spec.md", "specs/overview.spec.md" });
    try testing.expectEqual(@as(u8, 0), o.code);
    try testing.expectEqualStrings("specs/overview.spec.md\n", o.stdout);
    try testing.expectEqualStrings("Root context.\n", try s.read("specs/overview.spec.md"));
    try testing.expect(s.exists(login_path));
}

// specrail: specs/cli/mv.spec.md § 2.1 Source must match
// specrail: specs/cli/mv.spec.md § 4.2 Report
test "a stale or dangling source, or section to go next to, changes nothing" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const stale = try runMv(&s, &.{ login_path ++ " § 1.2 Gogle", login_path ++ " § 3 X" });
    try testing.expectEqual(@as(u8, 1), stale.code);
    try testing.expectEqualStrings("", stale.stdout);
    try sandbox.expectContains(stale.stderr, "stale source § 1.2 Gogle");
    const dangling = try runMv(&s, &.{ login_path ++ " § 9 Nope", login_path ++ " § 3 X" });
    try testing.expectEqual(@as(u8, 1), dangling.code);
    try sandbox.expectContains(dangling.stderr, "dangling source");
    const logout = login_path ++ " § 2 Logout";
    const near = try runMv(&s, &.{ logout, "--after", login_path ++ " § 1.3 Nope" });
    try testing.expectEqual(@as(u8, 1), near.code);
    try sandbox.expectContains(near.stderr, "dangling --after section");
    try expectUnchanged(&s);
}

// specrail: specs/cli/mv.spec.md § 2.2 Retitle
// specrail: specs/cli/mv.spec.md § 4.2 Report
test "a retitled section takes its references and dependency entries along" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const new_name = login_path ++ " § 1.2 Google sign-in";
    const o = try runMv(&s, &.{ login_path ++ " § 1.2 Google", new_name });
    try testing.expectEqual(@as(u8, 0), o.code);
    const report = new_name ++ "\n" ++ login_path ++ "\nspecs/other.spec.md\nsrc/t.zig\n";
    try testing.expectEqualStrings(report, o.stdout);
    const old = "## § 1.2 Google\n";
    const new = "## § 1.2 Google sign-in\n";
    const renamed = try std.mem.replaceOwned(u8, testing.allocator, login, old, new);
    defer testing.allocator.free(renamed);
    try testing.expectEqualStrings(renamed, try s.read(login_path));
    const dependency = "\"specs/auth/login.spec.md § 1.2 Google sign-in\"";
    try sandbox.expectContains(try s.read("specs/other.spec.md"), dependency);
    const reference = "// specrail: specs/auth/login.spec.md § 1.2 Google sign-in\n";
    try sandbox.expectContains(try s.read("src/t.zig"), reference);
    try expectChecks(&s);
}

// specrail: specs/cli/mv.spec.md § 2.3 Move a section
// specrail: specs/cli/mv.spec.md § 4.2 Report
test "a section moves to another file, and what names it follows" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const o = try runMv(&s, &.{ login_path ++ " § 1 Login", "specs/other.spec.md § 2 Login" });
    try testing.expectEqual(@as(u8, 0), o.code);
    try testing.expectEqualStrings(
        \\specs/other.spec.md § 2 Login
        \\specs/auth/login.spec.md
        \\specs/other.spec.md
        \\src/t.zig
        \\
    , o.stdout);
    try testing.expectEqualStrings("# § 1 Logout\n\nIt MUST log out.\n", try s.read(login_path));
    try testing.expectEqualStrings(
        \\# § 1 Waits
        \\```toml
        \\dependencies = ["specs/other.spec.md § 2.2 Google"]
        \\```
        \\It MUST wait.
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
    , try s.read("specs/other.spec.md"));
    try testing.expectEqualStrings(
        \\// specrail: specs/other.spec.md § 2.1 Password
        \\// specrail: specs/other.spec.md § 2.2 Google
        \\// specrail: specs/auth/login.spec.md § 1 Logout
        \\// specrail: specs/other.spec.md § 1 Waits
        \\
    , try s.read("src/t.zig"));
    try expectChecks(&s);
}

// specrail: specs/cli/mv.spec.md § 2.3 Move a section
test "a moved section's heading level follows its new depth" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const up = try runMv(&s, &.{ login_path ++ " § 1.1 Password", login_path ++ " § 3 Password" });
    try testing.expectEqual(@as(u8, 0), up.code);
    const down = try runMv(&s, &.{ login_path ++ " § 2 Logout", login_path ++ " § 1.2 Logout" });
    try testing.expectEqual(@as(u8, 0), down.code);
    try testing.expectEqualStrings(
        \\# § 1 Login
        \\
        \\## § 1.1 Google
        \\
        \\It MUST accept Google.
        \\
        \\## § 1.2 Logout
        \\
        \\It MUST log out.
        \\
        \\# § 2 Password
        \\
        \\It MUST accept a password.
        \\
    , try s.read(login_path));
    const reference = "// specrail: specs/auth/login.spec.md § 2 Password\n";
    try sandbox.expectContains(try s.read("src/t.zig"), reference);
    try expectChecks(&s);
}

// specrail: specs/cli/mv.spec.md § 2.3 Move a section
test "a section moved into a file of context alone gets a separator before it" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const o = try runMv(&s, &.{ login_path ++ " § 2 Logout", "specs/auth.spec.md § 1 Logout" });
    try testing.expectEqual(@as(u8, 0), o.code);
    try testing.expectEqualStrings(
        "Auth context.\n\n---\n\n# § 1 Logout\n\nIt MUST log out.\n",
        try s.read("specs/auth.spec.md"),
    );
    const without = login[0 .. std.mem.find(u8, login, "\n\n# § 2").? + 1];
    try testing.expectEqualStrings(without, try s.read(login_path));
    try expectChecks(&s);
}

const big =
    \\# § 1 Big
    \\
    \\## § 1.1 Part
    \\
    \\### § 1.1.1 Piece
    \\
    \\#### § 1.1.1.1 Bit
    \\
    \\It MUST be a bit.
    \\
    \\#### § 1.1.1.2 Other bit
    \\
    \\It MUST be another bit.
    \\
    \\## § 1.2 Rest
    \\
    \\It MUST rest.
    \\
;

// specrail: specs/cli/mv.spec.md § 2.4 Whole subtree
test "a section moves with every section below it, at any depth" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try s.write("specrail.toml", "spec_root = \"specs\"\n");
    try s.write("specs/big.spec.md", big);
    try s.write("src/t.zig",
        \\// specrail: specs/big.spec.md § 1.1.1.1 Bit
        \\// specrail: specs/big.spec.md § 1.1.1.2 Other bit
        \\// specrail: specs/big.spec.md § 1.2 Rest
        \\
    );
    const part = "specs/big.spec.md § 1.1 Part";
    const o = try runMv(&s, &.{ part, "specs/big/part.spec.md § 1 Part" });
    try testing.expectEqual(@as(u8, 0), o.code);
    try testing.expectEqualStrings(
        \\# § 1 Part
        \\
        \\## § 1.1 Piece
        \\
        \\### § 1.1.1 Bit
        \\
        \\It MUST be a bit.
        \\
        \\### § 1.1.2 Other bit
        \\
        \\It MUST be another bit.
        \\
    , try s.read("specs/big/part.spec.md"));
    const rest = "# § 1 Big\n\n## § 1.1 Rest\n\nIt MUST rest.\n";
    try testing.expectEqualStrings(rest, try s.read("specs/big.spec.md"));
    try testing.expectEqualStrings(
        \\// specrail: specs/big/part.spec.md § 1.1.1 Bit
        \\// specrail: specs/big/part.spec.md § 1.1.2 Other bit
        \\// specrail: specs/big.spec.md § 1.1 Rest
        \\
    , try s.read("src/t.zig"));
    try expectChecks(&s);
}

// specrail: specs/cli/mv.spec.md § 2.5 Existing destination
test "mv never overwrites a section, and points to --before, --after and swap" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const password = login_path ++ " § 1.1 Password";
    const taken = try runMv(&s, &.{ password, login_path ++ " § 1.2 Password" });
    try testing.expectEqual(@as(u8, 2), taken.code);
    try sandbox.expectContains(taken.stderr, "§ 1.2 already exists");
    try sandbox.expectContains(taken.stderr, "next free number there is § 1.3");
    try sandbox.expectContains(taken.stderr, "specrail swap");
    const logout = login_path ++ " § 2 Logout";
    const across = try runMv(&s, &.{ logout, "specs/other.spec.md § 1 Logout" });
    try testing.expectEqual(@as(u8, 2), across.code);
    try expectUnchanged(&s);
}

const four =
    \\# § 1 A
    \\
    \\## § 1.1 A1
    \\
    \\It MUST a.
    \\
    \\# § 2 B
    \\
    \\## § 2.1 B1
    \\
    \\It MUST b.
    \\
    \\# § 3 C
    \\
    \\## § 3.1 C1
    \\
    \\It MUST c.
    \\
;

// specrail: specs/cli/mv.spec.md § 2.6 Valid destination
test "destinations are counted before the move, and must be the next free number" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const from = login_path ++ " § 1.1 Password";
    const orphan = try runMv(&s, &.{ from, login_path ++ " § 9.1 Password" });
    try testing.expectEqual(@as(u8, 2), orphan.code);
    const skipping = try runMv(&s, &.{ from, login_path ++ " § 4 Password" });
    try testing.expectEqual(@as(u8, 2), skipping.code);
    try sandbox.expectContains(skipping.stderr, "the next free number there is § 3");
    const top = login_path ++ " § 1 Login";
    const inside = try runMv(&s, &.{ top, login_path ++ " § 1.3 Login" });
    try testing.expectEqual(@as(u8, 2), inside.code);
    try sandbox.expectContains(inside.stderr, "inside the subtree being moved");
    try expectUnchanged(&s);
    // § 3 is C as the file reads now, so A goes under C, and becomes § 2.2
    // once it has left § 1.
    try s.write("specs/four.spec.md", four);
    const a = "specs/four.spec.md § 1 A";
    const counted = try runMv(&s, &.{ a, "specs/four.spec.md § 3.2 A" });
    try testing.expectEqual(@as(u8, 0), counted.code);
    try sandbox.expectContains(counted.stdout, "specs/four.spec.md § 2.2 A\n");
    const expected = "# § 1 B\n\n## § 1.1 B1\n\nIt MUST b.\n\n# § 2 C\n\n## § 2.1 C1\n\n" ++
        "It MUST c.\n\n## § 2.2 A\n\n### § 2.2.1 A1\n\nIt MUST a.\n";
    try testing.expectEqualStrings(expected, try s.read("specs/four.spec.md"));
}

// specrail: specs/cli/mv.spec.md § 2.7 Moving to a new file
test "a section can start a new spec file at § 1" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const logout = login_path ++ " § 2 Logout";
    const refused = try runMv(&s, &.{ logout, "specs/session.spec.md § 2 Logout" });
    try testing.expectEqual(@as(u8, 2), refused.code);
    try testing.expect(!s.exists("specs/session.spec.md"));
    const o = try runMv(&s, &.{ logout, "specs/session.spec.md § 1 Logout" });
    try testing.expectEqual(@as(u8, 0), o.code);
    const created = try s.read("specs/session.spec.md");
    try testing.expectEqualStrings("# § 1 Logout\n\nIt MUST log out.\n", created);
    const reference = "// specrail: specs/session.spec.md § 1 Logout\n";
    try sandbox.expectContains(try s.read("src/t.zig"), reference);
    try expectChecks(&s);
}

// specrail: specs/cli/mv.spec.md § 2.8 Before and after
test "--before and --after put a section next to another, at its level" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const logout = login_path ++ " § 2 Logout";
    const before = try runMv(&s, &.{ logout, "--before", login_path ++ " § 1.1 Password" });
    try testing.expectEqual(@as(u8, 0), before.code);
    try sandbox.expectContains(before.stdout, login_path ++ " § 1.1 Logout\n");
    const after_login = "--after=" ++ login_path ++ " § 1 Login";
    const after = try runMv(&s, &.{ "specs/other.spec.md § 1 Waits", after_login });
    try testing.expectEqual(@as(u8, 0), after.code);
    try testing.expectEqualStrings(
        \\# § 1 Login
        \\
        \\## § 1.1 Logout
        \\
        \\It MUST log out.
        \\
        \\## § 1.2 Password
        \\
        \\It MUST accept a password.
        \\
        \\## § 1.3 Google
        \\
        \\It MUST accept Google.
        \\
        \\# § 2 Waits
        \\```toml
        \\dependencies = ["specs/auth/login.spec.md § 1.3 Google"]
        \\```
        \\It MUST wait.
        \\
    , try s.read(login_path));
    try testing.expectEqualStrings(
        \\// specrail: specs/auth/login.spec.md § 1.2 Password
        \\// specrail: specs/auth/login.spec.md § 1.3 Google
        \\// specrail: specs/auth/login.spec.md § 1.1 Logout
        \\// specrail: specs/auth/login.spec.md § 2 Waits
        \\
    , try s.read("src/t.zig"));
    try expectChecks(&s);
}

// specrail: specs/cli/mv.spec.md § 2.9 Next to itself
test "a section cannot go next to itself or a section inside it" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const login_section = login_path ++ " § 1 Login";
    const itself = try runMv(&s, &.{ login_section, "--before", login_section });
    try testing.expectEqual(@as(u8, 2), itself.code);
    const child = try runMv(&s, &.{ login_section, "--after", login_path ++ " § 1.2 Google" });
    try testing.expectEqual(@as(u8, 2), child.code);
    try sandbox.expectContains(child.stderr, "next to itself or a section inside it");
    try expectUnchanged(&s);
}

// specrail: specs/cli/mv.spec.md § 3.1 Missing directories
test "mv creates the directories a destination needs" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const logout = login_path ++ " § 2 Logout";
    const section = try runMv(&s, &.{ logout, "specs/split/deeper/logout.spec.md § 1 Logout" });
    try testing.expectEqual(@as(u8, 0), section.code);
    const created = try s.read("specs/split/deeper/logout.spec.md");
    try testing.expectEqualStrings("# § 1 Logout\n\nIt MUST log out.\n", created);
    const file = try runMv(&s, &.{ "specs/auth.spec.md", "specs/a/b/identity.spec.md" });
    try testing.expectEqual(@as(u8, 0), file.code);
    try testing.expectEqualStrings("Auth context.\n", try s.read("specs/a/b/identity.spec.md"));
    try testing.expect(s.exists("specs/a/b/identity/login.spec.md"));
    const reference = "// specrail: specs/a/b/identity/login.spec.md § 1.1 Password\n";
    try sandbox.expectContains(try s.read("src/t.zig"), reference);
    try expectChecks(&s);
}

// specrail: specs/cli/mv.spec.md § 3.2 Below the spec root
test "mv refuses paths that are absolute, climb out with .., or leave the spec root" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const logout = login_path ++ " § 2 Logout";
    const refused = [_][2][]const u8{
        .{ logout, "../outside.spec.md § 1 Logout" },
        .{ logout, "specs/../../outside.spec.md § 1 Logout" },
        .{ logout, "/outside.spec.md § 1 Logout" },
        .{ logout, "docs/outside.spec.md § 1 Logout" },
        .{ "specs/../specs/auth/login.spec.md § 2 Logout", "specs/x.spec.md § 1 Logout" },
        .{ "specs/auth.spec.md", "../identity.spec.md" },
        .{ "specs/auth.spec.md", "/identity.spec.md" },
        .{ "specs/auth.spec.md", "src/identity.spec.md" },
        .{ "specs/auth", "specs/../../identity" },
        .{ "src", "specs/src" },
    };
    for (refused) |args| {
        const o = try runMv(&s, &args);
        try testing.expectEqual(@as(u8, 2), o.code);
        try testing.expectEqualStrings("", o.stdout);
    }
    try expectUnchanged(&s);
    try testing.expect(!s.exists("docs"));
}

// specrail: specs/cli/mv.spec.md § 3.3 Symbolic links
test "mv refuses to move, create or write through a symbolic link" {
    var outside = try sandbox.Sandbox.init();
    defer outside.deinit();
    try outside.write("linked.zig", "// specrail: specs/auth/login.spec.md § 2 Logout\n");
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    try s.symlink(outside.root, "specs/elsewhere");
    const logout = login_path ++ " § 2 Logout";
    const created = try runMv(&s, &.{ logout, "specs/elsewhere/logout.spec.md § 1 Logout" });
    try testing.expectEqual(@as(u8, 2), created.code);
    try sandbox.expectContains(created.stderr, "specs/elsewhere is a symbolic link");
    const moved = try runMv(&s, &.{ "specs/auth.spec.md", "specs/elsewhere/auth.spec.md" });
    try testing.expectEqual(@as(u8, 2), moved.code);
    try testing.expect(!outside.exists("logout.spec.md"));
    try testing.expect(!outside.exists("auth.spec.md"));
    const target = try std.Io.Dir.path.join(testing.allocator, &.{ outside.root, "linked.zig" });
    defer testing.allocator.free(target);
    try s.symlink(target, "src/linked.zig");
    const written = try runMv(&s, &.{ logout, login_path ++ " § 2 Sign out" });
    try testing.expectEqual(@as(u8, 2), written.code);
    try sandbox.expectContains(written.stderr, "src/linked.zig is a symbolic link");
    const untouched = "// specrail: specs/auth/login.spec.md § 2 Logout\n";
    try testing.expectEqualStrings(untouched, try outside.read("linked.zig"));
    try expectUnchanged(&s);
}

// specrail: specs/cli/mv.spec.md § 4.1 Unparseable files
test "mv refuses to rewrite a spec file whose section tree is broken" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const broken = "## § 1 Deep\n\nIt MUST be deep.\n";
    try s.write("specs/broken.spec.md", broken);
    const deep = "specs/broken.spec.md § 1 Deep";
    const in_source = try runMv(&s, &.{ deep, "specs/broken.spec.md § 1 Deeper" });
    try testing.expectEqual(@as(u8, 1), in_source.code);
    try sandbox.expectContains(in_source.stderr, "must be level 1");
    const logout = login_path ++ " § 2 Logout";
    const in_destination = try runMv(&s, &.{ logout, "specs/broken.spec.md § 2 Logout" });
    try testing.expectEqual(@as(u8, 1), in_destination.code);
    const with_dependency = "## § 1 Deep\n```toml\ndependencies = [\"" ++ login_path ++
        " § 2 Logout\"]\n```\nIt MUST be deep.\n";
    try s.write("specs/broken.spec.md", with_dependency);
    const naming = try runMv(&s, &.{ logout, login_path ++ " § 2 Sign out" });
    try testing.expectEqual(@as(u8, 1), naming.code);
    try testing.expectEqualStrings(with_dependency, try s.read("specs/broken.spec.md"));
    try expectUnchanged(&s);
}

// specrail: specs/cli/mv.spec.md § 4.3 Failed writes
test "when a file cannot be written, mv changes nothing and cleans up" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    // A retitle writes the spec file first and then src/t.zig. Something
    // already at src/t.zig's temporary path makes the second write fail
    // after the first is staged.
    try s.write("src/.t.zig.1.specrail-tmp/blocker", "");
    const o = try runMv(&s, &.{ login_path ++ " § 2 Logout", login_path ++ " § 2 Sign out" });
    try testing.expectEqual(@as(u8, 2), o.code);
    try sandbox.expectContains(o.stderr, "cannot write src/t.zig");
    try sandbox.expectContains(o.stderr, "nothing was changed");
    try expectUnchanged(&s);
    try testing.expect(!s.exists("specs/auth/.login.spec.md.0.specrail-tmp"));
    try testing.expect(s.exists("src/.t.zig.1.specrail-tmp/blocker"));
}
