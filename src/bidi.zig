//! The Unicode Bidirectional Algorithm (UAX #9) for a layout engine: a
//! paragraph's embedding levels and runs, then each line reordered after the
//! engine has chosen its breaks. Every position is a byte offset into the
//! caller's UTF-8 text, the offsets `lines` and `graphemes` give, and nothing
//! is allocated: the caller gives a level and a scratch slot for each byte of
//! a paragraph.
//!
//! The rules run in order, as UAX #9 states them, over one representation:
//! a slot per byte, each code point's class at its first byte and its other
//! bytes skipped as rule X9 skips the characters it removes. Matched isolates
//! and paired brackets are linked through the slots, so an isolating run
//! sequence is followed without building it, and nothing is quadratic.
const std = @import("std");
const aegis = @import("aegis");
const domains = @import("domains.zig");
const properties = @import("properties.zig");
const records = @import("records.zig");
const utf8 = @import("utf8.zig");
const data = @import("data.zig");

const Bytes = domains.Bytes;
const Span = domains.Span;
pub const BidiClass = properties.BidiClass;

/// An embedding level: 0 to 125 explicitly, and 126 at most once implicit
/// levels are resolved. An odd level is right-to-left.
pub const Level = u7;

/// The deepest explicit embedding (BD2).
pub const max_depth = 125;

/// The longest paragraph `resolve` takes, in bytes: a slot links positions
/// in 24 bits.
pub const max_paragraph = (1 << 24) - 1;

pub const Direction = enum {
    ltr,
    rtl,

    /// The direction of a level.
    pub fn of(level: Level) Direction {
        return if (level & 1 == 0) .ltr else .rtl;
    }
};

pub const Options = struct {
    /// The paragraph's direction: given, or found by rules P2 and P3 from
    /// its first strong character outside isolates.
    direction: enum { auto, ltr, rtl } = .auto,
    /// The direction when `.auto` finds no strong character (HL1).
    fallback: Direction = .ltr,
};

/// One byte's working state while a paragraph is resolved. The caller owns
/// the memory; it means nothing after `resolve` returns.
pub const Scratch = packed struct(u32) {
    class: BidiClass,
    /// Skipped by every rule after X9: a byte inside a code point, or a
    /// character X9 removes.
    removed: bool,
    kind: Kind,
    /// An isolate initiator's matching PDI, a matched PDI's initiator, an
    /// opening bracket's closing one; `none` where there is none.
    link: u24,

    const Kind = enum(u2) { other, initiator, pdi };
    const none = std.math.maxInt(u24);
};

/// A range of the text at one level.
pub const Run = struct {
    span: Span,
    level: Level,

    pub fn direction(r: Run) Direction {
        return .of(r.level);
    }
};

/// The memory a paragraph is resolved in: at least as many entries in each
/// as the paragraph has bytes, its separator included.
pub const Buffers = struct {
    levels: []Level,
    scratch: []Scratch,
};

/// A resolved paragraph: the level of every byte after rules I1 and I2 (each
/// byte of a code point at its code point's level, and a character X9
/// removes at the level before it), before any line is reordered.
pub const Paragraph = struct {
    text: []const u8,
    /// The paragraph within `text`, its separator included.
    span: Span,
    /// The paragraph embedding level.
    level: Level,
    /// One per byte of `span`: `levels[i]` is the level of byte `span.start + i`.
    levels: []const Level,

    /// Resolves the paragraph of `text` that starts at `start`: up to and
    /// including its paragraph separator (a CR LF pair is one), or the end
    /// of the text. The next starts at `paragraph.span.end`.
    pub fn resolve(text: []const u8, start: Bytes, options: Options, buffers: Buffers) Paragraph {
        const from = start.raw();
        aegis.assert.pre(from <= text.len, "a paragraph starts inside its text");
        const end = paragraphEnd(text, from);
        const n = end - from;
        aegis.assert.pre(n <= max_paragraph, "a paragraph is at most max_paragraph bytes");
        aegis.assert.pre(buffers.levels.len >= n and buffers.scratch.len >= n, "the buffers hold a level and a slot for each byte of the paragraph");
        const source: Text = .{ .bytes = text[from..end] };
        const level = resolveIn(source, buffers.levels[0..n], buffers.scratch[0..n], options);
        return .{ .text = text, .span = .fromRaw(from, end), .level = level, .levels = buffers.levels[0..n] };
    }

    pub fn direction(p: *const Paragraph) Direction {
        return .of(p.level);
    }

    /// The level of the byte at `offset`, which is inside the paragraph.
    pub fn levelAt(p: *const Paragraph, offset: Bytes) Level {
        const at = offset.raw();
        const base = p.span.start.raw();
        aegis.assert.pre(at >= base and at - base < p.levels.len, "the offset is inside the paragraph");
        return p.levels[at - base];
    }

    /// The paragraph's level runs, in logical order.
    pub fn runs(p: *const Paragraph) RunIterator {
        return .{ .levels = p.levels, .base = p.span.start.raw(), .at = 0 };
    }

    /// The line `span` (inside the paragraph, starting and ending on code
    /// point boundaries) reordered for display: rule L1 applied to it, then
    /// L2, as runs in visual order in `buffer`, which holds at least one run
    /// a code point of the line (its byte length always suffices).
    pub fn line(p: *const Paragraph, span: Span, buffer: []Run) Line {
        const base = p.span.start.raw();
        const from = span.start.raw();
        const to = span.end.raw();
        aegis.assert.pre(from >= base and from <= to and to - base <= p.levels.len, "the line is inside the paragraph");
        const source: Text = .{ .bytes = p.span.of(p.text) };
        const n = reorder(source, p.levels, from - base, to - base, p.level, buffer);
        for (buffer[0..n]) |*r| r.span = shifted(r.span, base);
        return .{ .text = p.text, .runs = buffer[0..n] };
    }
};

/// `span` moved `by` bytes on.
fn shifted(span: Span, by: usize) Span {
    const start = span.start.raw();
    const end = span.end.raw();
    return .fromRaw(start + by, end + by);
}

/// Level runs in logical order.
pub const RunIterator = struct {
    levels: []const Level,
    base: usize,
    at: usize,

    pub fn next(it: *RunIterator) ?Run {
        if (it.at == it.levels.len) return null;
        const start = it.at;
        const level = it.levels[start];
        while (it.at < it.levels.len and it.levels[it.at] == level) it.at += 1;
        return .{ .span = .fromRaw(it.base + start, it.base + it.at), .level = level };
    }
};

/// A line reordered for display.
pub const Line = struct {
    text: []const u8,
    /// Runs in visual order, left to right; an odd level's run is shown
    /// right to left, its code points reversed and mirrored (L4).
    runs: []const Run,

    /// The byte offsets of the line's code points in visual order.
    pub fn visual(l: *const Line) VisualIterator {
        return .{ .text = l.text, .runs = l.runs, .run = 0, .at = if (l.runs.len == 0) 0 else VisualIterator.entry(l.runs[0]) };
    }
};

/// Each code point of a line, by its byte offset, in visual order.
pub const VisualIterator = struct {
    text: []const u8,
    runs: []const Run,
    run: usize,
    /// In a left-to-right run, where the next code point starts; in a
    /// right-to-left one, where it ends.
    at: usize,

    fn entry(r: Run) usize {
        return if (r.level & 1 == 0) r.span.start.raw() else r.span.end.raw();
    }

    pub fn next(it: *VisualIterator) ?Bytes {
        while (it.run < it.runs.len) {
            const r = it.runs[it.run];
            const start = r.span.start.raw();
            const end = r.span.end.raw();
            if (r.level & 1 == 0) {
                if (it.at < end) {
                    const here = it.at;
                    it.at += utf8.decode(it.text[here..end]).len;
                    return .fromRaw(here);
                }
            } else if (it.at > start) {
                it.at = records.codePointStart(it.text[0..it.at], it.at);
                return .fromRaw(it.at);
            }
            it.run += 1;
            if (it.run < it.runs.len) it.at = entry(it.runs[it.run]);
        }
        return null;
    }
};

/// Bidi_Mirroring_Glyph: the code point an odd level shows in place of
/// `cp`, or null.
pub fn mirror(cp: u21) ?u21 {
    const list = &data.bidi.mirrors;
    var low: usize = 0;
    var high: usize = list.len;
    while (low < high) {
        const mid = (low + high) / 2;
        if (list[mid][0] < cp) low = mid + 1 else high = mid;
    }
    return if (low < list.len and list[low][0] == cp) list[low][1] else null;
}

/// A paired bracket (Bidi_Paired_Bracket_Type Open or Close), and the code
/// point it pairs with.
pub const Bracket = struct { pair: u21, opening: bool };

/// Bidi_Paired_Bracket and Bidi_Paired_Bracket_Type of `cp`, or null when it
/// is no paired bracket.
pub fn pairedBracket(cp: u21) ?Bracket {
    const b = bracketOf(cp) orelse return null;
    return .{ .pair = b.pair, .opening = b.opening };
}

fn bracketOf(cp: u21) ?data.bidi.Bracket {
    const list = &data.bidi.brackets;
    var low: usize = 0;
    var high: usize = list.len;
    while (low < high) {
        const mid = (low + high) / 2;
        if (list[mid].code_point < cp) low = mid + 1 else high = mid;
    }
    return if (low < list.len and list[low].code_point == cp) list[low] else null;
}

/// The algorithm over a list of classes alone, one a character, as
/// BidiTest.txt states its cases: no paired brackets, so N0 does nothing.
/// Returns the paragraph embedding level; `levels` holds each character's,
/// a removed one's being the level before it.
pub fn resolveClasses(classes: []const BidiClass, options: Options, buffers: Buffers) Level {
    aegis.assert.pre(classes.len <= max_paragraph and buffers.levels.len >= classes.len and buffers.scratch.len >= classes.len, "the buffers hold a level and a slot for each class");
    return resolveIn(Classes{ .list = classes }, buffers.levels[0..classes.len], buffers.scratch[0..classes.len], options);
}

/// The line of `classes` from `start` to `end`, resolved by
/// `resolveClasses` at paragraph level `level`, reordered as
/// `Paragraph.line` reorders text: runs of character indices.
pub fn reorderClasses(classes: []const BidiClass, levels: []const Level, start: usize, end: usize, level: Level, buffer: []Run) []Run {
    return buffer[0..reorder(Classes{ .list = classes }, levels, start, end, level, buffer)];
}

// ---------------------------------------------------------------------------
// Sources: what the rules read of a position.

/// Text: each code point's class and bracket at its first byte.
const Text = struct {
    bytes: []const u8,

    /// The code point that starts at `i` and its class; `len` 1 for ASCII.
    inline fn at(t: Text, i: usize) struct { class: BidiClass, len: u3 } {
        const b = t.bytes[i];
        if (b < 0x80) return .{ .class = ascii_classes[b], .len = 1 };
        const d = utf8.decode(t.bytes[i..]);
        return .{ .class = properties.bidiClass(d.code_point), .len = d.len };
    }

    fn bracket(t: Text, i: usize) ?data.bidi.Bracket {
        const b = t.bytes[i];
        if (b < 0x80) return if (ascii_bracket[b]) bracketOf(b) else null;
        return bracketOf(utf8.decode(t.bytes[i..]).code_point);
    }
};

/// Classes alone, one a position.
const Classes = struct {
    list: []const BidiClass,

    inline fn at(c: Classes, i: usize) struct { class: BidiClass, len: u3 } {
        return .{ .class = c.list[i], .len = 1 };
    }

    fn bracket(c: Classes, i: usize) ?data.bidi.Bracket {
        _ = c;
        _ = i;
        return null;
    }
};

const ascii_classes = blk: {
    var out: [128]BidiClass = undefined;
    @setEvalBranchQuota(100_000);
    for (&out, 0..) |*c, cp| c.* = properties.bidiClass(cp);
    break :blk out;
};

const ascii_bracket = blk: {
    var out: [128]bool = @splat(false);
    for ("()[]{}") |c| out[c] = true;
    break :blk out;
};

/// The end of the paragraph starting at `from`: past its separator.
fn paragraphEnd(text: []const u8, from: usize) usize {
    const t: Text = .{ .bytes = text };
    var i = from;
    while (i < text.len) {
        const c = t.at(i);
        i += c.len;
        if (c.class == .paragraph_separator) {
            if (text[i - 1] == '\r' and i < text.len and text[i] == '\n') i += 1;
            return i;
        }
    }
    return text.len;
}

// ---------------------------------------------------------------------------
// The algorithm

fn isIsolateInitiator(c: BidiClass) bool {
    return c == .left_to_right_isolate or c == .right_to_left_isolate or c == .first_strong_isolate;
}

/// A neutral or isolate formatting character (NI, rules N1 and N2).
fn isNeutral(c: BidiClass) bool {
    return switch (c) {
        .paragraph_separator, .segment_separator, .white_space, .other_neutral, .left_to_right_isolate, .right_to_left_isolate, .first_strong_isolate, .pop_directional_isolate => true,
        else => false,
    };
}

/// The rules on one paragraph; returns its embedding level.
fn resolveIn(source: anytype, levels: []Level, slots: []Scratch, options: Options) Level {
    const n = slots.len;
    if (n == 0) return switch (options.direction) {
        .rtl => 1,
        .ltr => 0,
        .auto => @intFromBool(options.fallback == .rtl),
    };
    classify(source, slots);
    const para: Level = switch (options.direction) {
        .ltr => 0,
        .rtl => 1,
        .auto => if (firstStrong(slots, 0, n)) |d| @backingInt(d) else @intFromBool(options.fallback == .rtl),
    };
    explicit(slots, levels, para);
    var ctx: Context(@TypeOf(source)) = .{ .source = source, .slots = slots, .levels = levels, .para = para };
    ctx.sequences();
    // I1 and I2, once every sequence is resolved: following a sequence
    // compares explicit levels, so none moves before.
    for (slots, levels) |s, *lv| {
        if (s.removed) continue;
        if (lv.* & 1 == 0) {
            if (s.class == .right_to_left) lv.* += 1 else if (s.class == .arabic_number or s.class == .european_number) lv.* += 2;
        } else if (s.class == .left_to_right or s.class == .european_number or s.class == .arabic_number) lv.* += 1;
    }
    // A removed position takes the level before it: a code point's later
    // bytes their first byte's, a removed character the character's before.
    var before = para;
    for (slots, levels) |s, *lv| {
        if (s.removed) lv.* = before else before = lv.*;
    }
    return para;
}

/// Fills each slot with its position's class, marks the bytes inside code
/// points removed, and matches isolate initiators with PDIs (BD9) through
/// the links: an open initiator links to the one open before it, so the
/// links are the stack.
fn classify(source: anytype, slots: []Scratch) void {
    const n = slots.len;
    var open: u24 = Scratch.none;
    var i: usize = 0;
    while (i < n) {
        const c = source.at(i);
        const kind: Scratch.Kind = if (isIsolateInitiator(c.class)) .initiator else if (c.class == .pop_directional_isolate) .pdi else .other;
        slots[i] = .{ .class = c.class, .removed = false, .kind = kind, .link = Scratch.none };
        switch (kind) {
            .initiator => {
                slots[i].link = open;
                open = @intCast(i);
            },
            .pdi => if (open != Scratch.none) {
                const m = open;
                open = slots[m].link;
                slots[m].link = @intCast(i);
                slots[i].link = m;
            },
            .other => {},
        }
        var k: usize = 1;
        while (k < c.len) : (k += 1) slots[i + k] = .{ .class = .boundary_neutral, .removed = true, .kind = .other, .link = Scratch.none };
        i += c.len;
    }
    // Initiators left open have no matching PDI.
    while (open != Scratch.none) {
        const m = open;
        open = slots[m].link;
        slots[m].link = Scratch.none;
    }
}

/// Rules P2 and P3 on positions `from` to `to`: the direction of the first
/// L, R or AL, skipping what isolates hold, or null.
fn firstStrong(slots: []const Scratch, from: usize, to: usize) ?Direction {
    var i = from;
    while (i < to) {
        const s = slots[i];
        if (s.removed) {
            i += 1;
            continue;
        }
        switch (s.class) {
            .left_to_right => return .ltr,
            .right_to_left, .arabic_letter => return .rtl,
            .left_to_right_isolate, .right_to_left_isolate, .first_strong_isolate => {
                if (s.link == Scratch.none) return null;
                i = s.link;
            },
            .paragraph_separator => return null,
            else => {},
        }
        i += 1;
    }
    return null;
}

const Override = enum(u2) { neutral, ltr, rtl };

const Entry = struct { level: Level, override: Override, isolate: bool };

/// Rules X1 to X9: explicit levels, overrides applied to classes, and the
/// characters X9 removes marked.
fn explicit(slots: []Scratch, levels: []Level, para: Level) void {
    var stack: [max_depth + 2]Entry = undefined;
    var depth: usize = 1;
    stack[0] = .{ .level = para, .override = .neutral, .isolate = false };
    var overflow_isolates: usize = 0;
    var overflow_embeddings: usize = 0;
    var valid_isolates: usize = 0;
    const n = slots.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const s = &slots[i];
        if (s.removed) continue;
        const top = stack[depth - 1];
        switch (s.class) {
            .right_to_left_embedding, .left_to_right_embedding, .right_to_left_override, .left_to_right_override => {
                const rtl = s.class == .right_to_left_embedding or s.class == .right_to_left_override;
                const next: usize = if (rtl) (top.level + 1) | 1 else (top.level + 2) & ~@as(usize, 1);
                if (next <= max_depth and overflow_isolates == 0 and overflow_embeddings == 0) {
                    stack[depth] = .{ .level = @intCast(next), .override = switch (s.class) {
                        .right_to_left_override => .rtl,
                        .left_to_right_override => .ltr,
                        else => .neutral,
                    }, .isolate = false };
                    depth += 1;
                } else if (overflow_isolates == 0) overflow_embeddings += 1;
                levels[i] = top.level;
                s.removed = true;
            },
            .right_to_left_isolate, .left_to_right_isolate, .first_strong_isolate => {
                levels[i] = top.level;
                const initiator = s.class;
                applyOverride(s, top.override);
                const rtl = switch (initiator) {
                    .right_to_left_isolate => true,
                    .left_to_right_isolate => false,
                    // X5c: the direction of the first strong character before its matching PDI.
                    else => (firstStrong(slots, i + 1, if (s.link == Scratch.none) n else s.link) orelse .ltr) == .rtl,
                };
                const next: usize = if (rtl) (top.level + 1) | 1 else (top.level + 2) & ~@as(usize, 1);
                if (next <= max_depth and overflow_isolates == 0 and overflow_embeddings == 0) {
                    valid_isolates += 1;
                    stack[depth] = .{ .level = @intCast(next), .override = .neutral, .isolate = true };
                    depth += 1;
                } else overflow_isolates += 1;
            },
            .pop_directional_isolate => {
                if (overflow_isolates > 0) {
                    overflow_isolates -= 1;
                } else if (valid_isolates > 0) {
                    overflow_embeddings = 0;
                    while (!stack[depth - 1].isolate) depth -= 1;
                    depth -= 1;
                    valid_isolates -= 1;
                }
                const now = stack[depth - 1];
                levels[i] = now.level;
                applyOverride(s, now.override);
            },
            .pop_directional_format => {
                if (overflow_isolates > 0) {} else if (overflow_embeddings > 0) {
                    overflow_embeddings -= 1;
                } else if (!top.isolate and depth >= 2) depth -= 1;
                levels[i] = top.level;
                s.removed = true;
            },
            .paragraph_separator => levels[i] = para,
            .boundary_neutral => {
                levels[i] = top.level;
                s.removed = true;
            },
            else => {
                levels[i] = top.level;
                applyOverride(s, top.override);
            },
        }
    }
}

fn applyOverride(s: *Scratch, o: Override) void {
    switch (o) {
        .neutral => {},
        .ltr => s.class = .left_to_right,
        .rtl => s.class = .right_to_left,
    }
}

fn Context(comptime Source: type) type {
    return struct {
        source: Source,
        slots: []Scratch,
        levels: []Level,
        para: Level,

        const Self = @This();

        /// The next position kept by X9 after `p` in text order, or null.
        inline fn after(c: *const Self, p: usize) ?usize {
            var q = p + 1;
            while (q < c.slots.len) : (q += 1) if (!c.slots[q].removed) return q;
            return null;
        }

        inline fn before(c: *const Self, p: usize) ?usize {
            var q = p;
            while (q > 0) {
                q -= 1;
                if (!c.slots[q].removed) return q;
            }
            return null;
        }

        /// The position after `p` in its isolating run sequence (BD13): the
        /// next in its level run, or the matching PDI of an isolate
        /// initiator that ends one.
        fn next(c: *const Self, p: usize) ?usize {
            if (c.after(p)) |q| if (c.levels[q] == c.levels[p]) return q;
            const s = c.slots[p];
            if (s.kind == .initiator and s.link != Scratch.none) return s.link;
            return null;
        }

        fn prev(c: *const Self, p: usize) ?usize {
            if (c.before(p)) |q| if (c.levels[q] == c.levels[p]) return q;
            const s = c.slots[p];
            if (s.kind == .pdi and s.link != Scratch.none) return s.link;
            return null;
        }

        /// Every isolating run sequence, each resolved by rules W1 to I2.
        fn sequences(c: *Self) void {
            var p: usize = 0;
            while (p < c.slots.len) : (p += 1) {
                const s = c.slots[p];
                if (s.removed) continue;
                if (c.before(p)) |q| if (c.levels[q] == c.levels[p]) continue;
                // A matched PDI starting a level run continues its initiator's sequence.
                if (s.kind == .pdi and s.link != Scratch.none and c.prev(p) != null) continue;
                c.sequence(p);
            }
        }

        fn sequence(c: *Self, first: usize) void {
            const level = c.levels[first];
            var last = first;
            while (c.next(last)) |q| last = q;
            const before_level = if (c.before(first)) |q| c.levels[q] else c.para;
            const after_level = if (c.slots[last].kind == .initiator) c.para else if (c.after(last)) |q| c.levels[q] else c.para;
            const sos: BidiClass = if (@max(level, before_level) & 1 == 1) .right_to_left else .left_to_right;
            const eos: BidiClass = if (@max(level, after_level) & 1 == 1) .right_to_left else .left_to_right;
            const e: BidiClass = if (level & 1 == 1) .right_to_left else .left_to_right;
            c.weak(first, sos);
            c.brackets(first, sos, e);
            c.neutrals(first, sos, eos, e);
        }

        /// Rules W1 to W7.
        fn weak(c: *Self, first: usize, sos: BidiClass) void {
            // W1 to W3 in one pass: each reads only what is before it.
            var before_class = sos;
            var last_strong = sos;
            var p: ?usize = first;
            while (p) |at| : (p = c.next(at)) {
                const s = &c.slots[at];
                if (s.class == .nonspacing_mark) s.class = if (isIsolateInitiator(before_class) or before_class == .pop_directional_isolate) .other_neutral else before_class;
                before_class = s.class;
                switch (s.class) {
                    .left_to_right, .right_to_left => last_strong = s.class,
                    .arabic_letter => {
                        last_strong = .arabic_letter;
                        s.class = .right_to_left;
                    },
                    .european_number => if (last_strong == .arabic_letter) {
                        s.class = .arabic_number;
                    },
                    else => {},
                }
            }
            // W4 to W6 in one pass. W4 reads the class before a separator as
            // W4 left it and the one after as W3 did; W5 an ET run's
            // neighbours as W4 left them; W6 takes what is left.
            var earlier: BidiClass = sos;
            var before_run: BidiClass = sos;
            var ets: ?usize = null;
            p = first;
            while (p) |at| {
                const nxt = c.next(at);
                const s = &c.slots[at];
                if (s.class == .european_separator or s.class == .common_separator) {
                    if (nxt) |q| {
                        const later = c.slots[q].class;
                        if (earlier == .european_number and later == .european_number) {
                            s.class = .european_number;
                        } else if (s.class == .common_separator and earlier == .arabic_number and later == .arabic_number) s.class = .arabic_number;
                    }
                }
                if (s.class == .european_terminator) {
                    if (ets == null) {
                        ets = at;
                        before_run = earlier;
                    }
                } else if (ets) |run| {
                    c.setRun(run, at, if (before_run == .european_number or s.class == .european_number) .european_number else .other_neutral);
                    ets = null;
                }
                earlier = s.class;
                if (s.class == .european_separator or s.class == .common_separator) s.class = .other_neutral;
                p = nxt;
            }
            if (ets) |run| c.setRun(run, null, if (before_run == .european_number) .european_number else .other_neutral);
            // W7.
            last_strong = sos;
            p = first;
            while (p) |at| : (p = c.next(at)) {
                const s = &c.slots[at];
                switch (s.class) {
                    .left_to_right, .right_to_left => last_strong = s.class,
                    .european_number => if (last_strong == .left_to_right) {
                        s.class = .left_to_right;
                    },
                    else => {},
                }
            }
        }

        /// Sets the class of each position from `from` up to (not including)
        /// `to`, or to the end of the sequence.
        fn setRun(c: *Self, from: usize, to: ?usize, class: BidiClass) void {
            var p: ?usize = from;
            while (p) |at| : (p = c.next(at)) {
                if (to) |t| if (at == t) return;
                c.slots[at].class = class;
            }
        }

        /// Strong direction as N0 to N2 read it: EN and AN count as R.
        fn strong(class: BidiClass) ?BidiClass {
            return switch (class) {
                .left_to_right => .left_to_right,
                .right_to_left, .european_number, .arabic_number => .right_to_left,
                else => null,
            };
        }

        /// Rule N0: paired brackets (BD16), each pair taking a direction from
        /// what it holds and the context before it.
        fn brackets(c: *Self, first: usize, sos: BidiClass, e: BidiClass) void {
            if (Source == Classes) return;
            const Open = struct { id: u21, at: usize };
            var stack: [63]Open = undefined;
            var depth: usize = 0;
            var any = false;
            var p: ?usize = first;
            find: while (p) |at| : (p = c.next(at)) {
                if (c.slots[at].class != .other_neutral) continue;
                const b = c.source.bracket(at) orelse continue;
                if (b.opening) {
                    if (depth == stack.len) break :find;
                    stack[depth] = .{ .id = b.id, .at = at };
                    depth += 1;
                } else {
                    var k = depth;
                    while (k > 0) {
                        k -= 1;
                        if (stack[k].id == b.id) {
                            c.slots[stack[k].at].link = @intCast(at);
                            depth = k;
                            any = true;
                            break;
                        }
                    }
                }
            }
            if (!any) return;
            const opposite: BidiClass = if (e == .left_to_right) .right_to_left else .left_to_right;
            var context = sos;
            p = first;
            while (p) |at| : (p = c.next(at)) {
                const s = c.slots[at];
                if (s.kind == .other and s.link != Scratch.none and s.class == .other_neutral) {
                    const close: usize = s.link;
                    var found_e = false;
                    var found_opposite = false;
                    var q = c.next(at);
                    while (q) |in| : (q = c.next(in)) {
                        if (in == close) break;
                        if (strong(c.slots[in].class)) |d| {
                            if (d == e) {
                                found_e = true;
                                break;
                            }
                            found_opposite = true;
                        }
                    }
                    const resolved: ?BidiClass = if (found_e) e else if (found_opposite) (if (context == opposite) opposite else e) else null;
                    if (resolved) |d| {
                        c.setBracket(at, d);
                        c.setBracket(close, d);
                    }
                }
                if (strong(c.slots[at].class)) |d| context = d;
            }
        }

        /// Sets a bracket's class, and the class of the marks after it that
        /// were NSM before W1 changed them (N0's note).
        fn setBracket(c: *Self, at: usize, class: BidiClass) void {
            c.slots[at].class = class;
            var q = c.next(at);
            while (q) |mark| : (q = c.next(mark)) {
                if (c.source.at(mark).class != .nonspacing_mark) return;
                c.slots[mark].class = class;
            }
        }

        /// Rules N1 and N2.
        fn neutrals(c: *Self, first: usize, sos: BidiClass, eos: BidiClass, e: BidiClass) void {
            var earlier = sos;
            var run: ?usize = null;
            var p: ?usize = first;
            while (p) |at| : (p = c.next(at)) {
                const cls = c.slots[at].class;
                if (isNeutral(cls)) {
                    if (run == null) run = at;
                    continue;
                }
                const d = strong(cls) orelse e;
                if (run) |from| {
                    c.setRun(from, at, if (earlier == d) d else e);
                    run = null;
                }
                earlier = d;
            }
            if (run) |from| c.setRun(from, null, if (earlier == eos) eos else e);
        }
    };
}

// ---------------------------------------------------------------------------
// Lines: rules L1 and L2.

/// Whitespace as L1 reads it: what it resets before a separator and at the
/// end of a line, the characters X9 removes included.
fn trailing(c: BidiClass) bool {
    return switch (c) {
        .white_space, .left_to_right_isolate, .right_to_left_isolate, .first_strong_isolate, .pop_directional_isolate, .boundary_neutral, .left_to_right_embedding, .right_to_left_embedding, .left_to_right_override, .right_to_left_override, .pop_directional_format => true,
        else => false,
    };
}

/// Writes the line from `start` to `end` of a resolved paragraph as runs in
/// visual order into `buffer`; returns how many.
fn reorder(source: anytype, levels: []const Level, start: usize, end: usize, para: Level, buffer: []Run) usize {
    var out: Runs = .{ .buffer = buffer, .levels = levels };
    // L1, over the line's original classes: a segment or paragraph separator
    // and the whitespace before it, and the whitespace ending the line, at
    // the paragraph level.
    var plain = start;
    var pending: ?usize = null;
    var i = start;
    while (i < end) {
        const c = source.at(i);
        const next = i + c.len;
        if (c.class == .segment_separator or c.class == .paragraph_separator) {
            const reset = pending orelse i;
            out.plain(plain, reset);
            out.at(reset, next, para);
            plain = next;
            pending = null;
        } else if (trailing(c.class)) {
            if (pending == null) pending = i;
        } else pending = null;
        i = next;
    }
    if (pending) |reset| {
        out.plain(plain, reset);
        out.at(reset, end, para);
    } else out.plain(plain, end);
    // L2: from the highest level to the lowest odd one, reverse every
    // sequence of runs at that level or higher.
    const runs = buffer[0..out.len];
    var highest: Level = 0;
    var lowest_odd: Level = max_depth + 2;
    for (runs) |r| {
        highest = @max(highest, r.level);
        if (r.level & 1 == 1) lowest_odd = @min(lowest_odd, r.level);
    }
    var level = highest;
    while (level >= lowest_odd and level > 0) : (level -= 1) {
        var k: usize = 0;
        while (k < runs.len) {
            if (runs[k].level < level) {
                k += 1;
                continue;
            }
            const from = k;
            while (k < runs.len and runs[k].level >= level) k += 1;
            std.mem.reverse(Run, runs[from..k]);
        }
    }
    return out.len;
}

/// Runs in logical order, merged where neighbours share a level.
const Runs = struct {
    buffer: []Run,
    levels: []const Level,
    len: usize = 0,

    /// Positions `from` to `to` at their resolved levels.
    fn plain(r: *Runs, from: usize, to: usize) void {
        var i = from;
        while (i < to) {
            const level = r.levels[i];
            const run_start = i;
            while (i < to and r.levels[i] == level) i += 1;
            r.at(run_start, i, level);
        }
    }

    /// Positions `from` to `to` at `level`.
    fn at(r: *Runs, from: usize, to: usize, level: Level) void {
        if (from == to) return;
        if (r.len != 0 and r.buffer[r.len - 1].level == level and r.buffer[r.len - 1].span.end.eql(.fromRaw(from))) {
            r.buffer[r.len - 1].span.end = .fromRaw(to);
            return;
        }
        aegis.assert.pre(r.len < r.buffer.len, "the run buffer holds a run for each code point of the line");
        r.buffer[r.len] = .{ .span = .fromRaw(from, to), .level = level };
        r.len += 1;
    }
};

test "a right-to-left word in a left-to-right paragraph" {
    // "ab " then Hebrew alef, bet, then " c".
    const text = "ab \u{5d0}\u{5d1} c";
    var levels: [text.len]Level = undefined;
    var scratch: [text.len]Scratch = undefined;
    const p: Paragraph = .resolve(text, .fromRaw(0), .{}, .{ .levels = &levels, .scratch = &scratch });
    try std.testing.expectEqual(@as(Level, 0), p.level);
    try std.testing.expectEqual(@as(Level, 1), p.levelAt(.fromRaw(3)));
    try std.testing.expectEqual(@as(Level, 1), p.levelAt(.fromRaw(4)));
    var buffer: [text.len]Run = undefined;
    const l = p.line(p.span, &buffer);
    try std.testing.expectEqual(3, l.runs.len);
    var order: [8]usize = undefined;
    var n: usize = 0;
    var it = l.visual();
    while (it.next()) |at| : (n += 1) order[n] = at.raw();
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 5, 3, 7, 8 }, order[0..n]);
    try std.testing.expectEqual(@as(?u21, ')'), mirror('('));
    try std.testing.expect(pairedBracket('[').?.opening);
}
