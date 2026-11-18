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
    var src = try e.outline(source.file);
    // The destination number counts sections by position, so it is compared
    // with the number the source's position gives it, not the one written.
    const source_number = (try src.positions(e.ctx.arena))[source.index];
    if (same_file and edit.isBelow(to.number, source_number)) {
        return e.stop(2, "§ {s} lies inside the subtree being moved", .{to.number});
    }
    const di = try destination(e, to);
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
    const itself = target.index == source.index or e.contains(source, target);
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
    if (other) |o| return e.finishSections(&.{ src, o }, &moved, .by_position);
    return e.finishSections(&.{src}, &moved, .by_position);
}

/// Changes a section's title in place.
fn retitle(e: *Editor, source: edit.Place, title: []const u8) Error!void {
    const file = &e.specs[source.file];
    const number = file.sections[source.index].number;
    if (file.titleTaken(source.index, number, title)) {
        const msg = "§ {s} {s} already exists in {s}, and mv does not overwrite sections";
        return e.stop(2, msg, .{ number, title, file.path });
    }
    var o = try e.outline(source.file);
    const entry = &o.entries.items[source.index];
    const moved = [_]edit.Name{entry.old};
    entry.title = title;
    // A retitle changes one heading; renumbering the file is fmt's to do.
    return e.finishSections(&.{&o}, &moved, .as_written);
}

/// Plans `specrail mv <from> <to>` on an editor already open, writing
/// nothing. The language server's rename is checked against it.
pub fn planMove(e: *Editor, from: []const u8, to: []const u8) Error!void {
    return plan(e, .{ .from = from, .target = to });
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
// specrail: specs/cli/mv.spec.md § 4.2 Report
test "a directory moves with its parent file, and every file in it is reported" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    // Files under the spec root other than spec files move with their
    // directory, and specrail does not read them, even those git ignores.
    try s.write("specs/auth/notes.txt", "Notes.\n");
    try s.write("specs/auth/drafts/old.log", "Old.\n");
    try s.write(".gitignore", "*.log\n");
    const o = try runMv(&s, &.{ "specs/auth/", "./specs/identity" });
    try testing.expectEqual(@as(u8, 0), o.code);
    try testing.expectEqualStrings(
        \\specs/identity.spec.md
        \\specs/identity/drafts/old.log
        \\specs/identity/login.spec.md
        \\specs/identity/notes.txt
        \\specs/other.spec.md
        \\src/t.zig
        \\
    , o.stdout);
    try testing.expectEqualStrings("Notes.\n", try s.read("specs/identity/notes.txt"));
    try testing.expectEqualStrings("Old.\n", try s.read("specs/identity/drafts/old.log"));
    try expectMoved(&s);
}

// specrail: specs/cli/mv.spec.md § 4.2 Report
test "a directory whose files cannot be listed is not moved" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    try s.write("specs/auth/private/key.txt", "Key.\n");
    const dir = s.tmp.dir;
    try dir.setFilePermissions(testing.io, "specs/auth/private", .fromMode(0o000), .{});
    // Wherever the directory ends up, it must be readable again to be removed.
    const readable: std.Io.File.Permissions = .fromMode(0o755);
    defer dir.setFilePermissions(testing.io, "specs/auth/private", readable, .{}) catch {};
    defer dir.setFilePermissions(testing.io, "specs/identity/private", readable, .{}) catch {};
    // A user who can read it anyway, such as root, cannot run this test.
    const opened = dir.openDir(testing.io, "specs/auth/private", .{ .iterate = true });
    const listable = if (opened) |d| yes: {
        d.close(testing.io);
        break :yes true;
    } else |_| false;
    if (listable) return error.SkipZigTest;
    const o = try runMv(&s, &.{ "specs/auth", "specs/identity" });
    try testing.expectEqual(@as(u8, 2), o.code);
    try testing.expectEqualStrings("", o.stdout);
    try sandbox.expectContains(o.stderr, "cannot list the files in specs/auth");
    try expectUnchanged(&s);
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

// specrail: specs/cli/mv.spec.md § 2.2 Retitle
test "a retitle renumbers nothing, even in a file numbered out of order" {
    // Found by fuzzing the language server's rename, which kept the numbers
    // that mv's retitle renumbered by position.
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    try s.write("specs/odd.spec.md", "# § 2 One\n\nIt MUST work.\n\n# § 1 Two\n\nIt MUST work.\n");
    const o = try runMv(&s, &.{ "specs/odd.spec.md § 2 One", "specs/odd.spec.md § 2 First" });
    try testing.expectEqual(@as(u8, 0), o.code);
    try testing.expectEqualStrings("specs/odd.spec.md § 2 First\nspecs/odd.spec.md\n", o.stdout);
    const renamed = "# § 2 First\n\nIt MUST work.\n\n# § 1 Two\n\nIt MUST work.\n";
    try testing.expectEqualStrings(renamed, try s.read("specs/odd.spec.md"));
    // Found by fuzzing the rename too: a heading kept its line ending there,
    // and took the file's here.
    const mixed = "# § 1 One\n\nIt MUST work.\r\n\r\n# § 2 Two\r\n\r\nIt MUST work.\r\n";
    try s.write("specs/mixed.spec.md", mixed);
    const two = "specs/mixed.spec.md § 2 Two";
    const retitled = try runMv(&s, &.{ two, "specs/mixed.spec.md § 2 Second" });
    try testing.expectEqual(@as(u8, 0), retitled.code);
    const second = "# § 1 One\n\nIt MUST work.\r\n\r\n# § 2 Second\r\n\r\nIt MUST work.\r\n";
    try testing.expectEqualStrings(second, try s.read("specs/mixed.spec.md"));
    // Found by fuzzing too: keeping the numbers, a retitle could duplicate a
    // heading that a file numbered out of order already has.
    const twice = "# § 1 Two\n\nIt MUST work.\n\n# § 1 One\n\nIt MUST work.\n";
    try s.write("specs/twice.spec.md", twice);
    const taken = try runMv(&s, &.{ "specs/twice.spec.md § 1 Two", "specs/twice.spec.md § 1 One" });
    try testing.expectEqual(@as(u8, 2), taken.code);
    try sandbox.expectContains(taken.stderr, "§ 1 One already exists");
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

// specrail: specs/cli/mv.spec.md § 4.1 Unparseable files
test "a dependency entry mv cannot rewrite stops it, rather than going stale" {
    // Found by fuzzing: the entry sat in a metadata block that is never
    // closed, which check reads and mv skipped.
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const entry = "dependencies = [\"" ++ login_path ++ " § 1.2 Google\"]\n";
    const broken = "# § 1 Waits too\n```toml\n" ++ entry;
    try s.write("specs/broken.spec.md", broken);
    const google = login_path ++ " § 1.2 Google";
    const retitled = try runMv(&s, &.{ google, login_path ++ " § 1.2 Gmail" });
    try testing.expectEqual(@as(u8, 1), retitled.code);
    try sandbox.expectContains(retitled.stderr, "specs/broken.spec.md has errors");
    const moved = try runMv(&s, &.{ login_path, "specs/identity/login.spec.md" });
    try testing.expectEqual(@as(u8, 1), moved.code);
    try testing.expectEqualStrings(broken, try s.read("specs/broken.spec.md"));
    try expectUnchanged(&s);
}

// specrail: specs/cli/mv.spec.md § 4.1 Unparseable files
test "a spec file that ends inside an unclosed code block is not rewritten" {
    // Found by fuzzing: the section that held the open block took it along,
    // and the sections after it in its new file became code.
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const open = "# § 1 Open\n\n```zig\nconst a = 1;\n";
    try s.write("specs/open.spec.md", open);
    const open_section = "specs/open.spec.md § 1 Open";
    const logout = login_path ++ " § 2 Logout";
    const out = try runMv(&s, &.{ open_section, "--before", logout });
    try testing.expectEqual(@as(u8, 1), out.code);
    try sandbox.expectContains(out.stderr, "this code block is never closed");
    const in = try runMv(&s, &.{ logout, "--after", open_section });
    try testing.expectEqual(@as(u8, 1), in.code);
    try testing.expectEqualStrings(open, try s.read("specs/open.spec.md"));
    try expectUnchanged(&s);
}

// specrail: specs/cli/mv.spec.md § 2.6 Valid destination
// specrail: specs/cli/mv.spec.md § 2.9 Next to itself
test "a section is inside another by its heading level, whatever its number" {
    // Found by fuzzing, in swap: in a file numbered out of order, comparing
    // numbers took a section inside another for one beside it.
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try authProject(&s);
    const odd = "# § 5 One\n\nIt MUST work.\n\n## § 1.1.1 Two\n\nIt MUST work.\n";
    try s.write("specs/odd.spec.md", odd);
    const one = "specs/odd.spec.md § 5 One";
    const next_to = try runMv(&s, &.{ one, "--after", "specs/odd.spec.md § 1.1.1 Two" });
    try testing.expectEqual(@as(u8, 2), next_to.code);
    try sandbox.expectContains(next_to.stderr, "cannot go next to itself or a section inside it");
    // By position, § 5 One is § 1, so § 1.2 lies inside it.
    const inside = try runMv(&s, &.{ one, "specs/odd.spec.md § 1.2 One" });
    try testing.expectEqual(@as(u8, 2), inside.code);
    try sandbox.expectContains(inside.stderr, "lies inside the subtree being moved");
    try testing.expectEqualStrings(odd, try s.read("specs/odd.spec.md"));
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

// ---------------------------------------------------------------- fuzz tests

const fuzzing = @import("fuzzing.zig");
const fuzzed = edit.fuzzed;

/// The number after `number` among its siblings: `1.3` after `1.2`.
fn nextSibling(arena: std.mem.Allocator, number: []const u8) ![]const u8 {
    const dot = std.mem.findScalarLast(u8, number, '.');
    const last = number[if (dot) |d| d + 1 else 0..];
    const n = (std.fmt.parseInt(u32, last, 10) catch 0) + 1;
    const parent = if (dot) |d| number[0 .. d + 1] else "";
    return arena.print("{s}{d}", .{ parent, n });
}

/// A destination for a section: in either spec file or a new one, under a
/// section there or after one, often the next free number, with the
/// section's title or another.
fn madeUpDestination(
    smith: *testing.Smith,
    arena: std.mem.Allocator,
    e: *const Editor,
    from: refs.Form,
) ![]const u8 {
    const paths = fuzzing.spec_paths ++ [_][]const u8{"specs/c.spec.md"};
    const path = fuzzing.pick(smith, &paths);
    var number: []const u8 = try arena.print("{d}", .{smith.valueRangeAtMost(u8, 1, 4)});
    if (e.by_path.get(path)) |fi| {
        const sections = e.specs[fi].sections;
        if (sections.len > 0 and smith.boolWeighted(1, 4)) {
            const near = sections[smith.index(sections.len)].number;
            number = if (smith.value(bool))
                try arena.print("{s}.1", .{near})
            else
                try nextSibling(arena, near);
        }
    }
    const title = if (smith.value(bool)) from.title else fuzzing.pick(smith, &fuzzing.titles);
    return arena.print("{s} {s} {s} {s}", .{ path, refs.section_sign, number, title });
}

/// A request to move or retitle the section `from`.
fn madeUpRequest(
    smith: *testing.Smith,
    arena: std.mem.Allocator,
    e: *const Editor,
    from: []const u8,
) !?Request {
    const form = switch (refs.parseForm(from, .required)) {
        .ok => |f| f,
        .err => return error.TestUnexpectedResult,
    };
    switch (smith.valueRangeAtMost(u8, 0, 3)) {
        0 => {
            const title = fuzzing.pick(smith, &fuzzing.titles);
            const parts = .{ form.path, refs.section_sign, form.number, title };
            return .{ .from = from, .target = try arena.print("{s} {s} {s} {s}", parts) };
        },
        1 => return .{ .from = from, .target = try madeUpDestination(smith, arena, e, form) },
        else => {
            const near = (try fuzzed.pickSection(smith, arena, e)) orelse return null;
            const placement: Placement = if (smith.value(bool)) .before else .after;
            return .{ .from = from, .target = near, .placement = placement };
        },
    }
}

/// Wherever a section is moved, retitled or placed, every reference and
/// dependency entry that named a section exactly still does, no prose or
/// title is lost, and the section is where mv says, in a file numbered in
/// order.
fn moveAnySection(_: void, smith: *testing.Smith) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = try fuzzed.madeUp(smith, arena);
    var e = try Editor.fromProject(try fuzzed.context(arena), "mv", before);
    const from = (try fuzzed.pickSection(smith, arena, &e)) orelse return;
    const request = (try madeUpRequest(smith, arena, &e, from)) orelse return;
    plan(&e, request) catch |err| switch (err) {
        // A refusal changes nothing; it only has to say so.
        error.Stopped => return testing.expect(e.status != 0),
        else => |other| return other,
    };
    const after = try fuzzed.applied(arena, &e);
    errdefer {
        const option = if (request.placement) |p| switch (p) {
            .after => "--after ",
            .before => "--before ",
        } else "";
        std.debug.print("mv '{s}' {s}'{s}'\n", .{ request.from, option, request.target });
        fuzzed.show(before, after);
    }
    try fuzzed.expectKept(arena, before, after);
    try testing.expectEqual(@as(usize, 1), e.addresses.items.len);
    const address = e.addresses.items[0];
    const old = refs.parseForm(from, .required).ok;
    const new = refs.parseForm(address, .required).ok;
    // A retitle keeps the numbers as written; a move numbers by position.
    const same_place = std.mem.eql(u8, old.path, new.path) and
        std.mem.eql(u8, old.number, new.number);
    const retitled = request.placement == null and same_place;
    try fuzzed.expectLanded(arena, after, address, if (retitled) .as_written else .by_position);
    // The titles are those before, with the section's own as it is now.
    const old_title = old.title;
    const new_title = new.title;
    var expected: std.ArrayList([]const u8) = .empty;
    errdefer expected.deinit(arena);
    var dropped = false;
    for (try fuzzed.titles(arena, before)) |t| {
        if (!dropped and std.mem.eql(u8, t, old_title)) {
            dropped = true;
            continue;
        }
        try expected.append(arena, t);
    }
    try expected.append(arena, new_title);
    std.mem.sort([]const u8, expected.items, {}, lessThanText);
    const got = try fuzzed.titles(arena, after);
    try testing.expectEqual(expected.items.len, got.len);
    for (expected.items, got) |x, g| try testing.expectEqualStrings(x, g);
}

fn lessThanText(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// specrail: specs/cli/mv.spec.md § 2.2 Retitle
// specrail: specs/cli/mv.spec.md § 2.3 Move a section
// specrail: specs/cli/mv.spec.md § 2.4 Whole subtree
// specrail: specs/cli/mv.spec.md § 2.8 Before and after
// specrail: specs/cli/mv.spec.md § 4.2 Report
test "fuzz: a section moved anywhere keeps what names it, and lands where mv says" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const corpus = try fuzzing.seeds(arena_state.allocator(), &.{});
    try testing.fuzz({}, moveAnySection, .{ .corpus = corpus });
}

/// Wherever a spec file is moved, every reference and dependency entry that
/// named a section exactly still does, at the new path.
fn moveAnySpecFile(_: void, smith: *testing.Smith) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = try fuzzed.madeUp(smith, arena);
    var e = try Editor.fromProject(try fuzzed.context(arena), "mv", before);
    // The project is in memory, so a destination is new when no file has it.
    const targets = [_][]const u8{ "specs/c.spec.md", "specs/deep/a.spec.md", "specs/a/b.spec.md" };
    const old = fuzzing.pick(smith, &fuzzing.spec_paths);
    const new = fuzzing.pick(smith, &targets);
    plan(&e, .{ .from = old, .target = new }) catch |err| switch (err) {
        error.Stopped => return testing.expect(e.status != 0),
        else => |other| return other,
    };
    const after = try fuzzed.applied(arena, &e);
    errdefer {
        std.debug.print("mv '{s}' '{s}'\n", .{ old, new });
        fuzzed.show(before, after);
    }
    try fuzzed.expectKept(arena, before, after);
    const titles_before = try fuzzed.titles(arena, before);
    const titles_after = try fuzzed.titles(arena, after);
    try testing.expectEqual(titles_before.len, titles_after.len);
    for (after.spec_files) |f| try testing.expect(!std.mem.eql(u8, f.path, old));
}

// specrail: specs/cli/mv.spec.md § 1.1 Move a spec file
test "fuzz: a spec file moved anywhere keeps what names its sections" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const corpus = try fuzzing.seeds(arena_state.allocator(), &.{});
    try testing.fuzz({}, moveAnySpecFile, .{ .corpus = corpus });
}
