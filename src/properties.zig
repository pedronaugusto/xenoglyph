//! Character properties: one table lookup each, no allocation, no state.
//! A value above U+10FFFF is no code point; it gets each property's
//! default, as an unassigned code point does.
const std = @import("std");
const aegis = @import("aegis");
const classes = @import("classes.zig");
const data = @import("data.zig");
const records = @import("records.zig");
const general_category_data = data.general_category;
const east_asian_width_data = data.east_asian_width;
const word_break_data = data.word_break;
const sentence_break_data = data.sentence_break;
const line_break_data = data.line_break;
const emoji_data = data.emoji;
const core_data = data.core;
const script_data = data.script;

pub const GeneralCategory = classes.GeneralCategory;
pub const EastAsianWidth = classes.EastAsianWidth;
pub const GraphemeBreak = classes.GraphemeBreak;
pub const IndicConjunctBreak = classes.IndicConjunctBreak;
pub const WordBreak = classes.WordBreak;
pub const SentenceBreak = classes.SentenceBreak;
pub const LineBreak = classes.LineBreak;
pub const Emoji = classes.Emoji;
pub const Core = classes.Core;
pub const Script = script_data.Script;
pub const BidiClass = classes.BidiClass;
pub const JoiningType = classes.JoiningType;

/// The largest code point.
pub const max_code_point: u21 = 0x10ffff;

/// The Unicode version of every table.
pub const unicode_version: std.SemanticVersion = .{ .major = 18, .minor = 0, .patch = 0 };

/// A run of code points, the first and the last, inclusive.
pub const Range = [2]u21;

/// Every code point of General_Category `gc`, as sorted ranges: the set a regular expression's
/// class takes, where `generalCategory` answers one code point.
pub fn generalCategoryRanges(gc: GeneralCategory) []const Range {
    return data.ranges.general_category[@backingInt(gc)];
}

/// Every code point whose Script is `s`, as sorted ranges.
pub fn scriptRanges(s: Script) []const Range {
    return data.ranges.script[@backingInt(s)];
}

/// Every code point whose Script_Extensions holds `s`, as sorted ranges.
pub fn scriptExtensionRanges(s: Script) []const Range {
    return data.ranges.script_extensions[@backingInt(s)];
}

/// Every code point of one of General_Category's groups (L, LC, M, N, P, S, Z, C), as sorted ranges.
pub fn generalCategoryGroupRanges(group: GeneralCategory.Group) []const Range {
    return data.ranges.general_category_group[@backingInt(group)];
}

/// A binary property of the UCD: each of PropList.txt, DerivedCoreProperties.txt, emoji-data.txt
/// and DerivedNormalizationProps.txt, and Bidi_Mirrored, by its long name in lower case.
/// Composition_Exclusion (CompositionExclusions.txt) and the Unihan properties are left out:
/// their files are not among xenoglyph's.
pub const Binary = data.ranges.Binary;

/// Every code point with the binary property `property`, as sorted ranges.
pub fn binaryRanges(property: Binary) []const Range {
    return data.ranges.binary[@backingInt(property)];
}

/// Every code point with the binary property `property` of `Core`, as sorted ranges.
pub fn coreRanges(comptime property: std.meta.FieldEnum(Core)) []const Range {
    return binaryRanges(@field(Binary, @tagName(property)));
}

/// Every White_Space code point (PropList.txt), as sorted ranges.
pub fn whiteSpaceRanges() []const Range {
    return binaryRanges(.white_space);
}

/// How a property's or value's name is compared with the UCD's names and aliases.
pub const NameMatch = enum {
    /// Byte for byte, as ECMA-262's `\p{...}` compares them.
    exact,
    /// By UAX #44's LM3, as UTS #18 and Rust's regex compare them: case, spaces, hyphens and
    /// underscores ignored, and an `is` before the name.
    loose,
};

/// A property a regular expression's `\p{...}` names.
pub const Property = union(enum) {
    general_category,
    script,
    script_extensions,
    binary: Binary,
};

/// The property `name` names (General_Category, Script, Script_Extensions or a binary one), by
/// PropertyAliases.txt; null for any other name.
pub fn propertyNamed(name: []const u8, match: NameMatch) ?Property {
    if (named(&data.ranges.property_names, name, match)) |i| return switch (i) {
        0 => .general_category,
        1 => .script,
        2 => .script_extensions,
        else => aegis.assert.never("property_names holds General_Category, Script and Script_Extensions"),
    };
    return .{ .binary = binaryNamed(name, match) orelse return null };
}

/// The binary property `name` names, by PropertyAliases.txt.
pub fn binaryNamed(name: []const u8, match: NameMatch) ?Binary {
    return entry(Binary, named(&data.ranges.binary_names, name, match) orelse return null);
}

/// The script `name` names, by PropertyValueAliases.txt (`Greek`, `Grek`, `Qaai`).
pub fn scriptNamed(name: []const u8, match: NameMatch) ?Script {
    return entry(Script, named(&data.ranges.script_names, name, match) orelse return null);
}

/// A General_Category value, or one of its groups.
pub const GeneralCategoryValue = union(enum) {
    category: GeneralCategory,
    group: GeneralCategory.Group,
};

/// The General_Category value or group `name` names, by PropertyValueAliases.txt (`Lu`,
/// `Uppercase_Letter`, `digit`, `L`, `punct`).
pub fn generalCategoryNamed(name: []const u8, match: NameMatch) ?GeneralCategoryValue {
    if (named(&data.ranges.general_category_names, name, match)) |i| return .{ .category = entry(GeneralCategory, i) };
    return .{ .group = entry(GeneralCategory.Group, named(&data.ranges.general_category_group_names, name, match) orelse return null) };
}

/// What `name` names in `table`. Loosely, a name that names nothing is tried again without an
/// `is` before it.
fn named(table: []const data.ranges.Alias, name: []const u8, match: NameMatch) ?u8 {
    switch (match) {
        .exact => for (table) |alias| if (std.mem.eql(u8, alias.name, name)) return alias.value,
        .loose => {
            for (table) |alias| if (looseEql(alias.name, name)) return alias.value;
            const rest = withoutIs(name) orelse return null;
            for (table) |alias| if (looseEql(alias.name, rest)) return alias.value;
        },
    }
    return null;
}

fn ignoredLoosely(c: u8) bool {
    return c == ' ' or c == '_' or c == '-';
}

/// `a` and `b` equal by LM3, its `is` aside.
fn looseEql(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and ignoredLoosely(a[i])) i += 1;
        while (j < b.len and ignoredLoosely(b[j])) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[j])) return false;
        i += 1;
        j += 1;
    }
}

/// `name` after an `is` (of any case, with what LM3 ignores around it), or null without one.
fn withoutIs(name: []const u8) ?[]const u8 {
    var at: usize = 0;
    for ("is") |want| {
        while (at < name.len and ignoredLoosely(name[at])) at += 1;
        if (at == name.len or std.ascii.toLower(name[at]) != want) return null;
        at += 1;
    }
    return name[at..];
}

/// General_Category.
pub fn generalCategory(cp: u21) GeneralCategory {
    if (cp > max_code_point) return .unassigned;
    return entry(GeneralCategory, general_category_data.table.get(cp));
}

/// East_Asian_Width (UAX #11).
pub fn eastAsianWidth(cp: u21) EastAsianWidth {
    if (cp > max_code_point) return .neutral;
    return entry(EastAsianWidth, east_asian_width_data.table.get(cp));
}

/// Grapheme_Cluster_Break (UAX #29).
pub fn graphemeBreak(cp: u21) GraphemeBreak {
    return records.cluster(cp).grapheme_break;
}

/// Indic_Conjunct_Break.
pub fn indicConjunctBreak(cp: u21) IndicConjunctBreak {
    return records.cluster(cp).conjunct;
}

/// Word_Break (UAX #29).
pub fn wordBreak(cp: u21) WordBreak {
    if (cp > max_code_point) return .other;
    return entry(WordBreak, word_break_data.table.get(cp));
}

/// Sentence_Break (UAX #29).
pub fn sentenceBreak(cp: u21) SentenceBreak {
    if (cp > max_code_point) return .other;
    return entry(SentenceBreak, sentence_break_data.table.get(cp));
}

/// Line_Break (UAX #14).
pub fn lineBreak(cp: u21) LineBreak {
    if (cp > max_code_point) return .unknown;
    return entry(LineBreak, line_break_data.table.get(cp));
}

/// The emoji properties of UTS #51.
pub fn emoji(cp: u21) Emoji {
    if (cp > max_code_point) return .{};
    return @bitCast(emoji_data.table.get(cp));
}

/// The binary properties of DerivedCoreProperties.txt.
pub fn core(cp: u21) Core {
    if (cp > max_code_point) return .{};
    return @bitCast(core_data.records[core_data.table.get(cp)]);
}

/// Script (UAX #24).
pub fn script(cp: u21) Script {
    if (cp > max_code_point) return .unknown;
    return entry(Script, script_data.table.get(cp));
}

/// Script_Extensions (UAX #24): the scripts a code point is used with,
/// sorted. Where the UCD lists none it is the Script property alone, so a
/// Common or Inherited code point with no extensions gives `.common` or
/// `.inherited`.
pub fn scriptExtensions(cp: u21) []const Script {
    if (cp > max_code_point) return single(.unknown);
    const index = script_data.extensions.get(cp);
    if (index == 0) return single(script(cp));
    return script_data.sets[index - 1];
}

/// Bidi_Class (UAX #9), with the defaults DerivedBidiClass.txt gives
/// unassigned code points (R or AL in the right-to-left blocks).
pub fn bidiClass(cp: u21) BidiClass {
    if (cp > max_code_point) return .left_to_right;
    const r: classes.Idna = @bitCast(data.idna.records[data.idna.table.get(cp)]);
    return r.bidi;
}

/// Joining_Type (DerivedJoiningType.txt).
pub fn joiningType(cp: u21) JoiningType {
    if (cp > max_code_point) return .non_joining;
    const r: classes.Idna = @bitCast(data.idna.records[data.idna.table.get(cp)]);
    return r.joining;
}

const every_script = std.enums.values(Script);

fn single(s: Script) []const Script {
    return every_script[@backingInt(s)..][0..1];
}

/// A generated table's entry as the property value it stands for, checked
/// in every build: an entry that names no value is a broken table.
fn entry(comptime E: type, value: anytype) E {
    return std.enums.fromInt(E, value) orelse aegis.assert.never("a generated table entry names a value of its property");
}

test "each property value's ranges hold exactly the code points the lookups give it" {
    var gc_seen: [std.enums.values(GeneralCategory).len]usize = @splat(0);
    for (std.enums.values(GeneralCategory)) |gc| {
        var last: ?u21 = null;
        for (generalCategoryRanges(gc)) |r| {
            try std.testing.expect(r[0] <= r[1]);
            // Sorted and apart: two runs that touch would be one.
            if (last) |l| try std.testing.expect(r[0] > l + 1);
            last = r[1];
            var cp = r[0];
            while (true) : (cp += 1) {
                try std.testing.expectEqual(gc, generalCategory(cp));
                gc_seen[@backingInt(gc)] += 1;
                if (cp == r[1]) break;
            }
        }
    }
    var total: usize = 0;
    for (gc_seen) |n| total += n;
    try std.testing.expectEqual(@as(usize, max_code_point) + 1, total);
    for (scriptRanges(.greek)) |r| {
        try std.testing.expectEqual(Script.greek, script(r[0]));
        try std.testing.expectEqual(Script.greek, script(r[1]));
    }
    // U+0951 (DEVANAGARI STRESS SIGN UDATTA) is Inherited by Script, and Latin among its extensions.
    try std.testing.expectEqual(Script.inherited, script(0x951));
    try std.testing.expect(holds(scriptExtensionRanges(.latin), 0x951));
    try std.testing.expect(!holds(scriptRanges(.latin), 0x951));
    try std.testing.expect(holds(coreRanges(.alphabetic), 'a'));
    try std.testing.expect(!holds(coreRanges(.alphabetic), '1'));
    try std.testing.expect(holds(whiteSpaceRanges(), 0x2028));
    try std.testing.expect(!holds(whiteSpaceRanges(), 'x'));
}

/// `ranges` sorted, apart, and holding exactly the code points `want` holds of `[0, max]`.
fn expectRangesOf(ranges: []const Range, context: anytype, comptime want: fn (@TypeOf(context), u21) bool) !void {
    var last: ?u21 = null;
    var count: usize = 0;
    for (ranges) |r| {
        try std.testing.expect(r[0] <= r[1]);
        if (last) |l| try std.testing.expect(r[0] > l + 1);
        last = r[1];
        var cp = r[0];
        while (true) : (cp += 1) {
            try std.testing.expect(want(context, cp));
            count += 1;
            if (cp == r[1]) break;
        }
    }
    var expected: usize = 0;
    var cp: u21 = 0;
    while (true) : (cp += 1) {
        if (want(context, cp)) expected += 1;
        if (cp == max_code_point) break;
    }
    try std.testing.expectEqual(expected, count);
}

test "each group's and binary property's ranges hold exactly the code points the lookups give it" {
    for (std.enums.values(GeneralCategory.Group)) |group| {
        try expectRangesOf(generalCategoryGroupRanges(group), group, struct {
            fn want(g: GeneralCategory.Group, cp: u21) bool {
                return generalCategory(cp).within(g);
            }
        }.want);
    }
    inline for (@typeInfo(Core).@"struct".field_names) |name| if (comptime !std.mem.eql(u8, name, "_")) {
        try expectRangesOf(binaryRanges(@field(Binary, name)), {}, struct {
            fn want(_: void, cp: u21) bool {
                return @field(core(cp), name);
            }
        }.want);
    };
    const emoji_fields = .{
        .{ "emoji", .emoji },               .{ "presentation", .emoji_presentation },
        .{ "modifier", .emoji_modifier },   .{ "modifier_base", .emoji_modifier_base },
        .{ "component", .emoji_component }, .{ "extended_pictographic", .extended_pictographic },
    };
    inline for (emoji_fields) |pair| {
        try expectRangesOf(binaryRanges(pair[1]), {}, struct {
            fn want(_: void, cp: u21) bool {
                return @field(emoji(cp), pair[0]);
            }
        }.want);
    }
    try std.testing.expect(holds(binaryRanges(.bidi_mirrored), '('));
    try std.testing.expect(!holds(binaryRanges(.bidi_mirrored), 'a'));
    try std.testing.expect(holds(binaryRanges(.hex_digit), 0xff21)); // FULLWIDTH LATIN CAPITAL LETTER A
    try std.testing.expect(!holds(binaryRanges(.ascii_hex_digit), 0xff21));
    try std.testing.expect(holds(binaryRanges(.changes_when_nfkc_casefolded), 'A'));
}

test "properties and values are found by every name the UCD gives them, exactly or loosely" {
    try std.testing.expectEqual(Property.general_category, propertyNamed("gc", .exact).?);
    try std.testing.expectEqual(Property.script_extensions, propertyNamed("Script_Extensions", .exact).?);
    try std.testing.expectEqual(Property{ .binary = .white_space }, propertyNamed("space", .exact).?);
    try std.testing.expectEqual(Property{ .binary = .white_space }, propertyNamed("WSpace", .exact).?);
    try std.testing.expectEqual(Property{ .binary = .bidi_mirrored }, propertyNamed("Bidi_M", .exact).?);
    try std.testing.expectEqual(@as(?Property, null), propertyNamed("id_start", .exact));
    try std.testing.expectEqual(Property{ .binary = .id_start }, propertyNamed("id_start", .loose).?);
    try std.testing.expectEqual(Property{ .binary = .id_start }, propertyNamed("Is ID-Start", .loose).?);
    try std.testing.expectEqual(@as(?Property, null), propertyNamed("Line_Break", .exact));

    try std.testing.expectEqual(GeneralCategoryValue{ .category = .uppercase_letter }, generalCategoryNamed("Lu", .exact).?);
    try std.testing.expectEqual(GeneralCategoryValue{ .category = .uppercase_letter }, generalCategoryNamed("Uppercase_Letter", .exact).?);
    try std.testing.expectEqual(GeneralCategoryValue{ .category = .decimal_number }, generalCategoryNamed("digit", .exact).?);
    try std.testing.expectEqual(GeneralCategoryValue{ .group = .letter }, generalCategoryNamed("L", .exact).?);
    try std.testing.expectEqual(GeneralCategoryValue{ .group = .cased_letter }, generalCategoryNamed("LC", .exact).?);
    try std.testing.expectEqual(GeneralCategoryValue{ .group = .punctuation }, generalCategoryNamed("punct", .exact).?);
    try std.testing.expectEqual(GeneralCategoryValue{ .group = .mark }, generalCategoryNamed("Combining_Mark", .exact).?);
    try std.testing.expectEqual(@as(?GeneralCategoryValue, null), generalCategoryNamed("lu", .exact));
    try std.testing.expectEqual(GeneralCategoryValue{ .category = .uppercase_letter }, generalCategoryNamed("uppercase letter", .loose).?);
    try std.testing.expectEqual(GeneralCategoryValue{ .category = .uppercase_letter }, generalCategoryNamed("isLu", .loose).?);

    try std.testing.expectEqual(Script.greek, scriptNamed("Greek", .exact).?);
    try std.testing.expectEqual(Script.greek, scriptNamed("Grek", .exact).?);
    try std.testing.expectEqual(Script.inherited, scriptNamed("Qaai", .exact).?);
    try std.testing.expectEqual(Script.inherited, scriptNamed("Zinh", .exact).?);
    try std.testing.expectEqual(Script.common, scriptNamed("Zyyy", .exact).?);
    try std.testing.expectEqual(@as(?Script, null), scriptNamed("greek", .exact));
    try std.testing.expectEqual(Script.greek, scriptNamed("IS_GREEK", .loose).?);
    try std.testing.expectEqual(@as(?Script, null), scriptNamed("Klingon", .loose));
}

test "every name in the tables finds what it names, exactly and loosely: none shadows another" {
    const tables = .{
        &data.ranges.property_names,         &data.ranges.binary_names,
        &data.ranges.general_category_names, &data.ranges.general_category_group_names,
        &data.ranges.script_names,
    };
    inline for (tables) |table| for (table) |alias| {
        try std.testing.expectEqual(alias.value, named(table, alias.name, .exact).?);
        try std.testing.expectEqual(alias.value, named(table, alias.name, .loose).?);
    };
    // A value's name and a group's never meet loosely either: `generalCategoryNamed` tries values first.
    for (data.ranges.general_category_group_names) |alias| {
        try std.testing.expectEqual(@as(?u8, null), named(&data.ranges.general_category_names, alias.name, .loose));
    }
}

fn holds(ranges: []const Range, cp: u21) bool {
    for (ranges) |r| if (cp >= r[0] and cp <= r[1]) return true;
    return false;
}
