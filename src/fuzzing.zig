//! What the fuzz tests share: their seed inputs, and spec files and source
//! files made up from the fuzzer's choices. Made-up files are mostly well
//! formed, so that fuzzing gets past the parsers to the code behind them.
//!
//! `zig build test` runs every fuzz test once on each seed, as a property
//! test; `zig build test --fuzz` searches for inputs that break one.
//!
//! `Smith.boolWeighted` takes the weight of false first: `boolWeighted(7, 1)`
//! is true one time in eight. A choice with a rare side puts it on true, so
//! that a seed read back, which takes false, takes the common side.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Smith = std.testing.Smith;

const build_options = @import("build_options");
const spec = @import("spec.zig");

/// How many seeds each fuzz test starts from, and how many bytes each has.
const seed_count = 64;
const seed_len = 512;

/// Pseudo-random seeds, the same on every run, then `extra`, then the input
/// `zig build test -Dfuzz-input=<path>` names. The fuzzer reads every seed as
/// its choices, so any bytes make a valid seed, but not a useful one: a seed
/// read back ends a run of choices at its first byte that is not zero, and
/// takes the smallest value whenever eight bytes do not make one in range.
/// Half the seeds are therefore mostly zeros with small values among them,
/// which make files of several lines and vary the choices, and half are
/// random bytes, which make text of any bytes.
pub fn seeds(
    arena: Allocator,
    extra: []const []const u8,
) std.Io.Dir.ReadFileAllocError![]const []const u8 {
    var prng: std.Random.DefaultPrng = .init(0x5bec_7a11);
    const replay = build_options.fuzz_input != null;
    const out = try arena.alloc([]const u8, seed_count + extra.len + @intFromBool(replay));
    for (out[0..seed_count], 0..) |*s, i| {
        const seed = try arena.alloc(u8, seed_len);
        prng.random().bytes(seed);
        if (i % 2 == 0) {
            for (seed) |*b| b.* = if (b.* < 224) 0 else b.* % 16;
        }
        s.* = seed;
    }
    @memcpy(out[seed_count..][0..extra.len], extra);
    if (build_options.fuzz_input) |path| {
        const input = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .unlimited);
        out[out.len - 1] = try input;
    }
    return out;
}

/// A seed that `Smith.slice` reads back as `content`: its length, then it.
/// Built at compile time, so the seed outlives the call.
pub fn sliceSeed(comptime content: []const u8) []const u8 {
    return comptime seed: {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, content.len, .little);
        const whole = len ++ content[0..content.len].*;
        break :seed &whole;
    };
}

/// Text of any bytes, up to `buf.len` of them.
pub fn bytes(smith: *Smith, buf: []u8) []const u8 {
    return buf[0..smith.slice(buf)];
}

/// One of `choices`.
pub fn pick(smith: *Smith, choices: []const []const u8) []const u8 {
    return choices[smith.index(choices.len)];
}

/// The spec files the made-up project has.
pub const spec_paths = [_][]const u8{ "specs/a.spec.md", "specs/b.spec.md" };

const numbers = [_][]const u8{ "1", "2", "3", "1.1", "1.2", "2.1", "1.1.1", "1.2.1", "0", "1.01" };
/// Section titles, among them one that takes several bytes and two units in UTF-16.
pub const titles = [_][]const u8{ "One", "Two", "Café 🔑", "Login", "Two  words", "" };
const spaces = [_][]const u8{ " ", " ", " ", "  ", "\t", "" };
const prose = [_][]const u8{
    "",
    "Context.",
    "It MUST work.",
    "---",
    "- a list item",
    "    indented",
    "<!-- note -->",
};
const block_lines = [_][]const u8{
    "```toml",
    "```",
    "```zig",
    "status = \"planned\"",
    "status = \"in-progress\"",
    "status = \"done\"",
    "x-owner = \"a\"",
    "due = 2027-01-01",
    "assigned = \"bob\"",
    "assigned-until = 2030-01-01T00:00:00Z",
    "dependencies = [\"specs/a.spec.md § 1.1 One\"]",
    "dependencies = [",
    "  \"specs/b.spec.md § 1 Two\",",
    "]",
    "# a comment",
    "status = 1",
    "nonsense",
};

/// A section in reference form, with a path, number and title the made-up
/// spec files use, so that it often names one of their sections.
pub fn form(smith: *Smith, arena: Allocator) Allocator.Error![]const u8 {
    const sign = if (smith.boolWeighted(7, 1)) "%" else "§";
    const parts = .{ pick(smith, &spec_paths), sign, pick(smith, &numbers), pick(smith, &titles) };
    return arena.print("{s} {s} {s} {s}", parts);
}

/// A section heading, tidy or not, with either section sign.
fn heading(smith: *Smith, arena: Allocator, out: *std.ArrayList(u8)) Allocator.Error!void {
    const level = smith.valueRangeAtMost(u8, 1, 4);
    try out.appendNTimes(arena, '#', level);
    try out.appendSlice(arena, pick(smith, &spaces));
    try out.appendSlice(arena, if (smith.boolWeighted(7, 1)) "%" else "§");
    try out.appendSlice(arena, pick(smith, &spaces));
    try out.appendSlice(arena, pick(smith, &numbers));
    try out.appendSlice(arena, pick(smith, &spaces));
    try out.appendSlice(arena, pick(smith, &titles));
    if (smith.boolWeighted(7, 1)) try out.appendSlice(arena, pick(smith, &spaces));
}

/// The numbers and titles that are valid in a heading.
const valid_numbers = numbers[0..8];
const valid_titles = titles[0..5];
const statuses = [_][]const u8{ "planned", "in-progress", "done" };

/// A section in reference form that parses, for a dependency entry.
fn validForm(smith: *Smith, arena: Allocator) Allocator.Error![]const u8 {
    const path = pick(smith, &spec_paths);
    const parts = .{ path, pick(smith, valid_numbers), pick(smith, valid_titles) };
    return arena.print("{s} § {s} {s}", parts);
}

/// A metadata block that parses: a status, an owner, a due date or a
/// dependency entry.
fn tidyBlock(
    smith: *Smith,
    arena: Allocator,
    out: *std.ArrayList(u8),
    newline: []const u8,
) Allocator.Error!void {
    try out.print(arena, "```toml{s}", .{newline});
    switch (smith.valueRangeAtMost(u8, 0, 3)) {
        0 => try out.print(arena, "status = \"{s}\"{s}", .{ pick(smith, &statuses), newline }),
        1 => try out.print(arena, "x-owner = \"a\"{s}", .{newline}),
        2 => try out.print(arena, "due = 2027-01-01{s}", .{newline}),
        else => {
            const entry = try validForm(smith, arena);
            try out.print(arena, "dependencies = [\"{s}\"]{s}", .{ entry, newline });
        },
    }
    try out.print(arena, "```{s}", .{newline});
}

/// A spec file as a person writes it: maybe context and a separator, then
/// sections numbered in order, each at most one level deeper than the one
/// before it, with prose and sometimes a metadata block.
fn tidySpecText(smith: *Smith, arena: Allocator, newline: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    if (smith.value(bool)) {
        try out.print(arena, "Context.{s}{s}---{s}{s}", .{ newline, newline, newline, newline });
    }
    var numbering: spec.Numbering = .{};
    var level: u8 = 0;
    // The fuzzer ends the file; a seed ends it when its bytes run out.
    while (!smith.eosWeightedSimple(5, 1)) {
        level = smith.valueRangeAtMost(u8, 1, @min(level + 1, 4));
        const number = try numbering.next(arena, level);
        try out.appendNTimes(arena, '#', level);
        try out.print(arena, " § {s} {s}{s}", .{ number, pick(smith, valid_titles), newline });
        if (smith.boolWeighted(2, 1)) try tidyBlock(smith, arena, &out, newline);
        try out.print(arena, "{s}It MUST work.{s}{s}", .{ newline, newline, newline });
    }
    return out.toOwnedSlice(arena);
}

/// A spec file: half the time one as a person writes it, and otherwise
/// headings, metadata blocks, prose and the odd line of any bytes, in any
/// order. Either way, lines end the same way throughout.
pub fn specText(smith: *Smith, arena: Allocator) Allocator.Error![]const u8 {
    const newline = if (smith.boolWeighted(7, 1)) "\r\n" else "\n";
    // A seed read back takes the smallest value, false, so seeds make tidy files.
    if (!smith.value(bool)) return tidySpecText(smith, arena, newline);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    var buf: [24]u8 = undefined;
    // The fuzzer ends the file; a seed ends it when its bytes run out.
    while (!smith.eosWeightedSimple(15, 1)) {
        switch (smith.valueRangeAtMost(u8, 0, 7)) {
            0, 1, 2 => try heading(smith, arena, &out),
            3, 4 => try out.appendSlice(arena, pick(smith, &block_lines)),
            5 => try out.appendSlice(arena, pick(smith, &prose)),
            6 => {},
            else => try out.appendSlice(arena, bytes(smith, &buf)),
        }
        try out.appendSlice(arena, newline);
    }
    return out.toOwnedSlice(arena);
}

/// A source file: reference lines, mostly to sections the made-up spec files
/// may have, and other lines.
pub fn sourceText(smith: *Smith, arena: Allocator) Allocator.Error![]const u8 {
    const markers = [_][]const u8{
        "// specrail: ",
        "# specrail: ",
        "<!-- specrail: ",
        "x = \"specrail: ",
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    var buf: [24]u8 = undefined;
    // The fuzzer ends the file; a seed ends it when its bytes run out.
    while (!smith.eosWeightedSimple(7, 1)) {
        if (smith.boolWeighted(1, 4)) {
            try out.appendSlice(arena, pick(smith, &markers));
            try out.appendSlice(arena, try form(smith, arena));
        } else {
            try out.appendSlice(arena, bytes(smith, &buf));
        }
        try out.append(arena, '\n');
    }
    return out.toOwnedSlice(arena);
}
