//! `specrail claim` and `specrail release`: taking a section for a limited
//! time, and giving it up, by pushing a commit that changes only the
//! section's `assigned` and `assigned-until` straight to the claim branch.
//! The commit is built on the fetched tip of that branch with git's plumbing,
//! so the working tree, the index and the current branch stay as they are.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const claims = @import("claims.zig");
const cli = @import("cli.zig");
const config = @import("config.zig");
const date = @import("date.zig");
const diag = @import("diag.zig");
const files = @import("files.zig");
const git = @import("git.zig");
const project = @import("project.zig");
const refs = @import("refs.zig");
const spec = @import("spec.zig");

/// Help text for `specrail claim --help`.
pub const claim_usage =
    \\Usage: specrail claim <section> --for <duration> [--as <name>]
    \\
    \\Take a section for a limited time, so that agents working in parallel do
    \\not build the same thing twice. claim pushes a commit to the claim branch
    \\that sets the section's assigned and assigned-until, and prints that
    \\commit's id and the claim's expiry. Start your work branch from that
    \\commit, and remove the claim in the change that finishes the work.
    \\
    \\  specrail claim 'specs/auth/login.spec.md § 1.2 Google' --for 2h --as agent-7
    \\
    \\Claiming again before the claim expires renews it.
    \\
    \\Options:
    \\  --for <duration>   How long the claim lasts: minutes or hours, such as 90m or 2h
    \\  --as <name>        Who claims; by default, the SPECRAIL_ASSIGNEE environment variable
    \\  --help             Show this help
    \\
;

/// Help text for `specrail release --help`.
pub const release_usage =
    \\Usage: specrail release <section> [--as <name>]
    \\
    \\Give up a claim before it expires, by pushing a commit to the claim branch
    \\that removes the section's assigned and assigned-until. Finished work
    \\removes its claim in the change that finishes it instead.
    \\
    \\Options:
    \\  --as <name>   Who holds the claim; by default, the SPECRAIL_ASSIGNEE environment variable
    \\  --help        Show this help
    \\
;

/// Which of the two commands runs.
pub const Command = enum { claim, release };

/// How many times claim fetches, commits and pushes before it gives up on a
/// claim branch that keeps moving.
const attempts_max = 5;

/// What the command line asked for.
const Request = struct {
    section: []const u8 = "",
    duration: ?[]const u8 = null,
    assignee: ?[]const u8 = null,
};

/// Reads the arguments; null once a usage error has been reported.
fn parse(ctx: *cli.Ctx, command: Command, args: []const []const u8) cli.Error!?Request {
    const name = @tagName(command);
    var r: Request = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (!std.mem.startsWith(u8, a, "--")) {
            if (r.section.len > 0) {
                _ = try cli.usageError(ctx, name, "{s} takes one section", .{name});
                return null;
            }
            r.section = a;
            continue;
        }
        const eq = std.mem.findScalar(u8, a, '=');
        const option = a[0 .. eq orelse a.len];
        const as = std.mem.eql(u8, option, "--as");
        const for_ = command == .claim and std.mem.eql(u8, option, "--for");
        if (!as and !for_) {
            _ = try cli.usageError(ctx, name, "unknown option '{s}'", .{a});
            return null;
        }
        const value = if (eq) |at| a[at + 1 ..] else if (i + 1 < args.len) next: {
            i += 1;
            break :next args[i];
        } else {
            _ = try cli.usageError(ctx, name, "{s} takes a value", .{option});
            return null;
        };
        if (as) r.assignee = value else r.duration = value;
    }
    if (r.section.len == 0) {
        _ = try cli.usageError(ctx, name, "{s} takes a section in reference form", .{name});
        return null;
    }
    if (command == .claim and r.duration == null) {
        _ = try cli.usageError(ctx, name, "claim takes --for <duration>, such as --for 2h", .{});
        return null;
    }
    return r;
}

/// The seconds in a duration such as `90m` or `2h`: a positive whole number
/// of minutes or hours. Null when `text` is not one.
fn parseDuration(text: []const u8) ?i64 {
    if (text.len < 2 or text.len > 7) return null;
    const unit: i64 = switch (text[text.len - 1]) {
        'h' => 3600,
        'm' => 60,
        else => return null,
    };
    const number = text[0 .. text.len - 1];
    for (number) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    const n = std.fmt.parseInt(i64, number, 10) catch return null;
    if (n == 0) return null;
    return n * unit;
}

/// Why a step stopped the command, with its exit status kept in
/// `Claimer.status`.
const Error = cli.Error || error{Stopped};

/// How one attempt to claim or release ended.
const Attempt = enum {
    /// The commit is pushed, or there was nothing to push.
    done,
    /// The claim branch moved before the push landed; try again.
    lost,
};

/// The commit an attempt makes: the spec file's new content and the message.
const Change = struct {
    content: []const u8,
    subject: []const u8,
    body: []const u8,
    /// The claim's expiry, printed after the commit's id; empty for release.
    until: []const u8 = "",
};

/// One run of claim or release.
const Claimer = struct {
    ctx: *cli.Ctx,
    command: Command,
    settings: project.Settings,
    form: refs.Form,
    assignee: []const u8,
    /// How long a claim lasts, in seconds; null for release.
    seconds: ?i64,
    /// The project root's place in the repository, such as `tools/`, or "".
    prefix: []const u8 = "",
    status: u8 = 0,

    fn stop(c: *Claimer, status: u8, comptime format: []const u8, args: anytype) Error {
        c.ctx.stderr.print("specrail: " ++ format ++ "\n", args) catch |err| return err;
        c.status = status;
        return error.Stopped;
    }

    fn runGit(c: *Claimer, args: []const []const u8) Allocator.Error!git.Output {
        return git.run(c.ctx, c.settings.root, args, null);
    }

    /// Runs git, and stops with status 2 when it fails.
    fn runGitOk(
        c: *Claimer,
        args: []const []const u8,
        env: ?*const std.process.Environ.Map,
    ) Error!git.Output {
        const o = try git.run(c.ctx, c.settings.root, args, env);
        if (!o.success) return c.stop(2, "git {s} failed: {s}", .{ args[0], o.reason() });
        return o;
    }

    fn name(c: *const Claimer) Allocator.Error![]const u8 {
        const f = c.form;
        const parts = .{ f.path, refs.section_sign, f.number, f.title };
        return c.ctx.arena.print("{s} {s} {s} {s}", parts);
    }

    /// Fetches the claim branch, and returns the id of its tip.
    fn fetch(c: *Claimer) Error![]const u8 {
        const cfg = c.settings.config;
        const branch = try c.ctx.arena.print("refs/heads/{s}", .{cfg.claim_branch});
        const f = try c.runGit(&.{ "fetch", "--quiet", "--no-tags", cfg.claim_remote, branch });
        if (!f.success) {
            const msg = "cannot fetch {s} from {s}: {s}";
            return c.stop(2, msg, .{ cfg.claim_branch, cfg.claim_remote, f.reason() });
        }
        return (try c.runGitOk(&.{ "rev-parse", "--verify", "FETCH_HEAD^{commit}" }, null)).text();
    }

    /// Fetches, checks, commits and pushes once.
    fn attempt(c: *Claimer) Error!Attempt {
        const arena = c.ctx.arena;
        const cfg = c.settings.config;
        const tip = try c.fetch();
        const tree_path = try std.mem.concat(arena, u8, &.{ c.prefix, c.form.path });
        const listed = (try c.runGitOk(&.{ "ls-tree", tip, "--", tree_path }, null)).text();
        if (listed.len == 0) {
            const msg = "dangling section: {s} on {s} has no spec file {s}";
            return c.stop(1, msg, .{ cfg.claim_branch, cfg.claim_remote, c.form.path });
        }
        const mode = listed[0 .. std.mem.findScalar(u8, listed, ' ') orelse listed.len];
        const object = try arena.print("{s}:{s}", .{ tip, tree_path });
        const content = (try c.runGitOk(&.{ "cat-file", "blob", object }, null)).stdout;
        var found: diag.List = .empty;
        defer found.deinit(arena);
        const file = try spec.parse(arena, c.form.path, content, &found);
        if (file.broken or file.duplicate) return c.refuse(found.items);
        const index = try c.find(&file);
        const change = (try c.plan(&file, content, index)) orelse return .done;
        const commit = try c.makeCommit(tip, tree_path, mode, change);
        return c.push(commit, change);
    }

    /// Reports the errors that keep the spec file from being rewritten, and
    /// stops with status 1.
    fn refuse(c: *Claimer, found: []const diag.Diagnostic) Error {
        const intro = "specrail: {s} has errors that keep {s} from rewriting it:\n";
        c.ctx.stderr.print(intro, .{ c.form.path, @tagName(c.command) }) catch |err| return err;
        for (found) |d| {
            if (d.severity == .err) diag.write(c.ctx.stderr, d, c.ctx.color) catch |err| return err;
        }
        c.status = 1;
        return error.Stopped;
    }

    /// The index of the section the command names, which must match a
    /// heading exactly.
    fn find(c: *Claimer, file: *const spec.SpecFile) Error!usize {
        const f = c.form;
        for (file.sections, 0..) |s, i| {
            const same_number = std.mem.eql(u8, s.number, f.number);
            if (same_number and std.mem.eql(u8, s.title, f.title)) return i;
        }
        for (file.sections) |s| {
            const same_number = std.mem.eql(u8, s.number, f.number);
            if (!same_number and !std.mem.eql(u8, s.title, f.title)) continue;
            const msg = "stale section § {s} {s}: {s} has § {s} {s}";
            return c.stop(1, msg, .{ f.number, f.title, f.path, s.number, s.title });
        }
        const msg = "dangling section: {s} has no § {s} and no section titled '{s}'";
        return c.stop(1, msg, .{ f.path, f.number, f.title });
    }

    /// The change to commit; null when there is nothing to do, as when
    /// releasing a section that has no claim.
    fn plan(
        c: *Claimer,
        file: *const spec.SpecFile,
        content: []const u8,
        index: usize,
    ) Error!?Change {
        const arena = c.ctx.arena;
        const section = try c.name();
        switch (c.command) {
            .claim => {
                if (claims.conflict(file, index, c.assignee, c.ctx.now)) |j| {
                    const s = file.sections[j];
                    const held = try claims.holdOf(s).?.describe(arena);
                    return c.stop(1, "§ {s} {s} is held by {s}", .{ s.number, s.title, held });
                }
                var buf: [20]u8 = undefined;
                const expiry = date.formatDateTime(&buf, c.ctx.now + c.seconds.?);
                const until = try arena.dupe(u8, expiry);
                const claim: claims.Claim = .{ .assignee = c.assignee, .until = until };
                const new = (try claims.withClaim(arena, file, content, index, claim)) orelse
                    return c.stop(1, "the metadata block of {s} cannot be read", .{section});
                return .{
                    .content = new,
                    .subject = try arena.print("specrail claim {s}", .{section}),
                    .body = try arena.print("{s} holds it until {s}.", .{ c.assignee, until }),
                    .until = until,
                };
            },
            .release => {
                const hold = claims.holdOf(file.sections[index]) orelse {
                    const msg = "specrail: {s} has no claim; nothing to release\n";
                    try c.ctx.stderr.print(msg, .{section});
                    return null;
                };
                if (!std.mem.eql(u8, hold.assignee, c.assignee)) {
                    const msg = "{s} is held by {s}, not by {s}";
                    return c.stop(1, msg, .{ section, try hold.describe(arena), c.assignee });
                }
                const new = (try claims.withClaim(arena, file, content, index, null)) orelse
                    return c.stop(1, "the metadata block of {s} cannot be read", .{section});
                return .{
                    .content = new,
                    .subject = try arena.print("specrail release {s}", .{section}),
                    .body = try arena.print("{s} gives it up.", .{c.assignee}),
                };
            },
        }
    }

    /// Commits `change` on top of `tip`, without touching the working tree,
    /// the index or any branch, and returns the commit's id.
    fn makeCommit(
        c: *Claimer,
        tip: []const u8,
        tree_path: []const u8,
        mode: []const u8,
        change: Change,
    ) Error![]const u8 {
        const arena = c.ctx.arena;
        const git_dir = (try c.runGitOk(&.{ "rev-parse", "--absolute-git-dir" }, null)).text();
        const stamp = std.Io.Timestamp.now(c.ctx.io, .real).nanoseconds;
        const blob_path = try arena.print("{s}/specrail-{d}.blob", .{ git_dir, stamp });
        const index_path = try arena.print("{s}/specrail-{d}.index", .{ git_dir, stamp });
        const made = c.build(.{
            .tip = tip,
            .tree_path = tree_path,
            .mode = mode,
            .change = change,
            .blob_path = blob_path,
            .index_path = index_path,
        });
        try c.removeTemporary(blob_path);
        try c.removeTemporary(index_path);
        return made;
    }

    /// What a claim commit is made from.
    const Parts = struct {
        tip: []const u8,
        tree_path: []const u8,
        mode: []const u8,
        change: Change,
        /// Temporary files for the new content and for an index.
        blob_path: []const u8,
        index_path: []const u8,
    };

    fn build(c: *Claimer, p: Parts) Error![]const u8 {
        const arena = c.ctx.arena;
        const tip = p.tip;
        const change = p.change;
        const blob_path = p.blob_path;
        const blob_file: Io.Dir.WriteFileOptions = .{
            .sub_path = blob_path,
            .data = change.content,
        };
        Io.Dir.cwd().writeFile(c.ctx.io, blob_file) catch |err| {
            return c.stop(2, "cannot write {s}: {s}", .{ blob_path, @errorName(err) });
        };
        const hash_args = [_][]const u8{ "hash-object", "-w", "--no-filters", blob_path };
        const blob = (try c.runGitOk(&hash_args, null)).text();
        // A temporary index, so that the repository's own stays as it is.
        const env = try git.withVariable(c.ctx, "GIT_INDEX_FILE", p.index_path);
        _ = try c.runGitOk(&.{ "read-tree", tip }, env);
        const entry = try arena.print("{s},{s},{s}", .{ p.mode, blob, p.tree_path });
        _ = try c.runGitOk(&.{ "update-index", "--cacheinfo", entry }, env);
        const tree = (try c.runGitOk(&.{"write-tree"}, env)).text();
        // Unlike git commit, commit-tree signs only when told to, so it is told
        // to when commit.gpgsign is set.
        const sign = try c.runGit(&.{ "config", "--type=bool", "--get", "commit.gpgsign" });
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(arena);
        try args.appendSlice(arena, &.{ "commit-tree", tree, "-p", tip });
        if (sign.success and std.mem.eql(u8, sign.text(), "true")) try args.append(arena, "-S");
        try args.appendSlice(arena, &.{ "-m", change.subject, "-m", change.body });
        return (try c.runGitOk(args.items, null)).text();
    }

    fn removeTemporary(c: *Claimer, path: []const u8) Error!void {
        Io.Dir.cwd().deleteFile(c.ctx.io, path) catch |err| {
            if (err != error.FileNotFound) {
                const msg = "specrail: cannot remove {s}: {s}\n";
                try c.ctx.stderr.print(msg, .{ path, @errorName(err) });
            }
        };
    }

    /// Pushes `commit` to the claim branch. A push that loses a race with
    /// another is reported as lost, so that the caller tries again.
    fn push(c: *Claimer, commit: []const u8, change: Change) Error!Attempt {
        const cfg = c.settings.config;
        const refspec = try c.ctx.arena.print("{s}:refs/heads/{s}", .{ commit, cfg.claim_branch });
        const o = try c.runGit(&.{ "push", "--porcelain", cfg.claim_remote, refspec });
        if (o.success) {
            if (change.until.len > 0) {
                try c.ctx.stdout.print("{s} {s}\n", .{ commit, change.until });
            } else {
                try c.ctx.stdout.print("{s}\n", .{commit});
            }
            return .done;
        }
        if (lostRace(o.stdout) or lostRace(o.stderr)) return .lost;
        const msg = "cannot push to {s} on {s}: {s}";
        return c.stop(2, msg, .{ cfg.claim_branch, cfg.claim_remote, o.reason() });
    }

    /// Runs the attempts, and returns the exit status.
    fn run(c: *Claimer) cli.Error!u8 {
        c.prepare() catch |err| return c.statusOf(err);
        for (0..attempts_max) |_| {
            const outcome = c.attempt() catch |err| return c.statusOf(err);
            if (outcome == .done) return 0;
        }
        const cfg = c.settings.config;
        const msg = "specrail: gave up after {d} attempts: {s} on {s} kept moving\n";
        try c.ctx.stderr.print(msg, .{ attempts_max, cfg.claim_branch, cfg.claim_remote });
        return 1;
    }

    fn prepare(c: *Claimer) Error!void {
        c.prefix = (try c.runGitOk(&.{ "rev-parse", "--show-prefix" }, null)).text();
    }

    fn statusOf(c: *const Claimer, err: Error) cli.Error!u8 {
        switch (err) {
            error.Stopped => return c.status,
            else => |other| return other,
        }
    }
};

/// Whether what `git push` printed shows that the claim branch moved before
/// the push landed: rejected as not a fast-forward, or refused by the remote
/// because the ref was no longer where the push expected it. A hook that
/// refuses the push is not a race.
fn lostRace(output: []const u8) bool {
    const moved = [_][]const u8{
        "[rejected]", "cannot lock ref", "failed to update ref", "stale info", "fetch first",
    };
    for (moved) |m| {
        if (std.mem.find(u8, output, m) != null) return true;
    }
    return false;
}

/// Runs `specrail claim` or `specrail release` and returns its exit status.
pub fn run(ctx: *cli.Ctx, command: Command, args: []const []const u8) cli.Error!u8 {
    const name = @tagName(command);
    const r = (try parse(ctx, command, args)) orelse return 2;
    const assignee = r.assignee orelse ctx.assignee orelse "";
    if (assignee.len == 0) {
        const msg = "say who claims: give --as <name> or set SPECRAIL_ASSIGNEE";
        return cli.usageError(ctx, name, msg, .{});
    }
    const settings = (try project.openConfig(ctx)) orelse return 2;
    var seconds: ?i64 = null;
    if (command == .claim) {
        seconds = parseDuration(r.duration.?) orelse {
            const msg = "'{s}' is not a duration: give whole minutes or hours, such as 90m or 2h";
            return cli.usageError(ctx, name, msg, .{r.duration.?});
        };
        if (settings.config.claim_max_hours) |max| {
            if (seconds.? > max * 3600) {
                const msg = "specrail: claims last at most {d} hours here (claim_max_hours)\n";
                try ctx.stderr.print(msg, .{max});
                return 2;
            }
        }
    }
    var form = switch (refs.parseForm(r.section, .required)) {
        .ok => |f| f,
        .err => |msg| {
            const what = "'{s}' is not a section: {s}";
            return cli.usageError(ctx, name, what, .{ r.section, msg });
        },
    };
    const root = settings.config.spec_root;
    const path = config.normalizeDir(form.path) orelse "";
    if (path.len == 0 or !files.isUnder(path, root) or std.mem.eql(u8, path, root)) {
        return cli.usageError(ctx, name, "'{s}' is not a path below the spec root", .{form.path});
    }
    form.path = path;
    var c: Claimer = .{
        .ctx = ctx,
        .command = command,
        .settings = settings,
        .form = form,
        .assignee = assignee,
        .seconds = seconds,
    };
    return c.run();
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const sandbox = @import("sandbox.zig");

const Sandbox = sandbox.Sandbox;
const fixture = claims.fixture;

const google = "specs/a.spec.md § 1.2 Google";
const password = "specs/a.spec.md § 1.1 Password";
const config_toml = "spec_root = \"specs\"\n";

fn runClaim(s: *Sandbox, args: []const []const u8, assignee: ?[]const u8) !Sandbox.Output {
    return s.runIn("", args, .{ .assignee = assignee });
}

/// Runs claim or release as agent-7, and expects it to succeed.
fn succeed(s: *Sandbox, args: []const []const u8) !void {
    const o = try runClaim(s, args, "agent-7");
    if (o.code != 0) std.debug.print("{s}", .{o.stderr});
    try testing.expectEqual(@as(u8, 0), o.code);
}

/// Claims `section` for two hours as agent-7.
fn claimTwoHours(s: *Sandbox, section: []const u8) !Sandbox.Output {
    return runClaim(s, &.{ "claim", section, "--for", "2h" }, "agent-7");
}

const planned_line = "status = \"planned\"\n";

/// The fixture's spec with a claim on § 1.2 Google.
fn googleClaimed(arena: Allocator, assignee: []const u8, until: []const u8) ![]const u8 {
    const block = try arena.print(
        "## § 1.2 Google\n```toml\nassigned       = \"{s}\"\nassigned-until = {s}\n```\n",
        .{ assignee, until },
    );
    return std.mem.replaceOwned(u8, arena, fixture.login, "## § 1.2 Google\n", block);
}

/// Pushes the spec with `content` to the remote's main.
fn pushSpec(s: *Sandbox, content: []const u8) !void {
    _ = try fixture.commitSpec(s, content);
    try s.git(&.{ "git", "push", "-q", "origin", "HEAD:main" });
}

// specrail: specs/cli/claim.spec.md § 1.1 Claim commit
// specrail: specs/cli/claim.spec.md § 1.4 Built on the remote branch
// specrail: specs/cli/claim.spec.md § 1.10 Commit message
// specrail: specs/cli/claim.spec.md § 1.12 Output
test "claim pushes a commit on the remote's tip that only claims the section" {
    var remote = try Sandbox.init();
    defer remote.deinit();
    var s = try Sandbox.init();
    defer s.deinit();
    const arena = s.arena_state.allocator();
    try fixture.setUp(&s, &remote, config_toml);
    // The remote has moved on without this repository, which has work of its own.
    try s.git(&.{ "git", "commit", "-q", "--allow-empty", "-m", "elsewhere" });
    try s.git(&.{ "git", "push", "-q", "origin", "HEAD:main" });
    try s.git(&.{ "git", "reset", "-q", "--hard", "HEAD~1" });
    try s.git(&.{ "git", "commit", "-q", "--allow-empty", "-m", "unpushed" });
    try s.write("src/t.zig", "// work in progress\n");
    const head = try s.gitOutput(&.{ "git", "rev-parse", "HEAD" });
    const base = try fixture.remoteTip(&remote);
    const o = try runClaim(&s, &.{ "claim", google, "--for", "2h" }, "agent-7");
    try testing.expectEqual(@as(u8, 0), o.code);
    const tip = try fixture.remoteTip(&remote);
    try testing.expectEqualStrings(try arena.print("{s} 2026-11-17T02:00:00Z\n", .{tip}), o.stdout);
    const parent = try fixture.remoteGit(&remote, &.{ "rev-parse", "main^" });
    try testing.expectEqualStrings(base, parent);
    const subject = try fixture.remoteGit(&remote, &.{ "log", "-1", "--format=%s", "main" });
    try testing.expectEqualStrings("specrail claim " ++ google, subject);
    const diff_args = [_][]const u8{ "diff-tree", "--no-commit-id", "-r", "--name-only", "main" };
    const changed = try fixture.remoteGit(&remote, &diff_args);
    try testing.expectEqualStrings(fixture.path, changed);
    const claimed = try googleClaimed(arena, "agent-7", "2026-11-17T02:00:00Z");
    try testing.expectEqualStrings(claimed, try fixture.remoteSpec(&remote));
    // This repository is as it was.
    try testing.expectEqualStrings(head, try s.gitOutput(&.{ "git", "rev-parse", "HEAD" }));
    try testing.expectEqualStrings("// work in progress\n", try s.read("src/t.zig"));
    const status = try s.gitOutput(&.{ "git", "status", "--porcelain" });
    try testing.expectEqualStrings("M src/t.zig", status);
}

// specrail: specs/cli/claim.spec.md § 1.2 Duration syntax
test "a claim lasts a whole number of minutes or hours" {
    var remote = try Sandbox.init();
    defer remote.deinit();
    var s = try Sandbox.init();
    defer s.deinit();
    try fixture.setUp(&s, &remote, config_toml);
    const base = try fixture.remoteTip(&remote);
    for ([_][]const u8{ "0h", "2d", "h", "-1h", "1.5h", "2", "+2h", "2 h" }) |d| {
        const o = try runClaim(&s, &.{ "claim", google, "--for", d }, "agent-7");
        try testing.expectEqual(@as(u8, 2), o.code);
    }
    try testing.expectEqualStrings(base, try fixture.remoteTip(&remote));
    const o = try runClaim(&s, &.{ "claim", google, "--for=90m" }, "agent-7");
    try testing.expectEqual(@as(u8, 0), o.code);
    try testing.expect(std.mem.endsWith(u8, o.stdout, " 2026-11-17T01:30:00Z\n"));
}

// specrail: specs/cli/claim.spec.md § 1.3 Claimant
test "the claimant comes from --as, or else from SPECRAIL_ASSIGNEE" {
    var remote = try Sandbox.init();
    defer remote.deinit();
    var s = try Sandbox.init();
    defer s.deinit();
    try fixture.setUp(&s, &remote, config_toml);
    const nobody = try runClaim(&s, &.{ "claim", google, "--for", "2h" }, null);
    try testing.expectEqual(@as(u8, 2), nobody.code);
    try sandbox.expectContains(nobody.stderr, "give --as <name> or set SPECRAIL_ASSIGNEE");
    try succeed(&s, &.{ "claim", google, "--for", "2h" });
    try sandbox.expectContains(try fixture.remoteSpec(&remote), "assigned       = \"agent-7\"");
    const as_args = [_][]const u8{ "claim", password, "--for", "2h", "--as", "agent-9" };
    const as = try runClaim(&s, &as_args, "agent-7");
    try testing.expectEqual(@as(u8, 0), as.code);
    try sandbox.expectContains(try fixture.remoteSpec(&remote), "assigned       = \"agent-9\"");
}

// specrail: specs/cli/claim.spec.md § 1.5 Unknown section
test "a stale or dangling section changes nothing" {
    var remote = try Sandbox.init();
    defer remote.deinit();
    var s = try Sandbox.init();
    defer s.deinit();
    try fixture.setUp(&s, &remote, config_toml);
    const base = try fixture.remoteTip(&remote);
    const stale = try claimTwoHours(&s, "specs/a.spec.md § 1.2 Gogle");
    try testing.expectEqual(@as(u8, 1), stale.code);
    try sandbox.expectContains(stale.stderr, "stale section § 1.2 Gogle");
    const dangling = try claimTwoHours(&s, "specs/a.spec.md § 7 Nope");
    try testing.expectEqual(@as(u8, 1), dangling.code);
    try sandbox.expectContains(dangling.stderr, "dangling section");
    const missing = try claimTwoHours(&s, "specs/b.spec.md § 1 One");
    try testing.expectEqual(@as(u8, 1), missing.code);
    try sandbox.expectContains(missing.stderr, "has no spec file specs/b.spec.md");
    try testing.expectEqualStrings(base, try fixture.remoteTip(&remote));
}

// specrail: specs/cli/claim.spec.md § 1.6 Conflicting claims
test "a section held by someone else, or above or below one, cannot be claimed" {
    var remote = try Sandbox.init();
    defer remote.deinit();
    var s = try Sandbox.init();
    defer s.deinit();
    const arena = s.arena_state.allocator();
    try fixture.setUp(&s, &remote, config_toml);
    const held = planned_line ++ "assigned = \"agent-3\"\n" ++
        "assigned-until = 2026-11-17T05:00:00Z\n";
    try pushSpec(&s, try std.mem.replaceOwned(u8, arena, fixture.login, planned_line, held));
    const same = try runClaim(&s, &.{ "claim", password, "--for", "2h" }, "agent-7");
    try testing.expectEqual(@as(u8, 1), same.code);
    const holder = "§ 1.1 Password is held by agent-3 until 2026-11-17T05:00:00Z";
    try sandbox.expectContains(same.stderr, holder);
    const above = try claimTwoHours(&s, "specs/a.spec.md § 1 Login");
    try testing.expectEqual(@as(u8, 1), above.code);
    const person = "# § 1 Login\n```toml\nassigned = \"Dana\"\n```\n";
    try pushSpec(&s, try std.mem.replaceOwned(u8, arena, fixture.login, "# § 1 Login\n", person));
    const below = try runClaim(&s, &.{ "claim", google, "--for", "2h" }, "agent-7");
    try testing.expectEqual(@as(u8, 1), below.code);
    try sandbox.expectContains(below.stderr, "held by Dana, with no expiry");
    const lapsed = planned_line ++ "assigned = \"agent-3\"\n" ++
        "assigned-until = 2026-11-16T23:00:00Z\n";
    try pushSpec(&s, try std.mem.replaceOwned(u8, arena, fixture.login, planned_line, lapsed));
    try succeed(&s, &.{ "claim", password, "--for", "2h" });
}

// specrail: specs/cli/claim.spec.md § 1.7 Renewal
test "claiming again renews the claim" {
    var remote = try Sandbox.init();
    defer remote.deinit();
    var s = try Sandbox.init();
    defer s.deinit();
    try fixture.setUp(&s, &remote, config_toml);
    try succeed(&s, &.{ "claim", google, "--for", "2h" });
    try succeed(&s, &.{ "claim", google, "--for", "3h" });
    const renewed = try googleClaimed(s.arena_state.allocator(), "agent-7", "2026-11-17T03:00:00Z");
    try testing.expectEqualStrings(renewed, try fixture.remoteSpec(&remote));
}

/// A pre-push hook that moves the remote's main before the push lands, as
/// another agent's push would; once, or every time.
fn racingHook(s: *Sandbox, once: []const u8) !void {
    const script = try s.arena_state.allocator().print(
        \\#!/bin/sh
        \\cat >/dev/null
        \\{s}
        \\git fetch -q origin main
        \\race=$(git commit-tree "FETCH_HEAD^{{tree}}" -p FETCH_HEAD -m race)
        \\git push -q --no-verify origin "$race:refs/heads/main"
        \\
    , .{once});
    try s.write(".git/hooks/pre-push", script);
    try s.tmp.dir.setFilePermissions(testing.io, ".git/hooks/pre-push", .fromMode(0o755), .{});
}

// specrail: specs/cli/claim.spec.md § 1.8 Lost races
test "a claim that loses a race tries again on the new tip, five times at most" {
    var remote = try Sandbox.init();
    defer remote.deinit();
    var s = try Sandbox.init();
    defer s.deinit();
    try fixture.setUp(&s, &remote, config_toml);
    try racingHook(&s, "[ -e .git/raced ] && exit 0; touch .git/raced");
    const o = try runClaim(&s, &.{ "claim", google, "--for", "2h" }, "agent-7");
    try testing.expectEqual(@as(u8, 0), o.code);
    const parent = try fixture.remoteGit(&remote, &.{ "log", "-1", "--format=%s", "main^" });
    try testing.expectEqualStrings("race", parent);
    try racingHook(&s, "");
    const lost = try runClaim(&s, &.{ "claim", password, "--for", "2h" }, "agent-7");
    try testing.expectEqual(@as(u8, 1), lost.code);
    try sandbox.expectContains(lost.stderr, "gave up after 5 attempts");
    const subject = try fixture.remoteGit(&remote, &.{ "log", "-1", "--format=%s", "main" });
    try testing.expectEqualStrings("race", subject);
}

// specrail: specs/cli/claim.spec.md § 1.9 Maximum duration
test "a claim may not last longer than claim_max_hours" {
    var remote = try Sandbox.init();
    defer remote.deinit();
    var s = try Sandbox.init();
    defer s.deinit();
    try fixture.setUp(&s, &remote, "spec_root = \"specs\"\nclaim_max_hours = 4\n");
    const base = try fixture.remoteTip(&remote);
    const long = try runClaim(&s, &.{ "claim", google, "--for", "5h" }, "agent-7");
    try testing.expectEqual(@as(u8, 2), long.code);
    try sandbox.expectContains(long.stderr, "at most 4 hours");
    try testing.expectEqualStrings(base, try fixture.remoteTip(&remote));
    try succeed(&s, &.{ "claim", google, "--for", "4h" });
}

// specrail: specs/cli/claim.spec.md § 1.11 Identity and signing
test "claim commits are authored and signed as git commit would" {
    var remote = try Sandbox.init();
    defer remote.deinit();
    var s = try Sandbox.init();
    defer s.deinit();
    try fixture.setUp(&s, &remote, config_toml);
    try s.git(&.{ "git", "config", "user.name", "Agent Seven" });
    try s.git(&.{ "git", "config", "user.email", "agent7@example.invalid" });
    try succeed(&s, &.{ "claim", google, "--for", "2h" });
    const author = try fixture.remoteGit(&remote, &.{ "log", "-1", "--format=%an <%ae>", "main" });
    try testing.expectEqualStrings("Agent Seven <agent7@example.invalid>", author);
    const unsigned = try fixture.remoteGit(&remote, &.{ "cat-file", "commit", "main" });
    try testing.expect(std.mem.find(u8, unsigned, "gpgsig") == null);
    // A stand-in for gpg: it signs anything, so that the test needs no keys.
    try remote.write("fake-gpg",
        \\#!/bin/sh
        \\cat >/dev/null
        \\echo "[GNUPG:] SIG_CREATED D 1 8 00 1 ABCD" >&2
        \\printf -- '-----BEGIN PGP SIGNATURE-----\nfake\n-----END PGP SIGNATURE-----\n'
        \\
    );
    try remote.tmp.dir.setFilePermissions(testing.io, "fake-gpg", .fromMode(0o755), .{});
    const gpg = try std.Io.Dir.path.join(s.arena_state.allocator(), &.{ remote.root, "fake-gpg" });
    try s.git(&.{ "git", "config", "gpg.program", gpg });
    try s.git(&.{ "git", "config", "user.signingkey", "ABCD" });
    try s.git(&.{ "git", "config", "commit.gpgsign", "true" });
    try succeed(&s, &.{ "claim", password, "--for", "2h" });
    const signed = try fixture.remoteGit(&remote, &.{ "cat-file", "commit", "main" });
    try sandbox.expectContains(signed, "gpgsig -----BEGIN PGP SIGNATURE-----");
}

// specrail: specs/cli/claim.spec.md § 2.1 Release commit
// specrail: specs/cli/claim.spec.md § 2.3 Output
test "release pushes a commit that removes the claim" {
    var remote = try Sandbox.init();
    defer remote.deinit();
    var s = try Sandbox.init();
    defer s.deinit();
    try fixture.setUp(&s, &remote, config_toml);
    try succeed(&s, &.{ "claim", google, "--for", "2h" });
    const o = try runClaim(&s, &.{ "release", google }, "agent-7");
    try testing.expectEqual(@as(u8, 0), o.code);
    const tip = try fixture.remoteTip(&remote);
    try testing.expectEqualStrings(try s.arena_state.allocator().print("{s}\n", .{tip}), o.stdout);
    try testing.expectEqualStrings(fixture.login, try fixture.remoteSpec(&remote));
    const subject = try fixture.remoteGit(&remote, &.{ "log", "-1", "--format=%s", "main" });
    try testing.expectEqualStrings("specrail release " ++ google, subject);
}

// specrail: specs/cli/claim.spec.md § 2.2 Only the holder
test "only the holder releases a claim, and an unclaimed section needs no release" {
    var remote = try Sandbox.init();
    defer remote.deinit();
    var s = try Sandbox.init();
    defer s.deinit();
    try fixture.setUp(&s, &remote, config_toml);
    try succeed(&s, &.{ "claim", google, "--for", "2h" });
    const base = try fixture.remoteTip(&remote);
    const other = try runClaim(&s, &.{ "release", google, "--as", "agent-3" }, null);
    try testing.expectEqual(@as(u8, 1), other.code);
    const not_theirs = "held by agent-7 until 2026-11-17T02:00:00Z, not by agent-3";
    try sandbox.expectContains(other.stderr, not_theirs);
    const unclaimed = try runClaim(&s, &.{ "release", password }, "agent-7");
    try testing.expectEqual(@as(u8, 0), unclaimed.code);
    try testing.expectEqualStrings("", unclaimed.stdout);
    try sandbox.expectContains(unclaimed.stderr, "has no claim");
    try testing.expectEqualStrings(base, try fixture.remoteTip(&remote));
}
