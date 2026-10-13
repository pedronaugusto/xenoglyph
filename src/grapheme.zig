//! Extended grapheme clusters (UAX #29, section 3): what a reader takes for
//! one character. The rules are the extended rules GB1 to GB999 of Unicode
//! 18.0.0, Indic conjuncts (GB9c) and emoji sequences (GB11) included, with
//! two tailorings a caller may choose in `Rules`.
//!
//! Nothing here allocates. The rules are compiled into a state machine at
//! compile time (`Automaton`). `Breaker` runs it over a stream of code
//! points; `Iterator` walks a string with it, decoding as `utf8.decode`
//! does, so ill-formed bytes are U+FFFD (Grapheme_Cluster_Break Other).
const std = @import("std");
const classes = @import("classes.zig");
const records = @import("records.zig");

const Cluster = classes.Cluster;

/// The rules a segmentation follows. The default is UAX #29's extended
/// grapheme clusters exactly; each field names a tailoring of them.
pub const Rules = struct {
    controls: Controls = .separate,
    modifiers: Modifiers = .extend,

    pub const Controls = enum {
        /// GB3 to GB5: a control, CR or LF is a cluster of its own, and CR
        /// LF one cluster.
        separate,
        /// Control, CR and LF read as Other: for text whose controls the
        /// caller has already acted on or taken out, as a terminal does
        /// before it prints. A mark after a control then joins it.
        as_other,
    };

    pub const Modifiers = enum {
        /// UAX #29: an emoji modifier is Extend and joins anything before
        /// it.
        extend,
        /// UTS #51 (ED-13, and 2.4): a modifier changes only an
        /// Emoji_Modifier_Base it directly follows; after anything else it
        /// is a colour swatch that reads as Other in every rule
        /// (Grapheme_Cluster_Break Other, Indic_Conjunct_Break None), so it
        /// starts a cluster and continues no Indic conjunct.
        after_base,
    };

    /// How a terminal that measures by cluster (mode 2027) segments the
    /// text it prints.
    pub const terminal: Rules = .{ .controls = .as_other, .modifiers = .after_base };
};

/// A byte range of the text an iterator walks.
pub const Span = struct {
    start: usize,
    end: usize,

    pub fn len(s: Span) usize {
        return s.end - s.start;
    }
};

/// What the rules read of a code point: its Grapheme_Cluster_Break and
/// the properties GB9c, GB11 and the modifier tailoring look at.
const Class = struct {
    grapheme_break: classes.GraphemeBreak,
    conjunct: classes.IndicConjunctBreak,
    extended_pictographic: bool,
    modifier: bool,
    modifier_base: bool,

    fn of(r: Cluster) Class {
        return .{ .grapheme_break = r.grapheme_break, .conjunct = r.conjunct, .extended_pictographic = r.extended_pictographic, .modifier = r.modifier, .modifier_base = r.modifier_base };
    }
};

/// The rules, as UAX #29 states them, over the context they need: the
/// previous code point's class, the parity of a run of regional indicators,
/// an emoji ZWJ sequence or an Indic linker in progress. The automaton
/// below is built from this at compile time; nothing runs it at run time.
fn Context(comptime rules: Rules) type {
    return struct {
        const Self = @This();

        previous: Class = Class.of(.{}),
        started: bool = false,
        /// The run of regional indicators ending at `previous` is odd.
        ri_odd: bool = false,
        /// GB11's context: Extended_Pictographic Extend*, then a ZWJ.
        emoji: enum { none, pictographic, joined } = .none,
        /// GB9c's context: InCB=Linker InCB=Extend*.
        linker: bool = false,

        /// Whether `class` starts a cluster; the first code point does.
        fn step(ctx: *Self, class: Class) bool {
            var n = class;
            if (rules.controls == .as_other) switch (n.grapheme_break) {
                .cr, .lf, .control => n.grapheme_break = .other,
                else => {},
            };
            if (rules.modifiers == .after_base and n.modifier and !(ctx.started and ctx.previous.modifier_base)) {
                n.grapheme_break = .other;
                n.conjunct = .none;
            }
            const boundary = !ctx.started or ctx.isBoundary(n);
            ctx.advance(n);
            return boundary;
        }

        fn isBoundary(ctx: *const Self, n: Class) bool {
            const p = ctx.previous.grapheme_break;
            const c = n.grapheme_break;
            // GB3 to GB5.
            if (p == .cr and c == .lf) return false;
            if (p == .cr or p == .lf or p == .control) return true;
            if (c == .cr or c == .lf or c == .control) return true;
            // GB6 to GB8: Hangul syllables.
            switch (p) {
                .l => if (c == .l or c == .v or c == .lv or c == .lvt) return false,
                .lv, .v => if (c == .v or c == .t) return false,
                .lvt, .t => if (c == .t) return false,
                else => {},
            }
            // GB9, GB9a, GB9b.
            if (c == .extend or c == .zwj or c == .spacing_mark) return false;
            if (p == .prepend) return false;
            // GB9c: InCB=Linker InCB=Extend* x InCB=Consonant.
            if (ctx.linker and n.conjunct == .consonant) return false;
            // GB11: ExtPict Extend* ZWJ x ExtPict.
            if (ctx.emoji == .joined and n.extended_pictographic) return false;
            // GB12, GB13: pairs of regional indicators.
            if (p == .regional_indicator and c == .regional_indicator and ctx.ri_odd) return false;
            return true; // GB999
        }

        fn advance(ctx: *Self, n: Class) void {
            const c = n.grapheme_break;
            ctx.ri_odd = c == .regional_indicator and !(ctx.started and ctx.previous.grapheme_break == .regional_indicator and ctx.ri_odd);
            ctx.linker = n.conjunct == .linker or (ctx.linker and n.conjunct == .extend);
            ctx.emoji = if (n.extended_pictographic)
                .pictographic
            else if (ctx.emoji == .pictographic and c == .extend)
                .pictographic
            else if (ctx.emoji == .pictographic and c == .zwj)
                .joined
            else
                .none;
            ctx.previous = n;
            ctx.started = true;
        }
    };
}

/// The rules compiled: every context the rules can reach from the start
/// of a text is a state, and `transitions[state][record]` is the next
/// state, with the top bit set where the code point starts a cluster. A
/// code point is the index of its record in the cluster table, so a step
/// is one table read.
fn Automaton(comptime rules: Rules) type {
    const all = records.cluster_records;
    const Ctx = Context(rules);
    return struct {
        const max_states = 128;
        const start: u8 = 0;

        const built = blk: {
            @setEvalBranchQuota(1_000_000);
            var contexts: [max_states]Ctx = undefined;
            var table: [max_states][all.len]u8 = undefined;
            contexts[0] = .{};
            var reached: usize = 1;
            var at: usize = 0;
            while (at < reached) : (at += 1) {
                for (all, 0..) |r, i| {
                    var ctx = contexts[at];
                    const boundary = ctx.step(Class.of(@bitCast(r)));
                    const to = for (contexts[0..reached], 0..) |s, k| {
                        if (std.meta.eql(s, ctx)) break k;
                    } else new: {
                        if (reached == max_states) @compileError("the grapheme rules reach more than 128 contexts");
                        contexts[reached] = ctx;
                        reached += 1;
                        break :new reached - 1;
                    };
                    table[at][i] = @as(u8, to) | (if (boundary) 0x80 else 0);
                }
            }
            break :blk .{ .count = reached, .table = table };
        };

        pub const states = built.count;
        pub const transitions: [states][all.len]u8 = built.table[0..states].*;

        /// The state after an ASCII code point, which is the same whatever
        /// came before it.
        pub const after_ascii: [128]u8 = blk: {
            @setEvalBranchQuota(100_000);
            var after: [128]u8 = undefined;
            for (&after, 0..) |*a, byte| {
                const index = records.ascii_cluster_indexes[byte];
                a.* = transitions[start][index] & 0x7f;
                for (transitions) |row| std.debug.assert(row[index] & 0x7f == a.*);
            }
            break :blk after;
        };

        pub inline fn step(state: *u8, index: u8) bool {
            const t = transitions[state.*][index];
            state.* = t & 0x7f;
            return t & 0x80 != 0;
        }
    };
}

/// The rules over a stream of code points: `next` says whether each one
/// starts a cluster. It holds one byte of context.
pub fn Breaker(comptime rules: Rules) type {
    return struct {
        const Self = @This();
        const A = Automaton(rules);

        /// Private: the rules' context, a state of the compiled rules.
        state: u8 = A.start,

        /// Whether `cp` starts a cluster. The first code point does.
        pub fn next(b: *Self, cp: u21) bool {
            return A.step(&b.state, records.clusterIndex(cp));
        }

        /// `next` for a code point given by its record index
        /// (`records.clusterIndex`).
        pub inline fn nextIndex(b: *Self, index: u8) bool {
            return A.step(&b.state, index);
        }

        /// The context after an ASCII code point, which is the same whatever
        /// came before it.
        pub inline fn afterAscii(b: *Self, byte: u8) void {
            b.state = A.after_ascii[byte];
        }
    };
}

/// The grapheme clusters of a string, in order.
pub fn Iterator(comptime rules: Rules) type {
    return struct {
        const Self = @This();

        bytes: []const u8,
        /// Where the next cluster starts.
        index: usize = 0,
        /// Private: the rules' context, past the first code point of the
        /// next cluster when `pending` holds its length.
        breaker: Breaker(rules) = .{},
        /// Private: the length of the next cluster's first code point,
        /// already given to `breaker`, or 0.
        pending: u3 = 0,

        pub fn init(bytes: []const u8) Self {
            return .{ .bytes = bytes };
        }

        /// The next cluster, or null at the end.
        pub fn next(it: *Self) ?[]const u8 {
            const s = it.nextSpan() orelse return null;
            return it.bytes[s.start..s.end];
        }

        /// The next cluster's byte range, or null at the end.
        pub fn nextSpan(it: *Self) ?Span {
            const bytes = it.bytes;
            const start = it.index;
            if (start >= bytes.len) return null;
            // Two ASCII bytes: the first is a cluster of its own, unless CR LF.
            const lead = bytes[start];
            if (lead < 0x80 and start + 1 < bytes.len and bytes[start + 1] < 0x80 and
                !(rules.controls == .separate and lead == '\r' and bytes[start + 1] == '\n'))
            {
                if (it.pending == 0) it.breaker.afterAscii(lead);
                it.pending = 0;
                it.index = start + 1;
                return .{ .start = start, .end = start + 1 };
            }
            var at = start;
            if (it.pending != 0) {
                at += it.pending;
            } else {
                const first = records.read(bytes[at..]);
                _ = it.breaker.nextIndex(first.index);
                at += first.len;
            }
            it.pending = 0;
            while (at < bytes.len) {
                const n = records.read(bytes[at..]);
                if (it.breaker.nextIndex(n.index)) {
                    it.pending = n.len;
                    break;
                }
                at += n.len;
            }
            it.index = at;
            return .{ .start = start, .end = at };
        }
    };
}

/// The clusters of `bytes` by UAX #29's rules.
pub fn iterate(bytes: []const u8) Iterator(.{}) {
    return .init(bytes);
}

/// How many clusters `bytes` holds by `rules`.
pub fn count(bytes: []const u8, comptime rules: Rules) usize {
    var it: Iterator(rules) = .init(bytes);
    var n: usize = 0;
    while (it.nextSpan()) |_| n += 1;
    return n;
}

test "clusters of a mixed string" {
    const text = "e\u{301}\u{1f469}\u{1f3fd}\u{200d}\u{1f680}\u{1f1e8}\u{1f1ed}\r\n\u{915}\u{94d}\u{937}";
    var it = iterate(text);
    const want = [_][]const u8{ "e\u{301}", "\u{1f469}\u{1f3fd}\u{200d}\u{1f680}", "\u{1f1e8}\u{1f1ed}", "\r\n", "\u{915}\u{94d}\u{937}" };
    for (want) |w| try std.testing.expectEqualStrings(w, it.next().?);
    try std.testing.expectEqual(null, it.next());
}

test "tailorings" {
    // A modifier after a letter: joined by UAX #29, apart under UTS #51.
    try std.testing.expectEqual(1, count("a\u{1f3fb}", .{}));
    try std.testing.expectEqual(2, count("a\u{1f3fb}", .{ .modifiers = .after_base }));
    try std.testing.expectEqual(1, count("\u{1f44d}\u{1f3fb}", .{ .modifiers = .after_base }));
    // A swatch continues no Indic conjunct: linker, swatch, consonant.
    try std.testing.expectEqual(1, count("\u{94d}\u{1f3fb}\u{915}", .{}));
    try std.testing.expectEqual(3, count("\u{94d}\u{1f3fb}\u{915}", .{ .modifiers = .after_base }));
    // A mark after a control: apart by GB5, joined when controls are Other.
    try std.testing.expectEqual(2, count("\t\u{301}", .{}));
    try std.testing.expectEqual(1, count("\t\u{301}", .{ .controls = .as_other }));
}
