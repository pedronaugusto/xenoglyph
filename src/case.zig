//! Case mapping and case folding (the Unicode Standard, chapter 3.13):
//! lowercase, uppercase, titlecase and folding of Unicode 18.0.0, full
//! mappings included (`ß` uppercases to `SS`), with the contexts of
//! SpecialCasing.txt: Final_Sigma always, and the Lithuanian and Turkic
//! (Turkish, Azerbaijani) tailorings when `Options.language` asks for them.
//!
//! Nothing here allocates. `Iterator` yields the mapped code points;
//! `write` writes them as UTF-8; the simple mappings are one lookup each;
//! `equal` is each of the caseless matches the chapter defines.
//! Ill-formed UTF-8 reads as U+FFFD, as everywhere in xenoglyph.
const std = @import("std");
const aegis = @import("aegis");
const classes = @import("classes.zig");
const data = @import("data.zig");
const utf8 = @import("utf8.zig");
const normalize = @import("normalize.zig");
const canonical = @import("canonical.zig");
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

/// Soft_Dotted (PropList.txt): a letter whose dot an accent above it takes
/// the place of, as `i` and `j`.
pub fn softDotted(cp: u21) bool {
    return record(cp).soft_dotted;
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

/// The full case folding of `cp`, whose record is `r` (CaseFolding.txt C
/// and F, and T for Turkic), in `buffer` or the special list. Folding reads
/// no context.
fn folded(cp: u21, r: classes.Case, language: Language, buffer: *[3]u21) []const u21 {
    if (language == .turkic) switch (cp) {
        'I' => buffer[0] = 0x131,
        0x130 => buffer[0] = 'i',
        else => {},
    };
    if (language == .turkic and (cp == 'I' or cp == 0x130)) return buffer[0..1];
    if (r.special) if (special(cp, .fold)) |full| return full;
    buffer[0] = shifted(cp, r.fold);
    return buffer[0..1];
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
                .fold => {
                    var buffer: [3]u21 = undefined;
                    return it.emit(folded(cp, r, language, &buffer));
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

/// The caseless matches of the Unicode Standard, chapter 3.13. Each is
/// equality after a transform; toCasefold is full case folding.
pub const Match = enum {
    /// D144, default caseless match: toCasefold(X). Does not normalize, so
    /// canonically equivalent texts can differ.
    default,
    /// D145, canonical caseless match: NFD(toCasefold(NFD(X))).
    canonical,
    /// D147, identifier caseless match: toNFKC_Casefold(NFD(X)), which also
    /// ignores Default_Ignorable_Code_Point. NFKC_Casefold has no language
    /// tailoring, so `Options.language` does not change it.
    identifier,
};

/// Whether `a` and `b` match caselessly by `match`. `options.language`
/// tailors the folding of `.default` and `.canonical` (Turkic dotted and
/// dotless i).
pub fn equal(comptime match: Match, a: []const u8, b: []const u8, options: Options) bool {
    var x = matcher(match, a, options);
    var y = matcher(match, b, options);
    while (true) {
        const p = x.next();
        if (p != y.next()) return false;
        if (p == null) return true;
    }
}

/// The transformed text a match compares, one code point at a time.
fn Matcher(comptime match: Match) type {
    return switch (match) {
        .default => Iterator(.fold),
        .canonical, .identifier => canonical.Canonical(Mapped(match), false),
    };
}

fn matcher(comptime match: Match, text: []const u8, options: Options) Matcher(match) {
    return switch (match) {
        .default => .init(text, options),
        .canonical, .identifier => .{ .source = .{ .bytes = text, .language = options.language } },
    };
}

/// A text's canonical decomposition, each code point of it mapped (folded
/// then decomposed for `.canonical`, NFKC_Casefold decomposed for
/// `.identifier`), for the canonical ordering after it to put in NFD.
///
/// The definitions order the decomposition (the inner NFD) before mapping
/// it. That ordering changes nothing a later ordering would not, since a
/// non-starter maps to non-starters of its own class or to nothing, with one
/// kind of exception: a non-starter that maps to starters (U+0345, the iota
/// subscript, to U+03B9). Those are all of the highest combining class, 240,
/// and map alike, so the inner NFD puts them last in their run; they are
/// held here and given out where the run ends. The suite checks both facts
/// for every code point. So one ordering does the work of two, and a long
/// run costs a reading for each combining class in it, as normalizing does.
fn Mapped(comptime match: Match) type {
    return struct {
        const Self = @This();

        bytes: []const u8,
        language: Language,
        /// Private: where the next code point of the text starts.
        at: usize = 0,
        /// Private: the current code point's canonical decomposition, and
        /// the next code point of it to map.
        raw: [18]u21 = undefined,
        raw_len: u8 = 0,
        raw_index: u8 = 0,
        /// Private: the mapping being given out.
        out: [18]u21 = undefined,
        len: u8 = 0,
        index: u8 = 0,
        /// Private: what the held non-starters map to, and how many are
        /// held until their run ends.
        held: [18]u21 = undefined,
        held_len: u8 = 0,
        held_count: usize = 0,
        /// Private: how many code points it has given, which tells
        /// positions apart.
        given: usize = 0,

        pub const Position = struct {
            at: Self,

            pub fn eql(a: Position, b: Position) bool {
                return a.at.given == b.at.given;
            }
        };

        pub fn position(s: *const Self) Position {
            return .{ .at = s.* };
        }

        pub fn seek(s: *Self, p: Position) void {
            s.* = p.at;
        }

        pub fn next(s: *Self) ?u21 {
            while (s.index == s.len) {
                if (s.raw_index == s.raw_len) {
                    if (s.at >= s.bytes.len) {
                        if (s.held_count == 0) return null;
                        s.release();
                        continue;
                    }
                    const d = utf8.decode(s.bytes[s.at..]);
                    s.at += d.len;
                    s.raw_len = length(normalize.decompose(d.code_point, .nfd, &s.raw).len);
                    s.raw_index = 0;
                }
                const cp = s.raw[s.raw_index];
                const class = normalize.combiningClass(cp);
                // A starter ends the run: what was held goes before it.
                if (class == 0 and s.held_count > 0) {
                    s.release();
                    continue;
                }
                s.raw_index += 1;
                const image = s.map(cp);
                s.index = 0;
                s.len = length(image.len);
                if (class != 0) for (image) |m| if (normalize.combiningClass(m) != class) {
                    s.hold(image);
                    break;
                };
            }
            defer {
                s.index += 1;
                s.given += 1;
            }
            return s.out[s.index];
        }

        /// `cp` mapped and decomposed, in `out`.
        fn map(s: *Self, cp: u21) []const u21 {
            switch (match) {
                .canonical => {
                    var buffer: [3]u21 = undefined;
                    var len: usize = 0;
                    for (folded(cp, record(cp), s.language, &buffer)) |f| {
                        var decomposed: [18]u21 = undefined;
                        const d = normalize.decompose(f, .nfd, &decomposed);
                        @memcpy(s.out[len..][0..d.len], d);
                        len += d.len;
                    }
                    return s.out[0..len];
                },
                .identifier => return normalize.decompose(cp, .nfkc_casefold, &s.out),
                .default => comptime unreachable, // unreachable: `.default` reads no decomposition
            }
        }

        /// Holds a non-starter's mapping, `image`, in `out`, until its run ends.
        fn hold(s: *Self, image: []const u21) void {
            if (s.held_count == 0) {
                @memcpy(s.held[0..image.len], image);
                s.held_len = length(image.len);
            } else aegis.assert.invariant(std.mem.eql(u21, s.held[0..s.held_len], image), "the non-starters held map alike");
            s.held_count += 1;
            s.len = 0;
        }

        fn release(s: *Self) void {
            @memcpy(s.out[0..s.held_len], s.held[0..s.held_len]);
            s.len = s.held_len;
            s.index = 0;
            s.held_count -= 1;
        }

        fn length(n: usize) u8 {
            return aegis.int.narrow(u8, n) orelse aegis.assert.never("a mapping is at most 18 code points");
        }
    };
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
    try std.testing.expect(equal(.default, "Maße", "MASSE", .{}));
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

test "caseless matches" {
    // Canonically equivalent, so they match from canonical up.
    try std.testing.expect(!equal(.default, "A\u{30a}", "\u{e5}", .{}));
    try std.testing.expect(equal(.canonical, "A\u{30a}", "\u{e5}", .{}));
    try std.testing.expect(equal(.canonical, "\u{212b}", "a\u{30a}", .{}));
    // The iota subscript folds to iota after the marks NFD puts before it.
    try std.testing.expect(equal(.canonical, "\u{3b1}\u{345}\u{313}", "\u{1f00}\u{3b9}", .{}));
    // Compatibility characters: a sign and a squared unit.
    try std.testing.expect(!equal(.canonical, "\u{2122}", "tm", .{}));
    try std.testing.expect(equal(.identifier, "\u{2122}", "tm", .{}));
    try std.testing.expect(equal(.identifier, "\u{3392}", "mhz", .{}));
    // Identifier: default ignorables are ignored too.
    try std.testing.expect(!equal(.canonical, "pa\u{ad}ss", "PASS", .{}));
    try std.testing.expect(equal(.identifier, "pa\u{ad}ss", "PASS", .{}));
    try std.testing.expect(equal(.identifier, "\u{2160}", "i", .{}));
    // What NFKC_Casefold maps a starter to can need ordering with the marks
    // after it, and the iota subscript still folds after the marks before it.
    try std.testing.expect(equal(.identifier, "\u{a8}\u{323}", " \u{323}\u{308}", .{}));
    try std.testing.expect(equal(.identifier, "\u{3b1}\u{345}\u{313}", "\u{1f00}\u{3b9}", .{}));
    try std.testing.expect(!equal(.identifier, "\u{3b1}\u{345}\u{313}", "\u{3b1}\u{1f30}", .{}));
    try std.testing.expect(equal(.canonical, "I", "\u{131}", .{ .language = .turkic }));
}
