//! Word boundaries (UAX #29, section 4): the default rules WB1 to WB999 of
//! Unicode 18.0.0, with no tailoring. A segment is a word, a run of
//! horizontal space, or a single other character (punctuation, a symbol, a
//! line break); `isWordLike` tells a word from the rest.
//!
//! Every rule reads at most one code point past the boundary it decides,
//! skipping the Extend, Format and ZWJ code points WB4 ignores, and a
//! segment's own text: each code point is read at most twice, so a pass is
//! linear in the text. Nothing allocates.
const std = @import("std");
const properties = @import("properties.zig");
const utf8 = @import("utf8.zig");
const grapheme = @import("grapheme.zig");

const WordBreak = properties.WordBreak;
pub const Span = grapheme.Span;
pub const Bytes = @import("domains.zig").Bytes;

/// The words and the runs between them of a string, in order.
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

    /// The next segment, or null at the end.
    pub fn next(it: *Iterator) ?[]const u8 {
        const s = it.nextSpan() orelse return null;
        return s.of(it.bytes);
    }

    /// The next segment's byte range, or null at the end.
    pub fn nextSpan(it: *Iterator) ?Span {
        if (it.at >= it.bytes.len) return null;
        const start = it.at;
        it.at = endOf(it.bytes, start);
        return .{ .start = .fromRaw(start), .end = .fromRaw(it.at) };
    }
};

/// The words of `bytes` by UAX #29's default rules.
pub fn iterate(bytes: []const u8) Iterator {
    return .init(bytes);
}

/// Whether a segment is a word: it holds a letter (an ideograph or a kana
/// included), a digit, or a connector such as `_`. A run of space, a
/// punctuation mark, a symbol or an emoji is not.
pub fn isWordLike(segment: []const u8) bool {
    var it: utf8.Iterator = .init(segment);
    while (it.next()) |cp| switch (properties.wordBreak(cp)) {
        .a_letter, .hebrew_letter, .numeric, .katakana, .extend_num_let => return true,
        else => if (properties.generalCategory(cp).isLetter()) return true,
    };
    return false;
}

const Next = struct { class: WordBreak, code_point: u21, len: u3 };

const ascii: [128]WordBreak = blk: {
    @setEvalBranchQuota(100_000);
    var classes: [128]WordBreak = undefined;
    for (&classes, 0..) |*c, cp| c.* = properties.wordBreak(cp);
    break :blk classes;
};

inline fn classAt(bytes: []const u8, at: usize) Next {
    const lead = bytes[at];
    if (lead < 0x80) return .{ .class = ascii[lead], .code_point = lead, .len = 1 };
    const d = utf8.decode(bytes[at..]);
    return .{ .class = properties.wordBreak(d.code_point), .code_point = d.code_point, .len = d.len };
}

fn ignored(c: WordBreak) bool {
    return c == .extend or c == .format or c == .zwj;
}

fn ahLetter(c: WordBreak) bool {
    return c == .a_letter or c == .hebrew_letter;
}

fn midNumLetQ(c: WordBreak) bool {
    return c == .mid_num_let or c == .single_quote;
}

/// The first class at or after `at` that WB4 does not ignore, or null at
/// the end of the text.
fn effectiveFrom(bytes: []const u8, at: usize) ?WordBreak {
    var i = at;
    while (i < bytes.len) {
        const n = classAt(bytes, i);
        if (!ignored(n.class)) return n.class;
        i += n.len;
    }
    return null;
}

/// The end of the segment that starts at `start`, which must be a boundary
/// (the start of the text, or the end of an earlier segment).
pub fn boundaryAfter(bytes: []const u8, start: Bytes) Bytes {
    return .fromRaw(endOf(bytes, start.raw()));
}

fn endOf(bytes: []const u8, start: usize) usize {
    const first = classAt(bytes, start);
    var at = start + first.len;
    // The class of the code point before `at`, as written.
    var raw = first.class;
    // The last two classes WB4 kept, the last first; null before the text.
    var last: WordBreak = first.class;
    var before: ?WordBreak = null;
    // The run of regional indicators ending at `last` is odd.
    var ri_odd = first.class == .regional_indicator;
    while (at < bytes.len) {
        const n = classAt(bytes, at);
        const c = n.class;
        if (raw == .cr and c == .lf) { // WB3
        } else if (raw == .newline or raw == .cr or raw == .lf) { // WB3a
            return at;
        } else if (c == .newline or c == .cr or c == .lf) { // WB3b
            return at;
        } else if (raw == .zwj and properties.emoji(n.code_point).extended_pictographic) { // WB3c
        } else if (raw == .w_seg_space and c == .w_seg_space) { // WB3d
        } else if (ignored(c)) { // WB4
            raw = c;
            at += n.len;
            continue;
        } else switch (pairs[@backingInt(last)][@backingInt(c)]) {
            .join => {},
            .boundary => return at,
            .depends => if (!joins(Ahead{ .bytes = bytes, .at = at + n.len }, before, last, c, ri_odd)) return at,
        }
        raw = c;
        if (!ignored(c)) {
            ri_odd = c == .regional_indicator and !(last == .regional_indicator and ri_odd);
            before = last;
            last = c;
        }
        at += n.len;
    }
    return bytes.len;
}

/// The code point after the one decided, past what WB4 ignores, read only
/// when a rule asks for it.
const Ahead = struct {
    bytes: []const u8,
    at: usize,

    fn get(a: Ahead) ?WordBreak {
        return effectiveFrom(a.bytes, a.at);
    }
};

const Decision = enum { boundary, join, depends };

/// For each pair of classes (the last kept, the next), the rules' answer
/// when no wider context can change it, and `.depends` when the class
/// before, the class after or a run of regional indicators can. Built by
/// asking `joins` every context a rule reads: a class no rule names in
/// those places answers as Other does.
const pairs: [count][count]Decision = blk: {
    @setEvalBranchQuota(10_000_000);
    const named = [_]?WordBreak{ null, .other, .a_letter, .hebrew_letter, .numeric, .katakana, .extend_num_let, .single_quote, .double_quote, .mid_letter, .mid_num, .mid_num_let, .regional_indicator };
    const Fixed = struct {
        value: ?WordBreak,
        fn get(f: @This()) ?WordBreak {
            return f.value;
        }
    };
    var table: [count][count]Decision = undefined;
    for (0..count) |l| for (0..count) |r| {
        const last: WordBreak = @fromBackingInt(@intCast(l));
        const c: WordBreak = @fromBackingInt(@intCast(r));
        const first = joins(Fixed{ .value = null }, null, last, c, false);
        var same = true;
        for (named) |b| for (named) |a| for ([_]bool{ false, true }) |odd| {
            if (joins(Fixed{ .value = a }, b, last, c, odd) != first) same = false;
        };
        table[l][r] = if (!same) .depends else if (first) .join else .boundary;
    };
    break :blk table;
};

const count = @typeInfo(WordBreak).@"enum".field_names.len;

/// WB5 to WB16: whether `c` joins the word that ends `last` (preceded by
/// `before`). `ahead.get()` is the class after `c`.
fn joins(ahead: anytype, before: ?WordBreak, last: WordBreak, c: WordBreak, ri_odd: bool) bool {
    if (ahLetter(last) and ahLetter(c)) return true; // WB5
    if (ahLetter(last) and (c == .mid_letter or midNumLetQ(c))) { // WB6
        if (ahead.get()) |next| if (ahLetter(next)) return true;
    }
    if (before) |b| if (ahLetter(b) and (last == .mid_letter or midNumLetQ(last)) and ahLetter(c)) return true; // WB7
    if (last == .hebrew_letter and c == .single_quote) return true; // WB7a
    if (last == .hebrew_letter and c == .double_quote) { // WB7b
        if (ahead.get()) |next| if (next == .hebrew_letter) return true;
    }
    if (before) |b| if (b == .hebrew_letter and last == .double_quote and c == .hebrew_letter) return true; // WB7c
    if (last == .numeric and c == .numeric) return true; // WB8
    if (ahLetter(last) and c == .numeric) return true; // WB9
    if (last == .numeric and ahLetter(c)) return true; // WB10
    if (before) |b| if (b == .numeric and (last == .mid_num or midNumLetQ(last)) and c == .numeric) return true; // WB11
    if (last == .numeric and (c == .mid_num or midNumLetQ(c))) { // WB12
        if (ahead.get()) |next| if (next == .numeric) return true;
    }
    if (last == .katakana and c == .katakana) return true; // WB13
    if ((ahLetter(last) or last == .numeric or last == .katakana or last == .extend_num_let) and c == .extend_num_let) return true; // WB13a
    if (last == .extend_num_let and (ahLetter(c) or c == .numeric or c == .katakana)) return true; // WB13b
    if (last == .regional_indicator and c == .regional_indicator and ri_odd) return true; // WB15, WB16
    return false; // WB999
}

test "words of a sentence" {
    var it = iterate("The quick (\u{201c}brown\u{201d}) fox can\u{2019}t jump 32.3 feet, right?");
    const want = [_][]const u8{ "The", " ", "quick", " ", "(", "\u{201c}", "brown", "\u{201d}", ")", " ", "fox", " ", "can\u{2019}t", " ", "jump", " ", "32.3", " ", "feet", ",", " ", "right", "?" };
    for (want) |w| try std.testing.expectEqualStrings(w, it.next().?);
    try std.testing.expectEqual(null, it.next());
}
