# Architecture

xenoglyph is Unicode text for Zig: segmentation, line breaking, bidirectional text, normalization, case, width,
collation, IDNA and UTS #39 security, and the WHATWG legacy encodings. The README's Design section says what each
part does; this page holds how it is built and why. Change it with the code.

## Package rules

- Nothing allocates and nothing holds global state: a call that needs room takes the caller's buffers (bidi's
  `Buffers`, security's skeleton buffers), and output goes to a `std.Io.Writer`.
- Every call builds for wasm32-freestanding.
- One set of offsets: positions are byte offsets into the caller's UTF-8 (`Bytes`, an aegis domain) and ranges are
  `Span`s, so clusters, line breaks, bidi levels and words index the same text the same way.
- One table format. `tools/generate.zig` (and `tools/collation.zig`) write every table in `src/data/` from the files in
  `ucd/` as tries or sorted lists, and `bay test` fails unless regenerating reproduces them byte for byte.
- Each algorithm runs its standard's own conformance files in full, and where a reference implementation exists
  (ICU4C, encoding_rs) its outputs are checked in as digests the suite rebuilds and compares, never as vendored
  results. A difference that is the reference's own choice is written down beside the harness, not copied.

## Bidirectional text (UAX #9)

Shaped for a layout engine: `bidi.Paragraph.resolve(text, start, options, buffers)` resolves one paragraph through
its separator (P1) and the caller loops; `levels` holds one level per byte (every byte of a code point the same), so
any offset the other parts give indexes it; `paragraph.line(span, runs)` applies L1 to the line the engine chose and
L2 into visual runs, and `Line.visual()` gives code points in visual order. `mirror` and `pairedBracket` are lookups;
L3 is not applied (optional, and the shaper orders marks).

- The rules run over units: a run of code points of one class is one unit, its first byte holding the class; ES,
  CS, B, S, paired brackets, isolate controls and X9's removed controls stand alone. Each unit links to the next
  through its slot (initiators to their PDIs, openers to their closers), so isolating run sequences are followed
  without searching. An all-left-to-right paragraph skips the rules.
- Fixed stacks: 125 levels for X1–X8, 63 brackets for BD16.
- One engine for text and for a list of classes (`resolveClasses`), so BidiTest.txt and BidiCharacterTest.txt
  both run in full.
- L1 finds separators by their bytes and reads back over the whitespace before them, so a line is not decoded.

## Encodings (WHATWG Encoding Standard, and CP437)

`Decoder.init(encoding, options)` and `Encoder.init(encoding, options)` stream: `decode(input, last, writer)` and
`encode(input, last, writer)` keep the standard's state between pieces. BOM handling is an option (`.sniff`,
`.utf_8`, `.none`: the standard's "decode", "UTF-8 decode", "decode without BOM"). Errors: decoding `.replacement` or
`.fatal` (`Decoder.consumed` says how far it read); encoding `.html` or `.fatal` (`Encoder.unmappable`). `labels()`
lists the standard's labels, so a consumer keeps no second table.

- A decoder puts bytes back through the standard's "prepend" (a stack of 8), so the code follows the standard's
  steps. Without pending state it reads each whole sequence at once and falls back to the steps only at an error, a
  split sequence or an escape; ASCII runs go sixteen bytes at a time.
- Tables: decode arrays by pointer; encode tries from code point to pointer (one jis0208 trie serves EUC-JP,
  ISO-2022-JP and Shift_JIS); Big5 decodes from u16 and a plane-2 bit. Each encoding links only its own tables.
- CP437 (zip names) has no label in the standard: `.cp437` by value, all 256 bytes both ways.
- UTF-8 decoding is `utf8.decode` (maximal subparts) everywhere.

## Collation (UTS #10, CLDR root)

`compare(a, b, options)` re-reads the texts once per level and stops at the first level that decides, with no
buffers; `sortKey(text, writer, options)` writes bytes that compare as the strings do. Options: strength, alternate
(non-ignorable or shifted), case level and case first, numeric.

- Data: CLDR's allkeys_CLDR.txt and DUCET's implicit weights, one 32-bit element inline per code point where it has
  one, or a run in a shared array (expansions, contraction starters); implicit weights as UTS #10 computes them, so
  Han sorts by the implicit order CLDR's tests use (ICU's radical-stroke order is its own choice).
- Input is always taken through NFD (`normalize.Iterator(.nfd)`): one path. An FCD shortcut is a speed question.
- Discontiguous contractions look through 32 non-starters, normalization's run buffer.
- Numeric: a number carries the primary just below the digit zero's, its digit count, then digit pairs, so numbers
  sort after everything below the digits and before what only carries a digit's primary, as ICU orders them.
- Not built: tailorings and backwards secondary (only French Canadian tailoring needs it).

## Security (UTS #39)

`skeleton(text, writer, options, buffers)` with a `Direction` (`.ltr`, the standard's skeleton; `.rtl`;
`.first_strong`; `.logical`, the internal skeleton), `confusable(a, b, ...)` → single, mixed or whole-script,
`resolvedScripts`, `restrictionLevel`, `identifierStatus`/`identifierType`, and `check(text, allowed)` → `Failures`
by name. `check` runs every check in one pass and the caller reads the ones it wants, rather than choosing checks by
flags.

- The skeleton is four iterator steps (display order, decompose and order, drop default ignorables and map, order
  again), allocating nothing; display order uses `bidi` only where it can differ from logical order.
- A profile is tested per NFC segment with canonical equivalence (the segment's code points or its NFD's), which
  matches ICU where a whole-string NFC-or-NFD test refused mixed cases.
- Not built: the whole-script confusable test of one string, CLDR exemplar characters, UAX #31 identifier syntax.

## Normalization and case

NFC, NFD, NFKC, NFKD, NFKC_Casefold and NFKC_Simple_Casefold go through one iterator path. NFKC_SCF shares
NFKC_Casefold's mapping pool with an index of its own. It is not closed under NFD, so its mapping is applied to the
text's code points as they are and composed after, and its quick check answers `maybe` where a mapping can write the
code point (U+0345).

## Scope

The README's Scope lists what xenoglyph leaves out: tailorings and locale data, dictionary segmentation, shaping and
rendering (widths are a monospace terminal's cells), identifier syntax, and the deprecated or optional parts of the
standards.
