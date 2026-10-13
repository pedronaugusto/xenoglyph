# xenoglyph

xenoglyph handles Unicode text in Zig: grapheme clusters, words and sentences
(UAX #29), how many terminal cells text takes, and the character properties
those rest on, from the Unicode Character Database 18.0.0. Nothing in it
allocates, nothing holds global state, and every call builds for a target with
no operating system.

Work in progress. Line breaking (UAX #14), normalization (UAX #15) and case
mapping are not here yet; see [Scope](#scope).

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/xenoglyph`, then obtain the `xenoglyph`
module through `b.dependency` and add it to your executable's imports.
xenoglyph has no dependencies: a project that depends on it fetches it alone,
and builds no generator and reads no Unicode data files. The tables are Zig
source in the package.

## Usage

Grapheme clusters are what a reader takes for one character, and what a
cursor, a selection or a terminal cell holds:

<!-- BEGIN GENERATED zig build docs -- usage -->
```zig
const xenoglyph = @import("xenoglyph");

// A family emoji, a flag, a decomposed é and a Devanagari conjunct:
// four clusters, whatever their code points.
const text = "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467} \u{1f1e8}\u{1f1ed} e\u{301} \u{915}\u{94d}\u{937}";
var clusters = xenoglyph.graphemes(text);
var count: usize = 0;
while (clusters.next()) |cluster| {
    // Each cluster is a slice of `text`; nothing was allocated.
    if (!std.mem.eql(u8, cluster, " ")) count += 1;
}
std.debug.assert(count == 4);
// Terminal columns: each of the four is 2, 2, 1 and 2, and a space 1.
std.debug.assert(xenoglyph.width.string(text, .{}) == 10);
```
<!-- END GENERATED -->

Words and sentences:

<!-- BEGIN GENERATED zig build docs -- words -->
```zig
const xenoglyph = @import("xenoglyph");

var it = xenoglyph.words("Can't stop: 3.14 is \u{3c0}!");
var found: [5][]const u8 = undefined;
var n: usize = 0;
while (it.next()) |segment| {
    // Segments include the spaces and punctuation between words.
    if (xenoglyph.word.isWordLike(segment)) {
        found[n] = segment;
        n += 1;
    }
}
std.debug.assert(n == 5);
std.debug.assert(std.mem.eql(u8, found[0], "Can't"));
std.debug.assert(std.mem.eql(u8, found[2], "3.14"));
var sentences = xenoglyph.sentences("It works. Mr. Smith agrees? Yes.");
std.debug.assert(std.mem.eql(u8, sentences.next().?, "It works. "));
```
<!-- END GENERATED -->

Properties are one lookup each:

<!-- BEGIN GENERATED zig build docs -- properties -->
```zig
const xenoglyph = @import("xenoglyph");

std.debug.assert(xenoglyph.generalCategory('A') == .uppercase_letter);
std.debug.assert(xenoglyph.script(0x3b1) == .greek);
std.debug.assert(xenoglyph.eastAsianWidth(0x3042) == .wide);
std.debug.assert(xenoglyph.emoji(0x1f600).presentation);
std.debug.assert(xenoglyph.core(0x5f).xid_continue);
std.debug.assert(xenoglyph.lineBreak(' ') == .space);
// Code points shared by scripts list them all.
std.debug.assert(xenoglyph.scriptExtensions(0x0964).len > 1);
```
<!-- END GENERATED -->

A `Breaker` takes code points one at a time, for text that arrives in pieces:

<!-- BEGIN GENERATED zig build docs -- stream -->
```zig
const xenoglyph = @import("xenoglyph");

// Code points arriving one at a time, as a terminal receives them:
// `next` says whether each starts a cluster.
var breaker: xenoglyph.grapheme.Breaker(.terminal) = .{};
std.debug.assert(breaker.next(0x1f44d)); // thumbs up starts one
std.debug.assert(!breaker.next(0x1f3fd)); // its skin tone joins it
std.debug.assert(breaker.next('a'));
std.debug.assert(breaker.next(0x1f3fd)); // a skin tone after a letter stands alone
```
<!-- END GENERATED -->

## Design

### Segmentation

Grapheme clusters follow UAX #29's extended rules GB1 to GB999 for Unicode
18.0.0, Indic conjuncts (GB9c, as Unicode 18 changed it: a linker no longer
needs a consonant before it) and emoji ZWJ sequences (GB11) included. Two
tailorings are fields of `grapheme.Rules`, both off by default:

| Field | Default (UAX #29) | Tailoring |
|---|---|---|
| `controls` | `.separate`: a control, CR or LF is a cluster of its own (GB3 to GB5) | `.as_other`: they read as Other, for text whose controls the caller has acted on, as a terminal does before printing |
| `modifiers` | `.extend`: an emoji modifier joins whatever is before it | `.after_base`: a skin tone joins only an Emoji_Modifier_Base it directly follows, and otherwise stands alone, as UTS #51 shows it |

`Rules.terminal` sets both. The rules as UAX #29 states them are code in
`grapheme.zig`, and at compile time they are run over every context they can
reach from the start of a text to build a state machine: a state per context
(the previous code point's class, the parity of a run of regional indicators,
an emoji ZWJ sequence or an Indic linker in progress), a column per kind of
code point. Segmenting is then a table read per code point, and a `Breaker`
is one byte of state. Between two ASCII bytes there is always a boundary but
in CR LF, and the iterator takes that without the tables.

Words and sentences follow the default rules WB1 to WB999 and SB1 to SB998,
with no tailoring; `word.isWordLike` tells a word from the space or
punctuation between words. The rules that look past the boundary they decide
(WB6, WB7b, WB12, and SB8, which can look far ahead for a lowercase letter)
read ahead at most to the next character that decides them, and SB8's answer
is kept for every position it covers, so every pass is linear in the text.
For each pair of word classes, whether the answer can depend on more context
is worked out at compile time; most pairs are a table read.

The default rules do not keep every word and sentence boundary on a cluster
boundary: a word boundary falls inside a cluster after a Prepend (`U+0600`), before
a spacing mark that is not Word_Break Extend (`a` `U+0E33`), and before a consonant
a lone Indic linker joins (`U+094D U+0915`); a sentence boundary falls before a skin
tone after a full stop. xenoglyph keeps to the rules.

Text is any bytes. Each maximal subpart of an ill-formed UTF-8 sequence reads as
one U+FFFD and takes only its own bytes, as the Unicode Standard recommends
(chapter 3.9), so a stray byte never swallows the character after it.

### Width

Unicode defines no cell width; terminals do. `width` states its model as rules.
A code point's columns (`width.codepoint`):

1. 0 for a control, a surrogate, and the line and paragraph separators.
2. 1 for U+00AD SOFT HYPHEN, which terminals draw.
3. 0 for every other Default_Ignorable_Code_Point: joiners, variation
   selectors, tags, the Hangul fillers, invisible format characters.
4. 0 for a nonspacing or enclosing mark.
5. 0 for a Hangul medial vowel or final consonant (Grapheme_Cluster_Break V
   or T).
6. 2 for East_Asian_Width Wide or Fullwidth, which includes the emoji with
   emoji presentation.
7. 2 for a regional indicator.
8. 1 for everything else. East_Asian_Width Ambiguous is 1, or 2 with
   `.ambiguous = .wide`, as terminals in East Asian locales count it.

A grapheme cluster's columns (`width.cluster`) are 0, 1 or 2: its first code
point's, then for each code point after it, U+FE0F after a code point that has
emoji variation sequences makes it 2 and U+FE0E makes it 1 (after anything
else a selector changes nothing); an emoji modifier makes it 2, since a
modifier sequence has emoji presentation; any other code point with columns
of its own (a spacing mark, a second leading jamo, the emoji after a ZWJ)
makes it 2. A string's columns (`width.string`) are the sum of its clusters',
cut with `.after_base` modifiers, so a skin tone after a letter is a 2-column
swatch of its own. `.method = .codepoint` sums code points instead, as a
terminal that measures by code point (`wcwidth`) does. Two-em and three-em
dashes are 1, as East_Asian_Width has them; xenoglyph adds no exception to the
rules above beyond the soft hyphen.

### Tables

`tools/generate.zig` reads the UCD files in `ucd/` and writes the tables in
`src/data/` as Zig source, formatted as `zig fmt` would. Each table is a trie
over all 1,114,112 code points in which equal blocks are stored once; the
generator tries every block size, with two stages or three, and keeps the
smallest. The one table segmentation and width read on every code point stays
two stages, and its entries index 39 distinct records that hold everything
both need. The tables are committed: a project that depends on xenoglyph
compiles them and fetches nothing else. `bay generate` writes them again, and
`bay test` fails unless regenerating from `ucd/` reproduces them byte for byte.
The UCD files are in the repository and outside what the package ships.

| Table | Bytes |
|---|---|
| Cluster records (grapheme break, Indic conjunct break, emoji flags, width) | 34,126 |
| General_Category | 20,496 |
| Script | 20,704 |
| Script_Extensions | 4,016 |
| Derived core properties | 20,404 |
| Line_Break | 19,136 |
| Sentence_Break | 16,736 |
| Word_Break | 13,520 |
| East_Asian_Width | 5,248 |
| Emoji properties | 3,944 |

A program links only the tables it reads: segmenting and measuring graphemes
costs the first, 34 KB.

## API

| Call | Does |
|---|---|
| `graphemes(text)`, `grapheme.Iterator(rules)` | The clusters of a string: `next()` a slice, `nextSpan()` a byte range |
| `grapheme.Breaker(rules)` | `next(cp)`: whether a code point starts a cluster, for text that arrives a code point at a time |
| `grapheme.count(text, rules)` | How many clusters a string holds |
| `words(text)`, `word.isWordLike(segment)` | Words and the runs between them; whether a segment is a word |
| `sentences(text)` | Sentences |
| `width.string(text, options)` | A string's terminal columns |
| `width.cluster(bytes, options)` | One cluster's columns, 0 to 2 |
| `width.codepoint(cp, options)` | One code point's columns, 0 to 2 |
| `generalCategory`, `script`, `scriptExtensions`, `eastAsianWidth` | General_Category, Script, Script_Extensions (sorted), East_Asian_Width |
| `graphemeBreak`, `indicConjunctBreak`, `wordBreak`, `sentenceBreak`, `lineBreak` | The break classes of UAX #29 and UAX #14 |
| `emoji(cp)` | Emoji, Emoji_Presentation, Emoji_Modifier, Emoji_Modifier_Base, Emoji_Component, Extended_Pictographic, and whether it has emoji variation sequences |
| `core(cp)` | The binary properties of DerivedCoreProperties.txt: Alphabetic, Lowercase, Uppercase, Cased, Case_Ignorable, the Changes_When properties, ID_Start, ID_Continue, XID_Start, XID_Continue, Default_Ignorable_Code_Point, Grapheme_Base, Grapheme_Extend, Math |
| `utf8.decode`, `utf8.Iterator` | Code points of any bytes, ill-formed subparts as U+FFFD |

Each enumerated value is named for the UCD's long name in snake case
(`GeneralCategory.uppercase_letter`, `WordBreak.a_letter`, `Script.old_italic`),
and `Script.code()` gives its ISO 15924 code. A value above U+10FFFF gets each
property's default, as an unassigned code point does.

## Scope

- Steps still to come: line breaking (UAX #14, of which `lineBreak` is the
  class), normalization (NFC, NFD, NFKC, NFKD) and case mapping and folding.
- No tailoring of words or sentences, no dictionary segmentation for Thai,
  Lao, Khmer, Myanmar, Chinese or Japanese, and no locale data.
- No bidirectional text, shaping or rendering: widths are the cells a
  monospace terminal gives text, not glyph metrics.
- Iteration is forward only; a caller that needs a boundary before a position
  starts from a known boundary before it.
- No Grapheme_Link (deprecated), and no PropList properties beyond what the
  segmentation rules derive from.

## Platforms

Every call works on every target Zig supports, with the same results, and
needs no operating system or allocator: `zig build check-freestanding` builds
them all for wasm32-freestanding.

## Built with

- [Zig](https://ziglang.org) 0.17.0 and its standard library; nothing is linked.
- The [Unicode Character Database](https://www.unicode.org/ucd/) 18.0.0, whose
  data are under the Unicode License v3.
- [bay](https://github.com/pedronaugusto/bay) runs xenoglyph's development.
  [preflight](https://github.com/pedronaugusto/preflight) (the source checks,
  the tests and CI) and [shakedown](https://github.com/pedronaugusto/shakedown)
  (the property tests and the benchmark runner) are dev dependencies through
  bay, which a project that depends on xenoglyph never sees.

## Testing

`bay test` runs the suite, the usage example and the table check. Unicode's
own conformance files pass in full: all 853 lines of GraphemeBreakTest.txt,
1,944 of WordBreakTest.txt and 512 of SentenceBreakTest.txt, through the
iterators and, for graphemes, a code point at a time through a `Breaker` too.
With `.after_base` modifiers every line holds
with a boundary added before a skin tone that follows no modifier base, and with
`.as_other` controls every line that has no control, CR or LF holds unchanged. Every one of the 5,244 sequences of emoji-test.txt is one
cluster under both modifier rules, and each of the 3,972 fully-qualified ones
and components is 2 columns.

Every table is checked against the UCD file it comes from for every code
point, parsed again in the test apart from the generator, and the code point
widths are derived from the raw properties by the rules above and compared for
every code point. Properties through shakedown run on generated text that mixes
the code points the rules treat specially with arbitrary bytes: graphemes,
words and sentences must be what a second implementation that decides each
position from the whole text by the rules in order finds; segments cover the
text and fall on code point boundaries; a string's width is the sum of its
clusters'; and decoding agrees with std on well-formed UTF-8 and takes the
maximal subpart, by its definition, of everything else. They run on seeded
inputs in every `bay test`, and under `bay test --fuzz` they search further.
Nothing here can allocate: no call takes an allocator.

`bay bench` times segmentation and width over 64 KiB texts of ASCII, accented
Latin, CJK, Devanagari, emoji and a mix, in ReleaseFast. Run from
`zig-out/bench`, `segment` and `width` print shakedown's JSON lines. `bay test`
runs each row once with `--smoke`; CI times nothing.

## Licence

MIT. See [LICENSE](LICENSE). The Unicode data the tables are generated from are
under the [Unicode License v3](src/UNICODE-LICENSE.txt), a copy of which is
beside the tables and beside the data files in `ucd/`.
