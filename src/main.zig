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
    const code: u8 = run(init, &out.interface, &err.interface) catch |e| failed: {
        err.interface.print("specrail: {s}\n", .{@errorName(e)}) catch break :failed 2;
        break :failed 2;
    };
    // Output that cannot be delivered means the command did not run properly.
    out.interface.flush() catch return 2;
    err.interface.flush() catch return 2;
    return code;
}

fn run(init: std.process.Init, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const raw = try init.minimal.args.toSlice(arena);
    const argv = try arena.alloc([]const u8, raw.len);
    for (raw, 0..) |a, i| argv[i] = a;
    var ctx: cli.Ctx = .{
        .arena = arena,
        .io = io,
        .stdout = stdout,
        .stderr = stderr,
        .stdout_is_tty = std.Io.File.stdout().isTty(io) catch false,
        .no_color = init.environ_map.get("NO_COLOR"),
        .cwd = try std.process.currentPathAlloc(io, arena),
        .now = @intCast(@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s)),
    };
    return cli.run(&ctx, argv);
}

test {
    _ = @import("changes.zig");
    _ = @import("check.zig");
    _ = @import("cli.zig");
    _ = @import("config.zig");
    _ = @import("context.zig");
    _ = @import("date.zig");
    _ = @import("diag.zig");
    _ = @import("edit.zig");
    _ = @import("files.zig");
    _ = @import("fmt.zig");
    _ = @import("init.zig");
    _ = @import("mv.zig");
    _ = @import("project.zig");
    _ = @import("refs.zig");
    _ = @import("rewrite.zig");
    _ = @import("skill.zig");
    _ = @import("spec.zig");
    _ = @import("swap.zig");
    _ = @import("toml.zig");
}
