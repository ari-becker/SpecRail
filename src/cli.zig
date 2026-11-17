//! Argument parsing, help, usage errors and color.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const check = @import("check.zig");
const context = @import("context.zig");
const fmt_command = @import("fmt.zig");
const init_command = @import("init.zig");
const mv_command = @import("mv.zig");
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
    .{ .name = "context", .summary = "Print what to read before working on a section" },
    .{ .name = "fmt", .summary = "Renumber sections, rewrite references, normalize spec files" },
    .{ .name = "mv", .summary = "Move or retitle a section, spec file or directory" },
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
    if (std.mem.eql(u8, cmd, "context")) return runContext(ctx, rest);
    if (std.mem.eql(u8, cmd, "fmt")) return runFmt(ctx, rest);
    if (std.mem.eql(u8, cmd, "mv")) return runMv(ctx, rest);
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

fn runFmt(ctx: *Ctx, args: []const []const u8) !u8 {
    var opts: fmt_command.Options = .{};
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(ctx.arena);
    for (args) |a| {
        if (isHelp(a)) {
            try ctx.stdout.writeAll(fmt_command.usage);
            return 0;
        }
        if (std.mem.eql(u8, a, "--check")) {
            opts.check = true;
        } else if (std.mem.eql(u8, a, "--json")) {
            opts.json = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return usageError(ctx, "fmt", "unknown option '{s}'", .{a});
        } else try paths.append(ctx.arena, a);
    }
    if (opts.json and !opts.check) return usageError(ctx, "fmt", "--json needs --check", .{});
    opts.paths = paths.items;
    return fmt_command.run(ctx, opts);
}

fn runMv(ctx: *Ctx, args: []const []const u8) !u8 {
    for (args) |a| {
        if (isHelp(a)) {
            try ctx.stdout.writeAll(mv_command.usage);
            return 0;
        }
        if (std.mem.startsWith(u8, a, "--")) {
            return usageError(ctx, "mv", "unknown option '{s}'", .{a});
        }
    }
    return mv_command.run(ctx, args);
}

fn runContext(ctx: *Ctx, args: []const []const u8) !u8 {
    for (args) |a| {
        if (isHelp(a)) {
            try ctx.stdout.writeAll(context.usage);
            return 0;
        }
        if (std.mem.startsWith(u8, a, "--")) {
            return usageError(ctx, "context", "unknown option '{s}'", .{a});
        }
    }
    return context.run(ctx, args);
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

const sandbox = @import("sandbox.zig");

// specrail: specs/cli.spec.md § 1.1 Help
test "help lists every command and each command has usage" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    const top = try s.runAtRoot(&.{"--help"});
    try testing.expectEqual(@as(u8, 0), top.code);
    for (commands) |c| try sandbox.expectContains(top.stdout, c.name);
    for (commands) |c| {
        const one = try s.runAtRoot(&.{ c.name, "--help" });
        try testing.expectEqual(@as(u8, 0), one.code);
        try sandbox.expectContains(one.stdout, "Usage: specrail ");
    }
}

// specrail: specs/cli.spec.md § 1.2 Usage errors
test "usage errors go to stderr with a hint and exit with status 2" {
    var s = try sandbox.Sandbox.init();
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
        try sandbox.expectContains(o.stderr, case.hint);
    }
}

// specrail: specs/cli.spec.md § 2.2 Color option
// specrail: specs/cli.spec.md § 2.4 Forced color
// specrail: specs/cli.spec.md § 2.5 No color
test "--color=always and --color=never override the defaults" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try s.passing();
    try s.write("specs/b.spec.md", "# § 1 Uncovered\n\nIt MUST be reported.\n");
    const forced = try s.runIn("", &.{ "--color=always", "check" }, .{ .no_color = "1" });
    try sandbox.expectContains(forced.stdout, "\x1b[31merror");
    const never = try s.runIn("", &.{ "check", "--color=never" }, .{ .tty = true });
    try testing.expect(std.mem.find(u8, never.stdout, "\x1b[") == null);
    const auto = try s.runIn("", &.{ "check", "--color=auto" }, .{ .tty = true });
    try sandbox.expectContains(auto.stdout, "\x1b[31merror");
}

// specrail: specs/cli.spec.md § 2.3 Automatic color
test "by default color is on only for a terminal without NO_COLOR" {
    try testing.expect(useColor(.auto, true, null));
    try testing.expect(useColor(.auto, true, ""));
    try testing.expect(!useColor(.auto, true, "1"));
    try testing.expect(!useColor(.auto, false, null));
}
