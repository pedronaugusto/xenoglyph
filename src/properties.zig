//! Character properties: one table lookup each, no allocation, no state.
//! A value above U+10FFFF is no code point; it gets each property's
//! default, as an unassigned code point does.
const std = @import("std");
const classes = @import("classes.zig");
const data = @import("data.zig");
const cluster_data = data.cluster;
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

/// The largest code point.
pub const max_code_point: u21 = 0x10ffff;

/// The Unicode version of every table.
pub const unicode_version: std.SemanticVersion = .{ .major = 18, .minor = 0, .patch = 0 };

/// General_Category.
pub fn generalCategory(cp: u21) GeneralCategory {
    if (cp > max_code_point) return .unassigned;
    return @fromBackingInt(@intCast(general_category_data.table.get(cp)));
}

/// East_Asian_Width (UAX #11).
pub fn eastAsianWidth(cp: u21) EastAsianWidth {
    if (cp > max_code_point) return .neutral;
    return @fromBackingInt(@intCast(east_asian_width_data.table.get(cp)));
}

/// Grapheme_Cluster_Break (UAX #29).
pub fn graphemeBreak(cp: u21) GraphemeBreak {
    return cluster(cp).grapheme_break;
}

/// Indic_Conjunct_Break.
pub fn indicConjunctBreak(cp: u21) IndicConjunctBreak {
    return cluster(cp).conjunct;
}

/// Word_Break (UAX #29).
pub fn wordBreak(cp: u21) WordBreak {
    if (cp > max_code_point) return .other;
    return @fromBackingInt(@intCast(word_break_data.table.get(cp)));
}

/// Sentence_Break (UAX #29).
pub fn sentenceBreak(cp: u21) SentenceBreak {
    if (cp > max_code_point) return .other;
    return @fromBackingInt(@intCast(sentence_break_data.table.get(cp)));
}

/// Line_Break (UAX #14).
pub fn lineBreak(cp: u21) LineBreak {
    if (cp > max_code_point) return .unknown;
    return @fromBackingInt(@intCast(line_break_data.table.get(cp)));
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
    return @fromBackingInt(@intCast(script_data.table.get(cp)));
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

const every_script = std.enums.values(Script);

fn single(s: Script) []const Script {
    return every_script[@backingInt(s)..][0..1];
}

/// The record segmentation and measuring read: one lookup for every
/// property of a code point the hot path needs.
pub inline fn cluster(cp: u21) classes.Cluster {
    return clusterRecord(clusterIndex(cp));
}

/// The distinct cluster records; a code point's record index is its
/// position here.
pub const cluster_records = cluster_data.records;

/// The index of a code point's record in `cluster_records`.
pub inline fn clusterIndex(cp: u21) u8 {
    if (cp > max_code_point) return default_cluster_index;
    return cluster_data.table.get(cp);
}

pub inline fn clusterRecord(index: u8) classes.Cluster {
    return @bitCast(cluster_records[index]);
}

/// The record of a value past U+10FFFF: an unassigned code point's.
const default_cluster_index: u8 = for (cluster_records, 0..) |r, i| {
    if (r == @as(u16, @bitCast(classes.Cluster{}))) break i;
} else @compileError("no record for an unassigned code point");

/// The record indexes of the ASCII code points.
pub const ascii_cluster_indexes: [128]u8 = blk: {
    @setEvalBranchQuota(10_000);
    var indexes: [128]u8 = undefined;
    for (&indexes, 0..) |*i, cp| i.* = cluster_data.table.get(cp);
    break :blk indexes;
};
