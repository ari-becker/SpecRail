//! Navigation for the language server: what a position in a document is on,
//! and where that leads: the heading a reference names, everything that names
//! a section, and the text to show on hover.

const std = @import("std");
const Allocator = std.mem.Allocator;

const check = @import("check.zig");
const project = @import("project.zig");
const refs = @import("refs.zig");
const spec = @import("spec.zig");
const text = @import("lsp_text.zig");

/// A position in a document, as LSP counts it.
pub const Position = struct {
    line: u32,
    character: u32,
};

/// A stretch of a document.
pub const Range = struct {
    start: Position,
    end: Position,
};

/// A stretch of a document named by its URI.
pub const Location = struct {
    uri: []const u8,
    range: Range,
};

/// What the server knows of the project, as navigation needs it.
pub const Index = struct {
    /// The absolute path of the project root.
    root: []const u8,
    analysis: check.Analysis,
    /// The project's source files, with the open documents' text.
    source_files: []const project.SourceFile,
    /// Every file's text, by project path.
    contents: std.StringHashMapUnmanaged([]const u8),
    encoding: text.Encoding,

    /// The URI of the file at project path `path`.
    pub fn uri(ix: *const Index, arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
        return text.pathToUri(arena, try std.Io.Dir.path.join(arena, &.{ ix.root, path }));
    }

    /// The range from byte `start` to the end of line `index`, counted from 0,
    /// of the file at `path`, without trailing blanks.
    fn rangeToEnd(ix: *const Index, path: []const u8, index: u32, start: usize) Range {
        const content = ix.contents.get(path) orelse "";
        const l = std.mem.trimEnd(u8, text.lineAt(content, index), " \t");
        return .{
            .start = .{ .line = index, .character = text.column(l, start, ix.encoding) },
            .end = .{ .line = index, .character = text.column(l, l.len, ix.encoding) },
        };
    }
};

/// A section, by its spec file and its index there.
pub const SectionRef = struct {
    file: *const spec.SpecFile,
    index: usize,

    fn section(sr: SectionRef) spec.Section {
        return sr.file.sections[sr.index];
    }

    /// The index after the last section in this one's subtree.
    fn subtreeEnd(sr: SectionRef) usize {
        const level = sr.section().level;
        for (sr.file.sections[sr.index + 1 ..], sr.index + 1..) |s, i| {
            if (s.level <= level) return i;
        }
        return sr.file.sections.len;
    }
};

/// What a position in a document is on.
pub const Target = union(enum) {
    /// A section's heading.
    heading: SectionRef,
    /// A reference line or dependency entry, which names a section this way.
    named: refs.Form,
};

/// What line `index`, counted from 0, at byte `byte`, of the file at `path`
/// is on; null when it is on nothing navigation knows.
pub fn targetAt(ix: *const Index, path: []const u8, index: u32, byte: usize) ?Target {
    if (ix.analysis.file(path)) |file| {
        for (file.sections, 0..) |s, i| {
            if (s.line == index + 1) return .{ .heading = .{ .file = file, .index = i } };
        }
        return dependencyAt(file, index + 1, byte);
    }
    const content = ix.contents.get(path) orelse return null;
    const found = refs.scanLine(text.lineAt(content, index)) orelse return null;
    return switch (found.result) {
        .ok => |form| .{ .named = form },
        .err => null,
    };
}

/// The dependency entry on line `number` of `file` that starts last before
/// byte `byte`.
fn dependencyAt(file: *const spec.SpecFile, number: u32, byte: usize) ?Target {
    var best: ?spec.Dependency = null;
    for (file.sections) |s| {
        const m = s.metadata orelse continue;
        entries: for (m.dependencies) |d| {
            if (d.line != number or d.column > byte + 1) continue :entries;
            if (best == null or d.column >= best.?.column) best = d;
        }
    }
    return if (best) |d| .{ .named = d.form } else null;
}

/// The section `form` names: the one with its number and title, or, when the
/// form is stale, the only one with its title, or else the one with its
/// number.
pub fn resolve(ix: *const Index, form: refs.Form) ?SectionRef {
    const file = ix.analysis.file(form.path) orelse return null;
    var by_title: ?usize = null;
    var titles: usize = 0;
    var by_number: ?usize = null;
    for (file.sections, 0..) |s, i| {
        const same_number = std.mem.eql(u8, s.number, form.number);
        const same_title = std.mem.eql(u8, s.title, form.title);
        if (same_number and same_title) return .{ .file = file, .index = i };
        if (same_title) {
            by_title = i;
            titles += 1;
        }
        if (same_number) by_number = i;
    }
    const i = (if (titles == 1) by_title else null) orelse by_number orelse return null;
    return .{ .file = file, .index = i };
}

fn sectionOf(ix: *const Index, target: Target) ?SectionRef {
    return switch (target) {
        .heading => |h| h,
        .named => |form| resolve(ix, form),
    };
}

/// Where the heading of `sr` is.
fn headingLocation(ix: *const Index, arena: Allocator, sr: SectionRef) Allocator.Error!Location {
    const index = sr.section().line - 1;
    return .{
        .uri = try ix.uri(arena, sr.file.path),
        .range = ix.rangeToEnd(sr.file.path, index, 0),
    };
}

/// The heading of the section `target` names, or that it is on.
pub fn definition(ix: *const Index, arena: Allocator, target: Target) Allocator.Error!?Location {
    const sr = sectionOf(ix, target) orelse return null;
    return try headingLocation(ix, arena, sr);
}

/// Whether `form` names a section in the subtree of `sr` exactly.
fn namesSubtree(sr: SectionRef, form: refs.Form) bool {
    if (!std.mem.eql(u8, form.path, sr.file.path)) return false;
    for (sr.file.sections[sr.index..sr.subtreeEnd()]) |s| {
        const same_number = std.mem.eql(u8, s.number, form.number);
        if (same_number and std.mem.eql(u8, s.title, form.title)) return true;
    }
    return false;
}

/// Every reference line and dependency entry that names the section `target`
/// names, or is on, or a section in its subtree; and its heading, when
/// `declaration` is set.
pub fn references(
    ix: *const Index,
    arena: Allocator,
    target: Target,
    declaration: bool,
) Allocator.Error![]const Location {
    const sr = sectionOf(ix, target) orelse return &.{};
    var out: std.ArrayList(Location) = .empty;
    errdefer out.deinit(arena);
    if (declaration) try out.append(arena, try headingLocation(ix, arena, sr));
    for (ix.source_files) |f| {
        found: for (try refs.scanText(arena, f.content)) |found| {
            const form = switch (found.ref.result) {
                .ok => |form| form,
                .err => continue :found,
            };
            if (!namesSubtree(sr, form)) continue :found;
            const range = ix.rangeToEnd(f.path, found.line - 1, found.ref.column - 1);
            try out.append(arena, .{ .uri = try ix.uri(arena, f.path), .range = range });
        }
    }
    for (ix.analysis.specs) |*file| {
        sections: for (file.sections) |s| {
            const m = s.metadata orelse continue :sections;
            entries: for (m.dependencies) |d| {
                if (!namesSubtree(sr, d.form)) continue :entries;
                const range = ix.rangeToEnd(file.path, d.line - 1, d.column - 1);
                try out.append(arena, .{ .uri = try ix.uri(arena, file.path), .range = range });
            }
        }
    }
    return out.toOwnedSlice(arena);
}

/// The section a reference line or dependency entry names, as Markdown: its
/// heading, metadata block and own prose. Null on anything else.
pub fn hover(ix: *const Index, arena: Allocator, target: Target) Allocator.Error!?[]const u8 {
    const form = switch (target) {
        .named => |f| f,
        .heading => return null,
    };
    const sr = resolve(ix, form) orelse return null;
    const s = sr.section();
    var lines = sr.file.lines[s.line - 1 .. s.own_end];
    // The blank lines before the next heading are not the section's.
    while (lines.len > 1 and std.mem.trim(u8, lines[lines.len - 1], " \t").len == 0) {
        lines = lines[0 .. lines.len - 1];
    }
    return try std.mem.join(arena, "\n", lines);
}
