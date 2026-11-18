//! `specrail hook`: lets a git server forbid pushes to the claim branch in
//! general while letting claim commits through, and warns a client before it
//! pushes something the server would refuse. specrail only decides whether a
//! push consists of valid claim commits; the hook script decides when to ask.

const std = @import("std");
const Allocator = std.mem.Allocator;

const claims = @import("claims.zig");
const cli = @import("cli.zig");
const config = @import("config.zig");
const git = @import("git.zig");
const project = @import("project.zig");

/// Help text for `specrail hook --help`.
pub const usage =
    \\Usage: specrail hook pre-receive [--project <dir>]
    \\       specrail hook pre-push <remote> [<url>] [--project <dir>]
    \\
    \\Checks that updates to the claim branch consist only of claim commits:
    \\commits that only add, renew or remove assigned and assigned-until,
    \\without taking a section from someone who holds it. Pushes to other
    \\branches pass. Call it from your own hook scripts, which decide when to
    \\ask, such as only for agents, or not for the provider's own merges.
    \\
    \\  pre-receive   For a server's pre-receive hook. Reads git's
    \\                '<old> <new> <ref>' lines from stdin, and refuses the
    \\                push when an update to the claim branch is not valid.
    \\  pre-push      For a client's pre-push hook, with the arguments git
    \\                passes it. Refuses a push to the claim remote's claim
    \\                branch that the server would refuse.
    \\
    \\Options:
    \\  --project <dir>   The project's directory in the repository, when its
    \\                    specrail.toml is not at the top
    \\  --help            Show this help
    \\
;

const spec_suffix = ".spec.md";

/// What checking a push needs.
const Checker = struct {
    ctx: *cli.Ctx,
    /// Where git runs: the repository, bare or not.
    cwd: []const u8,
    cfg: config.Config,
    /// The project root's place in the repository, such as `tools/`, or "".
    prefix: []const u8,

    fn runGit(k: *const Checker, args: []const []const u8) Allocator.Error!git.Output {
        return git.run(k.ctx, k.cwd, args, null);
    }

    fn unreadable(k: *const Checker, o: git.Output) Allocator.Error![]const u8 {
        return k.ctx.arena.print("cannot be checked: {s}", .{o.reason()});
    }

    /// Why updating the claim branch from `old` to `new` is refused; null
    /// when it is allowed.
    fn checkUpdate(
        k: *const Checker,
        old: []const u8,
        new: []const u8,
    ) Allocator.Error!?[]const u8 {
        const arena = k.ctx.arena;
        if (git.isZero(old)) return "creates the claim branch, which grows only by claim commits";
        if (git.isZero(new)) return "deletes the claim branch";
        const ancestor = try k.runGit(&.{ "merge-base", "--is-ancestor", old, new });
        if (!ancestor.success) {
            if (ancestor.status == 1) return "is not a fast-forward";
            return try k.unreadable(ancestor);
        }
        const range = try arena.print("{s}..{s}", .{ old, new });
        const list = try k.runGit(&.{ "rev-list", "--reverse", range });
        if (!list.success) return try k.unreadable(list);
        var commits = std.mem.tokenizeAny(u8, list.stdout, " \r\n");
        while (commits.next()) |commit| {
            const why = (try k.checkCommit(commit)) orelse continue;
            return try arena.print("commit {s} {s}", .{ commit[0..@min(12, commit.len)], why });
        }
        return null;
    }

    /// Why `commit` is not a claim commit; null when it is one.
    fn checkCommit(k: *const Checker, commit: []const u8) Allocator.Error!?[]const u8 {
        const parents = try k.runGit(&.{ "rev-list", "--parents", "-n", "1", commit });
        if (!parents.success) return try k.unreadable(parents);
        var ids = std.mem.tokenizeScalar(u8, parents.text(), ' ');
        _ = ids.next();
        const parent = ids.next() orelse return "has no parent, and a claim commit has one";
        if (ids.next() != null) return "is a merge, and a claim commit has one parent";
        const args = [_][]const u8{
            "diff-tree", "--no-commit-id", "-r",   "--no-renames",
            "-z",        "--name-status",  parent, commit,
        };
        const diff = try k.runGit(&args);
        if (!diff.success) return try k.unreadable(diff);
        var fields = std.mem.splitScalar(u8, diff.stdout, 0);
        while (fields.next()) |status| {
            if (status.len == 0) continue;
            const path = fields.next() orelse break;
            if (try k.checkFile(parent, commit, status, path)) |why| return why;
        }
        return null;
    }

    /// Why the change to `path` from `parent` to `commit` is not one a
    /// claim commit may make; null when it is one.
    fn checkFile(
        k: *const Checker,
        parent: []const u8,
        commit: []const u8,
        status: []const u8,
        path: []const u8,
    ) Allocator.Error!?[]const u8 {
        const arena = k.ctx.arena;
        const spec_dir = if (k.cfg.spec_root.len == 0)
            k.prefix
        else
            try arena.print("{s}{s}/", .{ k.prefix, k.cfg.spec_root });
        const is_spec = std.mem.startsWith(u8, path, spec_dir) and
            std.mem.endsWith(u8, path, spec_suffix);
        if (!is_spec) return try arena.print("changes {s}, which is not a spec file", .{path});
        if (!std.mem.eql(u8, status, "M")) return try arena.print("adds or deletes {s}", .{path});
        const old_object = try arena.print("{s}:{s}", .{ parent, path });
        const before = try k.runGit(&.{ "cat-file", "blob", old_object });
        if (!before.success) return try k.unreadable(before);
        const new_object = try arena.print("{s}:{s}", .{ commit, path });
        const after = try k.runGit(&.{ "cat-file", "blob", new_object });
        if (!after.success) return try k.unreadable(after);
        const rules: claims.Rules = .{ .now = k.ctx.now, .hours_max = k.cfg.claim_max_hours };
        return claims.checkChange(arena, path[k.prefix.len..], before.stdout, after.stdout, rules);
    }
};

/// The `specrail.toml` a commit holds in the project's directory.
const ConfigAt = union(enum) {
    /// The commit has none, so specrail does not manage its branches.
    absent,
    err: []const u8,
    ok: config.Config,
};

/// The `specrail.toml` that `commit` holds in `dir`, the project's
/// directory in the repository, or at its top when `dir` is empty.
fn configAt(
    ctx: *cli.Ctx,
    cwd: []const u8,
    commit: []const u8,
    dir: []const u8,
) Allocator.Error!ConfigAt {
    const object = if (dir.len == 0)
        try ctx.arena.print("{s}:{s}", .{ commit, config.file_name })
    else
        try ctx.arena.print("{s}:{s}/{s}", .{ commit, dir, config.file_name });
    const o = try git.run(ctx, cwd, &.{ "cat-file", "blob", object }, null);
    if (!o.success) return .absent;
    return switch (try config.parseText(ctx.arena, o.stdout)) {
        .ok => |cfg| .{ .ok = cfg },
        .err => |msg| .{ .err = msg },
    };
}

/// One line of the input git gives a hook: the words on it.
fn words(line: []const u8, out: [][]const u8) usize {
    var it = std.mem.tokenizeAny(u8, line, " \t\r");
    var n: usize = 0;
    while (it.next()) |w| {
        if (n == out.len) return out.len + 1;
        out[n] = w;
        n += 1;
    }
    return n;
}

fn readInput(ctx: *cli.Ctx) cli.Error![]const u8 {
    const in = ctx.stdin orelse return "";
    return in.allocRemaining(ctx.arena, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => "",
    };
}

/// `specrail hook pre-receive`: checks every update to the claim branch.
fn preReceive(ctx: *cli.Ctx, dir: []const u8) cli.Error!u8 {
    const input = try readInput(ctx);
    var rejected = false;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        var w: [3][]const u8 = .{ "", "", "" };
        const n = words(line, &w);
        if (n == 0) continue;
        if (n != 3) {
            try ctx.stderr.print("specrail: cannot read hook input '{s}'\n", .{line});
            rejected = true;
            continue;
        }
        const old, const new, const ref = w;
        // The claim branch is the one the ref's old tip names.
        const source = if (git.isZero(old)) new else old;
        const cfg = switch (try configAt(ctx, ctx.cwd, source, dir)) {
            .absent => continue,
            .err => |msg| {
                const unreadable = "specrail: rejecting {s}: specrail.toml: {s}\n";
                try ctx.stderr.print(unreadable, .{ ref, msg });
                rejected = true;
                continue;
            },
            .ok => |c| c,
        };
        if (!isBranch(ref, cfg.claim_branch)) continue;
        const prefix = if (dir.len == 0) "" else try ctx.arena.print("{s}/", .{dir});
        const k: Checker = .{ .ctx = ctx, .cwd = ctx.cwd, .cfg = cfg, .prefix = prefix };
        const why = (try k.checkUpdate(old, new)) orelse continue;
        try ctx.stderr.print("specrail: rejecting {s}: {s}\n", .{ ref, why });
        rejected = true;
    }
    return if (rejected) 1 else 0;
}

fn isBranch(ref: []const u8, branch: []const u8) bool {
    const prefix = "refs/heads/";
    return std.mem.startsWith(u8, ref, prefix) and std.mem.eql(u8, ref[prefix.len..], branch);
}

/// `specrail hook pre-push`: checks a push to the claim remote's claim branch
/// as the server will.
fn prePush(ctx: *cli.Ctx, args: []const []const u8, dir: []const u8) cli.Error!u8 {
    if (args.len == 0 or args.len > 2) {
        const msg = "pre-push takes the remote's name and URL, as git passes them";
        return cli.usageError(ctx, "hook", msg, .{});
    }
    // Read everything git sends, even when the push is not checked.
    const input = try readInput(ctx);
    const settings = (try projectAt(ctx, dir)) orelse return 2;
    const cfg = settings.config;
    if (!std.mem.eql(u8, args[0], cfg.claim_remote)) return 0;
    const prefix = try git.run(ctx, settings.root, &.{ "rev-parse", "--show-prefix" }, null);
    if (!prefix.success) {
        try ctx.stderr.print("specrail: git rev-parse failed: {s}\n", .{prefix.reason()});
        return 2;
    }
    const k: Checker = .{ .ctx = ctx, .cwd = settings.root, .cfg = cfg, .prefix = prefix.text() };
    var rejected = false;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        var w: [4][]const u8 = .{ "", "", "", "" };
        if (words(line, &w) != 4) continue;
        const local, const remote_ref, const remote = .{ w[1], w[2], w[3] };
        if (!isBranch(remote_ref, cfg.claim_branch)) continue;
        const why = (try unknownTip(ctx, &k, remote)) orelse
            (try k.checkUpdate(remote, local)) orelse continue;
        try ctx.stderr.print("specrail: rejecting the push to {s}: {s}\n", .{ remote_ref, why });
        rejected = true;
    }
    return if (rejected) 1 else 0;
}

/// The project for pre-push: found from the working directory, or, when
/// `dir` names one, the one in `dir` under the top of the working tree.
fn projectAt(ctx: *cli.Ctx, dir: []const u8) cli.Error!?project.Settings {
    if (dir.len == 0) return project.openConfig(ctx);
    const top = try git.run(ctx, ctx.cwd, &.{ "rev-parse", "--show-toplevel" }, null);
    if (!top.success) {
        try ctx.stderr.print("specrail: git rev-parse failed: {s}\n", .{top.reason()});
        return null;
    }
    const root = try std.Io.Dir.path.join(ctx.arena, &.{ top.text(), dir });
    // The search starts and stops in the directory named, so that a
    // specrail.toml above it is never taken instead.
    var local = ctx.*;
    local.cwd = root;
    local.root_ceiling = root;
    return project.openConfig(&local);
}

/// Why the remote's tip cannot be checked against, when this repository does
/// not have it; null when it does, or when the branch is new.
fn unknownTip(ctx: *cli.Ctx, k: *const Checker, remote: []const u8) Allocator.Error!?[]const u8 {
    if (git.isZero(remote)) return null;
    const object = try ctx.arena.print("{s}^{{commit}}", .{remote});
    if ((try k.runGit(&.{ "cat-file", "-e", object })).success) return null;
    const msg = "the remote's tip, {s}, is not in this repository; fetch first";
    return try ctx.arena.print(msg, .{remote[0..@min(12, remote.len)]});
}

/// A hook's arguments: those git passes, and the project directory that
/// `--project` names, or "" for the root of the repository.
const Options = struct {
    positional: []const []const u8,
    dir: []const u8 = "",
};

/// Reads a hook's arguments; null once a usage error has been reported.
fn parseOptions(ctx: *cli.Ctx, args: []const []const u8) cli.Error!?Options {
    var positional: std.ArrayList([]const u8) = .empty;
    errdefer positional.deinit(ctx.arena);
    var dir: []const u8 = "";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (!std.mem.startsWith(u8, a, "--")) {
            try positional.append(ctx.arena, a);
            continue;
        }
        const eq = std.mem.findScalar(u8, a, '=');
        if (!std.mem.eql(u8, a[0 .. eq orelse a.len], "--project")) {
            _ = try cli.usageError(ctx, "hook", "unknown option '{s}'", .{a});
            return null;
        }
        const value = if (eq) |at| a[at + 1 ..] else if (i + 1 < args.len) next: {
            i += 1;
            break :next args[i];
        } else {
            _ = try cli.usageError(ctx, "hook", "--project takes a directory", .{});
            return null;
        };
        dir = config.normalizeDir(value) orelse {
            const msg = "'{s}' is not a directory inside the repository";
            _ = try cli.usageError(ctx, "hook", msg, .{value});
            return null;
        };
    }
    return .{ .positional = try positional.toOwnedSlice(ctx.arena), .dir = dir };
}

/// Runs `specrail hook` and returns its exit status.
pub fn run(ctx: *cli.Ctx, args: []const []const u8) cli.Error!u8 {
    const sub = if (args.len > 0) args[0] else "";
    const options = (try parseOptions(ctx, if (args.len > 0) args[1..] else args)) orelse return 2;
    if (std.mem.eql(u8, sub, "pre-receive")) {
        if (options.positional.len != 0) {
            return cli.usageError(ctx, "hook", "pre-receive takes no arguments", .{});
        }
        return preReceive(ctx, options.dir);
    }
    if (std.mem.eql(u8, sub, "pre-push")) return prePush(ctx, options.positional, options.dir);
    return cli.usageError(ctx, "hook", "hook takes pre-receive or pre-push", .{});
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const sandbox = @import("sandbox.zig");

const Sandbox = sandbox.Sandbox;
const fixture = claims.fixture;

const zero = "0000000000000000000000000000000000000000";

/// Runs `specrail hook pre-receive` in the remote's bare repository with
/// `lines` on stdin.
fn runPreReceive(remote: *Sandbox, lines: []const u8) !Sandbox.Output {
    return remote.runIn("r.git", &.{ "hook", "pre-receive" }, .{ .stdin = lines });
}

const main_ref = "refs/heads/main";

fn update(s: *Sandbox, old: []const u8, new: []const u8, ref: []const u8) ![]const u8 {
    return s.arena_state.allocator().print("{s} {s} {s}\n", .{ old, new, ref });
}

/// The pre-receive verdict on moving `ref` from `old` to `new`.
fn receive(
    s: *Sandbox,
    remote: *Sandbox,
    old: []const u8,
    new: []const u8,
    ref: []const u8,
) !Sandbox.Output {
    return runPreReceive(remote, try update(s, old, new, ref));
}

/// Runs `specrail hook pre-push` for a push to `remote_name` that moves `ref`
/// from `old` to `local`.
fn runPrePush(
    s: *Sandbox,
    remote_name: []const u8,
    local: []const u8,
    ref: []const u8,
    old: []const u8,
) !Sandbox.Output {
    const words_of = .{ main_ref, local, ref, old };
    const line = try s.arena_state.allocator().print("{s} {s} {s} {s}\n", words_of);
    return s.runIn("", &.{ "hook", "pre-push", remote_name, "url" }, .{ .stdin = line });
}

/// Pushes the current branch to the remote as `name`, so that the remote has
/// its commits without the claim branch moving.
fn offer(s: *Sandbox, name: []const u8) !void {
    const refspec = try s.arena_state.allocator().print("+HEAD:refs/heads/{s}", .{name});
    try s.git(&.{ "git", "push", "-q", "origin", refspec });
}

fn replaced(s: *Sandbox, old: []const u8, new: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, s.arena_state.allocator(), fixture.login, old, new);
}

/// The fixture's spec with a claim, written by hand, on § 1.2 Google.
fn googleHeldBy(s: *Sandbox, assignee: []const u8, until: []const u8) ![]const u8 {
    const block = try s.arena_state.allocator().print(
        "## § 1.2 Google\n```toml\nassigned = \"{s}\"\nassigned-until = {s}\n```\n",
        .{ assignee, until },
    );
    return replaced(s, "## § 1.2 Google\n", block);
}

/// The pre-receive verdict on a commit that claims § 1.2 Google on top of
/// `base`.
fn claimVerdict(
    s: *Sandbox,
    remote: *Sandbox,
    base: []const u8,
    assignee: []const u8,
    until: []const u8,
) !Sandbox.Output {
    return verdict(s, remote, base, try googleHeldBy(s, assignee, until));
}

/// Commits `content` as the spec on top of `base`, offers it, and returns the
/// pre-receive verdict on moving main from `base` to it.
fn verdict(s: *Sandbox, remote: *Sandbox, base: []const u8, content: []const u8) !Sandbox.Output {
    try s.git(&.{ "git", "reset", "-q", "--hard", base });
    const commit = try fixture.commitSpec(s, content);
    try offer(s, "candidate");
    return runPreReceive(remote, try update(s, base, commit, "refs/heads/main"));
}

// specrail: specs/cli/hook.spec.md § 1.1 Definition
test "claims, renewals and releases are claim commits" {
    var remote = try Sandbox.init();
    defer remote.deinit();
    var s = try Sandbox.init();
    defer s.deinit();
    try fixture.setUp(&s, &remote, "spec_root = \"specs\"\n");
    const base = try fixture.remoteTip(&remote);
    _ = try fixture.commitSpec(&s, try googleHeldBy(&s, "agent-7", "2026-11-17T02:00:00Z"));
    _ = try fixture.commitSpec(&s, try googleHeldBy(&s, "agent-7", "2026-11-17T03:00:00Z"));
    const held = "status = \"planned\"\nassigned = \"agent-9\"\n" ++
        "assigned-until = 2026-11-17T01:00:00Z\n";
    _ = try fixture.commitSpec(&s, try replaced(&s, "status = \"planned\"\n", held));
    const released = try fixture.commitSpec(&s, fixture.login);
    try offer(&s, "claims");
    const o = try runPreReceive(&remote, try update(&s, base, released, "refs/heads/main"));
    try testing.expectEqualStrings("", o.stderr);
    try testing.expectEqual(@as(u8, 0), o.code);
}

// specrail: specs/cli/hook.spec.md § 1.1 Definition
test "anything beyond assigned and assigned-until is not a claim commit" {
    var remote = try Sandbox.init();
    defer remote.deinit();
    var s = try Sandbox.init();
    defer s.deinit();
    try fixture.setUp(&s, &remote, "spec_root = \"specs\"\n");
    const base = try fixture.remoteTip(&remote);
    const reworded = try replaced(&s, "accept Google.", "accept Google sign-in.");
    const prose = try verdict(&s, &remote, base, reworded);
    try testing.expectEqual(@as(u8, 1), prose.code);
    const beyond = "changes specs/a.spec.md:12, beyond assigned and assigned-until";
    try sandbox.expectContains(prose.stderr, beyond);
    const started = try replaced(&s, "\"planned\"", "\"in-progress\"");
    const status = try verdict(&s, &remote, base, started);
    try testing.expectEqual(@as(u8, 1), status.code);
    try s.git(&.{ "git", "reset", "-q", "--hard", base });
    try s.write("src/t.zig", "// changed\n");
    try s.write("specs/b.spec.md", "# § 1 New\n\nIt MUST be new.\n");
    try s.commitAll("not a claim");
    try offer(&s, "other");
    const head = try s.gitOutput(&.{ "git", "rev-parse", "HEAD" });
    const files_out = try runPreReceive(&remote, try update(&s, base, head, "refs/heads/main"));
    try testing.expectEqual(@as(u8, 1), files_out.code);
    try sandbox.expectContains(files_out.stderr, "adds or deletes specs/b.spec.md");
}

// specrail: specs/cli/hook.spec.md § 1.1 Definition
test "a merge is not a claim commit" {
    var remote = try Sandbox.init();
    defer remote.deinit();
    var s = try Sandbox.init();
    defer s.deinit();
    try fixture.setUp(&s, &remote, "spec_root = \"specs\"\n");
    const base = try fixture.remoteTip(&remote);
    try s.git(&.{ "git", "checkout", "-q", "-b", "side" });
    _ = try fixture.commitSpec(&s, try googleHeldBy(&s, "agent-7", "2026-11-17T02:00:00Z"));
    try s.git(&.{ "git", "checkout", "-q", "main" });
    try s.git(&.{ "git", "commit", "-q", "--allow-empty", "-m", "nothing" });
    try s.git(&.{ "git", "merge", "-q", "--no-ff", "-m", "merge", "side" });
    try offer(&s, "merged");
    const head = try s.gitOutput(&.{ "git", "rev-parse", "HEAD" });
    const o = try runPreReceive(&remote, try update(&s, base, head, "refs/heads/main"));
    try testing.expectEqual(@as(u8, 1), o.code);
    try sandbox.expectContains(o.stderr, "is a merge");
}

// specrail: specs/cli/hook.spec.md § 1.2 Valid expiry
test "a claim must expire in the future, within claim_max_hours" {
    var remote = try Sandbox.init();
    defer remote.deinit();
    var s = try Sandbox.init();
    defer s.deinit();
    try fixture.setUp(&s, &remote, "spec_root = \"specs\"\nclaim_max_hours = 4\n");
    const base = try fixture.remoteTip(&remote);
    const past = try claimVerdict(&s, &remote, base, "agent-7", "2026-11-16T23:00:00Z");
    try testing.expectEqual(@as(u8, 1), past.code);
    try sandbox.expectContains(past.stderr, "which has passed");
    const far = try claimVerdict(&s, &remote, base, "agent-7", "2026-11-17T05:00:00Z");
    try testing.expectEqual(@as(u8, 1), far.code);
    try sandbox.expectContains(far.stderr, "more than claim_max_hours (4) from now");
    const unlimited = "## § 1.2 Google\n```toml\nassigned = \"agent-7\"\n```\n";
    const open = try replaced(&s, "## § 1.2 Google\n", unlimited);
    const forever = try verdict(&s, &remote, base, open);
    try testing.expectEqual(@as(u8, 1), forever.code);
    try sandbox.expectContains(forever.stderr, "assigns agent-7 without assigned-until");
    const fine = try claimVerdict(&s, &remote, base, "agent-7", "2026-11-17T04:00:00Z");
    try testing.expectEqual(@as(u8, 0), fine.code);
}

// specrail: specs/cli/hook.spec.md § 1.3 No takeovers
test "a claim commit takes no section, or section above or below one, from its holder" {
    var remote = try Sandbox.init();
    defer remote.deinit();
    var s = try Sandbox.init();
    defer s.deinit();
    try fixture.setUp(&s, &remote, "spec_root = \"specs\"\n");
    const held_by_3 = try googleHeldBy(&s, "agent-3", "2026-11-17T05:00:00Z");
    const held = try fixture.commitSpec(&s, held_by_3);
    const takeover = try claimVerdict(&s, &remote, held, "agent-7", "2026-11-17T02:00:00Z");
    try testing.expectEqual(@as(u8, 1), takeover.code);
    try sandbox.expectContains(takeover.stderr, "takes it from agent-3 until 2026-11-17T05:00:00Z");
    const parent = "# § 1 Login\n```toml\nassigned = \"agent-7\"\n" ++
        "assigned-until = 2026-11-17T02:00:00Z\n```\n";
    const arena = s.arena_state.allocator();
    const both = try std.mem.replaceOwned(u8, arena, held_by_3, "# § 1 Login\n", parent);
    const above = try verdict(&s, &remote, held, both);
    try testing.expectEqual(@as(u8, 1), above.code);
    try sandbox.expectContains(above.stderr, "while § 1.2 Google is held by agent-3");
    const lapsed_claim = try googleHeldBy(&s, "agent-3", "2026-11-16T23:00:00Z");
    const lapsed = try fixture.commitSpec(&s, lapsed_claim);
    const after = try claimVerdict(&s, &remote, lapsed, "agent-7", "2026-11-17T02:00:00Z");
    try testing.expectEqual(@as(u8, 0), after.code);
}

// specrail: specs/cli/hook.spec.md § 2.1 Input
// specrail: specs/cli/hook.spec.md § 2.4 Without a working tree
test "pre-receive checks only the claim branch, as the old tip's specrail.toml names it" {
    var remote = try Sandbox.init();
    defer remote.deinit();
    var s = try Sandbox.init();
    defer s.deinit();
    try fixture.setUp(&s, &remote, "spec_root = \"specs\"\n");
    const base = try fixture.remoteTip(&remote);
    try s.write("src/t.zig", "// changed\n");
    try s.commitAll("not a claim");
    try offer(&s, "feature");
    const head = try s.gitOutput(&.{ "git", "rev-parse", "HEAD" });
    const lines = try std.mem.concat(s.arena_state.allocator(), u8, &.{
        try update(&s, base, head, "refs/heads/feature"),
        try update(&s, zero, head, "refs/tags/v1"),
    });
    try testing.expectEqual(@as(u8, 0), (try runPreReceive(&remote, lines)).code);
    const on_main = try receive(&s, &remote, base, head, main_ref);
    try testing.expectEqual(@as(u8, 1), on_main.code);
    // The old tip names another claim branch, so main is not checked.
    try s.write("specrail.toml", "spec_root = \"specs\"\nclaim_branch = \"claims\"\n");
    try s.commitAll("claims go elsewhere");
    try offer(&s, "elsewhere");
    const named = try s.gitOutput(&.{ "git", "rev-parse", "HEAD" });
    try s.write("src/t.zig", "// changed again\n");
    try s.commitAll("not a claim either");
    try offer(&s, "elsewhere-2");
    const later = try s.gitOutput(&.{ "git", "rev-parse", "HEAD" });
    const unchecked = try receive(&s, &remote, named, later, main_ref);
    try testing.expectEqual(@as(u8, 0), unchecked.code);
    const checked = try receive(&s, &remote, named, later, "refs/heads/claims");
    try testing.expectEqual(@as(u8, 1), checked.code);
}

// specrail: specs/cli/hook.spec.md § 2.2 Fast-forward only
test "the claim branch is never created, deleted or rewound" {
    var remote = try Sandbox.init();
    defer remote.deinit();
    var s = try Sandbox.init();
    defer s.deinit();
    try fixture.setUp(&s, &remote, "spec_root = \"specs\"\n");
    const base = try fixture.remoteTip(&remote);
    const claimed = try googleHeldBy(&s, "agent-7", "2026-11-17T02:00:00Z");
    const claim = try fixture.commitSpec(&s, claimed);
    try offer(&s, "claim");
    const created = try runPreReceive(&remote, try update(&s, zero, claim, "refs/heads/main"));
    try testing.expectEqual(@as(u8, 1), created.code);
    try sandbox.expectContains(created.stderr, "creates the claim branch");
    const deleted = try runPreReceive(&remote, try update(&s, base, zero, "refs/heads/main"));
    try testing.expectEqual(@as(u8, 1), deleted.code);
    try sandbox.expectContains(deleted.stderr, "deletes the claim branch");
    const rewound = try runPreReceive(&remote, try update(&s, claim, base, "refs/heads/main"));
    try testing.expectEqual(@as(u8, 1), rewound.code);
    try sandbox.expectContains(rewound.stderr, "is not a fast-forward");
}

// specrail: specs/cli/hook.spec.md § 2.3 Only claim commits
// specrail: specs/cli/hook.spec.md § 2.5 Rejection messages
test "one commit that is not a claim commit refuses the update, and is named" {
    var remote = try Sandbox.init();
    defer remote.deinit();
    var s = try Sandbox.init();
    defer s.deinit();
    try fixture.setUp(&s, &remote, "spec_root = \"specs\"\n");
    const base = try fixture.remoteTip(&remote);
    _ = try fixture.commitSpec(&s, try googleHeldBy(&s, "agent-7", "2026-11-17T02:00:00Z"));
    try s.write("src/t.zig", "// changed\n");
    try s.commitAll("not a claim");
    try offer(&s, "mixed");
    const head = try s.gitOutput(&.{ "git", "rev-parse", "HEAD" });
    const o = try runPreReceive(&remote, try update(&s, base, head, "refs/heads/main"));
    try testing.expectEqual(@as(u8, 1), o.code);
    const expected = try s.arena_state.allocator().print(
        "specrail: rejecting refs/heads/main: commit {s} changes src/t.zig, " ++
            "which is not a spec file\n",
        .{head[0..12]},
    );
    try testing.expectEqualStrings(expected, o.stderr);
}

// specrail: specs/cli/hook.spec.md § 3.1 Input
// specrail: specs/cli/hook.spec.md § 3.2 Unknown remote tip
test "pre-push checks pushes to the claim remote's claim branch" {
    var remote = try Sandbox.init();
    defer remote.deinit();
    var s = try Sandbox.init();
    defer s.deinit();
    try fixture.setUp(&s, &remote, "spec_root = \"specs\"\n");
    const base = try fixture.remoteTip(&remote);
    const claimed = try googleHeldBy(&s, "agent-7", "2026-11-17T02:00:00Z");
    const claim = try fixture.commitSpec(&s, claimed);
    try s.write("src/t.zig", "// changed\n");
    try s.commitAll("not a claim");
    const head = try s.gitOutput(&.{ "git", "rev-parse", "HEAD" });
    const ok = try runPrePush(&s, "origin", claim, main_ref, base);
    try testing.expectEqual(@as(u8, 0), ok.code);
    const bad = try runPrePush(&s, "origin", head, main_ref, base);
    try testing.expectEqual(@as(u8, 1), bad.code);
    try sandbox.expectContains(bad.stderr, "rejecting the push to refs/heads/main: commit");
    const other = try runPrePush(&s, "upstream", head, main_ref, base);
    try testing.expectEqual(@as(u8, 0), other.code);
    const branch = try runPrePush(&s, "origin", head, "refs/heads/feature", base);
    try testing.expectEqual(@as(u8, 0), branch.code);
    const unknown = "1234567890abcdef1234567890abcdef12345678";
    const stale = try runPrePush(&s, "origin", claim, main_ref, unknown);
    try testing.expectEqual(@as(u8, 1), stale.code);
    try sandbox.expectContains(stale.stderr, "not in this repository; fetch first");
}

/// Makes `s` a repository whose project is in `tools/`, with nothing at its
/// top but a README, and pushes it to the bare repository `r.git` in
/// `remote`.
fn nestedProject(s: *Sandbox, remote: *Sandbox) !void {
    try remote.git(&.{ "git", "init", "-q", "--bare", "-b", "main", "r.git" });
    try s.write("tools/specrail.toml", "spec_root = \"specs\"\n");
    try s.write("tools/specs/a.spec.md", fixture.login);
    try s.write("tools/src/t.zig", "// specrail: specs/a.spec.md § 1.2 Google\n");
    try s.write("README.md", "The project is in tools/.\n");
    try s.commitAll("init");
    const url = try std.Io.Dir.path.join(s.arena_state.allocator(), &.{ remote.root, "r.git" });
    try s.git(&.{ "git", "remote", "add", "origin", url });
    try s.git(&.{ "git", "push", "-q", "origin", "main" });
}

/// Commits a claim on § 1.2 Google in the nested project, and then a change
/// to a test, and returns both commits.
fn nestedCommits(s: *Sandbox) !struct { []const u8, []const u8 } {
    try s.write("tools/specs/a.spec.md", try googleHeldBy(s, "agent-7", "2026-11-17T02:00:00Z"));
    try s.commitAll("claim");
    const claim = try s.gitOutput(&.{ "git", "rev-parse", "HEAD" });
    try s.write("tools/src/t.zig", "// changed\n");
    try s.commitAll("not a claim");
    const head = try s.gitOutput(&.{ "git", "rev-parse", "HEAD" });
    try offer(s, "nested");
    return .{ claim, head };
}

// specrail: specs/cli/hook.spec.md § 2.6 Project directory
test "with --project, pre-receive reads the project from that directory" {
    var remote = try Sandbox.init();
    defer remote.deinit();
    var s = try Sandbox.init();
    defer s.deinit();
    try nestedProject(&s, &remote);
    const base = try fixture.remoteTip(&remote);
    const claim, const head = try nestedCommits(&s);
    const run_in = struct {
        fn hook(r: *Sandbox, args: []const []const u8, lines: []const u8) !Sandbox.Output {
            return r.runIn("r.git", args, .{ .stdin = lines });
        }
    }.hook;
    const plain = [_][]const u8{ "hook", "pre-receive" };
    const nested = [_][]const u8{ "hook", "pre-receive", "--project", "tools" };
    // Without --project, nothing at the top says the repository has claims.
    const unmanaged = try run_in(&remote, &plain, try update(&s, base, head, main_ref));
    try testing.expectEqual(@as(u8, 0), unmanaged.code);
    const claimed = try run_in(&remote, &nested, try update(&s, base, claim, main_ref));
    try testing.expectEqual(@as(u8, 0), claimed.code);
    const mixed = try run_in(&remote, &nested, try update(&s, base, head, main_ref));
    try testing.expectEqual(@as(u8, 1), mixed.code);
    try sandbox.expectContains(mixed.stderr, "changes tools/src/t.zig, which is not a spec file");
    for ([_][]const u8{ "../tools", "/tools" }) |dir| {
        const args = [_][]const u8{ "hook", "pre-receive", "--project", dir };
        try testing.expectEqual(@as(u8, 2), (try run_in(&remote, &args, "")).code);
    }
}

// specrail: specs/cli/hook.spec.md § 3.3 Project directory
test "with --project, pre-push uses the project in that directory" {
    var remote = try Sandbox.init();
    defer remote.deinit();
    var s = try Sandbox.init();
    defer s.deinit();
    try nestedProject(&s, &remote);
    const base = try fixture.remoteTip(&remote);
    const claim, const head = try nestedCommits(&s);
    const arena = s.arena_state.allocator();
    const of_claim = try arena.print("refs/heads/main {s} refs/heads/main {s}\n", .{ claim, base });
    const of_head = try arena.print("refs/heads/main {s} refs/heads/main {s}\n", .{ head, base });
    const plain = [_][]const u8{ "hook", "pre-push", "origin", "url" };
    const nested = [_][]const u8{ "hook", "pre-push", "origin", "url", "--project=tools" };
    // From the top of the working tree, the search finds no project.
    const lost = try s.runIn("", &plain, .{ .stdin = of_claim });
    try testing.expectEqual(@as(u8, 2), lost.code);
    try testing.expectEqual(@as(u8, 0), (try s.runIn("", &nested, .{ .stdin = of_claim })).code);
    const refused = try s.runIn("", &nested, .{ .stdin = of_head });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try sandbox.expectContains(refused.stderr, "changes tools/src/t.zig, which is not a spec file");
    const empty = [_][]const u8{ "hook", "pre-push", "origin", "url", "--project", "tools/src" };
    try testing.expectEqual(@as(u8, 2), (try s.runIn("", &empty, .{ .stdin = of_claim })).code);
}
