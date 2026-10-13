//! Sentence boundaries (UAX #29, section 5): the default rules SB1 to
//! SB998 of Unicode 18.0.0, with no tailoring.
//!
//! SB8 looks ahead past a full stop for a lowercase letter, as far as the
//! first letter, separator or terminator. The answer holds for every
//! position up to where it stopped, so it is computed once per stop and a
//! pass stays linear in the text. Nothing allocates.
const std = @import("std");
const properties = @import("properties.zig");
const utf8 = @import("utf8.zig");
const grapheme = @import("grapheme.zig");

const SentenceBreak = properties.SentenceBreak;
pub const Span = grapheme.Span;
pub const Bytes = @import("domains.zig").Bytes;

/// The sentences of a string, in order.
pub const Iterator = struct {
    bytes: []const u8,
    /// Private: where the next segment starts; `offset` reads it.
    at: usize = 0,

    pub fn init(bytes: []const u8) Iterator {
        return .{ .bytes = bytes };
    }

    /// Where the next segment starts.
    pub fn offset(it: *const Iterator) Bytes {
        return .fromRaw(it.at);
    }

    /// The next sentence, or null at the end.
    pub fn next(it: *Iterator) ?[]const u8 {
        const s = it.nextSpan() orelse return null;
        return s.of(it.bytes);
    }

    /// The next sentence's byte range, or null at the end.
    pub fn nextSpan(it: *Iterator) ?Span {
        if (it.at >= it.bytes.len) return null;
        const start = it.at;
        it.at = endOf(it.bytes, start);
        return .{ .start = .fromRaw(start), .end = .fromRaw(it.at) };
    }
};

/// The sentences of `bytes` by UAX #29's default rules.
pub fn iterate(bytes: []const u8) Iterator {
    return .init(bytes);
}

const Next = struct { class: SentenceBreak, len: u3 };

const ascii: [128]SentenceBreak = blk: {
    @setEvalBranchQuota(100_000);
    var classes: [128]SentenceBreak = undefined;
    for (&classes, 0..) |*c, cp| c.* = properties.sentenceBreak(cp);
    break :blk classes;
};

inline fn classAt(bytes: []const u8, at: usize) Next {
    const lead = bytes[at];
    if (lead < 0x80) return .{ .class = ascii[lead], .len = 1 };
    const d = utf8.decode(bytes[at..]);
    return .{ .class = properties.sentenceBreak(d.code_point), .len = d.len };
}

fn paraSep(c: SentenceBreak) bool {
    return c == .sep or c == .cr or c == .lf;
}

fn saTerm(c: SentenceBreak) bool {
    return c == .s_term or c == .a_term;
}

/// Where a terminator's run stands: SATerm Close*, then Sp*, then a ParaSep.
const Run = enum { none, close, space, separator };

/// The end of the sentence that starts at `start`, which must be a boundary
/// (the start of the text, or the end of an earlier sentence).
pub fn boundaryAfter(bytes: []const u8, start: Bytes) Bytes {
    return .fromRaw(endOf(bytes, start.raw()));
}

fn endOf(bytes: []const u8, start: usize) usize {
    const first = classAt(bytes, start);
    var at = start + first.len;
    var raw = first.class;
    var last = first.class;
    var before: ?SentenceBreak = null;
    var run: Run = if (saTerm(first.class)) .close else .none;
    var full_stop = first.class == .a_term;
    // SB8's lookahead: the answer, and where the search for it stopped.
    var lower_until: usize = 0;
    var lower = false;
    while (at < bytes.len) {
        const n = classAt(bytes, at);
        const c = n.class;
        if (raw == .cr and c == .lf) { // SB3
        } else if (paraSep(raw)) { // SB4
            return at;
        } else if (c == .extend or c == .format) { // SB5
            raw = c;
            at += n.len;
            continue;
        } else if (last == .a_term and c == .numeric) { // SB6
        } else if (before != null and (before.? == .upper or before.? == .lower) and last == .a_term and c == .upper) { // SB7
        } else if ((run == .close or run == .space) and full_stop and lowerFollows(bytes, at, &lower_until, &lower)) { // SB8
        } else if ((run == .close or run == .space) and (c == .s_continue or saTerm(c))) { // SB8a
        } else if (run == .close and (c == .close or c == .sp or paraSep(c))) { // SB9
        } else if ((run == .close or run == .space) and (c == .sp or paraSep(c))) { // SB10
        } else if (run != .none) { // SB11
            return at;
        } // SB998
        if (saTerm(c)) {
            run = .close;
            full_stop = c == .a_term;
        } else run = switch (run) {
            .close => if (c == .close) .close else if (c == .sp) .space else if (paraSep(c)) .separator else .none,
            .space => if (c == .sp) .space else if (paraSep(c)) .separator else .none,
            .none, .separator => .none,
        };
        raw = c;
        before = last;
        last = c;
        at += n.len;
    }
    return bytes.len;
}

/// SB8: whether, from `at`, a Lower comes before any OLetter, Upper, ParaSep
/// or SATerm. `until` and `answer` keep the last search: it holds for any
/// position before where it stopped.
fn lowerFollows(bytes: []const u8, at: usize, until: *usize, answer: *bool) bool {
    if (at < until.*) return answer.*;
    var i = at;
    while (i < bytes.len) {
        const n = classAt(bytes, i);
        switch (n.class) {
            .lower => {
                until.* = i;
                answer.* = true;
                return true;
            },
            .o_letter, .upper, .sep, .cr, .lf, .s_term, .a_term => {
                until.* = i;
                answer.* = false;
                return false;
            },
            else => i += n.len,
        }
    }
    until.* = bytes.len;
    answer.* = false;
    return false;
}

test "sentences" {
    var it = iterate("He said, \u{201c}Are you going?\u{201d} John shook his head. etc. ok.\n\nThe end.");
    const want = [_][]const u8{ "He said, \u{201c}Are you going?\u{201d} ", "John shook his head. etc. ok.\n", "\n", "The end." };
    for (want) |w| try std.testing.expectEqualStrings(w, it.next().?);
    try std.testing.expectEqual(null, it.next());
}
