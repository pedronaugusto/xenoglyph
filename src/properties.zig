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

/// Every code point with the binary property `property` of `Core`, as sorted ranges.
pub fn coreRanges(comptime property: std.meta.FieldEnum(Core)) []const Range {
    return @field(data.ranges.core, @tagName(property));
}

/// Every White_Space code point (PropList.txt), as sorted ranges.
pub fn whiteSpaceRanges() []const Range {
    return data.ranges.white_space;
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

fn holds(ranges: []const Range, cp: u21) bool {
    for (ranges) |r| if (cp >= r[0] and cp <= r[1]) return true;
    return false;
}
