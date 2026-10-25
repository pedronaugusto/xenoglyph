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
    /// Skipped by every rule after X9: a character X9 removes, or a byte
    /// inside a unit (with class BN), which the unit's first byte stands for.
    removed: bool,
    kind: Kind,
    /// An isolate initiator's matching PDI, a matched PDI's initiator, a
    /// paired opening bracket's closing one; for any other position X9
    /// keeps, how far on the next such position is. `none` where there is
    /// none.
    link: u24,

    const Kind = enum(u2) { other, initiator, pdi, paired };
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
        const room = @min(text.len - from, buffers.levels.len, buffers.scratch.len, max_paragraph);
        const source: Text = .{ .bytes = text[from..] };
        const resolved = resolveIn(source, buffers.levels[0..room], buffers.scratch[0..room], options, .paragraph);
        return .{ .text = text, .span = .fromRaw(from, from + resolved.len), .level = resolved.level, .levels = buffers.levels[0..resolved.len] };
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
    return resolveIn(Classes{ .list = classes }, buffers.levels[0..classes.len], buffers.scratch[0..classes.len], options, .whole).level;
}

/// The line of `classes` from `start` to `end`, resolved by
/// `resolveClasses` at paragraph level `level`, reordered as
/// `Paragraph.line` reorders text: runs of character indices.
pub fn reorderClasses(classes: []const BidiClass, levels: []const Level, start: usize, end: usize, level: Level, buffer: []Run) []Run {
    return buffer[0..reorder(Classes{ .list = classes }, levels, start, end, level, buffer)];
}

// ---------------------------------------------------------------------------
// Sources: what the rules read of a position.

/// What a source holds at a position: its class, its length, and its code
/// point (0 for classes alone).
const Point = struct { class: BidiClass, len: u3, code_point: u21 };

/// Text: each code point's class and bracket at its first byte.
const Text = struct {
    bytes: []const u8,

    inline fn len(t: Text) usize {
        return t.bytes.len;
    }

    inline fn byte(t: Text, i: usize) u8 {
        return t.bytes[i];
    }

    /// The code point that starts at `i` and its class; `len` 1 for ASCII.
    inline fn at(t: Text, i: usize) Point {
        const b = t.bytes[i];
        if (b < 0x80) return .{ .class = ascii_classes[b], .len = 1, .code_point = b };
        const d = utf8.decode(t.bytes[i..]);
        return .{ .class = properties.bidiClass(d.code_point), .len = d.len, .code_point = d.code_point };
    }

    /// The bracket at `i`, whose code point is `cp`.
    fn bracket(t: Text, i: usize, cp: u21) ?data.bidi.Bracket {
        _ = t;
        _ = i;
        if (cp < 0x80) return if (ascii_bracket[cp]) bracketOf(cp) else null;
        return bracketOf(cp);
    }
};

/// Classes alone, one a position.
const Classes = struct {
    list: []const BidiClass,

    inline fn len(c: Classes) usize {
        return c.list.len;
    }

    inline fn byte(c: Classes, i: usize) u8 {
        _ = c;
        _ = i;
        return 0;
    }

    inline fn at(c: Classes, i: usize) Point {
        return .{ .class = c.list[i], .len = 1, .code_point = 0 };
    }

    fn bracket(c: Classes, i: usize, cp: u21) ?data.bidi.Bracket {
        _ = c;
        _ = i;
        _ = cp;
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

/// Where a paragraph ends: after its separator, for text, or at the end of
/// the classes, which BidiTest.txt reads as one paragraph whatever they hold.
const Extent = enum { paragraph, whole };

/// The classes no left-to-right paragraph needs resolving for: without one,
/// every level of a paragraph at level 0 is 0.
const leftward: u32 = blk: {
    var m: u32 = 0;
    for ([_]BidiClass{ .right_to_left, .arabic_letter, .arabic_number, .left_to_right_embedding, .right_to_left_embedding, .left_to_right_override, .right_to_left_override, .left_to_right_isolate, .right_to_left_isolate, .first_strong_isolate, .pop_directional_isolate }) |c| m |= @as(u32, 1) << @backingInt(c);
    break :blk m;
};

/// The rules on one paragraph, in the first `slots.len` positions of
/// `source` at most: its length and embedding level.
fn resolveIn(source: anytype, levels: []Level, slots: []Scratch, options: Options, comptime extent: Extent) struct { len: usize, level: Level } {
    const shape = classify(source, slots, extent);
    const n = shape.len;
    const sized = slots[0..n];
    const para: Level = switch (options.direction) {
        .ltr => 0,
        .rtl => 1,
        .auto => if (firstStrong(sized, 0, n)) |d| @backingInt(d) else @intFromBool(options.fallback == .rtl),
    };
    if (para == 0 and shape.seen & leftward == 0) {
        @memset(levels[0..n], 0);
        return .{ .len = n, .level = para };
    }
    explicit(sized, levels[0..n], para);
    var ctx: Context(@TypeOf(source)) = .{ .source = source, .slots = sized, .levels = levels[0..n], .para = para };
    ctx.sequences();
    // I1 and I2, once every sequence is resolved (following a sequence
    // compares explicit levels, so none moves before); and a removed
    // position takes the level before it: a code point's later bytes their
    // first byte's, a removed character the character's before.
    var before = para;
    for (sized, levels[0..n]) |sl, *lv| {
        if (sl.removed) {
            lv.* = before;
            continue;
        }
        if (lv.* & 1 == 0) {
            if (sl.class == .right_to_left) lv.* += 1 else if (sl.class == .arabic_number or sl.class == .european_number) lv.* += 2;
        } else if (sl.class == .left_to_right or sl.class == .european_number or sl.class == .arabic_number) lv.* += 1;
        before = lv.*;
    }
    return .{ .len = n, .level = para };
}

/// Fills the slots in units: a run of code points of one class is one unit,
/// its first byte holding the class and the rest marked inside it (removed,
/// class BN), as is a BN, which X9 removes and nothing reads. Separators
/// (ES, CS), paired brackets, isolate controls and the controls X9 removes
/// (kept, with their own classes, for the X rules) are units of their own:
/// the rules read them one at a time. Each unit links to the next, and
/// isolate initiators are matched with PDIs (BD9), an open initiator linking
/// to the one open before it, so the links are the stack. Returns where the
/// paragraph ends and the classes it holds.
fn classify(source: anytype, slots: []Scratch, comptime extent: Extent) struct { len: usize, seen: u32 } {
    const limit = slots.len;
    const inside: Scratch = .{ .class = .boundary_neutral, .removed = true, .kind = .other, .link = Scratch.none };
    var open: u24 = Scratch.none;
    var unit: ?usize = null;
    // The class of the unit later code points of the same class join.
    var joining: ?BidiClass = null;
    var seen: u32 = 0;
    var i: usize = 0;
    while (i < source.len()) {
        const c = source.at(i);
        aegis.assert.pre(i + c.len <= limit, "the buffers hold a level and a slot for each byte of the paragraph");
        seen |= @as(u32, 1) << @backingInt(c.class);
        const alone = switch (c.class) {
            .boundary_neutral => {
                fill(slots[i..][0..c.len], inside);
                i += c.len;
                continue;
            },
            .left_to_right_embedding, .right_to_left_embedding, .left_to_right_override, .right_to_left_override, .pop_directional_format, .left_to_right_isolate, .right_to_left_isolate, .first_strong_isolate, .pop_directional_isolate, .european_separator, .common_separator, .paragraph_separator, .segment_separator => true,
            .other_neutral => source.bracket(i, c.code_point) != null,
            else => false,
        };
        if (!alone and joining == c.class) {
            fill(slots[i..][0..c.len], inside);
        } else {
            const removed = switch (c.class) {
                .left_to_right_embedding, .right_to_left_embedding, .left_to_right_override, .right_to_left_override, .pop_directional_format => true,
                else => false,
            };
            const kind: Scratch.Kind = if (isIsolateInitiator(c.class)) .initiator else if (c.class == .pop_directional_isolate) .pdi else .other;
            slots[i] = .{ .class = c.class, .removed = removed, .kind = kind, .link = Scratch.none };
            if (unit) |u| if (slots[u].kind == .other) {
                slots[u].link = @intCast(i - u);
            };
            unit = i;
            joining = if (alone) null else c.class;
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
                .other, .paired => {},
            }
            fill(slots[i + 1 ..][0 .. c.len - 1], inside);
        }
        i += c.len;
        if (extent == .paragraph and c.class == .paragraph_separator) {
            // A CR LF pair is one separator.
            if (source.byte(i - 1) == '\r' and i < source.len() and source.byte(i) == '\n') {
                aegis.assert.pre(i < limit, "the buffers hold a level and a slot for each byte of the paragraph");
                slots[i] = inside;
                i += 1;
            }
            break;
        }
    }
    // Initiators left open have no matching PDI.
    while (open != Scratch.none) {
        const m = open;
        open = slots[m].link;
        slots[m].link = Scratch.none;
    }
    return .{ .len = i, .seen = seen };
}

/// Sets a code point's slots, at most four: stores, not a call to memset.
inline fn fill(slots: []Scratch, value: Scratch) void {
    switch (slots.len) {
        0 => {},
        1 => slots[0] = value,
        2 => slots[0..2].* = @splat(value),
        3 => slots[0..3].* = @splat(value),
        else => slots[0..4].* = @splat(value),
    }
}

/// The unit after the one at `p`, kept or removed, or null.
inline fn nextUnit(slots: []const Scratch, p: usize) ?usize {
    const s = slots[p];
    if (s.kind == .other) return if (s.link == Scratch.none) null else p + s.link;
    // An isolate control or a paired bracket links elsewhere: look.
    var q = p + 1;
    while (q < slots.len) : (q += 1) {
        const t = slots[q];
        if (!(t.removed and t.class == .boundary_neutral)) return q;
    }
    return null;
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
    // Every unit; the controls X9 removes still act here.
    var at: ?usize = for (slots, 0..) |s, k| {
        if (!(s.removed and s.class == .boundary_neutral)) break k;
    } else null;
    while (at) |i| : (at = nextUnit(slots, i)) {
        const s = &slots[i];
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
            var q = nextUnit(c.slots, p);
            while (q) |u| {
                if (!c.slots[u].removed) return u;
                q = nextUnit(c.slots, u);
            }
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

        /// Every isolating run sequence, each resolved by rules W1 to N2: one
        /// starts at each level run's first position, unless that is a
        /// matched PDI, which continues its initiator's.
        fn sequences(c: *Self) void {
            var p: ?usize = c.firstKept();
            var earlier: ?Level = null;
            while (p) |at| : (p = c.after(at)) {
                const level = c.levels[at];
                const starts = earlier == null or earlier.? != level;
                earlier = level;
                if (!starts) continue;
                const s = c.slots[at];
                if (s.kind == .pdi and s.link != Scratch.none) continue;
                c.sequence(at);
            }
        }

        fn firstKept(c: *const Self) ?usize {
            for (c.slots, 0..) |s, i| if (!s.removed) return i;
            return null;
        }

        fn sequence(c: *Self, start: usize) void {
            const level = c.levels[start];
            const before_level = if (c.before(start)) |q| c.levels[q] else c.para;
            const sos: BidiClass = if (@max(level, before_level) & 1 == 1) .right_to_left else .left_to_right;
            const e: BidiClass = if (level & 1 == 1) .right_to_left else .left_to_right;
            c.weak(start, sos);
            c.brackets(start, sos, e);
            c.neutrals(start, sos, level, e);
        }

        /// The end-of-sequence type, from the sequence's last position.
        fn eos(c: *const Self, last: usize, level: Level) BidiClass {
            const after_level = if (c.slots[last].kind == .initiator) c.para else if (c.after(last)) |q| c.levels[q] else c.para;
            return if (@max(level, after_level) & 1 == 1) .right_to_left else .left_to_right;
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
                const b = c.source.bracket(at, c.source.at(at).code_point) orelse continue;
                if (b.opening) {
                    if (depth == stack.len) break :find;
                    stack[depth] = .{ .id = b.id, .at = at };
                    depth += 1;
                } else {
                    var k = depth;
                    while (k > 0) {
                        k -= 1;
                        if (stack[k].id == b.id) {
                            c.slots[stack[k].at].kind = .paired;
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
                if (s.kind == .paired) {
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
        fn neutrals(c: *Self, start: usize, sos: BidiClass, level: Level, e: BidiClass) void {
            var earlier = sos;
            var run: ?usize = null;
            var last = start;
            var p: ?usize = start;
            while (p) |at| : (p = c.next(at)) {
                last = at;
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
            if (run) |from| {
                const end = c.eos(last, level);
                c.setRun(from, null, if (earlier == end) end else e);
            }
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
    // the paragraph level. Text finds its separators by their bytes and reads
    // back from each over the whitespace before it, so a line is not decoded.
    var plain = start;
    if (@TypeOf(source) == Text) {
        var i = start;
        while (separatorIn(source.bytes, i, end)) |sep| {
            const reset = whitespaceBefore(source, plain, sep.at);
            out.plain(plain, reset);
            out.at(reset, sep.at + sep.len, para);
            plain = sep.at + sep.len;
            i = plain;
        }
        const reset = whitespaceBefore(source, plain, end);
        out.plain(plain, reset);
        out.at(reset, end, para);
    } else {
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
    }
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

/// The first segment or paragraph separator from `from` to `to`, found by
/// its bytes: every one is below U+0020 but U+0085 (C2 85) and U+2029 (E2 80
/// A9), whose bytes start no other code point there.
fn separatorIn(bytes: []const u8, from: usize, to: usize) ?struct { at: usize, len: usize } {
    var i = from;
    while (i < to) : (i += 1) {
        const b = bytes[i];
        if (b < 0x20) {
            const c = ascii_classes[b];
            if (c == .segment_separator or c == .paragraph_separator) return .{ .at = i, .len = 1 };
        } else if (b == 0xc2 and i + 1 < to and bytes[i + 1] == 0x85) {
            return .{ .at = i, .len = 2 };
        } else if (b == 0xe2 and i + 2 < to and bytes[i + 1] == 0x80 and bytes[i + 2] == 0xa9) {
            return .{ .at = i, .len = 3 };
        }
    }
    return null;
}

/// Where the whitespace (as L1 reads it) ending at `to` starts, at `floor`
/// at the earliest.
fn whitespaceBefore(source: Text, floor: usize, to: usize) usize {
    var at = to;
    while (at > floor) {
        const start = records.codePointStart(source.bytes[0..at], at);
        if (!trailing(source.at(start).class)) break;
        at = start;
    }
    return at;
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
