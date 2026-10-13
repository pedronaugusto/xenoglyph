//! Unicode text handling: grapheme, word and sentence segmentation
//! (UAX #29), terminal cell widths, and character properties, from the
//! Unicode Character Database 18.0.0. Nothing allocates.
const std = @import("std");

pub const utf8 = @import("utf8.zig");
pub const grapheme = @import("grapheme.zig");
pub const word = @import("word.zig");
pub const sentence = @import("sentence.zig");
pub const width = @import("width.zig");
pub const line = @import("line.zig");
pub const properties = @import("properties.zig");

pub const unicode_version = properties.unicode_version;

pub const GeneralCategory = properties.GeneralCategory;
pub const EastAsianWidth = properties.EastAsianWidth;
pub const GraphemeBreak = properties.GraphemeBreak;
pub const IndicConjunctBreak = properties.IndicConjunctBreak;
pub const WordBreak = properties.WordBreak;
pub const SentenceBreak = properties.SentenceBreak;
pub const LineBreak = properties.LineBreak;
pub const Emoji = properties.Emoji;
pub const Core = properties.Core;
pub const Script = properties.Script;

pub const generalCategory = properties.generalCategory;
pub const eastAsianWidth = properties.eastAsianWidth;
pub const graphemeBreak = properties.graphemeBreak;
pub const indicConjunctBreak = properties.indicConjunctBreak;
pub const wordBreak = properties.wordBreak;
pub const sentenceBreak = properties.sentenceBreak;
pub const lineBreak = properties.lineBreak;
pub const emoji = properties.emoji;
pub const core = properties.core;
pub const script = properties.script;
pub const scriptExtensions = properties.scriptExtensions;

/// The grapheme clusters of a string (UAX #29).
pub const graphemes = grapheme.iterate;
/// The words of a string and the runs between them (UAX #29).
pub const words = word.iterate;
/// The sentences of a string (UAX #29).
pub const sentences = sentence.iterate;
/// The line break opportunities of a string (UAX #14).
pub const lines = line.iterate;

test {
    std.testing.refAllDecls(@This());
}
