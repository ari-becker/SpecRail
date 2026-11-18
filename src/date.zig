//! Calendar dates and RFC 3339 offset date-times, as used by metadata blocks.

const std = @import("std");

/// A calendar date without a time zone, as in `due = 2027-06-29`.
pub const Date = struct {
    year: i32,
    month: u8,
    day: u8,

    /// Days since 1970-01-01, by the proleptic Gregorian calendar.
    pub fn days(d: Date) i64 {
        const y: i64 = @as(i64, d.year) - @as(i64, if (d.month <= 2) 1 else 0);
        const era: i64 = @divFloor(y, 400);
        const yoe: i64 = y - era * 400;
        const m: i64 = d.month;
        const mp: i64 = if (m > 2) m - 3 else m + 9;
        const doy: i64 = @divFloor(153 * mp + 2, 5) + @as(i64, d.day) - 1;
        const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
        return era * 146097 + doe - 719468;
    }

    /// The date `days` days after 1970-01-01, the inverse of `days`.
    pub fn fromDays(days_since: i64) Date {
        const z = days_since + 719468;
        const era = @divFloor(z, 146097);
        const doe = z - era * 146097;
        const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) -
            @divFloor(doe, 146096), 365);
        const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
        const mp = @divFloor(5 * doy + 2, 153);
        const day = doy - @divFloor(153 * mp + 2, 5) + 1;
        const month = if (mp < 10) mp + 3 else mp - 9;
        const year = yoe + era * 400 + @as(i64, if (month <= 2) 1 else 0);
        return .{ .year = @intCast(year), .month = @intCast(month), .day = @intCast(day) };
    }
};

/// `seconds` since the epoch as an RFC 3339 date-time in UTC, such as
/// `2026-11-17T16:00:00Z`.
pub fn formatDateTime(buf: *[20]u8, seconds: i64) []const u8 {
    const d = Date.fromDays(@divFloor(seconds, 86400));
    const in_day: u64 = @intCast(@mod(seconds, 86400));
    // Years before 1 do not occur in claims, and a signed year would print a sign.
    const year: u32 = @intCast(@max(d.year, 0));
    const hours = @divFloor(in_day, 3600);
    const minutes = @divFloor(in_day, 60) % 60;
    const parts = .{ year, d.month, d.day, hours, minutes, in_day % 60 };
    const fmt = "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z";
    return std.mem.print(buf, fmt, parts) catch buf;
}

fn isLeap(y: i32) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

fn daysInMonth(y: i32, m: u8) u8 {
    return switch (m) {
        2 => if (isLeap(y)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

fn digits(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var n: u32 = 0;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return null;
        n = n * 10 + (c - '0');
    }
    return n;
}

/// Parses `YYYY-MM-DD`, rejecting dates that do not exist.
pub fn parseDate(s: []const u8) ?Date {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return null;
    const y = digits(s[0..4]) orelse return null;
    const m = digits(s[5..7]) orelse return null;
    const d = digits(s[8..10]) orelse return null;
    if (m < 1 or m > 12) return null;
    if (d < 1 or d > daysInMonth(@intCast(y), @intCast(m))) return null;
    return .{ .year = @intCast(y), .month = @intCast(m), .day = @intCast(d) };
}

/// True when `s` starts like a date (`YYYY-MM-DD...`), valid or not.
pub fn looksLikeDate(s: []const u8) bool {
    if (s.len < 10 or s[4] != '-' or s[7] != '-') return false;
    return digits(s[0..4]) != null and digits(s[5..7]) != null and digits(s[8..10]) != null;
}

/// The outcome of parsing an offset date-time.
pub const DateTimeResult = union(enum) {
    invalid,
    no_offset,
    /// Seconds since the epoch.
    ok: i64,
};

/// Parses an RFC 3339 date-time with a `Z` or `±HH:MM` offset.
pub fn parseOffsetDateTime(s: []const u8) DateTimeResult {
    if (s.len < 19) return .invalid;
    const d = parseDate(s[0..10]) orelse return .invalid;
    if (s[10] != 'T' and s[10] != 't' and s[10] != ' ') return .invalid;
    if (s[13] != ':' or s[16] != ':') return .invalid;
    const hh = digits(s[11..13]) orelse return .invalid;
    const mm = digits(s[14..16]) orelse return .invalid;
    const ss = digits(s[17..19]) orelse return .invalid;
    if (hh > 23 or mm > 59 or ss > 60) return .invalid;
    var i: usize = 19;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == start) return .invalid;
    }
    if (i == s.len) return .no_offset;
    var offset: i64 = 0;
    if (s[i] == 'Z' or s[i] == 'z') {
        i += 1;
    } else if (s[i] == '+' or s[i] == '-') {
        if (s.len - i != 6 or s[i + 3] != ':') return .invalid;
        const oh = digits(s[i + 1 .. i + 3]) orelse return .invalid;
        const om = digits(s[i + 4 .. i + 6]) orelse return .invalid;
        if (oh > 23 or om > 59) return .invalid;
        offset = (@as(i64, oh) * 60 + om) * 60;
        if (s[i] == '-') offset = -offset;
        i += 6;
    } else return .invalid;
    if (i != s.len) return .invalid;
    return .{ .ok = d.days() * 86400 + @as(i64, hh) * 3600 + @as(i64, mm) * 60 + ss - offset };
}

/// A due date has passed once it has ended everywhere on Earth: at the end of
/// that date in UTC-12, which is noon UTC on the following day.
pub fn isOverdue(due: Date, now: i64) bool {
    const deadline = (due.days() + 1) * 86400 + 12 * 3600;
    return now >= deadline;
}

test "dates convert to days since the epoch" {
    try std.testing.expectEqual(@as(i64, 0), (Date{ .year = 1970, .month = 1, .day = 1 }).days());
    try std.testing.expectEqual(
        @as(i64, 20774),
        (Date{ .year = 2026, .month = 11, .day = 17 }).days(),
    );
    try std.testing.expect(parseDate("2028-02-29") != null);
    try std.testing.expect(parseDate("2027-02-29") == null);
    try std.testing.expect(parseDate("2027-13-01") == null);
}

test "offset date-times convert to epoch seconds" {
    const utc = parseOffsetDateTime("2026-11-17T16:00:00Z").ok;
    try std.testing.expectEqual(@as(i64, 20774 * 86400 + 16 * 3600), utc);
    try std.testing.expectEqual(utc, parseOffsetDateTime("2026-11-17T18:00:00+02:00").ok);
    try std.testing.expectEqual(utc, parseOffsetDateTime("2026-11-17 16:00:00.5Z").ok);
    try std.testing.expect(parseOffsetDateTime("2026-11-17T16:00:00") == .no_offset);
    try std.testing.expect(parseOffsetDateTime("2026-11-17T25:00:00Z") == .invalid);
}

// specrail: specs/cli/check.spec.md § 3.4 Overdue work
test "a due date is overdue from noon UTC on the following day" {
    const due = parseDate("2027-06-29").?;
    const noon_next_day = (due.days() + 1) * 86400 + 12 * 3600;
    try std.testing.expect(!isOverdue(due, noon_next_day - 1));
    try std.testing.expect(isOverdue(due, noon_next_day));
}

test "epoch seconds format as RFC 3339 date-times in UTC" {
    var buf: [20]u8 = undefined;
    const now = 20774 * 86400 + 16 * 3600 + 5 * 60 + 9;
    try std.testing.expectEqualStrings("2026-11-17T16:05:09Z", formatDateTime(&buf, now));
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", formatDateTime(&buf, 0));
    const leap = parseOffsetDateTime("2028-02-29T23:59:59Z").ok;
    try std.testing.expectEqualStrings("2028-02-29T23:59:59Z", formatDateTime(&buf, leap));
    for ([_]i64{ -1, 0, 59, 10957, 20774, 2932896 }) |days_since| {
        const d = Date.fromDays(days_since);
        try std.testing.expectEqual(days_since, d.days());
    }
}
