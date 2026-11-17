//! `specrail check`: specs, references, dependencies and coverage.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const cli = @import("cli.zig");
const date = @import("date.zig");
const diag = @import("diag.zig");
const files = @import("files.zig");
const project = @import("project.zig");
const refs = @import("refs.zig");
const spec = @import("spec.zig");

/// The files `check` reads: the spec files, and the files scanned for
/// references.
pub const Input = struct {
    spec_files: []const project.SourceFile,
    source_files: []const project.SourceFile,
};

/// Everything `analyze` found, before scoping and sorting.
pub const Analysis = struct {
    diagnostics: diag.List,
    specs: []spec.SpecFile,
};

const Kind = enum {
    dependency,
    reference,

    fn name(k: Kind) []const u8 {
        return @tagName(k);
    }
};

/// Where a reference or dependency entry is written.
const Location = struct {
    path: []const u8,
    line: u32,
    column: u32,
};

const Analyzer = struct {
    arena: Allocator,
    out: diag.List = .empty,
    specs: []spec.SpecFile,
    by_path: std.StringHashMapUnmanaged(usize) = .empty,

    fn report(a: *Analyzer, d: diag.Diagnostic) Allocator.Error!void {
        try a.out.append(a.arena, d);
    }

    fn print(a: *Analyzer, comptime fmt: []const u8, args: anytype) Allocator.Error![]const u8 {
        return a.arena.print(fmt, args);
    }

    /// Finds the section a reference or dependency entry names. Reports
    /// dangling and stale ones at `where` and returns null for them.
    fn resolve(
        a: *Analyzer,
        kind: Kind,
        form: refs.Form,
        where: Location,
    ) Allocator.Error!?*spec.Section {
        const at: diag.Diagnostic = .{
            .path = where.path,
            .line = where.line,
            .column = where.column,
            .severity = .err,
            .message = "",
            .subject = form.path,
        };
        const index = a.by_path.get(form.path) orelse {
            var d = at;
            d.message = try a.print(
                "dangling {s}: there is no spec file {s}",
                .{ kind.name(), form.path },
            );
            try a.report(d);
            return null;
        };
        const sf = &a.specs[index];
        var by_number: ?usize = null;
        var by_title: std.ArrayList(usize) = .empty;
        defer by_title.deinit(a.arena);
        for (sf.sections, 0..) |*s, i| {
            const same_number = std.mem.eql(u8, s.number, form.number);
            const same_title = std.mem.eql(u8, s.title, form.title);
            if (same_number and same_title) return s;
            if (same_number and by_number == null) by_number = i;
            if (same_title) try by_title.append(a.arena, i);
        }
        var d = at;
        if (by_number == null and by_title.items.len == 0) {
            d.message = try a.print(
                "dangling {s} to § {s} {s}: {s} has no § {s} and no section titled '{s}'",
                .{ kind.name(), form.number, form.title, form.path, form.number, form.title },
            );
        } else {
            var current: std.ArrayList(u8) = .empty;
            if (by_number) |i| try current.print(
                a.arena,
                "§ {s} {s}",
                .{ sf.sections[i].number, sf.sections[i].title },
            );
            for (by_title.items) |i| {
                if (current.items.len > 0) try current.appendSlice(a.arena, " and ");
                try current.print(
                    a.arena,
                    "§ {s} {s}",
                    .{ sf.sections[i].number, sf.sections[i].title },
                );
            }
            d.message = try a.print(
                "stale {s} to § {s} {s}: {s} now has {s}",
                .{ kind.name(), form.number, form.title, form.path, current.items },
            );
        }
        try a.report(d);
        return null;
    }
};

/// Parses every spec file, resolves references and dependency entries, and
/// reports coverage, unfinished work and expired claims. `now` is seconds since
/// the epoch.
pub fn analyze(arena: Allocator, input: Input, now: i64) Allocator.Error!Analysis {
    var a: Analyzer = .{
        .arena = arena,
        .specs = try arena.alloc(spec.SpecFile, input.spec_files.len),
    };
    for (input.spec_files, 0..) |f, i| {
        a.specs[i] = try spec.parse(arena, f.path, f.content, &a.out);
        try a.by_path.put(arena, f.path, i);
    }
    for (input.source_files) |f| try scanReferences(&a, f);
    try checkDependencies(&a);
    try reportCoverage(&a);
    try noteUnfinishedWork(&a, now);
    return .{ .diagnostics = a.out, .specs = a.specs };
}

/// Resolves the references in one source file, and counts each toward the
/// coverage of the leaf it names.
fn scanReferences(a: *Analyzer, f: project.SourceFile) Allocator.Error!void {
    lines: for (try refs.scanText(a.arena, f.content)) |found| {
        switch (found.ref.result) {
            .err => |msg| try a.report(.{
                .path = f.path,
                .line = found.line,
                .column = found.ref.column,
                .severity = .err,
                .message = try a.print("malformed reference: {s}", .{msg}),
            }),
            .ok => |form| {
                const where: Location = .{
                    .path = f.path,
                    .line = found.line,
                    .column = found.ref.column,
                };
                const target = (try a.resolve(.reference, form, where)) orelse continue :lines;
                if (!target.is_leaf) {
                    try a.report(.{
                        .path = f.path,
                        .line = found.line,
                        .column = found.ref.column,
                        .severity = .err,
                        .message = try a.print(
                            "reference to § {s} {s} names a parent section; reference its " ++
                                "leaves instead",
                            .{ target.number, target.title },
                        ),
                        .subject = form.path,
                    });
                    continue :lines;
                }
                target.references += 1;
            },
        }
    }
}

/// Resolves dependency entries, and reports finished sections that wait on
/// unfinished ones.
fn checkDependencies(a: *Analyzer) Allocator.Error!void {
    for (a.specs) |sf| {
        sections: for (sf.sections) |s| {
            const m = s.metadata orelse continue :sections;
            deps: for (m.dependencies) |dep| {
                const where: Location = .{
                    .path = sf.path,
                    .line = dep.line,
                    .column = dep.column,
                };
                const target = (try a.resolve(.dependency, dep.form, where)) orelse continue :deps;
                if (s.effective == .done and target.effective != .done) {
                    try a.report(.{
                        .path = sf.path,
                        .line = dep.line,
                        .column = dep.column,
                        .severity = .err,
                        .message = try a.print(
                            "§ {s} {s} is done, but depends on § {s} {s} in {s}, which is {s}",
                            .{
                                s.number,
                                s.title,
                                target.number,
                                target.title,
                                dep.form.path,
                                target.effective.name(),
                            },
                        ),
                        .subject = dep.form.path,
                    });
                }
            }
        }
    }
}

/// Reports every done leaf that no reference names.
fn reportCoverage(a: *Analyzer) Allocator.Error!void {
    for (a.specs) |sf| {
        for (sf.sections) |s| {
            if (s.is_leaf and s.effective == .done and s.references == 0) {
                try a.report(.{
                    .path = sf.path,
                    .line = s.line,
                    .column = 1,
                    .severity = .err,
                    .message = try a.print(
                        "§ {s} {s} is not covered: no test references it",
                        .{ s.number, s.title },
                    ),
                });
            }
        }
    }
}

/// Notes each section whose own metadata block declares unfinished work, with
/// its due date and assignee, and each claim that has expired.
fn noteUnfinishedWork(a: *Analyzer, now: i64) Allocator.Error!void {
    for (a.specs) |sf| {
        sections: for (sf.sections) |s| {
            const m = s.metadata orelse continue :sections;
            if (m.status) |status| if (status != .done) {
                var msg: std.ArrayList(u8) = .empty;
                errdefer msg.deinit(a.arena);
                try msg.print(a.arena, "§ {s} {s} is {s}", .{ s.number, s.title, status.name() });
                if (m.due) |due| {
                    try msg.print(
                        a.arena,
                        "; due {d:0>4}-{d:0>2}-{d:0>2}",
                        .{ @as(u32, @intCast(due.year)), due.month, due.day },
                    );
                    if (date.isOverdue(due, now)) try msg.appendSlice(a.arena, ", overdue");
                }
                if (m.assigned) |who| {
                    try msg.print(a.arena, "; assigned to {s}", .{who});
                    if (m.assigned_until) |until| try msg.print(
                        a.arena,
                        " until {s}",
                        .{until.text},
                    );
                }
                const message = try msg.toOwnedSlice(a.arena);
                try a.report(
                    .{
                        .path = sf.path,
                        .line = s.line,
                        .column = 1,
                        .severity = .note,
                        .message = message,
                    },
                );
            };
            if (m.assigned_until) |until| if (until.seconds < now) {
                try a.report(.{
                    .path = sf.path,
                    .line = s.line,
                    .column = 1,
                    .severity = .note,
                    .message = try a.print(
                        "the claim on § {s} {s} by {s} expired at {s}",
                        .{ s.number, s.title, m.assigned orelse "nobody", until.text },
                    ),
                });
            };
        }
    }
}

/// Counts for the summary line and the JSON summary.
pub const Stats = struct {
    errors: u32 = 0,
    warnings: u32 = 0,
    done_leaves: u32 = 0,
    covered_leaves: u32 = 0,
    planned_leaves: u32 = 0,
    in_progress_leaves: u32 = 0,
};

/// What `check` prints: sorted diagnostics and the summary counts.
pub const Report = struct {
    diagnostics: []diag.Diagnostic,
    stats: Stats,
};

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

/// Scopes, sorts and counts. `selected` limits the report to those spec files
/// and the references and dependency entries that name them.
pub fn finish(
    arena: Allocator,
    analysis: Analysis,
    selected: ?[]const []const u8,
    warnings_as_errors: bool,
) Allocator.Error!Report {
    var kept: std.ArrayList(diag.Diagnostic) = .empty;
    errdefer kept.deinit(arena);
    var stats: Stats = .{};
    for (analysis.diagnostics.items) |d| {
        if (selected) |sel| {
            const subject_selected = if (d.subject) |s| contains(sel, s) else false;
            if (!contains(sel, d.path) and !subject_selected) continue;
        }
        var copy = d;
        if (warnings_as_errors and copy.severity == .warning) copy.severity = .err;
        switch (copy.severity) {
            .err => stats.errors += 1,
            .warning => stats.warnings += 1,
            .note => {},
        }
        try kept.append(arena, copy);
    }
    diag.sort(kept.items);
    for (analysis.specs) |sf| {
        if (selected) |sel| if (!contains(sel, sf.path)) continue;
        sections: for (sf.sections) |s| {
            if (!s.is_leaf) continue :sections;
            switch (s.effective) {
                .done => {
                    stats.done_leaves += 1;
                    if (s.references > 0) stats.covered_leaves += 1;
                },
                .planned => stats.planned_leaves += 1,
                .in_progress => stats.in_progress_leaves += 1,
            }
        }
    }
    return .{ .diagnostics = try kept.toOwnedSlice(arena), .stats = stats };
}

fn plural(n: u32, one: []const u8, many: []const u8) []const u8 {
    return if (n == 1) one else many;
}

/// Writes the diagnostic lines and then the summary line.
pub fn writeText(w: *Writer, r: Report, color: bool) Writer.Error!void {
    for (r.diagnostics) |d| try diag.write(w, d, color);
    const s = r.stats;
    try w.print("check: {d} {s}, {d} {s}; {d}/{d} done leaves covered; {d} planned, {d} in " ++
        "progress\n", .{
        s.errors,         plural(s.errors, "error", "errors"),
        s.warnings,       plural(s.warnings, "warning", "warnings"),
        s.covered_leaves, s.done_leaves,
        s.planned_leaves, s.in_progress_leaves,
    });
}

/// Writes one JSON object holding the diagnostics and the summary.
pub fn writeJson(w: *Writer, r: Report) Writer.Error!void {
    try w.writeAll("{\"diagnostics\":[");
    for (r.diagnostics, 0..) |d, i| {
        if (i > 0) try w.writeAll(",");
        try diag.writeJson(w, d);
    }
    const s = r.stats;
    try w.print(
        "],\"summary\":{{\"errors\":{d},\"warnings\":{d},\"done_leaves\":{d}," ++
            "\"covered_leaves\":{d},\"planned_leaves\":{d},\"in_progress_leaves\":{d}}}}}\n",
        .{
            s.errors,
            s.warnings,
            s.done_leaves,
            s.covered_leaves,
            s.planned_leaves,
            s.in_progress_leaves,
        },
    );
}

/// Command-line options for `specrail check`.
pub const Options = struct {
    json: bool = false,
    warnings_as_errors: bool = false,
    paths: []const []const u8 = &.{},
};

/// Help text for `specrail check --help`.
pub const usage =
    \\Usage: specrail check [options] [<spec file or directory>...]
    \\
    \\Verify specs, references and coverage. Given paths, report only on those
    \\spec files and the references and dependency entries that name them.
    \\
    \\Options:
    \\  --json                 Print one JSON object instead of diagnostic lines
    \\  --warnings-as-errors   Report warnings as errors
    \\  --color=<when>         Color diagnostics: auto (default), always or never
    \\  --help                 Show this help
    \\
;

/// Runs `specrail check` and returns its exit status.
pub fn run(ctx: *cli.Ctx, opts: Options) cli.Error!u8 {
    const p = (try project.open(ctx)) orelse return 2;
    var selected: ?[]const []const u8 = null;
    if (opts.paths.len > 0) {
        var sel: std.ArrayList([]const u8) = .empty;
        for (opts.paths) |arg| {
            const rel = (try project.projectPath(ctx.arena, ctx.cwd, p.root, arg)) orelse
                return cli.usageError(ctx, "check", "'{s}' is outside the project", .{arg});
            var matched = false;
            for (p.spec_files) |f| {
                if (std.mem.eql(u8, f.path, rel) or files.isUnder(f.path, rel)) {
                    matched = true;
                    if (!contains(sel.items, f.path)) try sel.append(ctx.arena, f.path);
                }
            }
            if (!matched) return cli.usageError(
                ctx,
                "check",
                "'{s}' is not a spec file or a directory of spec files",
                .{arg},
            );
        }
        selected = sel.items;
    }
    const analysis = try analyze(
        ctx.arena,
        .{ .spec_files = p.spec_files, .source_files = p.source_files },
        ctx.now,
    );
    const r = try finish(ctx.arena, analysis, selected, opts.warnings_as_errors);
    if (opts.json) try writeJson(ctx.stdout, r) else try writeText(ctx.stdout, r, ctx.color);
    return if (r.stats.errors > 0) 1 else 0;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// The tests' clock: noon UTC on 2026-11-17.
const test_now: i64 = 20774 * 86400 + 12 * 3600;

const Checked = struct {
    arena: std.heap.ArenaAllocator,
    analysis: Analysis,

    fn deinit(self: *Checked) void {
        self.arena.deinit();
    }

    fn report(self: *Checked, selected: ?[]const []const u8, warnings_as_errors: bool) !Report {
        return finish(self.arena.allocator(), self.analysis, selected, warnings_as_errors);
    }

    fn expect(
        self: *const Checked,
        path: []const u8,
        line: u32,
        severity: diag.Severity,
        needle: []const u8,
    ) !void {
        for (self.analysis.diagnostics.items) |d| {
            const same_place = std.mem.eql(u8, d.path, path) and d.line == line;
            const says = std.mem.find(u8, d.message, needle) != null;
            if (same_place and d.severity == severity and says) return;
        }
        std.debug.print(
            "no {s} containing '{s}' at {s}:{d}; got:\n",
            .{ severity.name(), needle, path, line },
        );
        self.dump();
        return error.TestUnexpectedResult;
    }

    fn expectNone(self: *const Checked, severity: diag.Severity) !void {
        for (self.analysis.diagnostics.items) |d| {
            if (d.severity == severity) {
                self.dump();
                return error.TestUnexpectedResult;
            }
        }
    }

    fn dump(self: *const Checked) void {
        for (self.analysis.diagnostics.items) |d| std.debug.print(
            "  {s}:{d}:{d}: {s}: {s}\n",
            .{ d.path, d.line, d.column, d.severity.name(), d.message },
        );
    }
};

fn checkTest(
    spec_files: []const project.SourceFile,
    source_files: []const project.SourceFile,
) !Checked {
    var c: Checked = .{ .arena = .init(testing.allocator), .analysis = undefined };
    c.analysis = try analyze(
        c.arena.allocator(),
        .{ .spec_files = spec_files, .source_files = source_files },
        test_now,
    );
    return c;
}

const login_spec: project.SourceFile = .{ .path = "specs/login.spec.md", .content =
    \\# § 1 Login
    \\## § 1.1 Password
    \\
    \\It MUST accept a password.
    \\
    \\## § 1.2 Google
    \\```toml
    \\status = "planned"
    \\```
    \\It MUST accept Google.
    \\
};

// specrail: specs/format/references.spec.md § 3.1 Dangling references
test "references to missing files or sections are dangling" {
    var c = try checkTest(&.{login_spec}, &.{.{ .path = "t.zig", .content =
        \\// specrail: specs/nope.spec.md § 1 Gone
        \\// specrail: specs/login.spec.md § 9 Nothing like it
    }});
    defer c.deinit();
    try c.expect("t.zig", 1, .err, "dangling reference: there is no spec file specs/nope.spec.md");
    try c.expect("t.zig", 2, .err, "dangling reference to § 9 Nothing like it");
}

// specrail: specs/format/references.spec.md § 3.2 Stale references
// specrail: specs/format/spec-files.spec.md § 3.7 Title comparison
test "references that match only the number or only the title are stale" {
    var c = try checkTest(&.{login_spec}, &.{.{ .path = "t.zig", .content =
        \\// specrail: specs/login.spec.md § 1.1 Passphrase
        \\// specrail: specs/login.spec.md § 1.3 Google
        \\// specrail: specs/login.spec.md § 1.1 password
        \\// specrail: specs/login.spec.md § 1.1   Password
    }});
    defer c.deinit();
    try c.expect(
        "t.zig",
        1,
        .err,
        "stale reference to § 1.1 Passphrase: specs/login.spec.md now has § 1.1 Password",
    );
    try c.expect("t.zig", 2, .err, "now has § 1.2 Google");
    try c.expect("t.zig", 3, .err, "stale reference");
    try testing.expectEqual(@as(usize, 3), c.analysis.diagnostics.items.len - 1);
}

// specrail: specs/format/references.spec.md § 3.3 References name leaves
test "a reference to a parent section is an error" {
    var c = try checkTest(
        &.{login_spec},
        &.{.{ .path = "t.zig", .content = "// specrail: specs/login.spec.md § 1 Login\n" }},
    );
    defer c.deinit();
    try c.expect("t.zig", 1, .err, "names a parent section");
}

// specrail: specs/format/references.spec.md § 1.4 Malformed references
test "malformed references are reported where they are" {
    var c = try checkTest(
        &.{login_spec},
        &.{.{ .path = "t.zig", .content = "x\n# specrail: specs/login.spec.md 1.1 Password\n" }},
    );
    defer c.deinit();
    try c.expect("t.zig", 2, .err, "malformed reference");
}

// specrail: specs/cli/check.spec.md § 1.1 Uncovered leaves
// specrail: specs/cli/check.spec.md § 1.2 Unfinished leaves
test "done leaves need a reference and unfinished ones do not" {
    var bare = try checkTest(&.{login_spec}, &.{});
    defer bare.deinit();
    try bare.expect("specs/login.spec.md", 2, .err, "§ 1.1 Password is not covered");
    var covered = try checkTest(&.{login_spec}, &.{.{ .path = "t.zig", .content =
        \\// specrail: specs/login.spec.md § 1.1 Password
        \\// specrail: specs/login.spec.md § 1.2 Google
    }});
    defer covered.deinit();
    try covered.expectNone(.err);
    try testing.expectEqual(@as(u32, 1), covered.analysis.specs[0].sections[2].references);
}

const deps_spec: project.SourceFile = .{ .path = "specs/deps.spec.md", .content =
    \\# § 1 Waits on planned work
    \\```toml
    \\dependencies = ["specs/login.spec.md § 1.2 Google"]
    \\```
    \\It MUST wait.
    \\
    \\# § 2 Waits on a parent
    \\```toml
    \\status       = "planned"
    \\dependencies = [
    \\  "specs/login.spec.md § 1 Login",
    \\  "specs/login.spec.md § 1 Logon",
    \\  "specs/missing.spec.md § 1 Gone",
    \\]
    \\```
    \\It MUST wait.
    \\
};

// specrail: specs/format/metadata.spec.md § 6.2 Targets
test "dependency entries are checked like references, but may name parents" {
    var c = try checkTest(&.{ login_spec, deps_spec }, &.{});
    defer c.deinit();
    try c.expect("specs/deps.spec.md", 12, .err, "stale dependency to § 1 Logon");
    try c.expect(
        "specs/deps.spec.md",
        13,
        .err,
        "dangling dependency: there is no spec file specs/missing.spec.md",
    );
    for (c.analysis.diagnostics.items) |d| {
        const in_deps = std.mem.eql(u8, d.path, "specs/deps.spec.md");
        if (d.line == 11 and in_deps) return error.TestUnexpectedResult;
    }
}

// specrail: specs/format/metadata.spec.md § 6.3 Finished work does not wait on unfinished work
test "a done section cannot depend on unfinished work" {
    var c = try checkTest(&.{ login_spec, deps_spec }, &.{});
    defer c.deinit();
    try c.expect(
        "specs/deps.spec.md",
        3,
        .err,
        "§ 1 Waits on planned work is done, but depends on § 1.2 Google in specs/login.spec.md, " ++
            "which is planned",
    );
}

const notes_spec: project.SourceFile = .{ .path = "specs/notes.spec.md", .content =
    \\# § 1 Planned area
    \\```toml
    \\status         = "planned"
    \\due            = 2026-11-15
    \\assigned       = "agent-7"
    \\assigned-until = 2026-11-17T11:00:00Z
    \\```
    \\## § 1.1 Inherits
    \\
    \\It MUST be noted only once.
    \\
    \\# § 2 In progress
    \\```toml
    \\status = "in-progress"
    \\due    = 2026-11-17
    \\```
    \\It MUST be noted.
    \\
};

// specrail: specs/cli/check.spec.md § 3.3 Unfinished work
// specrail: specs/cli/check.spec.md § 3.4 Overdue work
test "unfinished work is noted once per declaration" {
    var c = try checkTest(&.{notes_spec}, &.{});
    defer c.deinit();
    try c.expect(
        "specs/notes.spec.md",
        1,
        .note,
        "§ 1 Planned area is planned; due 2026-11-15, overdue; assigned to agent-7 until " ++
            "2026-11-17T11:00:00Z",
    );
    try c.expect(
        "specs/notes.spec.md",
        12,
        .note,
        "§ 2 In progress is in-progress; due 2026-11-17",
    );
    for (c.analysis.diagnostics.items) |d| {
        const overdue = std.mem.find(u8, d.message, "overdue") != null;
        if (d.line == 12 and overdue) return error.TestUnexpectedResult;
        if (d.line == 8) return error.TestUnexpectedResult;
    }
}

// specrail: specs/cli/check.spec.md § 3.5 Expired claims
test "expired claims are noted with their assignee" {
    var c = try checkTest(&.{notes_spec}, &.{});
    defer c.deinit();
    try c.expect(
        "specs/notes.spec.md",
        1,
        .note,
        "the claim on § 1 Planned area by agent-7 expired at 2026-11-17T11:00:00Z",
    );
}

// specrail: specs/cli/check.spec.md § 2.1 Whole project
// specrail: specs/cli/check.spec.md § 2.2 Selected specs
test "check reports everything at once, or only what concerns selected specs" {
    var c = try checkTest(&.{ login_spec, deps_spec }, &.{.{ .path = "t.zig", .content =
        \\// specrail: specs/login.spec.md § 1.1 Wrong title
        \\// specrail: specs/deps.spec.md § 9 Missing
    }});
    defer c.deinit();
    const all = try c.report(null, false);
    try testing.expectEqual(@as(u32, 7), all.stats.errors);
    const only_login = try c.report(&.{"specs/login.spec.md"}, false);
    try testing.expectEqual(@as(u32, 4), only_login.stats.errors);
    for (only_login.diagnostics) |d| {
        const in_login = std.mem.eql(u8, d.path, "specs/login.spec.md");
        const about_login = if (d.subject) |s| std.mem.eql(u8, s, "specs/login.spec.md") else false;
        try testing.expect(in_login or about_login);
    }
    try testing.expectEqual(@as(u32, 1), only_login.stats.done_leaves);
}

// specrail: specs/cli/check.spec.md § 3.6 Summary line
test "the text output ends with a summary line" {
    var c = try checkTest(&.{login_spec}, &.{});
    defer c.deinit();
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeText(&out.writer, try c.report(null, false), false);
    try testing.expect(
        std.mem.endsWith(
            u8,
            out.written(),
            "\ncheck: 1 error, 0 warnings; 0/1 done leaves covered; 1 planned, 0 in progress\n",
        ),
    );
}

// specrail: specs/cli/check.spec.md § 3.7 JSON output
// specrail: specs/cli/check.spec.md § 3.8 JSON summary
test "JSON output holds the diagnostics and the summary" {
    var c = try checkTest(&.{login_spec}, &.{});
    defer c.deinit();
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeJson(&out.writer, try c.report(null, false));
    try testing.expectEqualStrings(
        "{\"diagnostics\":[" ++
            "{\"path\":\"specs/login.spec.md\",\"line\":2,\"column\":1,\"severity\":\"error\"," ++
            "\"message\":\"§ 1.1 Password is not covered: no test references it\"}," ++
            "{\"path\":\"specs/login.spec.md\",\"line\":6,\"column\":1,\"severity\":\"note\"," ++
            "\"message\":\"§ 1.2 Google is planned\"}]," ++
            "\"summary\":{\"errors\":1,\"warnings\":0,\"done_leaves\":1,\"covered_leaves\":0," ++
            "\"planned_leaves\":1,\"in_progress_leaves\":0}}\n",
        out.written(),
    );
}

// specrail: specs/cli/check.spec.md § 4.2 Warnings as errors
test "warnings can be reported as errors" {
    var c = try checkTest(
        &.{
            .{
                .path = "specs/w.spec.md",
                .content = "# § 1 Draft\n```toml\nstatus = \"planned\"\n```\nTBD.\n",
            },
        },
        &.{},
    );
    defer c.deinit();
    const normal = try c.report(null, false);
    try testing.expectEqual(@as(u32, 0), normal.stats.errors);
    try testing.expectEqual(@as(u32, 1), normal.stats.warnings);
    const strict = try c.report(null, true);
    try testing.expectEqual(@as(u32, 1), strict.stats.errors);
    try testing.expectEqual(@as(u32, 0), strict.stats.warnings);
    try testing.expectEqual(diag.Severity.err, strict.diagnostics[0].severity);
}
