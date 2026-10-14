//! The values of the Unicode properties xenoglyph reads, and the packed records
//! its tables hold. Each enumerated value is named for the long name the
//! Unicode Character Database gives it, in snake case; the generator matches
//! names loosely (UAX #44 LM3: case, spaces, hyphens and underscores
//! ignored), so `a_letter` is `ALetter` and `zw_space` is `ZWSpace`.
//!
//! This file imports nothing: the table generator reads it too, so the
//! numbers it writes are the numbers these types give the same values.

/// General_Category, the two-letter categories.
pub const GeneralCategory = enum(u5) {
    unassigned,
    uppercase_letter,
    lowercase_letter,
    titlecase_letter,
    modifier_letter,
    other_letter,
    nonspacing_mark,
    spacing_mark,
    enclosing_mark,
    decimal_number,
    letter_number,
    other_number,
    connector_punctuation,
    dash_punctuation,
    open_punctuation,
    close_punctuation,
    initial_punctuation,
    final_punctuation,
    other_punctuation,
    math_symbol,
    currency_symbol,
    modifier_symbol,
    other_symbol,
    space_separator,
    line_separator,
    paragraph_separator,
    control,
    format,
    surrogate,
    private_use,

    /// L: Lu, Ll, Lt, Lm or Lo.
    pub fn isLetter(c: GeneralCategory) bool {
        return switch (c) {
            .uppercase_letter, .lowercase_letter, .titlecase_letter, .modifier_letter, .other_letter => true,
            else => false,
        };
    }

    /// LC: Lu, Ll or Lt.
    pub fn isCasedLetter(c: GeneralCategory) bool {
        return c == .uppercase_letter or c == .lowercase_letter or c == .titlecase_letter;
    }

    /// M: Mn, Mc or Me.
    pub fn isMark(c: GeneralCategory) bool {
        return c == .nonspacing_mark or c == .spacing_mark or c == .enclosing_mark;
    }

    /// N: Nd, Nl or No.
    pub fn isNumber(c: GeneralCategory) bool {
        return c == .decimal_number or c == .letter_number or c == .other_number;
    }

    /// P: Pc, Pd, Ps, Pe, Pi, Pf or Po.
    pub fn isPunctuation(c: GeneralCategory) bool {
        return switch (c) {
            .connector_punctuation, .dash_punctuation, .open_punctuation, .close_punctuation, .initial_punctuation, .final_punctuation, .other_punctuation => true,
            else => false,
        };
    }

    /// S: Sm, Sc, Sk or So.
    pub fn isSymbol(c: GeneralCategory) bool {
        return c == .math_symbol or c == .currency_symbol or c == .modifier_symbol or c == .other_symbol;
    }

    /// Z: Zs, Zl or Zp.
    pub fn isSeparator(c: GeneralCategory) bool {
        return c == .space_separator or c == .line_separator or c == .paragraph_separator;
    }

    /// C: Cc, Cf, Cs, Co or Cn.
    pub fn isOther(c: GeneralCategory) bool {
        return switch (c) {
            .control, .format, .surrogate, .private_use, .unassigned => true,
            else => false,
        };
    }
};

/// East_Asian_Width (UAX #11).
pub const EastAsianWidth = enum(u3) {
    neutral,
    ambiguous,
    halfwidth,
    fullwidth,
    narrow,
    wide,
};

/// Grapheme_Cluster_Break (UAX #29). The obsolete values E_Base,
/// E_Modifier, Glue_After_Zwj and E_Base_GAZ are assigned to nothing and
/// left out.
pub const GraphemeBreak = enum(u4) {
    other,
    cr,
    lf,
    control,
    extend,
    zwj,
    regional_indicator,
    prepend,
    spacing_mark,
    l,
    v,
    t,
    lv,
    lvt,
};

/// Indic_Conjunct_Break, which grapheme rule GB9c reads.
pub const IndicConjunctBreak = enum(u2) {
    none,
    linker,
    consonant,
    extend,
};

/// Word_Break (UAX #29), without the obsolete values.
pub const WordBreak = enum(u5) {
    other,
    cr,
    lf,
    newline,
    extend,
    zwj,
    regional_indicator,
    format,
    katakana,
    hebrew_letter,
    a_letter,
    single_quote,
    double_quote,
    mid_num_let,
    mid_letter,
    mid_num,
    numeric,
    extend_num_let,
    w_seg_space,
};

/// Sentence_Break (UAX #29).
pub const SentenceBreak = enum(u4) {
    other,
    cr,
    lf,
    extend,
    sep,
    format,
    sp,
    lower,
    upper,
    o_letter,
    numeric,
    a_term,
    s_continue,
    s_term,
    close,
};

/// Line_Break (UAX #14).
pub const LineBreak = enum(u6) {
    unknown,
    mandatory_break,
    carriage_return,
    line_feed,
    combining_mark,
    next_line,
    surrogate,
    word_joiner,
    zw_space,
    glue,
    space,
    zwj,
    break_both,
    break_after,
    break_before,
    hyphen,
    contingent_break,
    close_punctuation,
    close_parenthesis,
    exclamation,
    inseparable,
    nonstarter,
    open_punctuation,
    quotation,
    infix_numeric,
    numeric,
    postfix_numeric,
    prefix_numeric,
    break_symbols,
    ambiguous,
    alphabetic,
    conditional_japanese_starter,
    e_base,
    e_modifier,
    h2,
    h3,
    hebrew_letter,
    ideographic,
    jl,
    jt,
    jv,
    complex_context,
    regional_indicator,
    aksara,
    aksara_prebase,
    aksara_start,
    virama_final,
    virama,
    unambiguous_hyphen,
};

/// The emoji properties of UTS #51 (emoji-data.txt), and whether the code
/// point begins an emoji variation sequence (emoji-variation-sequences.txt).
pub const Emoji = packed struct(u8) {
    /// Emoji.
    emoji: bool = false,
    /// Emoji_Presentation: shown as an emoji unless asked otherwise.
    presentation: bool = false,
    /// Emoji_Modifier: the five skin tones.
    modifier: bool = false,
    /// Emoji_Modifier_Base: a modifier after it changes it.
    modifier_base: bool = false,
    /// Emoji_Component: a part of an emoji sequence.
    component: bool = false,
    /// Extended_Pictographic.
    extended_pictographic: bool = false,
    /// The first code point of a sequence in emoji-variation-sequences.txt:
    /// U+FE0E after it asks for text, U+FE0F for emoji presentation.
    variation_base: bool = false,
    _: u1 = 0,
};

/// The binary properties of DerivedCoreProperties.txt. The deprecated
/// Grapheme_Link is left out; Indic_Conjunct_Break is `IndicConjunctBreak`.
pub const Core = packed struct(u32) {
    math: bool = false,
    alphabetic: bool = false,
    lowercase: bool = false,
    uppercase: bool = false,
    cased: bool = false,
    case_ignorable: bool = false,
    changes_when_lowercased: bool = false,
    changes_when_uppercased: bool = false,
    changes_when_titlecased: bool = false,
    changes_when_casefolded: bool = false,
    changes_when_casemapped: bool = false,
    id_start: bool = false,
    id_continue: bool = false,
    xid_start: bool = false,
    xid_continue: bool = false,
    default_ignorable_code_point: bool = false,
    grapheme_extend: bool = false,
    grapheme_base: bool = false,
    _: u14 = 0,
};

/// What segmenting a grapheme cluster and measuring it need of one code
/// point, in one lookup. Internal to xenoglyph; the public functions read it.
pub const Cluster = packed struct(u16) {
    grapheme_break: GraphemeBreak = .other,
    conjunct: IndicConjunctBreak = .none,
    extended_pictographic: bool = false,
    modifier: bool = false,
    modifier_base: bool = false,
    variation_base: bool = false,
    /// The code point's columns by `width.codepoint`, an ambiguous one
    /// counted narrow.
    width: u2 = 1,
    /// East_Asian_Width=Ambiguous.
    ambiguous: bool = false,
    _: u3 = 0,
};

/// What the line breaking rules (UAX #14) need of one code point, in one
/// lookup. Internal to xenoglyph; `lineBreak` gives the property itself.
pub const Line = packed struct(u16) {
    /// Line_Break as rule LB1 resolves it by default: AI, SG and XX to AL,
    /// SA to CM for a mark (Mn, Mc) and AL otherwise, CJ to NS.
    class: LineBreak = .alphabetic,
    /// General_Category Initial_Punctuation (Pi), which LB15a and LB19 read.
    initial: bool = false,
    /// General_Category Final_Punctuation (Pf), which LB15b and LB19 read.
    final: bool = false,
    /// East_Asian_Width Fullwidth, Wide or Halfwidth: LB19a's and LB30's
    /// East Asian.
    east_asian: bool = false,
    /// Extended_Pictographic and unassigned, which LB30b reads.
    pictographic_unassigned: bool = false,
    /// U+25CC DOTTED CIRCLE, which LB28a reads as a base.
    dotted_circle: bool = false,
    _: u5 = 0,
};

/// A run of code points in a generated pool.
pub const Mapping = packed struct(u32) {
    start: u16 = 0,
    len: u8 = 0,
    _: u8 = 0,
};

/// A code point's full decompositions (UAX #15): canonical, and
/// compatibility (canonical and compatibility mappings applied until none
/// applies). A code point with no compatibility mapping of its own still
/// has a compatibility decomposition where its canonical one reaches one.
/// An empty mapping is the code point itself.
pub const Decomposition = packed struct(u64) {
    canonical: Mapping = .{},
    compatibility: Mapping = .{},
};

/// The quick check properties of DerivedNormalizationProps.txt: whether a
/// code point can occur in a normalized text (Yes, the zero value), cannot
/// (No), or can depending on what precedes it (Maybe).
pub const QuickCheck = packed struct(u8) {
    nfd_no: bool = false,
    nfkd_no: bool = false,
    nfc_no: bool = false,
    nfc_maybe: bool = false,
    nfkc_no: bool = false,
    nfkc_maybe: bool = false,
    /// Changes_When_NFKC_Casefolded: NFKC_Casefold maps the code point to
    /// something else.
    nfkc_casefold_changes: bool = false,
    _: u1 = 0,
};

/// A code point's simple case mappings as differences from it, and what the
/// casing rules read of it.
pub const Case = packed struct(u128) {
    lower: i24 = 0,
    upper: i24 = 0,
    title: i24 = 0,
    /// Simple case folding (CaseFolding.txt C and S).
    fold: i24 = 0,
    /// A full mapping of SpecialCasing.txt or CaseFolding.txt (F) differs
    /// from the simple one: look it up in the special list.
    special: bool = false,
    cased: bool = false,
    case_ignorable: bool = false,
    soft_dotted: bool = false,
    _: u28 = 0,
};

/// The full mappings of a code point whose `Case.special` is set; an empty
/// mapping is the simple one.
pub const Special = packed struct(u128) {
    lower: Mapping = .{},
    upper: Mapping = .{},
    title: Mapping = .{},
    fold: Mapping = .{},
};

/// Bidi_Class (UAX #9).
pub const BidiClass = enum(u5) {
    left_to_right,
    right_to_left,
    arabic_letter,
    european_number,
    european_separator,
    european_terminator,
    arabic_number,
    common_separator,
    nonspacing_mark,
    boundary_neutral,
    paragraph_separator,
    segment_separator,
    white_space,
    other_neutral,
    left_to_right_embedding,
    left_to_right_override,
    right_to_left_embedding,
    right_to_left_override,
    pop_directional_format,
    left_to_right_isolate,
    right_to_left_isolate,
    first_strong_isolate,
    pop_directional_isolate,
};

/// Joining_Type (ArabicShaping.txt, as DerivedJoiningType.txt gives it).
pub const JoiningType = enum(u3) {
    non_joining,
    join_causing,
    dual_joining,
    left_joining,
    right_joining,
    transparent,
};

/// A code point's status in the IDNA Mapping Table (UTS #46 §5).
pub const IdnaStatus = enum(u3) {
    valid,
    ignored,
    mapped,
    deviation,
    disallowed,
};

/// What IDNA processing (UTS #46) reads of a code point: its status, and
/// the properties the CheckBidi (RFC 5893) and CheckJoiners (RFC 5892
/// Appendix A) rules read. A mapped or deviation code point's mapping is in
/// the IDNA table's list of mappings.
pub const Idna = packed struct(u16) {
    status: IdnaStatus = .valid,
    bidi: BidiClass = .left_to_right,
    joining: JoiningType = .non_joining,
    /// Canonical_Combining_Class=Virama (9).
    virama: bool = false,
    /// General_Category=Mark.
    mark: bool = false,
    _: u3 = 0,
};
