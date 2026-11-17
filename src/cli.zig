//! Argument parsing, help, usage errors and color.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const check = @import("check.zig");
const init_command = @import("init.zig");
const skill = @import("skill.zig");

/// When diagnostics are colored, as chosen by `--color=<when>`.
pub const ColorMode = enum { always, auto, never };

/// What commands can fail with, besides the problems they report.
pub const Error = Allocator.Error || Io.Writer.Error;

/// Everything a command needs from the outside world.
pub const Ctx = struct {
    arena: Allocator,
    io: Io,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    stdout_is_tty: bool = false,
    /// The value of NO_COLOR, if set.
    no_color: ?[]const u8 = null,
    /// Absolute path of the working directory.
    cwd: []const u8,
    /// Seconds since the epoch.
    now: i64,
    /// Environment for git; null inherits ours.
    git_env: ?*const std.process.Environ.Map = null,
    /// Where the search for the project root stops; tests use it to stay
    /// inside their sandbox.
    root_ceiling: ?[]const u8 = null,
    /// Whether diagnostics on stdout are colored; set from --color.
    color: bool = false,
};

/// Decides whether to color output. `auto` colors only a terminal, and only
/// when NO_COLOR is unset or empty.
pub fn useColor(mode: ColorMode, is_tty: bool, no_color: ?[]const u8) bool {
    return switch (mode) {
        .always => true,
        .never => false,
        .auto => is_tty and (no_color == null or no_color.?.len == 0),
    };
}

const Command = struct {
    name: []const u8,
    summary: []const u8,
};

/// Every command, as `specrail --help` lists them.
pub const commands = [_]Command{
    .{ .name = "init", .summary = "Set up a project: specrail.toml and the spec root" },
    .{ .name = "check", .summary = "Verify specs, references and coverage" },
    .{ .name = "skill", .summary = "Print the agent skill" },
};

fn writeHelp(w: *Io.Writer) Io.Writer.Error!void {
    try w.writeAll(
        \\specrail keeps specs linked to the tests that prove them.
        \\
        \\Usage: specrail [--color=<when>] <command> [<args>]
        \\
        \\Commands:
        \\
    );
    for (commands) |c| try w.print("  {s:<8} {s}\n", .{ c.name, c.summary });
    try w.writeAll(
        \\
        \\Options:
        \\  --color=<when>   Color diagnostics: auto (default), always or never
        \\  --help           Show this help
        \\
        \\Run 'specrail <command> --help' for a command's usage.
        \\
    );
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

/// Prints a usage error with a hint, and returns exit status 2.
pub fn usageError(
    ctx: *Ctx,
    command: ?[]const u8,
    comptime fmt: []const u8,
    args: anytype,
) Io.Writer.Error!u8 {
    try ctx.stderr.print("specrail: " ++ fmt ++ "\n", args);
    if (command) |c| {
        try ctx.stderr.print("Run 'specrail {s} --help' for usage.\n", .{c});
    } else try ctx.stderr.writeAll("Run 'specrail --help' for usage.\n");
    return 2;
}

/// Runs specrail with `argv` (including the program name) and returns the
/// exit status.
pub fn run(ctx: *Ctx, argv: []const []const u8) u8 {
    return runArgs(ctx, if (argv.len > 0) argv[1..] else argv) catch |e| {
        // Reporting may fail too; the status is 2 either way.
        ctx.stderr.print("specrail: {s}\n", .{@errorName(e)}) catch return 2;
        return 2;
    };
}

fn runArgs(ctx: *Ctx, argv: []const []const u8) !u8 {
    var mode: ColorMode = .auto;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(ctx.arena);
    for (argv) |a| {
        if (std.mem.eql(u8, a, "--color") or std.mem.startsWith(u8, a, "--color=")) {
            const value = if (a.len > "--color=".len) a["--color=".len..] else "";
            mode = std.meta.stringToEnum(ColorMode, value) orelse
                return usageError(
                    ctx,
                    null,
                    "--color takes auto, always or never, as in --color=never",
                    .{},
                );
        } else try args.append(ctx.arena, a);
    }
    ctx.color = useColor(mode, ctx.stdout_is_tty, ctx.no_color);
    if (args.items.len == 0) return usageError(ctx, null, "missing command", .{});
    const cmd = args.items[0];
    if (isHelp(cmd)) {
        try writeHelp(ctx.stdout);
        return 0;
    }
    if (std.mem.startsWith(u8, cmd, "-")) {
        return usageError(ctx, null, "unknown option '{s}'", .{cmd});
    }
    const rest = args.items[1..];
    if (std.mem.eql(u8, cmd, "check")) return runCheck(ctx, rest);
    if (std.mem.eql(u8, cmd, "init")) return runInit(ctx, rest);
    if (std.mem.eql(u8, cmd, "skill")) return runSkill(ctx, rest);
    return usageError(ctx, null, "unknown command '{s}'", .{cmd});
}

fn runInit(ctx: *Ctx, args: []const []const u8) !u8 {
    var opts: init_command.Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (isHelp(a)) {
            try ctx.stdout.writeAll(init_command.usage);
            return 0;
        }
        if (std.mem.eql(u8, a, "--spec-root")) {
            i += 1;
            if (i == args.len) return usageError(ctx, "init", "--spec-root needs a directory", .{});
            opts.spec_root = args[i];
        } else if (std.mem.startsWith(u8, a, "--spec-root=")) {
            opts.spec_root = a["--spec-root=".len..];
        } else if (std.mem.startsWith(u8, a, "-")) {
            return usageError(ctx, "init", "unknown option '{s}'", .{a});
        } else {
            return usageError(ctx, "init", "unexpected argument '{s}'", .{a});
        }
    }
    return init_command.run(ctx, opts);
}

fn runSkill(ctx: *Ctx, args: []const []const u8) !u8 {
    for (args) |a| {
        if (isHelp(a)) {
            try ctx.stdout.writeAll(skill.usage);
            return 0;
        }
        return usageError(ctx, "skill", "unexpected argument '{s}'", .{a});
    }
    return skill.run(ctx);
}

fn runCheck(ctx: *Ctx, args: []const []const u8) !u8 {
    var opts: check.Options = .{};
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(ctx.arena);
    for (args) |a| {
        if (isHelp(a)) {
            try ctx.stdout.writeAll(check.usage);
            return 0;
        }
        if (std.mem.eql(u8, a, "--json")) {
            opts.json = true;
        } else if (std.mem.eql(u8, a, "--warnings-as-errors")) {
            opts.warnings_as_errors = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return usageError(ctx, "check", "unknown option '{s}'", .{a});
        } else try paths.append(ctx.arena, a);
    }
    opts.paths = paths.items;
    return check.run(ctx, opts);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// A throwaway git repository with a specrail project in it.
const Sandbox = struct {
    tmp: testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    root: []const u8,

    fn init() !Sandbox {
        var s: Sandbox = .{
            .tmp = testing.tmpDir(.{}),
            .arena_state = .init(testing.allocator),
            .root = undefined,
        };
        s.root = try s.tmp.dir.realPathFileAlloc(testing.io, ".", s.arena_state.allocator());
        try s.git(&.{ "git", "init", "-q" });
        return s;
    }

    fn deinit(s: *Sandbox) void {
        s.tmp.cleanup();
        s.arena_state.deinit();
    }

    fn git(s: *Sandbox, argv: []const []const u8) !void {
        const r = try std.process.run(
            s.arena_state.allocator(),
            testing.io,
            .{ .argv = argv, .cwd = .{ .path = s.root } },
        );
        if (!r.term.success()) return error.GitFailed;
    }

    fn write(s: *Sandbox, path: []const u8, data: []const u8) !void {
        if (std.Io.Dir.path.dirname(path)) |dir| try s.tmp.dir.createDirPath(testing.io, dir);
        try s.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = data });
    }

    fn read(s: *Sandbox, path: []const u8) ![]const u8 {
        return s.tmp.dir.readFileAlloc(testing.io, path, s.arena_state.allocator(), .unlimited);
    }

    fn exists(s: *Sandbox, path: []const u8) bool {
        return if (s.tmp.dir.access(testing.io, path, .{})) |_| true else |_| false;
    }

    const Output = struct {
        code: u8,
        stdout: []const u8,
        stderr: []const u8,
    };

    fn runIn(s: *Sandbox, sub: []const u8, args: []const []const u8, options: struct {
        tty: bool = false,
        no_color: ?[]const u8 = null,
        git_env: ?*const std.process.Environ.Map = null,
    }) !Output {
        const arena = s.arena_state.allocator();
        var out: Io.Writer.Allocating = .init(arena);
        var err: Io.Writer.Allocating = .init(arena);
        var ctx: Ctx = .{
            .arena = arena,
            .io = testing.io,
            .stdout = &out.writer,
            .stderr = &err.writer,
            .stdout_is_tty = options.tty,
            .no_color = options.no_color,
            .cwd = try std.Io.Dir.path.join(arena, &.{ s.root, sub }),
            .now = 20774 * 86400,
            .git_env = options.git_env,
            .root_ceiling = s.root,
        };
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        try argv.append(arena, "specrail");
        try argv.appendSlice(arena, args);
        const code = run(&ctx, argv.items);
        return .{ .code = code, .stdout = out.written(), .stderr = err.written() };
    }

    fn runAtRoot(s: *Sandbox, args: []const []const u8) !Output {
        return s.runIn("", args, .{});
    }

    /// A small project that passes check.
    fn passing(s: *Sandbox) !void {
        try s.write("specrail.toml", "spec_root = \"specs\"\n");
        try s.write("specs/a.spec.md", "# § 1 One\n\nIt MUST work.\n");
        try s.write("src/a_test.zig", "// specrail: specs/a.spec.md § 1 One\n");
    }
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.find(u8, haystack, needle) == null) {
        std.debug.print("expected '{s}' in:\n{s}\n", .{ needle, haystack });
        return error.TestUnexpectedResult;
    }
}

// specrail: specs/cli.spec.md § 1.1 Help
test "help lists every command and each command has usage" {
    var s = try Sandbox.init();
    defer s.deinit();
    const top = try s.runAtRoot(&.{"--help"});
    try testing.expectEqual(@as(u8, 0), top.code);
    for (commands) |c| try expectContains(top.stdout, c.name);
    for (commands) |c| {
        const one = try s.runAtRoot(&.{ c.name, "--help" });
        try testing.expectEqual(@as(u8, 0), one.code);
        try expectContains(one.stdout, "Usage: specrail ");
    }
}

// specrail: specs/cli.spec.md § 1.2 Usage errors
test "usage errors go to stderr with a hint and exit with status 2" {
    var s = try Sandbox.init();
    defer s.deinit();
    const cases = [_]struct { args: []const []const u8, hint: []const u8 }{
        .{ .args = &.{}, .hint = "specrail --help" },
        .{ .args = &.{"frobnicate"}, .hint = "specrail --help" },
        .{ .args = &.{"--frob"}, .hint = "specrail --help" },
        .{ .args = &.{"--color=sometimes"}, .hint = "specrail --help" },
        .{ .args = &.{ "check", "--frob" }, .hint = "specrail check --help" },
    };
    for (cases) |case| {
        const o = try s.runAtRoot(case.args);
        try testing.expectEqual(@as(u8, 2), o.code);
        try testing.expectEqualStrings("", o.stdout);
        try expectContains(o.stderr, case.hint);
    }
}

// specrail: specs/cli.spec.md § 2.2 Color option
// specrail: specs/cli.spec.md § 2.4 Forced color
// specrail: specs/cli.spec.md § 2.5 No color
test "--color=always and --color=never override the defaults" {
    var s = try Sandbox.init();
    defer s.deinit();
    try s.passing();
    try s.write("specs/b.spec.md", "# § 1 Uncovered\n\nIt MUST be reported.\n");
    const forced = try s.runIn("", &.{ "--color=always", "check" }, .{ .no_color = "1" });
    try expectContains(forced.stdout, "\x1b[31merror");
    const never = try s.runIn("", &.{ "check", "--color=never" }, .{ .tty = true });
    try testing.expect(std.mem.find(u8, never.stdout, "\x1b[") == null);
    const auto = try s.runIn("", &.{ "check", "--color=auto" }, .{ .tty = true });
    try expectContains(auto.stdout, "\x1b[31merror");
}

// specrail: specs/cli.spec.md § 2.3 Automatic color
test "by default color is on only for a terminal without NO_COLOR" {
    try testing.expect(useColor(.auto, true, null));
    try testing.expect(useColor(.auto, true, ""));
    try testing.expect(!useColor(.auto, true, "1"));
    try testing.expect(!useColor(.auto, false, null));
}

// specrail: specs/cli/check.spec.md § 4.1 Pass and fail
test "check exits 0 without errors and 1 with errors" {
    var s = try Sandbox.init();
    defer s.deinit();
    try s.passing();
    try s.write("specs/w.spec.md", "# § 1 Draft\n```toml\nstatus = \"planned\"\n```\nTBD.\n");
    const ok = try s.runAtRoot(&.{"check"});
    try testing.expectEqual(@as(u8, 0), ok.code);
    try expectContains(ok.stdout, "warning:");
    try expectContains(ok.stdout, "note:");
    try s.write("specs/b.spec.md", "# § 1 Uncovered\n\nIt MUST be reported.\n");
    const failing = try s.runAtRoot(&.{"check"});
    try testing.expectEqual(@as(u8, 1), failing.code);
    try expectContains(failing.stdout, "specs/b.spec.md:1:1: error: § 1 Uncovered is not covered");
}

// specrail: specs/config.spec.md § 1.2 No project root
test "without specrail.toml, commands exit 2 and suggest init" {
    var s = try Sandbox.init();
    defer s.deinit();
    const o = try s.runAtRoot(&.{"check"});
    try testing.expectEqual(@as(u8, 2), o.code);
    try expectContains(o.stderr, "specrail init");
}

// specrail: specs/config.spec.md § 1.1 Finding the project root
test "commands find the project root from a subdirectory" {
    var s = try Sandbox.init();
    defer s.deinit();
    try s.passing();
    const o = try s.runIn("src", &.{ "check", "../specs/a.spec.md" }, .{});
    try testing.expectEqual(@as(u8, 0), o.code);
    try expectContains(o.stdout, "1/1 done leaves covered");
}

// specrail: specs/config.spec.md § 3.1 Listed files
test "only files git lists are scanned" {
    var s = try Sandbox.init();
    defer s.deinit();
    try s.write("specrail.toml", "spec_root = \"specs\"\n");
    try s.write("specs/a.spec.md", "# § 1 One\n\nIt MUST work.\n# § 2 Two\n\nIt MUST work.\n");
    try s.write(".gitignore", "ignored/\n");
    try s.write("tracked.zig", "// specrail: specs/a.spec.md § 1 One\n");
    try s.git(&.{ "git", "add", "tracked.zig" });
    try s.write("ignored/t.zig", "// specrail: specs/a.spec.md § 2 Two\n");
    const o = try s.runAtRoot(&.{"check"});
    try testing.expectEqual(@as(u8, 1), o.code);
    try expectContains(o.stdout, "§ 2 Two is not covered");
    try expectContains(o.stdout, "1/2 done leaves covered");
}

// specrail: specs/config.spec.md § 3.2 Without git
test "outside a git work tree, commands exit 2 with git's reason" {
    var s = try Sandbox.init();
    defer s.deinit();
    try s.passing();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("GIT_DIR", "/nonexistent/specrail-test");
    const o = try s.runIn("", &.{"check"}, .{ .git_env = &env });
    try testing.expectEqual(@as(u8, 2), o.code);
    try expectContains(o.stderr, "not a git repository");
}

// specrail: specs/format/references.spec.md § 2.1 Scanned files
// specrail: specs/format/references.spec.md § 2.2 Binary files
test "spec files, excluded files and binary files are not scanned" {
    var s = try Sandbox.init();
    defer s.deinit();
    try s.write("specrail.toml", "spec_root = \"specs\"\nexclude = [\"docs/**\"]\n");
    try s.write(
        "specs/a.spec.md",
        "# § 1 One\n\nIt MUST work.\n\n```\n// specrail: specs/nope.spec.md § 1 Example\n```\n",
    );
    try s.write("docs/guide.md", "// specrail: specs/nope.spec.md § 1 Example\n");
    try s.write("blob.bin", "\x00// specrail: specs/nope.spec.md § 1 Example\n");
    try s.write("t.zig", "// specrail: specs/a.spec.md § 1 One\n");
    const o = try s.runAtRoot(&.{"check"});
    try testing.expectEqual(@as(u8, 0), o.code);
}

// specrail: specs/cli/init.spec.md § 1.1 Create config
// specrail: specs/cli/init.spec.md § 1.2 Root file
test "init sets up a project that check accepts" {
    var s = try Sandbox.init();
    defer s.deinit();
    const o = try s.runAtRoot(&.{"init"});
    try testing.expectEqual(@as(u8, 0), o.code);
    try testing.expectEqualStrings("spec_root = \"specs\"\n", try s.read("specrail.toml"));
    try expectContains(try s.read("specs/root.spec.md"), "root of the spec tree");
    try expectContains(o.stdout, "created specs/root.spec.md");
    const checked = try s.runAtRoot(&.{"check"});
    try testing.expectEqual(@as(u8, 0), checked.code);
}

// specrail: specs/cli/init.spec.md § 1.2 Root file
test "init keeps a root file that already exists" {
    var s = try Sandbox.init();
    defer s.deinit();
    try s.write("specs/root.spec.md", "Our own context.\n");
    const o = try s.runAtRoot(&.{"init"});
    try testing.expectEqual(@as(u8, 0), o.code);
    try testing.expectEqualStrings("Our own context.\n", try s.read("specs/root.spec.md"));
}

// specrail: specs/cli/init.spec.md § 1.3 Spec root option
test "init puts the spec root where --spec-root says" {
    var s = try Sandbox.init();
    defer s.deinit();
    const o = try s.runAtRoot(&.{ "init", "--spec-root", "docs/specs/" });
    try testing.expectEqual(@as(u8, 0), o.code);
    try testing.expectEqualStrings("spec_root = \"docs/specs\"\n", try s.read("specrail.toml"));
    try testing.expect(s.exists("docs/specs/root.spec.md"));
    try testing.expectEqual(@as(u8, 0), (try s.runAtRoot(&.{"check"})).code);
    const outside = try s.runAtRoot(&.{ "init", "--spec-root=../elsewhere" });
    try testing.expectEqual(@as(u8, 2), outside.code);
}

// specrail: specs/cli/init.spec.md § 1.4 Already initialized
test "init changes nothing in a project that is already set up" {
    var s = try Sandbox.init();
    defer s.deinit();
    try s.write("specrail.toml", "spec_root = \"other\"\n");
    const o = try s.runAtRoot(&.{"init"});
    try testing.expectEqual(@as(u8, 2), o.code);
    try expectContains(o.stderr, "already has a specrail.toml");
    try testing.expectEqualStrings("spec_root = \"other\"\n", try s.read("specrail.toml"));
    try testing.expect(!s.exists("specs"));
}

// specrail: specs/cli/skill.spec.md § 1.1 Output
test "skill prints the embedded skill, with or without a project" {
    var s = try Sandbox.init();
    defer s.deinit();
    const o = try s.runAtRoot(&.{"skill"});
    try testing.expectEqual(@as(u8, 0), o.code);
    try testing.expectEqualStrings(skill.text, o.stdout);
}
