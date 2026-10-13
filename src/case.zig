//! Case mapping and case folding (the Unicode Standard, chapter 3.13):
//! lowercase, uppercase, titlecase and folding of Unicode 18.0.0, full
//! mappings included (`ß` uppercases to `SS`), with the contexts of
//! SpecialCasing.txt: Final_Sigma always, and the Lithuanian and Turkic
//! (Turkish, Azerbaijani) tailorings when `Options.language` asks for them.
//!
//! Nothing here allocates. `Iterator` yields the mapped code points;
//! `write` writes them as UTF-8; the simple mappings are one lookup each.
//! Ill-formed UTF-8 reads as U+FFFD, as everywhere in xenoglyph.
const std = @import("std");
const aegis = @import("aegis");
const classes = @import("classes.zig");
const data = @import("data.zig");
const utf8 = @import("utf8.zig");
const normalize = @import("normalize.zig");
const word = @import("word.zig");

const tables = data.casing;

pub const Mapping = enum {
    lower,
    upper,
    /// The first cased letter of each word (UAX #29 word boundaries) to
    /// titlecase, everything else to lowercase.
    title,
    /// Full case folding (CaseFolding.txt C and F), for caseless matching.
    fold,
};

/// The language tailorings of SpecialCasing.txt.
pub const Language = enum {
    none,
    /// Turkish and Azerbaijani: dotted and dotless i (`I` lowercases to `ı`,
    /// `i` uppercases to `İ`), and folding to match.
    turkic,
    /// Lithuanian: a dot above kept on a lowercase i that carries an
    /// accent, and removed in uppercase.
    lithuanian,
};

pub const Options = struct {
    language: Language = .none,
};

fn record(cp: u21) classes.Case {
    if (cp > 0x10ffff) return .{};
    return @bitCast(tables.records[tables.table.get(cp)]);
}

fn shifted(cp: u21, delta: i24) u21 {
    return aegis.int.narrow(u21, @as(i32, cp) + delta) orelse aegis.assert.never("a case mapping gives a code point");
}

/// The simple lowercase mapping (UnicodeData.txt).
pub fn simpleLower(cp: u21) u21 {
    return shifted(cp, record(cp).lower);
}

/// The simple uppercase mapping.
pub fn simpleUpper(cp: u21) u21 {
    return shifted(cp, record(cp).upper);
}

/// The simple titlecase mapping.
pub fn simpleTitle(cp: u21) u21 {
    return shifted(cp, record(cp).title);
}

/// Simple case folding (CaseFolding.txt C and S).
pub fn simpleFold(cp: u21) u21 {
    return shifted(cp, record(cp).fold);
}

/// The full mapping of a code point whose record says it has one, or null
/// where it has none for `mapping` and the simple one applies.
fn special(cp: u21, mapping: Mapping) ?[]const u21 {
    const list = &tables.special_code_points;
    var low: usize = 0;
    var high: usize = list.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (list[mid] < cp) low = mid + 1 else high = mid;
    }
    if (low == list.len or list[low] != cp) return null;
    const s: classes.Special = @bitCast(tables.specials[low]);
    const m = switch (mapping) {
        .lower => s.lower,
        .upper => s.upper,
        .title => s.title,
        .fold => s.fold,
    };
    if (m.len == 0) return null;
    return tables.pool[m.start..][0..m.len];
}

/// What the casing contexts read behind a position, carried forward.
const Behind = struct {
    /// Final_Sigma: a cased letter, then case-ignorables.
    cased: bool = false,
    /// After_Soft_Dotted: a Soft_Dotted character, then no character of
    /// combining class 0 or 230.
    soft_dotted: bool = false,
    /// After_I: an `I`, then no character of combining class 0 or 230.
    capital_i: bool = false,

    fn push(b: *Behind, cp: u21, r: classes.Case) void {
        b.cased = if (r.case_ignorable) b.cased or r.cased else r.cased;
        const class = normalize.combiningClass(cp);
        if (class == 0 or class == 230) {
            b.soft_dotted = r.soft_dotted;
            b.capital_i = cp == 'I';
        }
    }
};

/// Final_Sigma's second half: no cased letter follows after case-ignorables.
fn casedFollows(bytes: []const u8, from: usize) bool {
    var it: utf8.Iterator = .{ .bytes = bytes, .index = from };
    while (it.next()) |cp| {
        const r = record(cp);
        if (r.cased) return true;
        if (!r.case_ignorable) return false;
    }
    return false;
}

/// More_Above: a character of combining class 230 follows, with none of
/// class 0 or 230 between.
fn moreAbove(bytes: []const u8, from: usize) bool {
    var it: utf8.Iterator = .{ .bytes = bytes, .index = from };
    while (it.next()) |cp| switch (normalize.combiningClass(cp)) {
        230 => return true,
        0 => return false,
        else => {},
    };
    return false;
}

/// Before_Dot: U+0307 follows, with none of class 0 or 230 between.
fn beforeDot(bytes: []const u8, from: usize) bool {
    var it: utf8.Iterator = .{ .bytes = bytes, .index = from };
    while (it.next()) |cp| {
        if (cp == 0x307) return true;
        const class = normalize.combiningClass(cp);
        if (class == 0 or class == 230) return false;
    }
    return false;
}

/// The mapped code points of a text, in order.
pub fn Iterator(comptime mapping: Mapping) type {
    return struct {
        const Self = @This();

        bytes: []const u8,
        options: Options,
        /// Private: where the next input code point starts.
        at: usize = 0,
        /// Private: the current code point's mapping, given out in turn.
        out: [3]u21 = undefined,
        len: u8 = 0,
        index: u8 = 0,
        behind: Behind = .{},
        /// Private, titlecase only: where the current word ends, and
        /// whether it has had its cased letter.
        word_end: usize = 0,
        titled: bool = false,
        /// Private, titlecase only: the soft-dotted letter that After_Soft_Dotted
        /// reads is the one titlecased, so a Lithuanian dot after it goes.
        dot_titled: bool = false,

        pub fn init(bytes: []const u8, options: Options) Self {
            return .{ .bytes = bytes, .options = options };
        }

        /// The next code point of the mapped text, or null at the end.
        pub fn next(it: *Self) ?u21 {
            while (it.index == it.len) {
                if (it.at >= it.bytes.len) return null;
                const d = utf8.decode(it.bytes[it.at..]);
                const after = it.at + d.len;
                if (mapping == .title and it.at >= it.word_end) {
                    it.word_end = word.boundaryAfter(it.bytes, .fromRaw(it.at)).raw();
                    it.titled = false;
                }
                const r = record(d.code_point);
                it.index = 0;
                it.len = 0;
                if (mapping == .title) {
                    var titled_now = false;
                    if (!it.titled and r.cased) {
                        it.titled = true;
                        titled_now = true;
                        it.map(.title, d.code_point, r, after);
                    } else if (d.code_point == 0x307 and it.options.language == .lithuanian and it.behind.soft_dotted and it.dot_titled) {
                        // The dot of a titlecased i: removed, as in uppercase.
                    } else it.map(.lower, d.code_point, r, after);
                    const class = normalize.combiningClass(d.code_point);
                    if (class == 0 or class == 230) it.dot_titled = titled_now and r.soft_dotted;
                } else it.map(mapping, d.code_point, r, after);
                it.behind.push(d.code_point, r);
                it.at = after;
            }
            defer it.index += 1;
            return it.out[it.index];
        }

        fn emit(it: *Self, cps: []const u21) void {
            @memcpy(it.out[0..cps.len], cps);
            it.len = aegis.int.narrow(u8, cps.len) orelse aegis.assert.never("a full mapping is at most three code points");
        }

        fn map(it: *Self, m: Mapping, cp: u21, r: classes.Case, after: usize) void {
            const language = it.options.language;
            switch (m) {
                .lower => {
                    if (language == .lithuanian) switch (cp) {
                        'I', 'J', 0x12e => if (moreAbove(it.bytes, after)) return it.emit(&.{ simpleLower(cp), 0x307 }),
                        0xcc => return it.emit(&.{ 'i', 0x307, 0x300 }),
                        0xcd => return it.emit(&.{ 'i', 0x307, 0x301 }),
                        0x128 => return it.emit(&.{ 'i', 0x307, 0x303 }),
                        else => {},
                    };
                    if (language == .turkic) switch (cp) {
                        0x130 => return it.emit(&.{'i'}),
                        0x307 => if (it.behind.capital_i) return,
                        'I' => if (!beforeDot(it.bytes, after)) return it.emit(&.{0x131}),
                        else => {},
                    };
                    if (cp == 0x3a3) {
                        const final = it.behind.cased and !casedFollows(it.bytes, after);
                        return it.emit(&.{if (final) 0x3c2 else 0x3c3});
                    }
                },
                .upper, .title => {
                    if (language == .lithuanian and cp == 0x307 and it.behind.soft_dotted) return;
                    if (language == .turkic and cp == 'i') return it.emit(&.{0x130});
                },
                .fold => if (language == .turkic) switch (cp) {
                    'I' => return it.emit(&.{0x131}),
                    0x130 => return it.emit(&.{'i'}),
                    else => {},
                },
            }
            if (r.special) if (special(cp, m)) |full| return it.emit(full);
            it.emit(&.{shifted(cp, switch (m) {
                .lower => r.lower,
                .upper => r.upper,
                .title => r.title,
                .fold => r.fold,
            })});
        }
    };
}

/// `text` mapped, written as UTF-8.
pub fn write(comptime mapping: Mapping, text: []const u8, w: *std.Io.Writer, options: Options) std.Io.Writer.Error!void {
    var it: Iterator(mapping) = .init(text, options);
    try utf8.encode(&it, w);
}

/// Whether `a` and `b` are equal under full case folding: the default
/// caseless match. It does not normalize; normalize both first where
/// canonically equivalent text must match.
pub fn equalFold(a: []const u8, b: []const u8, options: Options) bool {
    var x: Iterator(.fold) = .init(a, options);
    var y: Iterator(.fold) = .init(b, options);
    while (true) {
        const p = x.next();
        if (p != y.next()) return false;
        if (p == null) return true;
    }
}

fn expectMapped(comptime mapping: Mapping, input: []const u8, want: []const u8, options: Options) !void {
    var out: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try write(mapping, input, &w, options);
    try std.testing.expectEqualStrings(want, w.buffered());
}

test "mappings" {
    try expectMapped(.upper, "straße", "STRASSE", .{});
    try expectMapped(.lower, "ΟΔΟΣ ΟΔΟΣ.", "οδος οδος.", .{});
    try expectMapped(.lower, "Σ", "σ", .{});
    try expectMapped(.title, "hello wORLD, 'quoted' ǆemal", "Hello World, 'Quoted' ǅemal", .{});
    try expectMapped(.fold, "Straße", "strasse", .{});
    try expectMapped(.upper, "istanbul", "İSTANBUL", .{ .language = .turkic });
    try expectMapped(.lower, "I\u{307}", "i", .{ .language = .turkic });
    try expectMapped(.lower, "DIYARBAKIR", "dıyarbakır", .{ .language = .turkic });
    try expectMapped(.lower, "\u{cc}", "i\u{307}\u{300}", .{ .language = .lithuanian });
    try std.testing.expect(equalFold("Maße", "MASSE", .{}));
    try std.testing.expectEqual('a', simpleLower('A'));
    try std.testing.expectEqual(0x1c5, simpleTitle(0x1c6));
}

test "every conditional mapping of SpecialCasing.txt in its context" {
    // Final_Sigma: after a cased letter and case-ignorables, before none.
    try expectMapped(.lower, "\u{391}\u{3a3}", "\u{3b1}\u{3c2}", .{});
    try expectMapped(.lower, "\u{391}.\u{3a3}", "\u{3b1}.\u{3c2}", .{});
    try expectMapped(.lower, "\u{391}\u{3a3}\u{391}", "\u{3b1}\u{3c3}\u{3b1}", .{});
    try expectMapped(.lower, "\u{391}\u{3a3}.\u{391}", "\u{3b1}\u{3c3}.\u{3b1}", .{});
    try expectMapped(.lower, " \u{3a3} ", " \u{3c3} ", .{});
    // Lithuanian: More_Above keeps the dot; After_Soft_Dotted drops it.
    const lt: Options = .{ .language = .lithuanian };
    try expectMapped(.lower, "I\u{301}", "i\u{307}\u{301}", lt);
    try expectMapped(.lower, "J\u{301}", "j\u{307}\u{301}", lt);
    try expectMapped(.lower, "\u{12e}\u{301}", "\u{12f}\u{307}\u{301}", lt);
    try expectMapped(.lower, "I", "i", lt);
    try expectMapped(.lower, "\u{cd}\u{128}", "i\u{307}\u{301}i\u{307}\u{303}", lt);
    try expectMapped(.upper, "i\u{307}", "I", lt);
    try expectMapped(.upper, "i\u{323}\u{307}", "I\u{323}", lt);
    try expectMapped(.title, "i\u{307}x", "Ix", lt);
    try expectMapped(.upper, "i\u{307}", "I\u{307}", .{});
    // Turkic: dotted and dotless i.
    const tr: Options = .{ .language = .turkic };
    try expectMapped(.lower, "\u{130}", "i", tr);
    try expectMapped(.lower, "I\u{323}\u{307}", "i\u{323}", tr);
    try expectMapped(.lower, "I", "\u{131}", tr);
    try expectMapped(.upper, "i", "\u{130}", tr);
    try expectMapped(.title, "ilk", "\u{130}lk", tr);
    try expectMapped(.fold, "I\u{130}", "\u{131}i", tr);
    try expectMapped(.lower, "\u{130}", "i\u{307}", .{});
}
