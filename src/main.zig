//! The entry point: connects the process's arguments, environment, clock and
//! standard streams to `cli.run`.

const std = @import("std");

const cli = @import("cli.zig");

/// Runs specrail and returns its exit status.
pub fn main(init: std.process.Init) u8 {
    var out_buf: [16 * 1024]u8 = undefined;
    var err_buf: [4 * 1024]u8 = undefined;
    // Streaming, not positional: output appends to whatever stdout already
    // holds, such as a file opened with `>>`.
    var out: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &out_buf);
    var err: std.Io.File.Writer = .initStreaming(.stderr(), init.io, &err_buf);
    var in_buf: [16 * 1024]u8 = undefined;
    var in: std.Io.File.Reader = .initStreaming(.stdin(), init.io, &in_buf);
    const streams: Streams = .{
        .stdin = &in.interface,
        .stdout = &out.interface,
        .stderr = &err.interface,
    };
    const code: u8 = run(init, streams) catch |e| failed: {
        err.interface.print("specrail: {s}\n", .{@errorName(e)}) catch break :failed 2;
        break :failed 2;
    };
    // Output that cannot be delivered means the command did not run properly.
    out.interface.flush() catch return 2;
    err.interface.flush() catch return 2;
    return code;
}

/// `value`, unless it is empty.
fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len > 0) v else null;
}

/// The process's standard streams.
const Streams = struct {
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

fn run(init: std.process.Init, streams: Streams) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const raw = try init.minimal.args.toSlice(arena);
    const argv = try arena.alloc([]const u8, raw.len);
    for (raw, 0..) |a, i| argv[i] = a;
    var ctx: cli.Ctx = .{
        .arena = arena,
        .io = io,
        .stdout = streams.stdout,
        .stderr = streams.stderr,
        .stdin = streams.stdin,
        .stdout_is_tty = std.Io.File.stdout().isTty(io) catch false,
        .no_color = init.environ_map.get("NO_COLOR"),
        .assignee = nonEmpty(init.environ_map.get("SPECRAIL_ASSIGNEE")),
        // Passed explicitly so that commands can add to it, as claim does.
        .git_env = init.environ_map,
        .cwd = try std.process.currentPathAlloc(io, arena),
        .now = @intCast(@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s)),
    };
    return cli.run(&ctx, argv);
}

test {
    _ = @import("changes.zig");
    _ = @import("check.zig");
    _ = @import("claim.zig");
    _ = @import("claims.zig");
    _ = @import("cli.zig");
    _ = @import("config.zig");
    _ = @import("context.zig");
    _ = @import("date.zig");
    _ = @import("diag.zig");
    _ = @import("edit.zig");
    _ = @import("files.zig");
    _ = @import("fmt.zig");
    _ = @import("git.zig");
    _ = @import("hook.zig");
    _ = @import("init.zig");
    _ = @import("lsp.zig");
    _ = @import("lsp_nav.zig");
    _ = @import("lsp_text.zig");
    _ = @import("mv.zig");
    _ = @import("project.zig");
    _ = @import("refs.zig");
    _ = @import("rewrite.zig");
    _ = @import("skill.zig");
    _ = @import("spec.zig");
    _ = @import("swap.zig");
    _ = @import("toml.zig");
}
