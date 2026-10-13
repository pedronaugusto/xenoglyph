//! How many terminal cells text takes.
//!
//! Unicode does not define this; terminals do, and this file states the
//! model it follows, one rule at a time. A code point's columns
//! (`codepoint`):
//!
//! 1. 0 for a control (Cc), a surrogate (Cs), and the line and paragraph
//!    separators (Zl, Zp): a terminal acts on a control or drops it, and
//!    draws nothing for it.
//! 2. 1 for U+00AD SOFT HYPHEN, which terminals draw as a hyphen.
//! 3. 0 for every other Default_Ignorable_Code_Point: joiners, variation
//!    selectors, tags, the Hangul fillers, invisible format characters.
//! 4. 0 for a nonspacing (Mn) or enclosing (Me) mark, which draws over the
//!    character before it.
//! 5. 0 for a Hangul medial vowel or final consonant
//!    (Grapheme_Cluster_Break V or T), which joins the syllable before it.
//! 6. 2 for East_Asian_Width Wide or Fullwidth (UAX #11), the emoji with
//!    emoji presentation among them.
//! 7. 2 for a regional indicator, which emoji fonts draw as a wide letter.
//! 8. 1 for everything else: spacing marks, unassigned and private-use code
//!    points included. East_Asian_Width Ambiguous is 1, or 2 with
//!    `.ambiguous = .wide`, as terminals in East Asian locales count it.
//!
//! A grapheme cluster's columns (`cluster`) are 0, 1 or 2: its first code
//! point's columns, then for each code point after it:
//!
//! - U+FE0F (VS16) after a code point that has emoji variation sequences
//!   (emoji-variation-sequences.txt) asks for emoji presentation: 2.
//! - U+FE0E (VS15) after such a code point asks for text presentation: 1.
//! - A variation selector after anything else is ignored.
//! - An emoji modifier (a skin tone) makes an emoji modifier sequence, which
//!   UTS #51 shows with emoji presentation: 2, whether the base alone is
//!   text by default (U+1F590) or emoji.
//! - Any other code point with columns of its own (a spacing mark, a second
//!   Hangul leading consonant, the emoji after a ZWJ) makes the cluster 2.
//! - A code point of no columns makes no change.
//!
//! So a family emoji, a flag, a keycap and a skin-toned hand are 2, `é`
//! decomposed is 1, a Devanagari conjunct is 2, and `☁︎` (with VS15) is 1.
//! A string's columns are the sum of its clusters'. By default the clusters
//! are cut as UTS #51 shows emoji: a skin tone after anything but a
//! modifier base stands alone, as a 2-column swatch.
//!
//! A terminal that measures by code point (wcwidth, mode 2027 off) is
//! `.method = .codepoint`: the sum of the code points' columns.
const std = @import("std");
const classes = @import("classes.zig");
const grapheme = @import("grapheme.zig");
const records = @import("records.zig");

const Cluster = classes.Cluster;

pub const Options = struct {
    /// East_Asian_Width Ambiguous: `.narrow` (1) or `.wide` (2).
    ambiguous: Ambiguous = .narrow,
    /// By cluster, or by code point as `wcwidth(3)` measures.
    method: Method = .cluster,
    /// How `string` cuts clusters.
    rules: grapheme.Rules = .{ .modifiers = .after_base },

    pub const Ambiguous = enum { narrow, wide };
    pub const Method = enum { cluster, codepoint };
};

inline fn columnsOf(record: Cluster, comptime options: Options) u2 {
    if (options.ambiguous == .wide and record.ambiguous and record.width == 1) return 2;
    return record.width;
}

/// The columns of one code point standing alone, by the rules above.
pub fn codepoint(cp: u21, comptime options: Options) u2 {
    return columnsOf(records.cluster(cp), options);
}

/// One cluster's width as it grows: give it each of the cluster's code
/// points in order.
const Measure = struct {
    columns: u2,
    previous: Cluster,

    inline fn start(index: u8, comptime options: Options) Measure {
        const record = records.clusterRecord(index);
        return .{ .columns = columnsOf(record, options), .previous = record };
    }

    inline fn add(m: *Measure, cp: u21, index: u8, comptime options: Options) void {
        const record = records.clusterRecord(index);
        if (cp == 0xfe0f or cp == 0xfe0e) {
            if (!m.previous.variation_base) return;
            m.columns = if (cp == 0xfe0f) 2 else 1;
        } else if (columnsOf(record, options) != 0) {
            m.columns = 2;
        }
        m.previous = record;
    }
};

/// The columns of `bytes` taken as one grapheme cluster, whatever its
/// boundaries: 0, 1 or 2. Empty is 0.
pub fn cluster(bytes: []const u8, comptime options: Options) u2 {
    if (bytes.len == 0) return 0;
    const first = records.read(bytes);
    var m: Measure = .start(first.index, options);
    var at: usize = first.len;
    while (at < bytes.len) {
        const n = records.read(bytes[at..]);
        m.add(n.code_point, n.index, options);
        at += n.len;
    }
    return m.columns;
}

/// The columns of a string: the sum of its clusters' by `options.rules`,
/// or of its code points' with `.method = .codepoint`.
pub fn string(bytes: []const u8, comptime options: Options) usize {
    var total: usize = 0;
    var at: usize = 0;
    // Printable ASCII is a column a byte by either method, and a cluster of
    // one byte unless something after it joins it.
    while (at < bytes.len) {
        const b = bytes[at];
        if (b < 0x20 or b > 0x7e) break;
        if (at + 1 < bytes.len and bytes[at + 1] >= 0x80) break;
        total += 1;
        at += 1;
    }
    if (at == bytes.len) return total;
    switch (options.method) {
        .codepoint => {
            while (at < bytes.len) {
                const n = records.read(bytes[at..]);
                total += columnsOf(records.clusterRecord(n.index), options);
                at += n.len;
            }
        },
        .cluster => {
            var breaker: grapheme.Breaker(options.rules) = .{};
            const first = records.read(bytes[at..]);
            _ = breaker.nextIndex(first.index);
            var m: Measure = .start(first.index, options);
            at += first.len;
            while (at < bytes.len) {
                const n = records.read(bytes[at..]);
                if (breaker.nextIndex(n.index)) {
                    total += m.columns;
                    m = .start(n.index, options);
                } else {
                    m.add(n.code_point, n.index, options);
                }
                at += n.len;
            }
            total += m.columns;
        },
    }
    return total;
}

test "the model's examples" {
    const t = std.testing;
    try t.expectEqual(2, cluster("\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}", .{}));
    try t.expectEqual(2, cluster("\u{1f1fa}\u{1f1f8}", .{}));
    try t.expectEqual(2, cluster("1\u{fe0f}\u{20e3}", .{}));
    try t.expectEqual(2, cluster("\u{1f44b}\u{1f3fd}", .{}));
    try t.expectEqual(1, cluster("e\u{301}", .{}));
    try t.expectEqual(2, cluster("\u{915}\u{94d}\u{937}", .{}));
    try t.expectEqual(1, cluster("\u{2601}\u{fe0e}", .{}));
    try t.expectEqual(2, cluster("\u{2601}\u{fe0f}", .{}));
    try t.expectEqual(1, cluster("V\u{fe0f}", .{}));
    try t.expectEqual(2, codepoint(0x4e00, .{}));
    try t.expectEqual(1, codepoint(0xa1, .{}));
    try t.expectEqual(2, codepoint(0xa1, .{ .ambiguous = .wide }));
    try t.expectEqual(0, codepoint(0x200b, .{}));
    try t.expectEqual(1, codepoint(0xad, .{}));
    try t.expectEqual(5, string("hello", .{}));
    try t.expectEqual(3, string("a\u{1f3fb}", .{}));
    try t.expectEqual(2, string("a\u{1f3fb}", .{ .rules = .{} }));
    try t.expectEqual(6, string("日本語", .{}));
}
