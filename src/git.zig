//! Running git, for the commands that read and write history: `claim`,
//! `release` and `hook`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

const cli = @import("cli.zig");

/// What one git command printed, and whether it succeeded.
pub const Output = struct {
    success: bool,
    /// The exit status; 255 when git could not be started at all.
    status: u8,
    stdout: []const u8,
    stderr: []const u8,

    /// The standard output without surrounding whitespace, such as a single
    /// object id.
    pub fn text(o: Output) []const u8 {
        return std.mem.trim(u8, o.stdout, " \t\r\n");
    }

    /// The standard error without surrounding whitespace, or a stand-in when
    /// it is empty.
    pub fn reason(o: Output) []const u8 {
        const r = std.mem.trim(u8, o.stderr, " \t\r\n");
        return if (r.len > 0) r else "git gave no reason";
    }
};

/// Runs `git args` in `cwd` with the context's git environment, or with `env`
/// when it is given. When git cannot be started, the result says so as a
/// failed run.
pub fn run(
    ctx: *cli.Ctx,
    cwd: []const u8,
    args: []const []const u8,
    env: ?*const Environ.Map,
) Allocator.Error!Output {
    const argv = try ctx.arena.alloc([]const u8, args.len + 1);
    argv[0] = "git";
    @memcpy(argv[1..], args);
    const options: std.process.RunOptions = .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = env orelse ctx.git_env,
    };
    const r = std.process.run(ctx.arena, ctx.io, options) catch |e| {
        const msg = try ctx.arena.print("cannot run git: {s}", .{@errorName(e)});
        return .{ .success = false, .status = 255, .stdout = "", .stderr = msg };
    };
    const status: u8 = switch (r.term) {
        .exited => |code| code,
        else => 255,
    };
    return .{ .success = status == 0, .status = status, .stdout = r.stdout, .stderr = r.stderr };
}

/// The context's git environment with `key` set to `value`.
pub fn withVariable(
    ctx: *cli.Ctx,
    key: []const u8,
    value: []const u8,
) Allocator.Error!*const Environ.Map {
    const env = try ctx.arena.create(Environ.Map);
    env.* = if (ctx.git_env) |base| try base.clone(ctx.arena) else .init(ctx.arena);
    try env.put(key, value);
    return env;
}

/// Whether `id` is git's all-zero object id, which stands for a ref that does
/// not exist.
pub fn isZero(id: []const u8) bool {
    return id.len > 0 and std.mem.trimEnd(u8, id, "0").len == 0;
}

test "the all-zero object id names a missing ref" {
    try std.testing.expect(isZero("0000000000000000000000000000000000000000"));
    try std.testing.expect(!isZero("0000000000000000000000000000000000000001"));
    try std.testing.expect(!isZero(""));
}
