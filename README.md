# xenoglyph

xenoglyph handles Unicode text in Zig: grapheme clusters, forward and
backward, words and sentences (UAX #29), line break opportunities (UAX #14),
normalization (UAX #15) and NFKC_Casefold, case mapping, folding and caseless
matching, how many terminal cells text takes, internationalized domain names
(UTS #46) and Punycode, bidirectional text (UAX #9) for layout, and the
character properties those rest on, from the
Unicode Character Database 18.0.0. Nothing in it
allocates, nothing holds global state, and every call builds for a target with
no operating system.

Work in progress.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/xenoglyph`, then obtain the `xenoglyph`
module through `b.dependency` and add it to your executable's imports.
xenoglyph depends on the std-only [aegis](https://github.com/pedronaugusto/aegis)
safety library, and on nothing else: a project that depends on it builds no
generator and reads no Unicode data files. The tables are Zig source in the
package.

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
std.debug.assert(xenoglyph.width.string(text, .{}).eql(.fromRaw(10)));
```
<!-- END GENERATED -->

A cursor steps a cluster at a time either way, from any boundary:

<!-- BEGIN GENERATED zig build docs -- cursor -->
```zig
const xenoglyph = @import("xenoglyph");

// A cursor at the end of "e" and a combining acute, a flag and "x".
const text = "e\u{301}\u{1f1e8}\u{1f1ed}x";
var at: xenoglyph.Bytes = .fromRaw(text.len);
// Left a cluster at a time: the text before is read only as far as the
// rules need, never from the start of the text.
at = xenoglyph.grapheme.boundaryBefore(text, at, .{});
std.debug.assert(at.eql(.fromRaw(11)));
at = xenoglyph.grapheme.boundaryBefore(text, at, .{});
std.debug.assert(at.eql(.fromRaw(3)));
// Right again.
std.debug.assert(xenoglyph.grapheme.boundaryAfter(text, at, .{}).eql(.fromRaw(11)));
// An iterator steps both ways from any boundary.
var it: xenoglyph.grapheme.Iterator(.{}) = .initAt(text, .fromRaw(text.len));
std.debug.assert(std.mem.eql(u8, it.prev().?, "x"));
std.debug.assert(std.mem.eql(u8, it.prev().?, "\u{1f1e8}\u{1f1ed}"));
std.debug.assert(std.mem.eql(u8, it.next().?, "\u{1f1e8}\u{1f1ed}"));
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

Line break opportunities, for wrapping:

<!-- BEGIN GENERATED zig build docs -- lines -->
```zig
const xenoglyph = @import("xenoglyph");

// Where a line may break, and where it must.
const text = "A (quick) test\u{2014}costs $12.50.\nNext";
var it = xenoglyph.lines(text);
// A bracket stays with its word, a dash breaks on either side, a price
// holds together, and the line feed ends a line whatever the width.
for ([_][]const u8{ "A ", "(quick) ", "test", "\u{2014}", "costs ", "$12.50.\n" }) |want| {
    const b = it.nextBreak().?;
    std.debug.assert(std.mem.eql(u8, b.span.of(text), want));
    std.debug.assert(b.mandatory == (want[want.len - 1] == '\n'));
}
```
<!-- END GENERATED -->

Normal forms and case, written to any `std.Io.Writer`, and caseless matching:

<!-- BEGIN GENERATED zig build docs -- transform -->
```zig
const xenoglyph = @import("xenoglyph");

var out: [64]u8 = undefined;
var w: std.Io.Writer = .fixed(&out);
// "e" and a combining acute compose to "é"; "ﬁ" stays, as it is canonical.
try xenoglyph.normalize.write(.nfc, "cafe\u{301} \u{fb01}", &w);
std.debug.assert(std.mem.eql(u8, w.buffered(), "caf\u{e9} \u{fb01}"));
std.debug.assert(xenoglyph.normalize.equal(.nfkc, "\u{fb01}", "fi"));
w = .fixed(&out);
try xenoglyph.case.write(.upper, "stra\u{df}e", &w, .{});
std.debug.assert(std.mem.eql(u8, w.buffered(), "STRASSE"));
std.debug.assert(xenoglyph.case.equal(.default, "Ma\u{df}e", "MASSE", .{}));
// Canonical caseless match normalizes too; identifier caseless match
// uses NFKC_Casefold, which also drops default ignorables (a soft hyphen).
std.debug.assert(xenoglyph.case.equal(.canonical, "\u{212b}NGSTR\u{f6}M", "a\u{30a}ngstro\u{308}m", .{}));
std.debug.assert(xenoglyph.case.equal(.identifier, "\u{2167}_val\u{ad}ue", "viii_VALUE", .{}));
w = .fixed(&out);
try xenoglyph.normalize.write(.nfkc_casefold, "\u{fb01}LE\u{2460}", &w);
std.debug.assert(std.mem.eql(u8, w.buffered(), "file1"));
w = .fixed(&out);
try xenoglyph.case.write(.lower, "D\u{130}YARBAKIR", &w, .{ .language = .turkic });
std.debug.assert(std.mem.eql(u8, w.buffered(), "diyarbak\u{131}r"));
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

Bidirectional text, levels and runs for a layout engine, on the same byte
offsets:

<!-- BEGIN GENERATED zig build docs -- bidi -->
```zig
const xenoglyph = @import("xenoglyph");

// An English sentence holding a Hebrew word: one paragraph, auto-detected
// left to right. Levels and runs are on the text's own byte offsets.
const text = "Read \u{5e9}\u{5dc}\u{5d5}\u{5dd} (shalom) twice.";
var levels: [text.len]xenoglyph.bidi.Level = undefined;
var scratch: [text.len]xenoglyph.bidi.Scratch = undefined;
const paragraph: xenoglyph.bidi.Paragraph = .resolve(text, .fromRaw(0), .{}, .{ .levels = &levels, .scratch = &scratch });
std.debug.assert(paragraph.direction() == .ltr);
std.debug.assert(paragraph.levelAt(.fromRaw(5)) == 1); // the Hebrew word
// After choosing line breaks (here the whole paragraph is one line), each
// line is reordered: its runs in visual order, left to right.
var runs: [text.len]xenoglyph.bidi.Run = undefined;
const line = paragraph.line(paragraph.span, &runs);
std.debug.assert(line.runs.len == 3);
std.debug.assert(line.runs[1].direction() == .rtl);
std.debug.assert(std.mem.eql(u8, line.runs[1].span.of(text), "\u{5e9}\u{5dc}\u{5d5}\u{5dd}"));
// A right-to-left run shows its code points in reverse: the last letter
// of the word is drawn first. A bracket in one shows its mirror.
var visual = line.visual();
for (0..5) |_| _ = visual.next();
std.debug.assert(visual.next().?.eql(.fromRaw(11)));
std.debug.assert(xenoglyph.bidi.mirror('(').? == ')');
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

Backward (`grapheme.boundaryBefore`, `Iterator.prev`), each position is decided
from the text before it, read only as far back as the rule that decides it
needs, never from the start of the text. Most positions are decided by the
two code points beside them: for each pair of records, whether every state the
automaton can be in after the first agrees on the second is worked out at
compile time. Where they do not, the context is rebuilt from the run it
depends on and the same rules decide: GB9c reads back through InCB=Extend to an
InCB=Linker, GB11 through Extend before a ZWJ to an Extended_Pictographic, and
GB12 and GB13 count the run of regional indicators. The clusters after a
boundary are the same whatever came before it, so an iterator starts at any
boundary (`Iterator.initAt`) and `boundaryAfter` steps forward from one. An
iterator stepping back knows it stands on a boundary, which decides a run of
regional indicators it is inside without counting it again, so stepping back
over a whole text is linear. Decoding backward finds the same code points as
forward: a byte that is not a continuation byte always starts one, so the start
of the code point before an offset is at most four bytes back.

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

### Line breaking

Line break opportunities follow UAX #14's default rules LB1 to LB31 for Unicode
18.0.0, with no tailoring, and with LB1's default resolution of the classes it
leaves open: AI, SG and XX are AL, SA is CM for a mark and AL otherwise, CJ is
NS. A segment ends where a line may break; `Break.mandatory` is set where it
ends with a hard line break (BK, CR, LF, NL). What the rules read behind a
position is carried forward as a few values (the last two items after LB9 joins
marks to their base, the last that is not a space and the one before it, a
number in progress, the parity of a run of regional indicators), and what they
read ahead, at most two items, is read only when a rule asks, so a pass is
linear. The iterator carries that context from one segment to the next, since
LB15a, LB19a, LB20a and LB21a read the item before a break. Fitting segments to
a width is the caller's: `width.string` measures each.

### Bidirectional text

`bidi` is UAX #9 for Unicode 18.0.0, shaped for a layout engine as ICU's ubidi
and SheenBidi are used: resolve a paragraph, let the engine choose its line
breaks, then reorder each line. `Paragraph.resolve(text, start, options,
buffers)` takes the paragraph that starts at `start` up to and including its
separator (P1; a CR LF pair is one), finds its direction from its first strong
character outside isolates when `options.direction` is `.auto` (P2, P3; HL1's
`fallback` when there is none), and resolves the level of every byte: rules X1
to X10, W1 to W7, N0 to N2, I1 and I2, as UAX #9 states them, with the
125-deep embedding stack and BD16's 63-deep bracket stack. Brackets match up to
canonical equivalence (U+2329 pairs with U+3009). Each byte of a code point
has its code point's level, and a character X9 removes (BN, the embedding and
override controls) the level before it. `Paragraph.line(span, buffer)` takes a
line within the paragraph, applies L1 to it alone (segment and paragraph
separators, and the whitespace and isolate controls before them or at the end
of the line, to the paragraph level), then L2, and gives its runs in visual
order, left to right; `Line.visual()` gives each code point's offset in display
order. L3 is left to the shaper, as UAX #9 allows; L4 is `bidi.mirror`, the
glyph an odd level shows.

Every offset is a byte offset into the caller's text, the offsets `lines`
gives its breaks at and `graphemes` its clusters, so an engine keeps one set.
Nothing is allocated: the caller gives `Buffers`, a level and a 4-byte
`Scratch` slot for each byte of the paragraph (a paragraph of up to 16 MiB).
The algorithm runs on one representation, a slot per byte holding each code
point's class at its first byte, the bytes after it skipped as X9 skips what it
removes. An isolate initiator is linked to its matching PDI through the slots,
and an opening bracket to its closing one, so an isolating run sequence is
followed from one level run to the next without being built, and no rule is
quadratic in the paragraph. The same rules run on a list of classes
(`resolveClasses`, `reorderClasses`), which is how BidiTest.txt states its
cases.

### Normalization

NFD, NFC, NFKD and NFKC follow UAX #15 for Unicode 18.0.0: full decomposition
(Hangul by the algorithm of chapter 3.12), canonical ordering, and canonical
composition with its blocking rule and the composition exclusions. `write`
normalizes a region at a time: a position before an ASCII byte is a boundary
normalization never crosses, since an ASCII character is a starter that
composes with nothing before it, so ASCII runs and regions the quick check
passes are copied as they are. Within a region, a run of a starter and the
non-starters after it is ordered and composed in a buffer of 32 code points.
A longer run, which only text that is not stream-safe has, is ordered by
reading it again once for each combining class it holds, and for the composed
forms its compositions are worked out the same way, so every input normalizes
exactly and nothing is allocated, at a cost proportional to the run and the
classes in it.

NFKC_Casefold (`.nfkc_casefold`) is toNFKC_Casefold as chapter 3.13 of the
Unicode Standard defines it: each code point mapped by the NFKC_Casefold
property of DerivedNormalizationProps.txt (NFKC, full case folding and the
removal of default ignorables, repeated until stable), then NFC. The table holds
each mapping fully decomposed where it differs from the code point's
compatibility decomposition, so the form runs through the same ordering and
composition as NFKC. Its quick check answers `no` for a code point the mapping
changes (Changes_When_NFKC_Casefolded), since the transform never writes one:
the suite checks that what the mappings give is unchanged by them, and so is
every composite canonical composition makes of unchanged code points.

### Case

Lowercase, uppercase, titlecase and case folding follow chapter 3.13 of the
Unicode Standard: full mappings (`ß` uppercases to `SS`, `ﬁ` folds to `fi`), the
Final_Sigma context always, and SpecialCasing.txt's Lithuanian and Turkic
tailorings when `Options.language` names them. Titlecase maps the first cased
letter of each UAX #29 word to titlecase and everything else to lowercase.
`case.equal` is a caseless match of chapter 3.13: `.default` (D144) is
equality after full folding; `.canonical` (D145) folds between NFDs,
NFD(toCasefold(NFD(X))); `.identifier` (D147) is toNFKC_Casefold(NFD(X)),
which also ignores default ignorables and is what loose matching of
compatibility characters wants. Each compares the two transformed texts a code
point at a time with nothing allocated. The definitions order a text's
decomposition (the inner NFD) before mapping it and order again after; one
ordering does the work of both, since a non-starter maps to non-starters of its
own class or to nothing, except U+0345, the iota subscript, which maps to a
starter, has the highest combining class and so ends its run in NFD: it is held
to the end of its run and given out there. The suite checks both facts for every
code point. So a match reads the text once, and a long run once more for each
combining class in it, as normalizing does.

### Domain names

`idna.toAscii(name, writer, options)` is UTS #46's ToASCII with Nontransitional
Processing: the name mapped through the IDNA Mapping Table, normalized to NFC,
its `xn--` labels decoded, every label checked, and each label with non-ASCII
written as `xn--` and its Punycode (RFC 3492). `idna.toUnicode` gives the name to
show and always writes it. Both return `idna.Failures`, what failed by name:
disallowed code points, the STD3 rules, hyphens, a leading combining mark, bad
Punycode, the Bidi rule of RFC 5893 and the ContextJ rules of RFC 5892, and DNS
lengths; `toAscii` writes nothing when anything failed. `idna.Options` holds
UTS #46's flags, its strict conformance settings by default, and
`Options.url` is the URL Standard's. A name is worked on in buffers on the
stack, up to `idna.max_code_points` once mapped (no DNS name comes near it).
`punycode.encode` and `punycode.decode` are the encoding alone.

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
compiles them and fetches nothing else. `bay ucd` writes them again, and
`bay test` fails unless regenerating from `ucd/` reproduces them byte for byte.
The UCD files are in the repository and outside what the package ships.

| Table | Bytes |
|---|---|
| Cluster records (grapheme break, Indic conjunct break, emoji flags, width) | 34,126 |
| General_Category | 20,496 |
| Script | 20,704 |
| Script_Extensions | 4,016 |
| Derived core properties | 20,404 |
| Line breaking records (resolved class and the flags the rules read) | 36,348 |
| Normalization: combining classes, decompositions, NFKC_Casefold and their code points, compositions, quick checks | 144,448 |
| Case: simple mappings and the flags the contexts read, full mappings | 19,216 |
| Line_Break | 19,136 |
| Sentence_Break | 16,736 |
| Word_Break | 13,520 |
| East_Asian_Width | 5,248 |
| Emoji properties | 3,944 |

A program links only the tables it reads: segmenting and measuring graphemes
costs the first, 34 KB.

## API

Byte offsets and lengths, terminal columns and cluster counts are distinct
aegis domains: `Bytes` (`aegis.units.Bytes(usize)`), `Columns` and `Clusters`
(`aegis.units.Count` of their own domains). One is never taken for another,
none for a code point (a `u21`), and reading the number out is an explicit
`.raw()`. A `Span` holds two `Bytes`; `span.of(text)` is the part of the text
it covers. Every iterator's `offset()` is where its next segment starts.

| Call | Does |
|---|---|
| `graphemes(text)`, `grapheme.Iterator(rules)` | The clusters of a string: `next()` a slice, `nextSpan()` a byte range, and `prev()`, `prevSpan()` the one before; `initAt(text, offset)` starts at any boundary |
| `grapheme.boundaryBefore(text, offset, rules)`, `grapheme.boundaryAfter(text, start, rules)` | The last boundary before any offset (cursor left, backspace, the start of the cluster holding a byte); the end of the cluster that starts at a boundary (cursor right) |
| `grapheme.Breaker(rules)` | `next(cp)`: whether a code point starts a cluster, for text that arrives a code point at a time |
| `grapheme.count(text, rules)` | How many clusters a string holds, as `Clusters` |
| `words(text)`, `word.isWordLike(segment)` | Words and the runs between them; whether a segment is a word |
| `sentences(text)` | Sentences |
| `lines(text)`, `line.Iterator.nextBreak()` | Line break opportunities, each with whether the break is mandatory |
| `normalize.write(form, text, writer)`, `normalize.Iterator(form)` | NFD, NFC, NFKD, NFKC or NFKC_Casefold of a text |
| `normalize.isNormalized`, `normalize.quickCheck`, `normalize.equal` | Whether a text is in a form; UAX #15's quick check; whether two texts have the same normal form |
| `normalize.combiningClass`, `normalize.decompose`, `normalize.compose` | Canonical_Combining_Class, a code point's full decomposition, a primary composite |
| `case.write(mapping, text, writer, options)`, `case.Iterator(mapping)` | Lowercase, uppercase, titlecase or full case folding of a text |
| `case.equal(match, a, b, options)` | Whether two texts match caselessly: default, canonical or identifier caseless match |
| `case.simpleLower`, `simpleUpper`, `simpleTitle`, `simpleFold` | The simple, one-to-one mappings of a code point |
| `width.string(text, options)` | A string's terminal columns, as `Columns` |
| `width.cluster(bytes, options)` | One cluster's columns, 0 to 2 |
| `width.codepoint(cp, options)` | One code point's columns, 0 to 2 |
| `word.boundaryAfter(text, start)`, `sentence.boundaryAfter(text, start)` | Where the segment that starts at a boundary ends |
| `generalCategory`, `script`, `scriptExtensions`, `eastAsianWidth` | General_Category, Script, Script_Extensions (sorted), East_Asian_Width |
| `graphemeBreak`, `indicConjunctBreak`, `wordBreak`, `sentenceBreak`, `lineBreak` | The break classes of UAX #29 and UAX #14 |
| `emoji(cp)` | Emoji, Emoji_Presentation, Emoji_Modifier, Emoji_Modifier_Base, Emoji_Component, Extended_Pictographic, and whether it has emoji variation sequences |
| `core(cp)` | The binary properties of DerivedCoreProperties.txt: Alphabetic, Lowercase, Uppercase, Cased, Case_Ignorable, the Changes_When properties, ID_Start, ID_Continue, XID_Start, XID_Continue, Default_Ignorable_Code_Point, Grapheme_Base, Grapheme_Extend, Math |
| `idna.toAscii(name, writer, options)`, `idna.toUnicode` | A domain name for DNS or for showing (UTS #46), and what failed |
| `punycode.encode(code_points, writer)`, `punycode.decode(text, out)` | Punycode (RFC 3492) |
| `bidiClass`, `joiningType` | Bidi_Class (with the defaults of unassigned code points), Joining_Type |
| `bidi.Paragraph.resolve(text, start, options, buffers)` | A paragraph's direction and the level of every byte (UAX #9) |
| `Paragraph.levelAt(offset)`, `Paragraph.runs()`, `Paragraph.line(span, buffer)` | A byte's level; level runs in logical order; a line reordered (L1, L2) as runs in visual order |
| `Line.runs`, `Line.visual()` | The line's runs, left to right; its code points' offsets in display order |
| `bidi.mirror(cp)`, `bidi.pairedBracket(cp)` | Bidi_Mirroring_Glyph; Bidi_Paired_Bracket and its type |
| `bidi.resolveClasses`, `bidi.reorderClasses` | The same algorithm on classes alone |
| `utf8.decode`, `utf8.Iterator` | Code points of any bytes, ill-formed subparts as U+FFFD |
| `utf8.encode(iterator, writer)` | Writes the code points an iterator gives as UTF-8 |

Each enumerated value is named for the UCD's long name in snake case
(`GeneralCategory.uppercase_letter`, `WordBreak.a_letter`, `Script.old_italic`),
and `Script.code()` gives its ISO 15924 code. A value above U+10FFFF gets each
property's default, as an unassigned code point does.

## Scope

- No tailoring of words, sentences or lines, no dictionary segmentation for
  Thai, Lao, Khmer, Myanmar, Chinese or Japanese (SA lines break only at
  spaces and punctuation), no hyphenation, and no locale data.
- No shaping or rendering: widths are the cells a monospace terminal gives
  text, not glyph metrics, and `bidi` orders runs for a shaper without
  applying L3 (combining marks), which shapers do.
- No Grapheme_Link (deprecated), and no PropList properties beyond what the
  segmentation rules derive from.
- No collation, no locale data beyond the Lithuanian and Turkic casings, no
  NFKC_Simple_Casefold, and no identifier profiles (UAX #31).
- No compatibility caseless match (D146): identifier caseless match covers
  loose matching of compatibility characters.
- No Transitional Processing for domain names (UTS #46 deprecates it), no
  CONTEXTO rules (optional for clients), and no confusable or mixed-script
  checks (UTS #39).

## Platforms

Every call works on every target Zig supports, with the same results, and
needs no operating system or allocator: `zig build check-freestanding` builds
them all for wasm32-freestanding.

## Built with

- [Zig](https://ziglang.org) 0.17.0 and its standard library; nothing is linked.
- [aegis](https://github.com/pedronaugusto/aegis), whose runtime is std only:
  the byte, column and cluster domains, and the checks that stop on a broken
  table entry in every build mode.
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
1,944 of WordBreakTest.txt, 512 of SentenceBreakTest.txt, 19,346 of
LineBreakTest.txt and 20,171 of NormalizationTest.txt (all five columns in all
four forms, through the iterator, `write`, `isNormalized` and the quick check), through the
iterators and, for graphemes, a code point at a time through a `Breaker` too.
GraphemeBreakTest.txt read backward gives exactly its boundaries, under each
tailoring as forward: by `prev` from the end, and by `boundaryBefore` from
every byte offset.
With `.after_base` modifiers every line holds
with a boundary added before a skin tone that follows no modifier base, and with
`.as_other` controls every line that has no control, CR or LF holds unchanged. Every one of the 5,244 sequences of emoji-test.txt is one
cluster under both modifier rules, and each of the 3,972 fully-qualified ones
and components is 2 columns. All 6,396 test lines of IdnaTestV2.txt pass, toUnicode
and toASCII with Nontransitional Processing and every check on (a line that
expects a failure is checked for one, as the file allows). BidiTest.txt passes
every case at every paragraph direction its bits name (levels after L1 and the
visual order), and all of BidiCharacterTest.txt: paragraph level, levels and
visual order, through `Paragraph.resolve`, `line` and `visual`. The bracket and
mirroring lists are BidiBrackets.txt and BidiMirroring.txt, and no other code
point has either. Arbitrary text dense in the classes the rules treat
specially (isolates, embeddings, brackets, numbers, separators, ill-formed
bytes) resolves with every byte at a level, a code point's bytes at one, runs
covering each paragraph, and each code point once in a line's visual order.

Every code point NormalizationTest.txt does not list is its own normal form in
all four forms. NFKC_Casefold of every code point is DerivedNormalizationProps.txt's,
through the iterator, `write`, `isNormalized` and the quick check, and
Changes_When_NFKC_Casefolded is what the mapping changes. The simple and full case mappings and folding are checked against
UnicodeData.txt, SpecialCasing.txt and CaseFolding.txt for every code point, every
conditional mapping of SpecialCasing.txt in its context, and the five
Changes_When properties of DerivedCoreProperties.txt, which the UCD derives by
mapping each code point's NFD, are what normalization and the mappings here give,
for every code point.

Every table is checked against the UCD file it comes from for every code
point, parsed again in the test apart from the generator, and the code point
widths are derived from the raw properties by the rules above and compared for
every code point. Properties through shakedown run on generated text that mixes
the code points the rules treat specially with arbitrary bytes: graphemes,
words, sentences and lines (mandatory breaks included) must be what a second
implementation that decides each position from the whole text by the rules in
order finds; clusters read backward, from every byte offset and by `prev`, and
forward from any boundary, are the ones read from the start, on that text and on
text dense in the runs the backward rules read context from; segments cover the
text and fall on code point boundaries; a string's width is the sum of its
clusters'; and decoding agrees with std on well-formed UTF-8 and takes the
maximal subpart, by its definition, of everything else. Normal forms of generated
text with runs of up to a hundred marks are what a plain allocating
implementation gives; folding, lowercasing and uppercasing are idempotent in
every language tailoring; and each caseless match agrees with the transform it
is defined as, done a step at a time over the whole text, on generated pairs of
texts in other cases and normal forms. Punycode decodes what it encodes and
refuses or decodes any bytes; a domain name toASCII accepts is ASCII, processes
to itself and shows with no failure, under both option sets. They run on seeded
inputs in every `bay test`, and under `bay test --fuzz` they search further.
Nothing here can allocate: no call takes an allocator. The source checks gate
glint's aegis rules A001 to A004: no raw arithmetic or cast on a domain value
outside an explicit `.raw()` boundary.

`bay bench` times segmentation, line breaking, width, normalization and case
mapping over 64 KiB texts of ASCII, accented
Latin, CJK, Devanagari, emoji and a mix, in ReleaseFast. Run from
`zig-out/bench`, `segment`, `width` and `transform` print shakedown's JSON lines. `bay test`
runs each row once with `--smoke`; CI times nothing.

## Licence

MIT. See [LICENSE](LICENSE). The Unicode data the tables are generated from are
under the [Unicode License v3](src/UNICODE-LICENSE.txt), a copy of which is
beside the tables and beside the data files in `ucd/`.
