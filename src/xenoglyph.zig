//! Unicode text handling: grapheme, word and sentence segmentation
//! (UAX #29), terminal cell widths, and character properties, from the
//! Unicode Character Database 18.0.0; internationalized domain names (UTS
//! #46) and Punycode. Nothing allocates.
const std = @import("std");
const domains = @import("domains.zig");

pub const utf8 = @import("utf8.zig");
pub const grapheme = @import("grapheme.zig");
pub const word = @import("word.zig");
pub const sentence = @import("sentence.zig");
pub const width = @import("width.zig");
pub const line = @import("line.zig");
pub const normalize = @import("normalize.zig");
pub const case = @import("case.zig");
pub const properties = @import("properties.zig");
pub const idna = @import("idna.zig");
pub const punycode = @import("punycode.zig");
pub const bidi = @import("bidi.zig");
pub const encoding = @import("encoding.zig");
pub const collation = @import("collation.zig");
pub const security = @import("security.zig");

/// A number of bytes: a length, or an offset into a text.
pub const Bytes = domains.Bytes;
/// A byte range of a text.
pub const Span = domains.Span;
/// A number of terminal columns.
pub const Columns = domains.Columns;
/// A number of grapheme clusters.
pub const Clusters = domains.Clusters;

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
pub const BidiClass = properties.BidiClass;
pub const JoiningType = properties.JoiningType;

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
pub const bidiClass = properties.bidiClass;
pub const joiningType = properties.joiningType;

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
