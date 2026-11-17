//! `specrail init`: sets up a project in the working directory.

const std = @import("std");
const Io = std.Io;

const cli = @import("cli.zig");
const config = @import("config.zig");

/// Help text for `specrail init --help`.
pub const usage =
    \\Usage: specrail init [--spec-root <dir>]
    \\
    \\Set up a project in the working directory: specrail.toml, the spec root
    \\(specs/ unless --spec-root names another), and a root.spec.md holding the
    \\context every spec shares.
    \\
    \\Options:
    \\  --spec-root <dir>   Keep the specs in <dir> instead of specs/
    \\  --help              Show this help
    \\
;

/// Command-line options for `specrail init`.
pub const Options = struct {
    spec_root: []const u8 = "specs",
};

/// The root file a new project starts with: context only, so that
/// `specrail check` passes before any spec is written. `{s}` is the spec root.
const root_template =
    \\# Specs
    \\
    \\This file is the root of the spec tree. Everything in it is context for every
    \\spec in this project: say here what the project is for, the words its specs
    \\use, and anything else they all assume.
    \\
    \\Specs live in `*.spec.md` files under this directory. A spec file starts with
    \\context, then a line holding only `---`, then numbered sections such as
    \\`# § 1 Title` and `## § 1.1 Title`. Requirements go only in leaf sections, the
    \\ones without children, written with the uppercase requirement keywords of
    \\RFC 2119; context such as this file never uses them.
    \\
    \\A test claims the leaf it verifies with a comment line of its own, such as
    \\`// specrail: {s}example.spec.md § 1.1 Title`. Run `specrail check` to see
    \\which requirements still need tests, and `specrail skill` for the whole
    \\workflow.
    \\
;

fn fail(ctx: *cli.Ctx, comptime fmt: []const u8, args: anytype) Io.Writer.Error!u8 {
    try ctx.stderr.print("specrail: " ++ fmt ++ "\n", args);
    return 2;
}

/// `s` as a TOML basic string.
fn tomlString(arena: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    try out.append(arena, '"');
    for (s) |c| {
        if (c == '"' or c == '\\') try out.append(arena, '\\');
        try out.append(arena, c);
    }
    try out.append(arena, '"');
    return out.toOwnedSlice(arena);
}

/// Runs `specrail init` and returns its exit status.
pub fn run(ctx: *cli.Ctx, opts: Options) cli.Error!u8 {
    const spec_root = config.normalizeDir(opts.spec_root) orelse return cli.usageError(
        ctx,
        "init",
        "--spec-root must name a directory inside the project, not '{s}'",
        .{opts.spec_root},
    );
    var dir = Io.Dir.cwd().openDir(ctx.io, ctx.cwd, .{}) catch |e| {
        return fail(ctx, "cannot open {s}: {s}", .{ ctx.cwd, @errorName(e) });
    };
    defer dir.close(ctx.io);
    const initialized = if (dir.access(ctx.io, config.file_name, .{})) |_| true else |_| false;
    if (initialized) {
        return fail(
            ctx,
            "{s} already has a {s}; the project is set up",
            .{ ctx.cwd, config.file_name },
        );
    }

    if (spec_root.len > 0) {
        dir.createDirPath(ctx.io, spec_root) catch |e| {
            return fail(ctx, "cannot create {s}: {s}", .{ spec_root, @errorName(e) });
        };
    }
    const prefix = if (spec_root.len == 0) "" else try ctx.arena.print("{s}/", .{spec_root});
    const root_path = try ctx.arena.print("{s}root.spec.md", .{prefix});
    const root_text = try ctx.arena.print(root_template, .{prefix});
    // An existing root file is the project's own; it is kept as it is.
    const root_flags: Io.Dir.CreateFileOptions = .{ .exclusive = true };
    var root_created = true;
    dir.writeFile(
        ctx.io,
        .{ .sub_path = root_path, .data = root_text, .flags = root_flags },
    ) catch |e| {
        switch (e) {
            error.PathAlreadyExists => root_created = false,
            else => return fail(ctx, "cannot write {s}: {s}", .{ root_path, @errorName(e) }),
        }
    };

    const shown_root = if (spec_root.len == 0) "." else spec_root;
    const toml_text = try ctx.arena.print(
        "spec_root = {s}\n",
        .{try tomlString(ctx.arena, shown_root)},
    );
    const toml_flags: Io.Dir.CreateFileOptions = .{ .exclusive = true };
    dir.writeFile(
        ctx.io,
        .{ .sub_path = config.file_name, .data = toml_text, .flags = toml_flags },
    ) catch |e| {
        return fail(ctx, "cannot write {s}: {s}", .{ config.file_name, @errorName(e) });
    };

    try ctx.stdout.print("created {s}\n", .{config.file_name});
    if (root_created) try ctx.stdout.print("created {s}\n", .{root_path});
    return 0;
}
