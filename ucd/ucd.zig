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
pub const line_break_test = @embedFile("auxiliary/LineBreakTest.txt");
pub const normalization_test = @embedFile("NormalizationTest.txt");
pub const unicode_data = @embedFile("UnicodeData.txt");
pub const special_casing = @embedFile("SpecialCasing.txt");
pub const case_folding = @embedFile("CaseFolding.txt");
pub const derived_normalization_props = @embedFile("DerivedNormalizationProps.txt");
pub const idna_test = @embedFile("idna/IdnaTestV2.txt");
pub const bidi_class = @embedFile("extracted/DerivedBidiClass.txt");
pub const joining_type = @embedFile("extracted/DerivedJoiningType.txt");
pub const bidi_test = @embedFile("BidiTest.txt");
pub const bidi_character_test = @embedFile("BidiCharacterTest.txt");
pub const bidi_brackets = @embedFile("BidiBrackets.txt");
pub const bidi_mirroring = @embedFile("BidiMirroring.txt");

/// CLDR 49's root collation conformance tests (UCA 18.0.0), without their comments.
pub const collation_test_non_ignorable = @embedFile("uca/CollationTest_CLDR_NON_IGNORABLE_SHORT.txt");
pub const collation_test_shifted = @embedFile("uca/CollationTest_CLDR_SHIFTED_SHORT.txt");

/// The digests of encoding_rs 0.8.42 decoding and encoding the interop inputs (the header of digests.txt says how they were written).
pub const encoding_rs_digests = @embedFile("whatwg/encoding_rs/digests.txt");
/// encoding_rs's WHATWG-derived vectors (ucd/whatwg/encoding_rs, BSD 3-Clause: whatwg/LICENSE-WHATWG).
pub const encoding_rs_big5_in = @embedFile("whatwg/encoding_rs/big5_in.txt");
pub const encoding_rs_big5_in_ref = @embedFile("whatwg/encoding_rs/big5_in_ref.txt");
pub const encoding_rs_big5_out = @embedFile("whatwg/encoding_rs/big5_out.txt");
pub const encoding_rs_big5_out_ref = @embedFile("whatwg/encoding_rs/big5_out_ref.txt");
pub const encoding_rs_euc_kr_in = @embedFile("whatwg/encoding_rs/euc_kr_in.txt");
pub const encoding_rs_euc_kr_in_ref = @embedFile("whatwg/encoding_rs/euc_kr_in_ref.txt");
pub const encoding_rs_euc_kr_out = @embedFile("whatwg/encoding_rs/euc_kr_out.txt");
pub const encoding_rs_euc_kr_out_ref = @embedFile("whatwg/encoding_rs/euc_kr_out_ref.txt");
pub const encoding_rs_gb18030_in = @embedFile("whatwg/encoding_rs/gb18030_in.txt");
pub const encoding_rs_gb18030_in_ref = @embedFile("whatwg/encoding_rs/gb18030_in_ref.txt");
pub const encoding_rs_gb18030_out = @embedFile("whatwg/encoding_rs/gb18030_out.txt");
pub const encoding_rs_gb18030_out_ref = @embedFile("whatwg/encoding_rs/gb18030_out_ref.txt");
pub const encoding_rs_iso_2022_jp_in = @embedFile("whatwg/encoding_rs/iso_2022_jp_in.txt");
pub const encoding_rs_iso_2022_jp_in_ref = @embedFile("whatwg/encoding_rs/iso_2022_jp_in_ref.txt");
pub const encoding_rs_iso_2022_jp_out = @embedFile("whatwg/encoding_rs/iso_2022_jp_out.txt");
pub const encoding_rs_iso_2022_jp_out_ref = @embedFile("whatwg/encoding_rs/iso_2022_jp_out_ref.txt");
pub const encoding_rs_jis0208_in = @embedFile("whatwg/encoding_rs/jis0208_in.txt");
pub const encoding_rs_jis0208_in_ref = @embedFile("whatwg/encoding_rs/jis0208_in_ref.txt");
pub const encoding_rs_jis0208_out = @embedFile("whatwg/encoding_rs/jis0208_out.txt");
pub const encoding_rs_jis0208_out_ref = @embedFile("whatwg/encoding_rs/jis0208_out_ref.txt");
pub const encoding_rs_shift_jis_in = @embedFile("whatwg/encoding_rs/shift_jis_in.txt");
pub const encoding_rs_shift_jis_in_ref = @embedFile("whatwg/encoding_rs/shift_jis_in_ref.txt");
pub const encoding_rs_shift_jis_out = @embedFile("whatwg/encoding_rs/shift_jis_out.txt");
pub const encoding_rs_shift_jis_out_ref = @embedFile("whatwg/encoding_rs/shift_jis_out_ref.txt");
pub const encoding_rs_jis0212_in = @embedFile("whatwg/encoding_rs/jis0212_in.txt");
pub const encoding_rs_jis0212_in_ref = @embedFile("whatwg/encoding_rs/jis0212_in_ref.txt");
pub const whatwg_encodings = @embedFile("whatwg/encodings.json");
