//! Line break opportunities (UAX #14): the default rules LB1 to LB31 of
//! Unicode 18.0.0, with no tailoring. A segment ends where a line may break,
//! and `Break.mandatory` says where it must: after a hard line break.
//!
//! The rules read context on both sides of a position. Behind it, what they
//! read reduces to a few values carried forward (the last two items, the
//! last that is not a space and the one before it, a number in progress,
//! the parity of a run of regional indicators); ahead, at most two items,
//! read only when a rule asks. So one pass is linear in the text, and the
//! iterator carries its context from one segment to the next: some rules
//! (LB15a, LB19a, LB20a, LB21a) read the item before a break. Nothing
//! allocates.
const std = @import("std");
const classes = @import("classes.zig");
const records = @import("records.zig");
const utf8 = @import("utf8.zig");
const grapheme = @import("grapheme.zig");
const domains = @import("domains.zig");

const Class = classes.LineBreak;
const Line = classes.Line;
pub const Span = grapheme.Span;

/// A line's byte range, and whether it must end there.
pub const Break = struct {
    span: Span,
    /// The segment ends with a hard line break (BK, CR, LF or NL, as LB4
    /// and LB5 have them), so the line must end.
    mandatory: bool,
};

/// One item of the text as the rules after LB9 see it: a code point with
/// the combining marks and joiners that attach to it.
const Item = Line;

/// LB10: a combining mark or joiner that attaches to nothing reads as
/// U+0041.
const letter_a: Item = .{ .class = .alphabetic };

fn hard(c: Class) bool {
    return c == .mandatory_break or c == .carriage_return or c == .line_feed or c == .next_line;
}

fn attaching(c: Class) bool {
    return c == .combining_mark or c == .zwj;
}

/// LB9: what a combining mark attaches to; not a hard break, a space or a
/// zero width space.
fn base(c: Class) bool {
    return !(hard(c) or c == .space or c == .zw_space);
}

fn letter(c: Class) bool {
    return c == .alphabetic or c == .hebrew_letter;
}

fn hangul(c: Class) bool {
    return switch (c) {
        .jl, .jv, .jt, .h2, .h3 => true,
        else => false,
    };
}

/// LB28a's (AK | ◌ | AS).
fn aksara(i: Item) bool {
    return i.class == .aksara or i.class == .aksara_start or i.dotted_circle;
}

/// What the rules read behind a position, carried forward item by item.
const Behind = struct {
    /// Before the first code point: no position has been decided.
    started: bool = false,
    /// The class of the code point just behind, as written (LB4 to LB8a).
    raw: Class = .alphabetic,
    /// The last two items, the last first; null is the start of the text.
    last: ?Item = null,
    before: ?Item = null,
    /// The last item that is not a space, and the one before it (LB8, LB14
    /// to LB17 read through spaces).
    solid: ?Item = null,
    before_solid: ?Item = null,
    /// LB25: NU (SY | IS)*, then (CL | CP).
    number: enum { none, digits, closed } = .none,
    /// The run of regional indicators ending at `last` is odd (LB30a).
    ri_odd: bool = false,

    fn lastIs(b: Behind, c: Class) bool {
        return if (b.last) |l| l.class == c else false;
    }

    /// Takes in the code point `record` stands for.
    fn push(b: *Behind, record: Line) void {
        defer b.started = true;
        defer b.raw = record.class;
        // LB9: a mark or joiner after a base joins it and changes nothing.
        if (attaching(record.class)) if (b.last) |l| if (base(l.class)) return;
        const item = if (attaching(record.class)) letter_a else record;
        b.ri_odd = item.class == .regional_indicator and !(b.lastIs(.regional_indicator) and b.ri_odd);
        b.number = switch (item.class) {
            .numeric => .digits,
            .break_symbols, .infix_numeric => if (b.number == .digits) .digits else .none,
            .close_punctuation, .close_parenthesis => if (b.number == .digits) .closed else .none,
            else => .none,
        };
        if (item.class != .space) {
            b.before_solid = b.last;
            b.solid = item;
        }
        b.before = b.last;
        b.last = item;
    }
};

/// The item that starts at `at` and the end of the marks attached to it, or
/// null at the end of the text: LB9 lookahead.
fn itemAt(bytes: []const u8, at: usize) ?struct { item: Item, end: usize } {
    if (at >= bytes.len) return null;
    const first = readLine(bytes[at..]);
    var end = at + first.len;
    var item = first.record;
    if (attaching(item.class)) item = letter_a else if (base(item.class)) {
        while (end < bytes.len) {
            const n = readLine(bytes[end..]);
            if (!attaching(n.record.class)) break;
            end += n.len;
        }
    }
    return .{ .item = item, .end = end };
}

const ascii: [128]Line = blk: {
    var lines: [128]Line = undefined;
    for (&lines, 0..) |*r, cp| r.* = records.line(cp);
    break :blk lines;
};

inline fn readLine(bytes: []const u8) struct { record: Line, len: u3 } {
    if (bytes[0] < 0x80) return .{ .record = ascii[bytes[0]], .len = 1 };
    const d = utf8.decode(bytes);
    return .{ .record = records.line(d.code_point), .len = d.len };
}

const Decision = enum { mandatory, allowed, prohibited };

/// The rules at the position before the code point `record`, which starts
/// at `at` and ends at `end`.
fn decide(b: *const Behind, record: Line, bytes: []const u8, end: usize) Decision {
    const p = b.raw;
    const c = record.class;
    // Two letters, the first as written (so an item of its own): LB28, and
    // no rule before it reads this pair. Most positions in words.
    if (letter(p) and letter(c)) return .prohibited;
    if (p == .mandatory_break) return .mandatory; // LB4
    if (p == .carriage_return and c == .line_feed) return .prohibited; // LB5
    if (p == .carriage_return or p == .line_feed or p == .next_line) return .mandatory; // LB5
    if (hard(c)) return .prohibited; // LB6
    if (c == .space or c == .zw_space) return .prohibited; // LB7
    if (b.solid != null and b.solid.?.class == .zw_space and (b.lastIs(.zw_space) or b.lastIs(.space))) return .allowed; // LB8
    if (p == .zwj) return .prohibited; // LB8a
    const left = b.last.?; // a code point has been taken in: `b.started`
    if (attaching(c) and base(left.class)) return .prohibited; // LB9
    const r: Item = if (attaching(c)) letter_a else record; // LB10
    const l = left.class;
    const rc = r.class;
    if (rc == .word_joiner or l == .word_joiner) return .prohibited; // LB11
    if (l == .glue) return .prohibited; // LB12
    if (rc == .glue and !(l == .space or l == .hyphen or l == .unambiguous_hyphen)) return .prohibited; // LB12a
    if (rc == .close_punctuation or rc == .close_parenthesis or rc == .exclamation or rc == .break_symbols) return .prohibited; // LB13
    // Through spaces: the last item that is not one, or the start.
    const solid: Item = b.solid orelse .{ .class = .space };
    if (solid.class == .open_punctuation) return .prohibited; // LB14
    if (solid.class == .quotation and solid.initial) { // LB15a
        const s = b.before_solid;
        if (s == null) return .prohibited;
        switch (s.?.class) {
            .mandatory_break, .carriage_return, .line_feed, .next_line, .open_punctuation, .quotation, .glue, .space, .zw_space => return .prohibited,
            else => {},
        }
    }
    if (rc == .quotation and r.final) { // LB15b
        const next = ahead.first(bytes, attachedEnd(bytes, end, r));
        if (next == null) return .prohibited;
        switch (next.?.class) {
            .space, .glue, .word_joiner, .close_punctuation, .quotation, .close_parenthesis, .exclamation, .infix_numeric, .break_symbols, .mandatory_break, .carriage_return, .line_feed, .next_line, .zw_space => return .prohibited,
            else => {},
        }
    }
    if (l == .space and rc == .infix_numeric) { // LB15c
        if (ahead.first(bytes, attachedEnd(bytes, end, r))) |next| if (next.class == .numeric) return .allowed;
    }
    if (rc == .infix_numeric) return .prohibited; // LB15d
    if ((solid.class == .close_punctuation or solid.class == .close_parenthesis) and rc == .nonstarter) return .prohibited; // LB16
    if (solid.class == .break_both and rc == .break_both) return .prohibited; // LB17
    if (l == .space) return .allowed; // LB18
    return decideItems(b, left, r, bytes, end);
}

/// LB19 to LB31, which read the items around the position: `left` before
/// it, `r` after it.
fn decideItems(b: *const Behind, left: Item, r: Item, bytes: []const u8, end: usize) Decision {
    const l = left.class;
    const rc = r.class;
    if (rc == .quotation and !r.initial) return .prohibited; // LB19
    if (l == .quotation and !left.final) return .prohibited; // LB19
    if (rc == .quotation) { // LB19a
        if (!left.east_asian) return .prohibited;
        const next = ahead.first(bytes, attachedEnd(bytes, end, r));
        if (next == null or !next.?.east_asian) return .prohibited;
    }
    if (l == .quotation) {
        if (!r.east_asian) return .prohibited;
        if (b.before == null or !b.before.?.east_asian) return .prohibited;
    }
    if (rc == .contingent_break or l == .contingent_break) return .allowed; // LB20
    if ((l == .hyphen or l == .unambiguous_hyphen) and letter(rc)) { // LB20a
        const s = b.before;
        if (s == null) return .prohibited;
        switch (s.?.class) {
            .mandatory_break, .carriage_return, .line_feed, .next_line, .space, .zw_space, .contingent_break, .glue => return .prohibited,
            else => {},
        }
    }
    if (rc == .break_after or rc == .unambiguous_hyphen or rc == .hyphen or rc == .nonstarter) return .prohibited; // LB21
    if (l == .break_before) return .prohibited; // LB21
    if ((l == .hyphen or l == .unambiguous_hyphen) and rc != .hebrew_letter and b.before != null and b.before.?.class == .hebrew_letter) return .prohibited; // LB21a
    if (l == .break_symbols and rc == .hebrew_letter) return .prohibited; // LB21b
    if (rc == .inseparable) return .prohibited; // LB22
    if (letter(l) and rc == .numeric) return .prohibited; // LB23
    if (l == .numeric and letter(rc)) return .prohibited; // LB23
    if (l == .prefix_numeric and (rc == .ideographic or rc == .e_base or rc == .e_modifier)) return .prohibited; // LB23a
    if ((l == .ideographic or l == .e_base or l == .e_modifier) and rc == .postfix_numeric) return .prohibited; // LB23a
    if ((l == .prefix_numeric or l == .postfix_numeric) and letter(rc)) return .prohibited; // LB24
    if (letter(l) and (rc == .prefix_numeric or rc == .postfix_numeric)) return .prohibited; // LB24
    // LB25.
    if (b.number != .none and (rc == .postfix_numeric or rc == .prefix_numeric)) return .prohibited;
    if (b.number == .digits and rc == .numeric) return .prohibited;
    if ((l == .postfix_numeric or l == .prefix_numeric) and rc == .open_punctuation) {
        if (ahead.first(bytes, attachedEnd(bytes, end, r))) |next| {
            if (next.class == .numeric) return .prohibited;
            if (next.class == .infix_numeric) if (ahead.second(bytes, attachedEnd(bytes, end, r))) |second| if (second.class == .numeric) return .prohibited;
        }
    }
    if ((l == .postfix_numeric or l == .prefix_numeric or l == .hyphen or l == .infix_numeric) and rc == .numeric) return .prohibited;
    // LB26, LB27: Korean syllable blocks.
    if (l == .jl and (rc == .jl or rc == .jv or rc == .h2 or rc == .h3)) return .prohibited;
    if ((l == .jv or l == .h2) and (rc == .jv or rc == .jt)) return .prohibited;
    if ((l == .jt or l == .h3) and rc == .jt) return .prohibited;
    if (hangul(l) and rc == .postfix_numeric) return .prohibited;
    if (l == .prefix_numeric and hangul(rc)) return .prohibited;
    if (letter(l) and letter(rc)) return .prohibited; // LB28
    // LB28a: Brahmic orthographic syllables.
    if (l == .aksara_prebase and aksara(r)) return .prohibited;
    if (aksara(left) and (rc == .virama_final or rc == .virama)) return .prohibited;
    if (l == .virama and (rc == .aksara or r.dotted_circle) and b.before != null and aksara(b.before.?)) return .prohibited;
    if (aksara(left) and aksara(r)) {
        if (ahead.first(bytes, attachedEnd(bytes, end, r))) |next| if (next.class == .virama_final) return .prohibited;
    }
    if (l == .infix_numeric and letter(rc)) return .prohibited; // LB29
    // LB30.
    if ((letter(l) or l == .numeric) and rc == .open_punctuation and !r.east_asian) return .prohibited;
    if (l == .close_parenthesis and !left.east_asian and (letter(rc) or rc == .numeric)) return .prohibited;
    if (l == .regional_indicator and rc == .regional_indicator and b.ri_odd) return .prohibited; // LB30a
    if (rc == .e_modifier and (l == .e_base or left.pictographic_unassigned)) return .prohibited; // LB30b
    return .allowed; // LB31
}

/// What comes after the item at a position, read only when a rule asks.
const ahead = struct {
    fn first(text: []const u8, from: usize) ?Item {
        const n = itemAt(text, from) orelse return null;
        return n.item;
    }
    fn second(text: []const u8, from: usize) ?Item {
        const n = itemAt(text, from) orelse return null;
        const m = itemAt(text, n.end) orelse return null;
        return m.item;
    }
};

/// Where the marks attached to `r` (ending at `end`) end: LB9 joins them to
/// it, so what is ahead of `r` starts there.
fn attachedEnd(bytes: []const u8, end: usize, r: Item) usize {
    if (!base(r.class) or attaching(r.class)) return end;
    var at = end;
    while (at < bytes.len) {
        const n = readLine(bytes[at..]);
        if (!attaching(n.record.class)) break;
        at += n.len;
    }
    return at;
}

/// The line break opportunities of a string, in order: each segment ends
/// where a line may break.
pub const Iterator = struct {
    bytes: []const u8,
    /// Private: where the next segment starts; `offset` reads it.
    start: usize = 0,
    /// Private: where the next undecided code point starts.
    at: usize = 0,
    /// Private: the context behind `at`.
    behind: Behind = .{},

    pub fn init(bytes: []const u8) Iterator {
        return .{ .bytes = bytes };
    }

    /// Where the next segment starts.
    pub fn offset(it: *const Iterator) domains.Bytes {
        return .fromRaw(it.start);
    }

    /// The next segment, or null at the end.
    pub fn next(it: *Iterator) ?[]const u8 {
        const b = it.nextBreak() orelse return null;
        return b.span.of(it.bytes);
    }

    /// The next segment's byte range, or null at the end.
    pub fn nextSpan(it: *Iterator) ?Span {
        const b = it.nextBreak() orelse return null;
        return b.span;
    }

    /// The next segment and whether the line must end after it, or null at
    /// the end.
    pub fn nextBreak(it: *Iterator) ?Break {
        const bytes = it.bytes;
        const start = it.start;
        if (start >= bytes.len) return null;
        while (it.at < bytes.len) {
            const at = it.at;
            const n = readLine(bytes[at..]);
            const decision: Decision = if (it.behind.started) decide(&it.behind, n.record, bytes, at + n.len) else .prohibited;
            it.behind.push(n.record);
            it.at = at + n.len;
            if (decision != .prohibited and at > start) {
                it.start = at;
                return .{ .span = .{ .start = .fromRaw(start), .end = .fromRaw(at) }, .mandatory = decision == .mandatory };
            }
        }
        it.start = bytes.len;
        return .{ .span = .{ .start = .fromRaw(start), .end = .fromRaw(bytes.len) }, .mandatory = hard(it.behind.raw) };
    }
};

/// The line break opportunities of `bytes` by UAX #14's default rules.
pub fn iterate(bytes: []const u8) Iterator {
    return .init(bytes);
}

test "breaks of a sentence" {
    var it = iterate("The (quick) fox\u{2014}a \u{201c}test\u{201d}, $12.50 each.\nNext");
    const want = [_][]const u8{ "The ", "(quick) ", "fox", "\u{2014}", "a ", "\u{201c}test\u{201d}, ", "$12.50 ", "each.\n", "Next" };
    for (want) |w| try std.testing.expectEqualStrings(w, it.next().?);
    try std.testing.expectEqual(null, it.next());
    var hard_break = iterate("a\r\nb");
    try std.testing.expect(hard_break.nextBreak().?.mandatory);
    try std.testing.expect(!hard_break.nextBreak().?.mandatory);
}
