# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
