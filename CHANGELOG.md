# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking

- `encoding.Decoder`'s ISO-2022-JP state is aegis's `state.Machine`, every transition the standard's decoder takes declared: the fields `iso_state` and `iso_output_state` (an `Iso2022`) are `iso` (the machine's runtime) and `iso_output_state` (the event back to the output state). They are the decoder's own state, which no caller sets.

### Added

- `security`: UTS #39, Unicode Security Mechanisms, for Unicode 18.0.0, as ICU's spoof checker. `security.skeleton(text, writer, options, buffers)` and the iterator `security.Skeleton`: a text's skeleton, as shown left to right (UTS #39's `skeleton`), right to left, by its first strong character, or in logical order (internalSkeleton), with `security.Direction`, `security.Options` and `security.Buffers`; nothing allocated. `security.confusable(a, b, options, buffers)` and `security.Confusability`: single-, mixed- or whole-script confusables. `security.resolvedScripts(text)`, `security.ScriptSet` and `security.WritingSystem`: augmented and resolved script sets with Hanb, Hntl, Jpan and Kore. `security.restrictionLevel(text)` and `security.RestrictionLevel` with the General Security Profile. `security.check(text, allowed)` and `security.Failures`: characters outside the profile, restriction level, mixed numbers, repeated nonspacing marks, runs of more than four, hidden overlays. `security.identifierStatus(cp)`, `security.identifierType(cp)`, `security.IdentifierStatus`, `security.IdentifierType`. Tables generated from confusables.txt, IdentifierType.txt and IdentifierStatus.txt; UTS #39's examples pass, and skeletons, confusables, restriction levels and checks match ICU4C 78's spoof checker.
- `case.softDotted(cp)`: Soft_Dotted.
- `collation`: the Unicode Collation Algorithm (UTS #10) with CLDR's root collation (CLDR 49, UCA 18.0.0). `collation.compare` orders two texts and `collation.sortKey` writes bytes that order as their texts do; neither allocates. `collation.Options`: `strength` (primary to identical), `alternate` (non-ignorable or shifted, CLDR's variable top), `case_first`, `case_level`, `numeric`; `collation.Strength`. Input in any normalization form; contractions contiguous and discontiguous; implicit weights for Han, Tangut, Nushu, Khitan, Jurchen, Seal and unassigned code points. CLDR's CollationTest_CLDR_NON_IGNORABLE.txt and _SHIFTED.txt pass in full, and every combination of the options orders generated text as ICU4C 78's root collator does.

### Changed

- Development: preflight 0.18.0, with the aegis pack's rules A001-A021 at gate. The generator reads files with aegis's `own.readFile`, and `bidi`'s bracket stack is aegis's `bounded.Array`.
- Pins aegis 0.1.18.
- Development: `bench/security.zig`, UTS #39's rows: skeletons left to right and right to left, confusables (with the next identifier, and with itself), restriction levels and checks, in four scripts.
- Development: `bench/collation.zig`, collation's rows: names sorted and given sort keys in six languages, under shifted and numeric, and a comparison that reads every level to its end.
- Development: the rivals' harnesses (SheenBidi and ICU for bidi, encoding_rs for the encodings) are out of the repository; `bench/` holds xenoglyph's own rows only.

## [0.4.3] - 2026-10-25

### Added

- `bidi`: the Unicode Bidirectional Algorithm (UAX #9) for a layout engine. `bidi.Paragraph.resolve` resolves a paragraph's embedding levels, given or auto-detected direction, into a level for every byte of the caller's UTF-8 text; `Paragraph.runs` gives its level runs, and `Paragraph.line` reorders a line the engine has broken (L1 per line, then L2) into runs in visual order, whose `visual()` gives each code point's offset in display order. Every offset is a byte offset into the text, as `lines` and `graphemes` give them; nothing is allocated: the caller gives a level and a 4-byte slot a byte. `bidi.mirror` (Bidi_Mirroring_Glyph) and `bidi.pairedBracket` (Bidi_Paired_Bracket and its type), from BidiMirroring.txt and BidiBrackets.txt. `bidi.resolveClasses` and `bidi.reorderClasses` run the same algorithm on classes alone. BidiTest.txt and BidiCharacterTest.txt pass in full.
- `encoding`: character encodings both ways, streaming, as the WHATWG Encoding Standard states them: UTF-8, its 28 single-byte encodings, GBK, gb18030, Big5, EUC-JP, ISO-2022-JP, Shift_JIS, EUC-KR, replacement, UTF-16BE/LE and x-user-defined, and IBM code page 437 for zip names. `encoding.Decoder` writes UTF-8 and `encoding.Encoder` reads it, each taking input in pieces and holding the standard's state between them; the standard's BOM sniffing ("decode", "UTF-8 decode", "decode without BOM") and error modes (replacement or fatal decoding, html or fatal encoding); `encoding.forLabel` (the standard's labels), `name`, `outputEncoding`. Tables generated from the standard's index files and CP437.TXT; encoding_rs's vectors pass byte for byte both ways, and every encoding matches encoding_rs 0.8.42 over every input of one and two bytes and every scalar value.
- `utf8.wellFormed`: how many bytes a string starts with that are well-formed UTF-8, sixteen bytes at a time.

## [0.4.2] - 2026-10-24

### Changed

- Development: the lint gates glint's A005 as well (the aegis pack's five rules at gate).
- Development: `bay ucd` writes the tables from `ucd/`, where `bay generate` did: `generate` is preflight's step, which makes the CI caller for the package's pins, and a package step of that name ran in its place.
- Pins aegis 0.1.17.

## [0.4.1] - 2026-10-14

### Changed

- Pins aegis 0.1.8.

## [0.4.0] - 2026-10-14

### Added

- `idna`: internationalized domain names as UTS #46 processes them, with Nontransitional Processing. `toAscii` gives the name DNS looks up and `toUnicode` the name to show; each maps through the IDNA Mapping Table, normalizes to NFC, decodes `xn--` labels and checks every label (STD3 rules, hyphens, a leading combining mark, the Bidi rule of RFC 5893, the ContextJ rules of RFC 5892, DNS lengths), and returns `Failures` by name. `Options` defaults to UTS #46's strict settings; `Options.url` is the URL Standard's. All 6,396 test lines of IdnaTestV2.txt pass.
- `punycode`: RFC 3492's `encode` and `decode`.
- `bidiClass` and `joiningType`: Bidi_Class, with the defaults DerivedBidiClass.txt gives unassigned code points, and Joining_Type.

## [0.3.1] - 2026-10-14

### Changed

- Pins aegis 0.1.6.

## [0.3.0] - 2026-10-13

### Breaking

- `case.equalFold(a, b, options)` is `case.equal(.default, a, b, options)`:
  `case.equal` takes a `case.Match`, one of the caseless matches of the Unicode
  Standard's chapter 3.13.
- `normalize.Form` has a fifth value, `.nfkc_casefold`, so an exhaustive switch
  over it needs a case for it.

### Added

- Grapheme clusters backward: `grapheme.Iterator.prev` and `prevSpan` step back a
  cluster from any boundary, `Iterator.initAt` starts at any boundary,
  `grapheme.boundaryBefore` gives the last boundary before any byte offset and
  `grapheme.boundaryAfter` the end of the cluster that starts at a boundary,
  under both tailorings and with no allocation. The text before is read only as
  far back as the rule that decides a position needs (GB9c, GB11, GB12 and GB13
  included), never from the start of the text.
- NFKC_Casefold: `normalize.Form.nfkc_casefold` is toNFKC_Casefold, through
  `write`, `Iterator`, `isNormalized`, `quickCheck`, `equal` and `decompose`,
  generated from DerivedNormalizationProps.txt.
- Caseless matching: `case.equal` with `.default` (D144), `.canonical` (D145,
  canonical caseless match) and `.identifier` (D147, identifier caseless match,
  through NFKC_Casefold).

## [0.2.0] - 2026-10-13

### Breaking

- Byte offsets and lengths, terminal columns and cluster counts are distinct aegis
  domains: `Span.start` and `Span.end` are `Bytes` (`aegis.units.Bytes(usize)`),
  `width.codepoint`, `width.cluster` and `width.string` return `Columns`, and
  `grapheme.count` returns `Clusters`; read a number with `.raw()`. `Span.len`
  returns `Bytes`. `word.boundaryAfter` and `sentence.boundaryAfter` take and
  return `Bytes`. The iterators' `index` fields are private; `offset()` returns
  where the next segment starts.

### Added

- `Span.of(text)`, the part of a text a span covers, and `Span.fromRaw`.

### Changed

- Depends on aegis 0.1.3, std only. A generated table entry is checked against
  its property's values in every build mode, as are the narrowings in case
  mapping and decomposition.
- The source checks gate glint's aegis rules A001 to A004.
- The release tier runs preflight's hardened profile: the suite with safety on,
  a bounded fuzz campaign over its properties, and ThreadSanitizer on Linux. `bay
  unit` runs the suite alone.

## [0.1.1] - 2026-10-13

### Added

- Line break opportunities (UAX #14) of Unicode 18.0.0: `lines`, `line.Iterator`,
  whose `nextBreak` says where a break is mandatory.
- Normalization (UAX #15): `normalize.write`, `normalize.Iterator`,
  `isNormalized`, `quickCheck`, `equal`, `combiningClass`, `decompose` and `compose`,
  for NFD, NFC, NFKD and NFKC, exact for any input with no allocation.
- Case mapping and folding: `case.write`, `case.Iterator` and `case.equalFold` for
  lowercase, uppercase, titlecase and full folding, with Final_Sigma and the
  Lithuanian and Turkic tailorings; `simpleLower`, `simpleUpper`, `simpleTitle`
  and `simpleFold`.

### Fixed

- The table generator builds for the host's baseline CPU, so CI, which runs a
  binary built on one runner on another, can run the table check on any runner.

## [0.1.0] - 2026-10-13

### Added

- Grapheme clusters (UAX #29) of Unicode 18.0.0, with GB9c's Indic conjuncts
  and GB11's emoji sequences: `graphemes`, `grapheme.Iterator`, `grapheme.count`,
  and `grapheme.Breaker` for code points that arrive one at a time. `Rules`
  tailors controls (`.as_other`) and emoji modifiers (`.after_base`, as UTS #51
  shows them); `Rules.terminal` sets both.
- Word and sentence boundaries (UAX #29): `words`, `word.isWordLike`, `sentences`.
- Terminal widths: `width.string`, `width.cluster` and `width.codepoint`, by
  cluster or by code point, with East_Asian_Width Ambiguous narrow or wide.
- Properties: `generalCategory`, `script`, `scriptExtensions`, `eastAsianWidth`,
  `graphemeBreak`, `indicConjunctBreak`, `wordBreak`, `sentenceBreak`, `lineBreak`,
  `emoji` and `core` (the binary properties of DerivedCoreProperties.txt).
- `utf8.decode` and `utf8.Iterator`, reading each maximal subpart of an
  ill-formed sequence as U+FFFD.
- The tables are generated from the Unicode Character Database 18.0.0 by
  `tools/generate.zig` and committed; `bay test` checks that regenerating
  reproduces them byte for byte.

[Unreleased]: https://github.com/pedronaugusto/xenoglyph/commits/main
