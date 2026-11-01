//! Collation: the Unicode Collation Algorithm (UTS #10) with CLDR's root
//! collation (CLDR 49, UCA 18.0.0), the order a language with no tailoring
//! sorts in. `compare` orders two texts and `sortKey` writes bytes that
//! compare as their texts do; neither allocates. Input is any UTF-8, read in
//! NFD (UTS #10 step 1), ill-formed bytes as U+FFFD.
const std = @import("std");
const data = @import("data.zig");
const normalize = @import("normalize.zig");
const canonical = @import("canonical.zig");
const properties = @import("properties.zig");

const Writer = std.Io.Writer;
const tables = data.collation;

/// How many levels decide: two texts that differ only beyond `strength`
/// compare equal.
pub const Strength = enum {
    /// Base letters: "a" = "á" = "A".
    primary,
    /// Accents: "a" < "á", "a" = "A".
    secondary,
    /// Case and variants: "a" < "A".
    tertiary,
    /// With `.shifted`, the punctuation and spaces set aside: "ab" < "a-b".
    quaternary,
    /// Then the texts' code points in NFD: canonically equivalent texts
    /// alone compare equal.
    identical,
};

pub const Options = struct {
    strength: Strength = .tertiary,
    /// `.non_ignorable` (CLDR's default) weighs spaces and punctuation as
    /// any character; `.shifted` sets them aside to the quaternary level, so
    /// "di Silva" and "diSilva" sort together (UTS #10 §4). CLDR's variable
    /// top is the end of the punctuation.
    alternate: enum { non_ignorable, shifted } = .non_ignorable,
    /// At the tertiary level, uppercase before lowercase (`.upper`) or
    /// lowercase first (`.lower`); `.off` keeps the table's order, lowercase
    /// first for most characters.
    case_first: enum { off, upper, lower } = .off,
    /// A level of case alone between the secondary and the tertiary, so that
    /// case decides before the other tertiary differences, and at
    /// `.primary` or `.secondary` strength case still counts.
    case_level: bool = false,
    /// A run of decimal digits weighs as the number it writes ("2" < "10"),
    /// leading zeros aside (CLDR's `kn`).
    numeric: bool = false,
};

/// One collation element as the levels read it. A primary weight is the
/// table's 16 bits in the high half; the low half is nonzero only in the
/// elements of a number, under `numeric`.
const Element = struct {
    primary: u32,
    secondary: u16,
    tertiary: u8,
    variable: bool,

    fn unpack(e: u32) Element {
        return .{
            .primary = e & 0xffff0000,
            .secondary = @intCast((e >> 7) & 0x1ff),
            .tertiary = @intCast((e >> 2) & 0x1f),
            .variable = e & 1 != 0,
        };
    }
};

/// The base weights of implicit primaries (UTS #10 §10.1.3).
const han_core_base = 0xfb40;
const han_other_base = 0xfb80;
const unassigned_base = 0xfbc0;

/// The primary of the digit zero; every decimal digit's primary is zero's
/// plus its value.
const zero_primary = Element.unpack(tables.collation.get('0') & ~@as(u32, 2)).primary;

/// The high half of a number's primaries: the primary just below the digit
/// zero's, so a number sorts after every character below the digits and
/// before every one with a digit's primary that is no decimal digit (U+2070
/// SUPERSCRIPT ZERO, U+24EA CIRCLED DIGIT ZERO), as ICU's numeric
/// primaries do. No character has a low half, so a number's never meets
/// one's.
const number_primary = zero_primary - (1 << 16);

/// The non-starters after a contraction's starter that discontiguous
/// matching looks through, as many as normalization orders at once.
const window = 32;

/// The collation elements of a text, in order (UTS #10 steps 2 and 3).
const Elements = struct {
    source: normalize.Iterator(.nfd),
    numeric: bool,
    /// Code points read ahead of where the elements are, the next first.
    ahead: [window + 2]u21 = undefined,
    ahead_len: usize = 0,
    /// Elements made and not yet given, the next at `pending_at`.
    pending: [32]Element = undefined,
    pending_at: usize = 0,
    pending_len: usize = 0,
    /// Under `numeric`, the elements of a number still to give: how many
    /// digits, the first (read already), and whether its count is given.
    number_left: usize = 0,
    number_head: ?u8 = null,
    number_counted: bool = false,

    fn init(text: []const u8, options: Options) Elements {
        return .{ .source = .init(text), .numeric = options.numeric };
    }

    fn next(e: *Elements) ?Element {
        while (true) {
            if (e.pending_at < e.pending_len) {
                e.pending_at += 1;
                return e.pending[e.pending_at - 1];
            }
            if (e.number_left != 0) return e.nextDigits();
            const cp = e.read() orelse return null;
            e.pending_at = 0;
            e.pending_len = 0;
            if (e.numeric) if (digitValue(cp)) |value| {
                e.number(value);
                continue;
            };
            var value = tables.collation.get(cp);
            if (value & 2 == 0 and value & 1 != 0) value = e.contraction(cp, value);
            if (value == 0) {
                e.implicit(cp);
            } else e.put(value);
        }
    }

    /// The next code point of the text, from those read ahead first.
    fn read(e: *Elements) ?u21 {
        if (e.ahead_len == 0) return e.source.next();
        const cp = e.ahead[0];
        @memmove(e.ahead[0 .. e.ahead_len - 1], e.ahead[1..e.ahead_len]);
        e.ahead_len -= 1;
        return cp;
    }

    /// Reads ahead until `count` code points are there; false at the end.
    fn fill(e: *Elements, count: usize) bool {
        while (e.ahead_len < count) {
            e.ahead[e.ahead_len] = e.source.next() orelse return false;
            e.ahead_len += 1;
        }
        return true;
    }

    fn drop(e: *Elements, at: usize) void {
        @memmove(e.ahead[at .. e.ahead_len - 1], e.ahead[at + 1 .. e.ahead_len]);
        e.ahead_len -= 1;
    }

    /// The elements of the longest contraction `starter` begins, contiguous
    /// then extended by unblocked non-starters after it (UTS #10 S2.1), or
    /// `own`, the starter's alone.
    fn contraction(e: *Elements, starter: u21, own: u32) u32 {
        var matched: [3]u21 = .{ starter, 0, 0 };
        var len: usize = 1;
        var value = own & ~@as(u32, 1);
        // Contiguous: the longest of the next one or two code points.
        var take: usize = 2;
        while (take > 0) : (take -= 1) {
            if (!e.fill(take)) continue;
            if (suffix(starter, e.ahead[0..take])) |v| {
                value = v;
                @memcpy(matched[1 .. 1 + take], e.ahead[0..take]);
                len = 1 + take;
                for (0..take) |_| _ = e.read();
                break;
            }
        }
        // Discontiguous: each non-starter no code point between blocks.
        var at: usize = 0;
        var highest: u8 = 0;
        while (len < matched.len and at < window and e.fill(at + 1)) {
            const class = canonical.combiningClass(e.ahead[at]);
            if (class == 0) break;
            if (class > highest) {
                matched[len] = e.ahead[at];
                if (suffix(starter, matched[1 .. len + 1])) |v| {
                    value = v;
                    len += 1;
                    e.drop(at);
                    continue;
                }
                highest = class;
            }
            at += 1;
        }
        return value;
    }

    fn put(e: *Elements, value: u32) void {
        if (value & 2 != 0) {
            e.pending[0] = .unpack(value & ~@as(u32, 2));
            e.pending_len = 1;
            return;
        }
        const run = tables.elements[value >> 7 ..][0 .. (value >> 2) & 0x1f];
        for (run, 0..) |packed_element, k| e.pending[k] = .unpack(packed_element);
        e.pending_len = run.len;
    }

    /// A code point with no entry: two elements made from its value (UTS #10
    /// §10.1).
    fn implicit(e: *Elements, cp: u21) void {
        var high: u32 = undefined;
        var low: u32 = undefined;
        weighed: {
            for (tables.implicit_ranges) |r| if (cp >= r[0] and cp <= r[1]) {
                high = r[2];
                low = (cp - r[3]) | 0x8000;
                break :weighed;
            };
            const base: u32 = if (!unifiedIdeograph(cp))
                unassigned_base
            else if ((cp >= 0x4e00 and cp <= 0x9fff) or (cp >= 0xf900 and cp <= 0xfaff))
                // The CJK Unified Ideographs and CJK Compatibility Ideographs blocks.
                han_core_base
            else
                han_other_base;
            high = base + (cp >> 15);
            low = (cp & 0x7fff) | 0x8000;
        }
        e.pending[0] = .{ .primary = high << 16, .secondary = 0x20, .tertiary = 0x02, .variable = false };
        e.pending[1] = .{ .primary = low << 16, .secondary = 0, .tertiary = 0, .variable = false };
        e.pending_len = 2;
    }

    /// A run of decimal digits as one number: its first element says how
    /// many digits it has past its leading zeros, the rest give them two at
    /// a time.
    fn number(e: *Elements, first: u8) void {
        var value = first;
        // Leading zeros count for nothing, but a number of zeros is zero.
        while (value == 0) {
            if (!e.fill(1)) break;
            const after = digitValue(e.ahead[0]) orelse break;
            _ = e.read();
            value = after;
        }
        e.number_left = 1 + e.countDigits(max_digits - 1);
        e.number_head = value;
        e.number_counted = false;
    }

    /// How many digits follow, up to `limit`: those read ahead, then the
    /// rest counted on a copy of the source.
    fn countDigits(e: *Elements, limit: usize) usize {
        var count: usize = 0;
        for (e.ahead[0..e.ahead_len]) |cp| {
            if (count == limit or digitValue(cp) == null) return count;
            count += 1;
        }
        var copy = e.source;
        while (count < limit) : (count += 1) {
            const cp = copy.next() orelse break;
            if (digitValue(cp) == null) break;
        }
        return count;
    }

    fn nextDigits(e: *Elements) Element {
        var out: Element = .{ .primary = number_primary, .secondary = 0x20, .tertiary = 0x02, .variable = false };
        if (!e.number_counted) {
            e.number_counted = true;
            out.primary |= @intCast(e.number_left);
            return out;
        }
        const high = e.number_head orelse digitValue(e.read().?).?;
        e.number_head = null;
        e.number_left -= 1;
        var low: u8 = 0;
        if (e.number_left != 0) {
            low = digitValue(e.read().?).?;
            e.number_left -= 1;
        }
        out.primary |= 1 + @as(u32, high) * 10 + low;
        return out;
    }
};

/// The levels, in the order they decide.
const Level = enum { primary, secondary, case, tertiary, quaternary };

/// The tertiary weights of uppercase: capital, wide, compatibility, font
/// and circled capitals, and the normal (not small) kana (UTS #10 §7.3's
/// tertiary table).
fn upper(tertiary: u8) bool {
    return switch (tertiary) {
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0e, 0x11, 0x12, 0x1d => true,
        else => false,
    };
}

/// A text's weights at one level, the zero ones left out, with the
/// variable weighting applied (UTS #10 §4).
fn Weights(comptime level: Level) type {
    return struct {
        const Self = @This();

        elements: Elements,
        options: Options,
        /// Whether the last element with a primary was variable, so that
        /// the ignorables after it are ignored at every level.
        after_variable: bool = false,

        fn init(text: []const u8, options: Options) Self {
            return .{ .elements = .init(text, options), .options = options };
        }

        /// The next nonzero weight at the level, or null at the end.
        fn next(w: *Self) ?u32 {
            while (w.elements.next()) |e| {
                const weight = w.weigh(e);
                if (weight != 0) return weight;
            }
            return null;
        }

        fn weigh(w: *Self, e: Element) u32 {
            if (w.options.alternate == .shifted) {
                if (e.variable and e.primary != 0) {
                    w.after_variable = true;
                    return if (level == .quaternary) e.primary else 0;
                }
                if (e.primary == 0 and w.after_variable) return 0;
                if (e.primary != 0) w.after_variable = false;
            }
            return switch (level) {
                .primary => e.primary,
                .secondary => e.secondary,
                .case => if (e.primary == 0 or e.tertiary == 0)
                    0
                else if (upper(e.tertiary) == (w.options.case_first == .upper)) 1 else 2,
                .tertiary => if (e.tertiary == 0) 0 else switch (w.options.case_first) {
                    .off => e.tertiary,
                    .upper => (@as(u32, @intFromBool(!upper(e.tertiary))) << 5) | e.tertiary,
                    .lower => (@as(u32, @intFromBool(upper(e.tertiary))) << 5) | e.tertiary,
                },
                .quaternary => if (e.primary == 0 and e.secondary == 0 and e.tertiary == 0) 0 else 0xffff0000,
            };
        }
    };
}

/// The levels `options` compare at, in order; the identical level apart.
fn levels(options: Options) std.EnumSet(Level) {
    var set: std.EnumSet(Level) = .initOne(.primary);
    const strength = @backingInt(options.strength);
    if (strength >= @backingInt(Strength.secondary)) set.insert(.secondary);
    if (options.case_level) set.insert(.case);
    if (strength >= @backingInt(Strength.tertiary)) set.insert(.tertiary);
    if (strength >= @backingInt(Strength.quaternary) and options.alternate == .shifted) set.insert(.quaternary);
    return set;
}

/// How `a` sorts against `b`.
pub fn compare(a: []const u8, b: []const u8, options: Options) std.math.Order {
    const set = levels(options);
    inline for (comptime std.enums.values(Level)) |level| if (set.contains(level)) {
        const order = compareAt(level, a, b, options);
        if (order != .eq) return order;
    };
    if (options.strength != .identical) return .eq;
    var x: normalize.Iterator(.nfd) = .init(a);
    var y: normalize.Iterator(.nfd) = .init(b);
    while (true) {
        const p = x.next();
        const q = y.next();
        if (p == null or q == null) return std.math.order(@intFromBool(p != null), @intFromBool(q != null));
        if (p.? != q.?) return std.math.order(p.?, q.?);
    }
}

fn compareAt(comptime level: Level, a: []const u8, b: []const u8, options: Options) std.math.Order {
    var x: Weights(level) = .init(a, options);
    var y: Weights(level) = .init(b, options);
    while (true) {
        const p = x.next();
        const q = y.next();
        if (p == null or q == null) return std.math.order(@intFromBool(p != null), @intFromBool(q != null));
        if (p.? != q.?) return std.math.order(p.?, q.?);
    }
}

/// Writes the sort key of `text`: bytes that compare (as `std.mem.order`
/// does) as `compare` orders their texts under the same options. Each
/// level's weights in turn, a separator lower than any weight between
/// levels; the identical level is the text's NFD in UTF-8.
pub fn sortKey(text: []const u8, w: *Writer, options: Options) Writer.Error!void {
    const set = levels(options);
    // A level of 16-bit weights ends with two zero bytes, one of 8-bit
    // weights with one; the first has none before it.
    var separator: []const u8 = "";
    inline for (comptime std.enums.values(Level)) |level| if (set.contains(level)) {
        const wide = level == .primary or level == .secondary or level == .quaternary;
        try w.writeAll(separator);
        separator = if (wide) "\x00\x00" else "\x00";
        var weights: Weights(level) = .init(text, options);
        while (weights.next()) |weight| {
            if (!wide) {
                try w.writeByte(@intCast(weight));
            } else if (level == .secondary) {
                try w.writeInt(u16, @intCast(weight), .big);
            } else {
                // A primary in the low half too only within a number, whose
                // high half is `number_primary`'s: there both halves go.
                try w.writeInt(u16, @intCast(weight >> 16), .big);
                if (options.numeric and weight >> 16 == number_primary >> 16) try w.writeInt(u16, @truncate(weight), .big);
            }
        }
    };
    if (options.strength != .identical) return;
    try w.writeAll(separator);
    try normalize.write(.nfd, text, w);
}

/// The most digits one number holds; a longer run goes on as the next.
const max_digits = 0xfffe;

/// A decimal digit's value: a General_Category Nd code point whose one
/// element weighs as a digit does.
fn digitValue(cp: u21) ?u8 {
    if (properties.generalCategory(cp) != .decimal_number) return null;
    const value = tables.collation.get(cp);
    if (value & 2 == 0) return null;
    const primary = Element.unpack(value & ~@as(u32, 2)).primary;
    if (primary < zero_primary or primary > zero_primary + (9 << 16)) return null;
    return @intCast((primary - zero_primary) >> 16);
}

/// The value of the contraction `starter` and `rest` make, if there is one.
fn suffix(starter: u21, rest: []const u21) ?u32 {
    const starters = &tables.contraction_starters;
    var low: usize = 0;
    var high: usize = starters.len;
    while (low < high) {
        const mid = (low + high) / 2;
        if (starters[mid][0] < starter) low = mid + 1 else high = mid;
    }
    if (low == starters.len or starters[low][0] != starter) return null;
    const list = tables.contractions[starters[low][1]..][0..starters[low][2]];
    for (list) |c| if (c[1] == rest.len and std.mem.eql(u21, c[0][0..c[1]], rest)) return c[2];
    return null;
}

fn unifiedIdeograph(cp: u21) bool {
    const ranges = &tables.unified_ideographs;
    var low: usize = 0;
    var high: usize = ranges.len;
    while (low < high) {
        const mid = (low + high) / 2;
        if (ranges[mid][1] < cp) low = mid + 1 else high = mid;
    }
    return low < ranges.len and ranges[low][0] <= cp;
}
