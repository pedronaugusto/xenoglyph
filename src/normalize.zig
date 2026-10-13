//! Normalization (UAX #15): NFD, NFC, NFKD and NFKC of Unicode 18.0.0.
//!
//! Nothing here allocates. `Iterator` yields the code points of a text's
//! normal form; `write` writes it as UTF-8 to any writer; `isNormalized`
//! and `quickCheck` answer without writing. A run of a starter and the
//! non-starters after it is put in canonical order in a buffer of 32 code
//! points; a longer run, which only text that is not stream-safe has, is
//! put in order by reading it again once for each combining class in it,
//! so every input, however long its runs, normalizes exactly. Ill-formed
//! UTF-8 reads as U+FFFD, as everywhere in xenoglyph.
const std = @import("std");
const aegis = @import("aegis");
const classes = @import("classes.zig");
const data = @import("data.zig");
const utf8 = @import("utf8.zig");

const tables = data.normalization;

pub const Form = enum {
    /// Canonical decomposition.
    nfd,
    /// Canonical decomposition, then canonical composition.
    nfc,
    /// Compatibility decomposition.
    nfkd,
    /// Compatibility decomposition, then canonical composition.
    nfkc,

    fn compatibility(f: Form) bool {
        return f == .nfkd or f == .nfkc;
    }

    fn composes(f: Form) bool {
        return f == .nfc or f == .nfkc;
    }
};

/// Canonical_Combining_Class.
pub fn combiningClass(cp: u21) u8 {
    if (cp > 0x10ffff) return 0;
    return tables.ccc.get(cp);
}

const hangul = struct {
    const s_base = 0xac00;
    const l_base = 0x1100;
    const v_base = 0x1161;
    const t_base = 0x11a7;
    const l_count = 19;
    const v_count = 21;
    const t_count = 28;
    const n_count = v_count * t_count;
    const s_count = l_count * n_count;

    fn syllable(cp: u21) bool {
        return cp >= s_base and cp < s_base + s_count;
    }
};

/// The primary composite of `first` and `second`, if there is one: the
/// composition canonical composition makes when nothing blocks it.
pub fn compose(first: u21, second: u21) ?u21 {
    // Hangul: L V to LV, LV T to LVT.
    if (first >= hangul.l_base and first < hangul.l_base + hangul.l_count and second >= hangul.v_base and second < hangul.v_base + hangul.v_count)
        return hangul.s_base + ((first - hangul.l_base) * hangul.v_count + second - hangul.v_base) * hangul.t_count;
    if (hangul.syllable(first) and (first - hangul.s_base) % hangul.t_count == 0 and second > hangul.t_base and second < hangul.t_base + hangul.t_count)
        return first + (second - hangul.t_base);
    const key = (@as(u64, first) << 21) | second;
    const keys = &tables.pair_keys;
    var low: usize = 0;
    var high: usize = keys.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (keys[mid] < key) low = mid + 1 else high = mid;
    }
    if (low < keys.len and keys[low] == key) return tables.pair_composites[low];
    return null;
}

/// A code point's full decomposition by `form` (compatibility for NFKD
/// and NFKC, canonical otherwise) into `buffer`; the code point itself
/// where it has none. At most 18 code points.
pub fn decompose(cp: u21, form: Form, buffer: *[18]u21) []const u21 {
    var e: Expansion = .of(cp, form.compatibility());
    for (buffer[0..e.len], 0..) |*out, i| out.* = e.at(aegis.int.narrow(u8, i) orelse aegis.assert.never("a decomposition is at most 18 code points"));
    return buffer[0..e.len];
}

/// One code point's decomposition, read from the pool or made by the
/// Hangul algorithm. Holds no pointer, so it may be copied.
const Expansion = struct {
    local: [3]u21 = undefined,
    start: u16 = 0,
    len: u8 = 0,
    in_pool: bool = false,

    fn of(cp: u21, compatibility: bool) Expansion {
        if (hangul.syllable(cp)) {
            const s = cp - hangul.s_base;
            var e: Expansion = .{ .len = if (s % hangul.t_count == 0) 2 else 3 };
            e.local[0] = hangul.l_base + s / hangul.n_count;
            e.local[1] = hangul.v_base + (s % hangul.n_count) / hangul.t_count;
            e.local[2] = hangul.t_base + s % hangul.t_count;
            return e;
        }
        if (cp <= 0x10ffff) {
            const index = tables.decomposition.get(cp);
            if (index != 0) {
                const record: classes.Decomposition = @bitCast(tables.decompositions[index]);
                const m = if (compatibility) record.compatibility else record.canonical;
                if (m.len != 0) return .{ .start = m.start, .len = m.len, .in_pool = true };
            }
        }
        var e: Expansion = .{ .len = 1 };
        e.local[0] = cp;
        return e;
    }

    fn at(e: *const Expansion, i: u8) u21 {
        return if (e.in_pool) tables.pool[e.start + i] else e.local[i];
    }
};

/// Where the decomposed stream stands: an input code point and a place in
/// its decomposition.
const Position = struct {
    byte: usize,
    index: u8,

    fn eql(a: Position, b: Position) bool {
        return a.byte == b.byte and a.index == b.index;
    }
};

/// The full decomposition of a text, one code point at a time.
fn Decomposer(comptime compatibility: bool) type {
    return struct {
        const Self = @This();

        bytes: []const u8,
        /// Where the input code point after the current one starts.
        next_byte: usize = 0,
        /// Where the current input code point starts.
        byte: usize = 0,
        expansion: Expansion = .{},
        index: u8 = 0,

        fn position(d: *const Self) Position {
            if (d.index < d.expansion.len) return .{ .byte = d.byte, .index = d.index };
            return .{ .byte = d.next_byte, .index = 0 };
        }

        fn next(d: *Self) ?u21 {
            if (d.index == d.expansion.len) {
                if (d.next_byte >= d.bytes.len) return null;
                d.load(d.next_byte);
            }
            const cp = d.expansion.at(d.index);
            d.index += 1;
            return cp;
        }

        fn load(d: *Self, at: usize) void {
            const lead = d.bytes[at];
            if (lead < 0x80) {
                d.expansion = .{ .len = 1 };
                d.expansion.local[0] = lead;
                d.byte = at;
                d.next_byte = at + 1;
            } else {
                const dec = utf8.decode(d.bytes[at..]);
                d.expansion = .of(dec.code_point, compatibility);
                d.byte = at;
                d.next_byte = at + dec.len;
            }
            d.index = 0;
        }

        fn seek(d: *Self, p: Position) void {
            if (p.byte >= d.bytes.len) {
                d.byte = p.byte;
                d.next_byte = p.byte;
                d.expansion = .{};
                d.index = 0;
                return;
            }
            d.load(p.byte);
            d.index = p.index;
        }
    };
}

/// The code points of a text's normal form, in order.
pub fn Iterator(comptime form: Form) type {
    return struct {
        const Self = @This();
        const capacity = 32;

        /// Private: the decomposed input.
        source: Decomposer(form.compatibility()),
        /// Private: the run being given out, in canonical order and, for
        /// the composed forms, composed.
        buffer: [capacity]u21 = undefined,
        len: u8 = 0,
        out: u8 = 0,
        /// Private: a starter read past the end of the run, and where the
        /// code point after it starts.
        pending: ?u21 = null,
        after_pending: Position = .{ .byte = 0, .index = 0 },
        /// Private: the non-starters of a run too long for the buffer,
        /// given out a combining class at a time.
        long: ?Long = null,

        const Long = struct {
            /// Where the run's non-starters start and where they end.
            marks: Position,
            end: Position,
            /// The combining class being given out, and where its reading
            /// stands.
            class: u8 = 0,
            cursor: Position,
            /// For the composed forms: the run's starter as the compositions
            /// so far make it, and whether a non-starter of `class` was kept.
            starter: ?u21,
            kept: bool = false,
        };

        pub fn init(bytes: []const u8) Self {
            return .{ .source = .{ .bytes = bytes } };
        }

        /// The next code point of the normal form, or null at the end.
        pub fn next(it: *Self) ?u21 {
            while (true) {
                if (it.out < it.len) {
                    defer it.out += 1;
                    return it.buffer[it.out];
                }
                if (it.long != null) {
                    if (it.nextLong()) |cp| return cp;
                    continue;
                }
                if (!it.fill()) return null;
            }
        }

        /// Gathers the next run into the buffer: a starter (or, at the
        /// start of the text, none) and the non-starters after it.
        fn fill(it: *Self) bool {
            it.len = 0;
            it.out = 0;
            const first = it.pending orelse it.source.next() orelse return false;
            const after_first = if (it.pending != null) it.after_pending else it.source.position();
            it.pending = null;
            if (combiningClass(first) != 0) {
                // Only at the start of the text: the run has no starter.
                it.buffer[0] = first;
                it.len = 1;
                it.gather(null, .{ .byte = 0, .index = 0 });
                return true;
            }
            it.buffer[0] = first;
            it.len = 1;
            it.gather(first, after_first);
            return true;
        }

        /// Reads non-starters onto the buffer until a starter, which it
        /// keeps pending or, composed with a lone starter, absorbs. `starter`
        /// is the run's starter and `marks` where its non-starters begin.
        fn gather(it: *Self, starter: ?u21, marks: Position) void {
            var s = starter;
            var from = marks;
            while (true) {
                const cp = it.source.next() orelse break;
                if (combiningClass(cp) == 0) {
                    it.finish();
                    if (form.composes() and it.len == 1 and s != null) {
                        if (compose(it.buffer[0], cp)) |composite| {
                            it.buffer[0] = composite;
                            s = composite;
                            from = it.source.position();
                            continue;
                        }
                    }
                    it.pending = cp;
                    it.after_pending = it.source.position();
                    return;
                }
                if (it.len == capacity) return it.startLong(s, from);
                it.buffer[it.len] = cp;
                it.len += 1;
            }
            it.finish();
        }

        /// Puts the buffered run in canonical order and composes it.
        fn finish(it: *Self) void {
            const run = it.buffer[0..it.len];
            const marks_from: usize = if (combiningClass(run[0]) == 0) 1 else 0;
            // A stable insertion sort by combining class.
            var i: usize = marks_from + 1;
            while (i < run.len) : (i += 1) {
                const cp = run[i];
                const class = combiningClass(cp);
                var j: usize = i;
                while (j > marks_from and combiningClass(run[j - 1]) > class) : (j -= 1) run[j] = run[j - 1];
                run[j] = cp;
            }
            if (!form.composes() or marks_from == 0) return;
            // Canonical composition: a non-starter composes with the starter
            // unless a kept non-starter of its class stands between.
            var kept: u8 = 1;
            var last: u8 = 0;
            for (run[1..]) |cp| {
                const class = combiningClass(cp);
                if (last != class) if (compose(run[0], cp)) |composite| {
                    run[0] = composite;
                    continue;
                };
                run[kept] = cp;
                kept += 1;
                last = class;
            }
            it.len = kept;
        }

        /// A run longer than the buffer: finds where its non-starters end,
        /// then gives out its starter and the non-starters a class at a time.
        fn startLong(it: *Self, starter: ?u21, marks: Position) void {
            var scan = it.source;
            scan.seek(marks);
            var end = marks;
            while (scan.next()) |cp| {
                if (combiningClass(cp) == 0) break;
                end = scan.position();
            }
            const long: Long = .{ .marks = marks, .end = end, .cursor = end, .starter = starter };
            it.source.seek(end);
            it.out = 0;
            it.len = 0;
            if (starter) |s| {
                it.buffer[0] = s;
                it.len = 1;
                if (form.composes()) {
                    const result = it.composeLong(long);
                    it.buffer[0] = result.starter;
                    // Every non-starter composed: the starter stays open to
                    // the starter after the run, as in a short run.
                    if (!result.kept) return it.gather(result.starter, end);
                }
            }
            it.long = long;
        }

        /// Every composition of a long run, in canonical order: the final
        /// starter, and whether any non-starter is kept.
        fn composeLong(it: *const Self, long: Long) struct { starter: u21, kept: bool } {
            var starter = long.starter.?;
            var any_kept = false;
            var class: u8 = 0;
            while (it.classAbove(long, class)) |c| : (class = c) {
                var scan = it.source;
                scan.seek(long.marks);
                var kept = false;
                while (!scan.position().eql(long.end)) {
                    const cp = scan.next().?;
                    if (combiningClass(cp) != c) continue;
                    if (!kept) if (compose(starter, cp)) |composite| {
                        starter = composite;
                        continue;
                    };
                    kept = true;
                    any_kept = true;
                }
            }
            return .{ .starter = starter, .kept = any_kept };
        }

        /// The smallest combining class above `class` among a long run's
        /// non-starters.
        fn classAbove(it: *const Self, long: Long, class: u8) ?u8 {
            var scan = it.source;
            scan.seek(long.marks);
            var best: ?u8 = null;
            while (!scan.position().eql(long.end)) {
                const c = combiningClass(scan.next().?);
                if (c > class and (best == null or c < best.?)) best = c;
            }
            return best;
        }

        /// The next non-starter of a long run, or null when it is done.
        fn nextLong(it: *Self) ?u21 {
            const long = &it.long.?;
            while (true) {
                if (long.cursor.eql(long.end)) {
                    long.class = it.classAbove(long.*, long.class) orelse {
                        it.long = null;
                        return null;
                    };
                    long.cursor = long.marks;
                    long.kept = false;
                }
                var scan = it.source;
                scan.seek(long.cursor);
                const cp = scan.next().?;
                long.cursor = scan.position();
                if (combiningClass(cp) != long.class) continue;
                if (form.composes()) if (long.starter) |s| if (!long.kept) if (compose(s, cp)) |composite| {
                    long.starter = composite;
                    continue;
                };
                long.kept = true;
                return cp;
            }
        }
    };
}

/// The normal form of `text`, written as UTF-8.
///
/// A position before an ASCII byte is a boundary normalization never
/// crosses: an ASCII character is a starter that composes with nothing
/// before it. So the text is taken a region at a time, from one such
/// boundary to the next, and a region the quick check passes is copied.
pub fn write(comptime form: Form, text: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var at: usize = 0;
    while (at < text.len) {
        // ASCII followed by ASCII is final: copy the run but its last byte,
        // which a mark after it may compose with.
        var end = at;
        while (end < text.len and text[end] < 0x80) end += 1;
        if (end == text.len) return w.writeAll(text[at..]);
        if (end > at + 1) {
            try w.writeAll(text[at .. end - 1]);
            at = end - 1;
        }
        // The region up to the next ASCII byte.
        end = at + 1;
        while (end < text.len and text[end] >= 0x80) end += 1;
        const region = text[at..end];
        if (quickCheck(form, region) == .yes) {
            try w.writeAll(region);
        } else {
            var it: Iterator(form) = .init(region);
            try utf8.encode(&it, w);
        }
        at = end;
    }
}

pub const QuickCheck = enum { yes, no, maybe };

/// UAX #15's quick check: `yes` when `text` is certainly in `form`, `no`
/// when it certainly is not, `maybe` when only normalizing tells. Ill-formed
/// UTF-8 is `no`: normalizing writes U+FFFD in its place.
pub fn quickCheck(comptime form: Form, text: []const u8) QuickCheck {
    var result: QuickCheck = .yes;
    var last: u8 = 0;
    var at: usize = 0;
    while (at < text.len) {
        if (text[at] < 0x80) {
            last = 0;
            at += 1;
            continue;
        }
        const d = utf8.decode(text[at..]);
        if (d.code_point == utf8.replacement and !std.mem.eql(u8, text[at..][0..d.len], "\u{fffd}")) return .no;
        at += d.len;
        const class = combiningClass(d.code_point);
        if (last > class and class != 0) return .no;
        const q: classes.QuickCheck = @bitCast(tables.quick_check.get(d.code_point));
        switch (form) {
            .nfd => if (q.nfd_no) return .no,
            .nfkd => if (q.nfkd_no) return .no,
            .nfc => if (q.nfc_no) return .no else if (q.nfc_maybe) {
                result = .maybe;
            },
            .nfkc => if (q.nfkc_no) return .no else if (q.nfkc_maybe) {
                result = .maybe;
            },
        }
        last = class;
    }
    return result;
}

/// Whether `text` is in `form`: normalizing it would give the same bytes.
pub fn isNormalized(comptime form: Form, text: []const u8) bool {
    switch (quickCheck(form, text)) {
        .yes => return true,
        .no => return false,
        .maybe => {},
    }
    var it: Iterator(form) = .init(text);
    var original: utf8.Iterator = .init(text);
    while (it.next()) |cp| if (original.next() != cp) return false;
    return original.next() == null;
}

/// Whether `a` and `b` have the same normal form: canonically equivalent
/// for `.nfd` and `.nfc`, compatibility equivalent for `.nfkd` and `.nfkc`.
pub fn equal(comptime form: Form, a: []const u8, b: []const u8) bool {
    var x: Iterator(form) = .init(a);
    var y: Iterator(form) = .init(b);
    while (true) {
        const p = x.next();
        if (p != y.next()) return false;
        if (p == null) return true;
    }
}

fn expectForm(comptime form: Form, input: []const u8, want: []const u21) !void {
    var it: Iterator(form) = .init(input);
    for (want) |w| try std.testing.expectEqual(w, it.next().?);
    try std.testing.expectEqual(null, it.next());
}

test "the four forms" {
    try expectForm(.nfd, "\u{e9}", &.{ 'e', 0x301 });
    try expectForm(.nfc, "e\u{301}", &.{0xe9});
    try expectForm(.nfc, "\u{1100}\u{1161}\u{11a8}", &.{0xac01});
    try expectForm(.nfkd, "\u{fb01}", &.{ 'f', 'i' });
    try expectForm(.nfkc, "\u{2460}", &.{'1'});
    // Canonical order: dot below (220) before dot above (230).
    try expectForm(.nfd, "q\u{307}\u{323}", &.{ 'q', 0x323, 0x307 });
    try expectForm(.nfc, "\u{1e0b}\u{323}", &.{ 0x1e0d, 0x307 });
    try std.testing.expect(equal(.nfc, "\u{212b}", "A\u{30a}"));
    try std.testing.expect(isNormalized(.nfc, "caf\u{e9}"));
    try std.testing.expect(!isNormalized(.nfc, "cafe\u{301}"));
}

test "a run longer than the buffer is ordered and composed exactly" {
    // 'a', then fifty pairs of acute (230) and dot below (220).
    var text: [1 + 50 * 4]u8 = undefined;
    text[0] = 'a';
    for (0..50) |i| @memcpy(text[1 + i * 4 ..][0..4], "\u{301}\u{323}");
    // NFD: the dots below first, then the acutes, each in order.
    var d: Iterator(.nfd) = .init(&text);
    try std.testing.expectEqual('a', d.next().?);
    for (0..50) |_| try std.testing.expectEqual(0x323, d.next().?);
    for (0..50) |_| try std.testing.expectEqual(0x301, d.next().?);
    try std.testing.expectEqual(null, d.next());
    // NFC: the first dot below composes (U+1EA1); nothing composes with
    // U+1EA1 and an acute, and every other dot below is blocked by the one
    // kept before it.
    var c: Iterator(.nfc) = .init(&text);
    try std.testing.expectEqual(0x1ea1, c.next().?);
    for (0..49) |_| try std.testing.expectEqual(0x323, c.next().?);
    for (0..50) |_| try std.testing.expectEqual(0x301, c.next().?);
    try std.testing.expectEqual(null, c.next());
}
