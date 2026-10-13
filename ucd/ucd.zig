//! The Unicode Character Database 18.0.0 files the tests read: the
//! conformance tests and the property files the tables are checked against.
//! A module of the development build only; nothing here ships.

pub const grapheme_break_test = @embedFile("auxiliary/GraphemeBreakTest.txt");
pub const word_break_test = @embedFile("auxiliary/WordBreakTest.txt");
pub const sentence_break_test = @embedFile("auxiliary/SentenceBreakTest.txt");
pub const emoji_test = @embedFile("emoji/emoji-test.txt");

pub const grapheme_break_property = @embedFile("auxiliary/GraphemeBreakProperty.txt");
pub const word_break_property = @embedFile("auxiliary/WordBreakProperty.txt");
pub const sentence_break_property = @embedFile("auxiliary/SentenceBreakProperty.txt");
pub const line_break = @embedFile("LineBreak.txt");
pub const east_asian_width = @embedFile("EastAsianWidth.txt");
pub const general_category = @embedFile("extracted/DerivedGeneralCategory.txt");
pub const derived_core_properties = @embedFile("DerivedCoreProperties.txt");
pub const emoji_data = @embedFile("emoji/emoji-data.txt");
pub const emoji_variation_sequences = @embedFile("emoji/emoji-variation-sequences.txt");
pub const scripts = @embedFile("Scripts.txt");
pub const script_extensions = @embedFile("ScriptExtensions.txt");
pub const property_value_aliases = @embedFile("PropertyValueAliases.txt");
