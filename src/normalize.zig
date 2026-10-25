//! Normalization (UAX #15): NFD, NFC, NFKD and NFKC of Unicode 18.0.0, and
//! NFKC_Casefold (the Unicode Standard, chapter 3.13).
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
const canonical = @import("canonical.zig");

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
    /// toNFKC_Casefold: each code point mapped by NFKC_Casefold
    /// (DerivedNormalizationProps.txt: NFKC, full case folding and the
    /// removal of Default_Ignorable_Code_Point, repeated until stable), then
    /// NFC. For identifiers and loose matching.
    nfkc_casefold,
    /// toNFKC_Simple_Casefold: as `nfkc_casefold`, with simple case folding
    /// in place of full (NFKC_Simple_Casefold, Unicode 15.1): no mapping
    /// changes a string's length by folding, so `ß` stays and `ẞ` becomes it.
    nfkc_simple_casefold,

    fn decomposition(f: Form) Decomposition {
        return switch (f) {
            .nfd, .nfc => .canonical,
            .nfkd, .nfkc => .compatibility,
            .nfkc_casefold => .casefold,
            .nfkc_simple_casefold => .simple_casefold,
        };
    }

    fn composes(f: Form) bool {
        return switch (f) {
            .nfd, .nfkd => false,
            .nfc, .nfkc, .nfkc_casefold, .nfkc_simple_casefold => true,
        };
    }

    /// Whether the form folds case: ASCII goes to lowercase.
    fn folds(f: Form) bool {
        return f == .nfkc_casefold or f == .nfkc_simple_casefold;
    }
};

/// Which full decomposition a form starts from.
const Decomposition = enum {
    canonical,
    compatibility,
    /// NFKC_Casefold's mapping, fully decomposed canonically.
    casefold,
    /// NFKC_Simple_Casefold's mapping, fully decomposed canonically.
    simple_casefold,
};

/// Canonical_Combining_Class.
pub const combiningClass = canonical.combiningClass;

/// The primary composite of `first` and `second`, if there is one: the
/// composition canonical composition makes when nothing blocks it.
pub const compose = canonical.compose;

const hangul = canonical.hangul;

/// A code point's full decomposition by `form` (compatibility for NFKD
/// and NFKC, NFKC_Casefold's mapping decomposed canonically for
/// `.nfkc_casefold`, which may be empty, canonical otherwise) into
/// `buffer`; the code point itself where it has none. At most 18 code
/// points.
pub fn decompose(cp: u21, form: Form, buffer: *[18]u21) []const u21 {
    var e: Expansion = .of(cp, form.decomposition());
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

    fn of(cp: u21, decomposition: Decomposition) Expansion {
        if (hangul.syllable(cp)) {
            const s = cp - hangul.s_base;
            var e: Expansion = .{ .len = if (s % hangul.t_count == 0) 2 else 3 };
            e.local[0] = hangul.l_base + s / hangul.n_count;
            e.local[1] = hangul.v_base + (s % hangul.n_count) / hangul.t_count;
            e.local[2] = hangul.t_base + s % hangul.t_count;
            return e;
        }
        if (cp <= 0x10ffff) {
            if (decomposition == .casefold or decomposition == .simple_casefold) {
                const folded = if (decomposition == .casefold) tables.casefold.get(cp) else tables.simple_casefold.get(cp);
                if (folded != 0) {
                    const m: classes.Mapping = @bitCast(tables.casefolds[folded]);
                    return .{ .start = m.start, .len = m.len, .in_pool = true };
                }
            }
            const index = tables.decomposition.get(cp);
            if (index != 0) {
                const record: classes.Decomposition = @bitCast(tables.decompositions[index]);
                const m = if (decomposition == .canonical) record.canonical else record.compatibility;
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

/// The full decomposition of a text, one code point at a time.
fn Decomposer(comptime decomposition: Decomposition) type {
    return struct {
        const Self = @This();

        /// Where the decomposed stream stands: an input code point and a
        /// place in its decomposition.
        pub const Position = struct {
            byte: usize,
            index: u8,

            pub fn eql(a: Position, b: Position) bool {
                return a.byte == b.byte and a.index == b.index;
            }
        };

        bytes: []const u8,
        /// Where the input code point after the current one starts.
        next_byte: usize = 0,
        /// Where the current input code point starts.
        byte: usize = 0,
        expansion: Expansion = .{},
        index: u8 = 0,

        pub fn position(d: *const Self) Position {
            if (d.index < d.expansion.len) return .{ .byte = d.byte, .index = d.index };
            return .{ .byte = d.next_byte, .index = 0 };
        }

        pub fn next(d: *Self) ?u21 {
            // An NFKC_Casefold mapping may be empty.
            while (d.index == d.expansion.len) {
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
                d.expansion.local[0] = if (decomposition == .casefold or decomposition == .simple_casefold) std.ascii.toLower(lead) else lead;
                d.byte = at;
                d.next_byte = at + 1;
            } else {
                const dec = utf8.decode(d.bytes[at..]);
                d.expansion = .of(dec.code_point, decomposition);
                d.byte = at;
                d.next_byte = at + dec.len;
            }
            d.index = 0;
        }

        pub fn seek(d: *Self, p: Position) void {
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
    return canonical.Canonical(Decomposer(form.decomposition()), form.composes());
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
        if (end == text.len) return writeAscii(form, text[at..], w);
        if (end > at + 1) {
            try writeAscii(form, text[at .. end - 1], w);
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

/// ASCII text in `form`: itself, or lowercase for NFKC_Casefold, which
/// changes no other ASCII character.
fn writeAscii(comptime form: Form, ascii: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (!form.folds()) return w.writeAll(ascii);
    var buffer: [256]u8 = undefined;
    var rest = ascii;
    while (rest.len > 0) {
        const n = @min(rest.len, buffer.len);
        try w.writeAll(std.ascii.lowerString(&buffer, rest[0..n]));
        rest = rest[n..];
    }
}

pub const QuickCheck = enum { yes, no, maybe };

/// UAX #15's quick check: `yes` when `text` is certainly in `form`, `no`
/// when it certainly is not, `maybe` when only normalizing tells. Ill-formed
/// UTF-8 is `no`: normalizing writes U+FFFD in its place. For
/// `.nfkc_casefold`, a code point that NFKC_Casefold changes
/// (Changes_When_NFKC_Casefolded) is `no`, since toNFKC_Casefold never
/// writes one, and the rest is NFC's quick check; likewise for
/// `.nfkc_simple_casefold` with NFKC_Simple_Casefold, but for U+0345, which
/// it changes and also writes (inside the small Greek letters with
/// ypogegrammeni), so that only normalizing tells.
pub fn quickCheck(comptime form: Form, text: []const u8) QuickCheck {
    var result: QuickCheck = .yes;
    var last: u8 = 0;
    var at: usize = 0;
    while (at < text.len) {
        if (text[at] < 0x80) {
            if (form.folds() and std.ascii.isUpper(text[at])) return .no;
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
            .nfkc_casefold => if (q.nfkc_casefold_changes) return .no else if (q.nfc_maybe) {
                result = .maybe;
            },
            .nfkc_simple_casefold => if (q.nfkc_simple_casefold_changes) return .no else if (q.nfc_maybe) {
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
/// for `.nfd` and `.nfc`, compatibility equivalent for `.nfkd` and `.nfkc`,
/// and for `.nfkc_casefold` and `.nfkc_simple_casefold` equal under
/// toNFKC_Casefold or toNFKC_Simple_Casefold (which, unlike
/// `case.equal(.identifier, ...)`, do not decompose first).
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

test "the forms" {
    try expectForm(.nfd, "\u{e9}", &.{ 'e', 0x301 });
    try expectForm(.nfc, "e\u{301}", &.{0xe9});
    try expectForm(.nfc, "\u{1100}\u{1161}\u{11a8}", &.{0xac01});
    try expectForm(.nfkd, "\u{fb01}", &.{ 'f', 'i' });
    try expectForm(.nfkc, "\u{2460}", &.{'1'});
    // NFKC_Casefold: compatibility, case and default ignorables, then NFC.
    try expectForm(.nfkc_casefold, "\u{2160}\u{200b}A\u{30a}\u{1e9e}", &.{ 'i', 0xe5, 's', 's' });
    try expectForm(.nfkc_casefold, "\u{ad}", &.{});
    try expectForm(.nfkc_simple_casefold, "\u{2160}\u{200b}A\u{30a}\u{1e9e}\u{df}", &.{ 'i', 0xe5, 0xdf, 0xdf });
    // NFC after the mapping, also where a mark follows a character that maps
    // to itself but holds one that changes (ICU 78's nfkc_scf leaves these
    // as they are, not in NFC).
    try expectForm(.nfkc_simple_casefold, "\u{1f88}\u{300}", &.{0x1f82});
    try expectForm(.nfkc_simple_casefold, "\u{130}\u{323}", &.{ 0x1eca, 0x307 });
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
