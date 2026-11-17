//! `specrail context`: prints what an agent should read before working on a
//! section, from the most general context down to the section itself.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const check = @import("check.zig");
const cli = @import("cli.zig");
const files = @import("files.zig");
const project = @import("project.zig");
const refs = @import("refs.zig");
const spec = @import("spec.zig");

/// Help text for `specrail context --help`.
pub const usage =
    \\Usage: specrail context <path> [§ <number> [<title>]]
    \\
    \\Print what to read before working on a section: the context of every spec
    \\file above it, its ancestors, the section and its subsections, its
    \\dependencies, and the tests that verify it. Given only a spec file, print
    \\its context and an outline of its sections. Paths are relative to the
    \\project root, and `%` may stand in for `§`.
    \\
    \\Options:
    \\  --help   Show this help
    \\
;

/// Writes the pieces of the output, with a blank line between them.
const Printer = struct {
    out: *Writer,
    started: bool = false,

    fn gap(pr: *Printer) Writer.Error!void {
        if (pr.started) try pr.out.writeByte('\n');
        pr.started = true;
    }

    /// Writes the lines of `range`, trimmed of blank lines at either end, after
    /// a marker naming the file and the line they start on.
    fn piece(pr: *Printer, file: *const spec.SpecFile, range: spec.Range) Writer.Error!void {
        var start = range.start;
        var end = range.end;
        while (start < end and isBlank(file.lines[start])) start += 1;
        while (end > start and isBlank(file.lines[end - 1])) end -= 1;
        if (start == end) return;
        try pr.gap();
        try pr.out.print("<!-- {s}:{d} -->\n", .{ file.path, start + 1 });
        for (file.lines[start..end]) |line| {
            try pr.out.writeAll(line);
            try pr.out.writeByte('\n');
        }
    }
};

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

fn missing(ctx: *cli.Ctx, comptime fmt: []const u8, args: anytype) Writer.Error!u8 {
    try ctx.stderr.print("specrail: " ++ fmt ++ "\n", args);
    return 1;
}

/// Runs `specrail context` and returns its exit status.
pub fn run(ctx: *cli.Ctx, args: []const []const u8) cli.Error!u8 {
    if (args.len == 0) return cli.usageError(ctx, "context", "missing a spec file or section", .{});
    const address = try std.mem.join(ctx.arena, " ", args);
    const p = (try project.open(ctx)) orelse return 2;
    const input: check.Input = .{ .spec_files = p.spec_files, .source_files = p.source_files };
    const an = try check.analyze(ctx.arena, input, ctx.now);
    var pr: Printer = .{ .out = ctx.stdout };

    if (std.mem.findAny(u8, address, " \t") == null) {
        const file = an.file(
            address,
        ) orelse return missing(ctx, "there is no spec file {s}", .{address});
        try writeAncestry(ctx.arena, &pr, an, p.config.spec_root, file);
        try writeOutline(&pr, file);
        return 0;
    }
    const form = switch (refs.parseForm(address, .optional)) {
        .err => |msg| return cli.usageError(
            ctx,
            "context",
            "'{s}' is not a section: {s}",
            .{ address, msg },
        ),
        .ok => |f| f,
    };
    const file = an.file(
        form.path,
    ) orelse return missing(ctx, "there is no spec file {s}", .{form.path});
    const index = for (file.sections, 0..) |s, i| {
        if (std.mem.eql(u8, s.number, form.number)) break i;
    } else return missing(ctx, "{s} has no § {s}", .{ form.path, form.number });
    const s = file.sections[index];
    if (form.title.len > 0 and !std.mem.eql(u8, form.title, s.title)) {
        return missing(
            ctx,
            "stale address {s} § {s} {s}: the section is now § {s} {s}",
            .{ form.path, form.number, form.title, s.number, s.title },
        );
    }
    try writeAncestry(ctx.arena, &pr, an, p.config.spec_root, file);
    try writeSection(&pr, file, index);
    try writeDependencies(&pr, an, file, index);
    try writeVerifiers(ctx.arena, &pr, an, file, index);
    return 0;
}

/// The context of each ancestor file, outermost first, then the file's own.
fn writeAncestry(
    arena: Allocator,
    pr: *Printer,
    an: check.Analysis,
    spec_root: []const u8,
    file: *const spec.SpecFile,
) cli.Error!void {
    for (try files.ancestorFiles(arena, spec_root, file.path, &an.by_path)) |path| {
        const parent = an.file(path).?;
        try pr.piece(parent, parent.context);
    }
    try pr.piece(file, file.context);
}

/// Every section heading in the file, without prose or metadata.
fn writeOutline(pr: *Printer, file: *const spec.SpecFile) Writer.Error!void {
    if (file.sections.len == 0) return;
    try pr.gap();
    try pr.out.print("<!-- {s}:{d} -->\n", .{ file.path, file.sections[0].line });
    for (file.sections) |s| {
        try pr.out.writeAll(file.lines[s.line - 1]);
        try pr.out.writeByte('\n');
    }
}

/// The section's ancestors, top-level first, each without its other children;
/// then the section with its whole subtree.
fn writeSection(pr: *Printer, file: *const spec.SpecFile, index: usize) Writer.Error!void {
    // Each parent is one level up, and there are six levels at most.
    var chain: [6]usize = undefined;
    var depth: usize = 0;
    var next = file.sections[index].parent;
    while (next) |i| : (next = file.sections[i].parent) {
        chain[depth] = i;
        depth += 1;
    }
    for (0..depth) |k| {
        const a = file.sections[chain[depth - 1 - k]];
        try pr.piece(file, .{ .start = a.line - 1, .end = a.own_end });
    }
    const s = file.sections[index];
    try pr.piece(file, .{ .start = s.line - 1, .end = s.subtree_end });
}

/// The dependency entries of the section and its ancestors, each with the
/// effective status of the section it names.
fn writeDependencies(
    pr: *Printer,
    an: check.Analysis,
    file: *const spec.SpecFile,
    index: usize,
) Writer.Error!void {
    var listed = false;
    var next: ?usize = index;
    while (next) |i| : (next = file.sections[i].parent) {
        const m = file.sections[i].metadata orelse continue;
        for (m.dependencies) |dep| {
            if (!listed) {
                try pr.gap();
                try pr.out.writeAll("Dependencies:\n");
                listed = true;
            }
            const f = dep.form;
            const target = an.section(f.path, f.number);
            const status = if (target) |t|
                if (std.mem.eql(u8, t.title, f.title)) t.effective.name() else "stale"
            else
                "not found";
            try pr.out.print("- {s} § {s} {s} ({s})\n", .{ f.path, f.number, f.title, status });
        }
    }
}

fn byLocation(_: void, a: check.Reference, b: check.Reference) bool {
    return switch (std.mem.order(u8, a.path, b.path)) {
        .lt => true,
        .gt => false,
        .eq => a.line < b.line,
    };
}

/// Where every reference to the section, or to a leaf below it, is written.
fn writeVerifiers(
    arena: Allocator,
    pr: *Printer,
    an: check.Analysis,
    file: *const spec.SpecFile,
    index: usize,
) cli.Error!void {
    const number = file.sections[index].number;
    var found: std.ArrayList(check.Reference) = .empty;
    defer found.deinit(arena);
    for (an.references) |r| {
        if (!std.mem.eql(u8, r.form.path, file.path)) continue;
        const n = r.form.number;
        const below = n.len > number.len and std.mem.startsWith(
            u8,
            n,
            number,
        ) and n[number.len] == '.';
        if (std.mem.eql(u8, n, number) or below) try found.append(arena, r);
    }
    if (found.items.len == 0) return;
    std.mem.sort(check.Reference, found.items, {}, byLocation);
    try pr.gap();
    try pr.out.writeAll("Verified by:\n");
    for (found.items) |r| try pr.out.print("- {s}:{d}\n", .{ r.path, r.line });
}
