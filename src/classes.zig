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
