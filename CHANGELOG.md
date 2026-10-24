# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
