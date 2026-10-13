//! Extended grapheme clusters (UAX #29, section 3): what a reader takes for
//! one character. The rules are the extended rules GB1 to GB999 of Unicode
//! 18.0.0, Indic conjuncts (GB9c) and emoji sequences (GB11) included, with
//! two tailorings a caller may choose in `Rules`.
//!
//! Nothing here allocates. The rules are compiled into a state machine at
//! compile time (`Automaton`). `Breaker` runs it over a stream of code
//! points; `Iterator` walks a string with it, decoding as `utf8.decode`
//! does, so ill-formed bytes are U+FFFD (Grapheme_Cluster_Break Other).
//! Backward, `Reverse` decides each position from the text before it, read
//! back only as far as the rule that decides it needs.
const std = @import("std");
const classes = @import("classes.zig");
const records = @import("records.zig");
const domains = @import("domains.zig");
const aegis = @import("aegis");

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
pub const Span = domains.Span;

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

/// A code point's class as `rules` read it: Other for a control under
/// `.as_other`, and Other with no Indic conjunct role for an emoji modifier
/// under `.after_base` unless it directly follows an Emoji_Modifier_Base
/// (`after_base`).
fn tailor(comptime rules: Rules, class: Class, after_base: bool) Class {
    var n = class;
    if (rules.controls == .as_other) switch (n.grapheme_break) {
        .cr, .lf, .control => n.grapheme_break = .other,
        else => {},
    };
    if (rules.modifiers == .after_base and n.modifier and !after_base) {
        n.grapheme_break = .other;
        n.conjunct = .none;
    }
    return n;
}

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
            const n = tailor(rules, class, ctx.started and ctx.previous.modifier_base);
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

        /// What the pair of code points on either side of a position says
        /// of it, whatever came before them: a boundary, none, or that it
        /// depends on more of the text before (GB9c, GB11, GB12 and GB13).
        pub const Pair = enum(u2) { boundary, joined, context };

        /// `pairs[before][after]`, by record index: for every state the
        /// rules can be in after `before`, whether `after` starts a cluster,
        /// when all of them agree.
        pub const pairs: [all.len][all.len]Pair = blk: {
            @setEvalBranchQuota(10_000_000);
            var table: [all.len][all.len]Pair = undefined;
            for (0..all.len) |before| {
                var after_before: [states]bool = @splat(false);
                for (transitions) |row| after_before[row[before] & 0x7f] = true;
                for (0..all.len) |after| {
                    var splits = false;
                    var joins = false;
                    for (after_before, transitions) |reached, row| if (reached) {
                        if (row[after] & 0x80 != 0) splits = true else joins = true;
                    };
                    table[before][after] = if (!joins) .boundary else if (!splits) .joined else .context;
                }
            }
            break :blk table;
        };

        pub inline fn step(state: *u8, index: u8) bool {
            const t = transitions[state.*][index];
            state.* = t & 0x7f;
            return t & 0x80 != 0;
        }
    };
}

/// The rules read backward: whether a position is a boundary, decided from
/// the text before it, read only as far back as the rule that decides it
/// needs. Most positions are decided by the two code points beside them
/// (`Automaton.pairs`); the rest by the context the rules carry, rebuilt
/// from the run it depends on: the Indic linker and the InCB=Extend before
/// it (GB9c), the pictograph and the Extend before a ZWJ (GB11), the run of
/// regional indicators (GB12, GB13). Each is decided by `Context`, the
/// rules as the forward automaton is built from them.
fn Reverse(comptime rules: Rules) type {
    return struct {
        const A = Automaton(rules);
        const Ctx = Context(rules);

        /// A code point read backward: where it starts, and its record.
        const Back = struct { start: usize, index: u8 };

        fn before(bytes: []const u8, end: usize) Back {
            const r = records.readBefore(bytes, end);
            return .{ .start = r.start, .index = r.index };
        }

        fn raw(c: Back) Class {
            return Class.of(records.clusterRecord(c.index));
        }

        fn regional(c: Back) bool {
            return raw(c).grapheme_break == .regional_indicator;
        }

        /// The class the rules read of `c`, which for an emoji modifier
        /// depends on the code point before it.
        fn tailored(bytes: []const u8, c: Back) Class {
            const class = raw(c);
            const after_base = rules.modifiers == .after_base and class.modifier and c.start > 0 and
                raw(before(bytes, c.start)).modifier_base;
            return tailor(rules, class, after_base);
        }

        /// Whether the position between `p` and the code point `c` after it
        /// is a boundary.
        fn isBoundary(bytes: []const u8, p: Back, c: Back) bool {
            return switch (A.pairs[p.index][c.index]) {
                .boundary => true,
                .joined => false,
                .context => contextual(bytes, p, c),
            };
        }

        /// The rules' context after `p`, rebuilt from the text before it,
        /// then the rules' step over `c`.
        fn contextual(bytes: []const u8, p: Back, c: Back) bool {
            var ctx: Ctx = .{ .previous = tailored(bytes, p), .started = true };
            if (ctx.previous.grapheme_break == .regional_indicator) ctx.ri_odd = regionalRunOdd(bytes, p);
            if (ctx.previous.grapheme_break == .zwj and pictographBefore(bytes, p.start)) ctx.emoji = .joined;
            ctx.linker = linkerAt(bytes, p);
            return ctx.step(raw(c));
        }

        /// Whether the run of regional indicators that ends with `p` is odd.
        fn regionalRunOdd(bytes: []const u8, p: Back) bool {
            var odd = true;
            var at = p.start;
            while (at > 0) {
                const b = before(bytes, at);
                if (!regional(b)) break;
                odd = !odd;
                at = b.start;
            }
            return odd;
        }

        /// GB11's context before a ZWJ that starts at `end`: an
        /// Extended_Pictographic, then Extend only.
        fn pictographBefore(bytes: []const u8, end: usize) bool {
            var at = end;
            while (at > 0) {
                const b = before(bytes, at);
                const class = tailored(bytes, b);
                if (class.extended_pictographic) return true;
                if (class.grapheme_break != .extend) return false;
                at = b.start;
            }
            return false;
        }

        /// GB9c's context after `p`: an InCB=Linker, then InCB=Extend only.
        fn linkerAt(bytes: []const u8, p: Back) bool {
            var c = p;
            while (true) {
                switch (tailored(bytes, c).conjunct) {
                    .linker => return true,
                    .extend => {},
                    .none, .consonant => return false,
                }
                if (c.start == 0) return false;
                c = before(bytes, c.start);
            }
        }

        /// The last boundary before `end` (0 < `end` <= `bytes.len`).
        /// With `at_boundary`, `end` is a boundary itself, which decides a
        /// run of regional indicators it falls in without counting the run.
        fn start(bytes: []const u8, end: usize, comptime at_boundary: bool) usize {
            // Two ASCII code points: a boundary between them, unless CR LF.
            if (end >= 2 and bytes[end - 1] < 0x80 and bytes[end - 2] < 0x80 and
                !(rules.controls == .separate and bytes[end - 2] == '\r' and bytes[end - 1] == '\n')) return end - 1;
            var c = before(bytes, end);
            if (at_boundary and end < bytes.len and regional(c) and c.start > 0 and
                raw(.{ .start = end, .index = records.read(bytes[end..]).index }).grapheme_break == .regional_indicator)
            {
                // A boundary between two regional indicators: the run before
                // it is even, so `c` pairs with the indicator before it, and
                // before that pair is a boundary when the run goes on.
                const pair = before(bytes, c.start);
                if (regional(pair)) {
                    if (pair.start == 0 or regional(before(bytes, pair.start))) return pair.start;
                    c = pair;
                }
            }
            while (c.start > 0) {
                const p = before(bytes, c.start);
                if (isBoundary(bytes, p, c)) return c.start;
                c = p;
            }
            return 0;
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
        /// Private: where the next cluster starts; `offset` reads it.
        at: usize = 0,
        /// Private: the rules' context, past the first code point of the
        /// next cluster when `pending` holds its length.
        breaker: Breaker(rules) = .{},
        /// Private: the length of the next cluster's first code point,
        /// already given to `breaker`, or 0.
        pending: u3 = 0,

        pub fn init(bytes: []const u8) Self {
            return .{ .bytes = bytes };
        }

        /// An iterator whose next cluster starts at `at`, a boundary of
        /// `bytes`: its start, its end, or where an earlier iterator's
        /// cluster started or ended. The clusters after a boundary are the
        /// same whatever came before it.
        pub fn initAt(bytes: []const u8, at: domains.Bytes) Self {
            aegis.assert.pre(at.compare(.fromRaw(bytes.len)) != .gt, "the offset is within the text");
            return .{ .bytes = bytes, .at = at.raw() };
        }

        /// Where the next cluster starts.
        pub fn offset(it: *const Self) domains.Bytes {
            return .fromRaw(it.at);
        }

        /// The next cluster, or null at the end.
        pub fn next(it: *Self) ?[]const u8 {
            const s = it.nextSpan() orelse return null;
            return s.of(it.bytes);
        }

        /// The cluster before `offset()`, or null at the start; `offset()`
        /// moves back to where it starts, so `next` gives it again.
        pub fn prev(it: *Self) ?[]const u8 {
            const s = it.prevSpan() orelse return null;
            return s.of(it.bytes);
        }

        /// The byte range of the cluster before `offset()`, or null at the
        /// start. Reads back only as far as the rules need (`boundaryBefore`),
        /// and through a run of regional indicators once however many
        /// clusters it is stepped back over.
        pub fn prevSpan(it: *Self) ?Span {
            const end = it.at;
            if (end == 0) return null;
            const start = Reverse(rules).start(it.bytes, end, true);
            it.at = start;
            it.pending = 0;
            it.breaker = .{};
            return .{ .start = .fromRaw(start), .end = .fromRaw(end) };
        }

        /// The next cluster's byte range, or null at the end.
        pub fn nextSpan(it: *Self) ?Span {
            const bytes = it.bytes;
            const start = it.at;
            if (start >= bytes.len) return null;
            // Two ASCII bytes: the first is a cluster of its own, unless CR LF.
            const lead = bytes[start];
            if (lead < 0x80 and start + 1 < bytes.len and bytes[start + 1] < 0x80 and
                !(rules.controls == .separate and lead == '\r' and bytes[start + 1] == '\n'))
            {
                if (it.pending == 0) it.breaker.afterAscii(lead);
                it.pending = 0;
                it.at = start + 1;
                return .{ .start = .fromRaw(start), .end = .fromRaw(start + 1) };
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
            it.at = at;
            return .{ .start = .fromRaw(start), .end = .fromRaw(at) };
        }
    };
}

/// The clusters of `bytes` by UAX #29's rules.
pub fn iterate(bytes: []const u8) Iterator(.{}) {
    return .init(bytes);
}

/// The last boundary before `offset` (0 < `offset` <= `bytes.len`): where
/// the cluster that holds byte `offset - 1` starts, as segmenting `bytes`
/// from its start finds it. A cursor's step left, or a backspace.
///
/// The text before is read only as far as the rule that decides each
/// position needs: to the start of the cluster, and past it through a run
/// of InCB=Extend (GB9c), of Extend before a ZWJ (GB11), or of regional
/// indicators (GB12, GB13), never from the start of the text. Stepping back
/// over many clusters is linear with `Iterator.prev`, which knows it stands
/// on a boundary and so counts a run of regional indicators once.
pub fn boundaryBefore(bytes: []const u8, offset: domains.Bytes, comptime rules: Rules) domains.Bytes {
    aegis.assert.pre(offset.compare(.fromRaw(0)) == .gt and offset.compare(.fromRaw(bytes.len)) != .gt, "a boundary before the offset exists");
    return .fromRaw(Reverse(rules).start(bytes, offset.raw(), false));
}

/// The end of the cluster that starts at `start`, which must be a boundary
/// before the end of `bytes`. A cursor's step right.
pub fn boundaryAfter(bytes: []const u8, start: domains.Bytes, comptime rules: Rules) domains.Bytes {
    aegis.assert.pre(start.compare(.fromRaw(bytes.len)) == .lt, "a cluster starts at the offset");
    var it: Iterator(rules) = .initAt(bytes, start);
    return (it.nextSpan() orelse aegis.assert.never("a cluster starts before the end")).end;
}

/// How many clusters `bytes` holds by `rules`.
pub fn count(bytes: []const u8, comptime rules: Rules) domains.Clusters {
    var it: Iterator(rules) = .init(bytes);
    var n: usize = 0;
    while (it.nextSpan()) |_| n += 1;
    return .fromRaw(n);
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
    try std.testing.expectEqual(1, count("a\u{1f3fb}", .{}).raw());
    try std.testing.expectEqual(2, count("a\u{1f3fb}", .{ .modifiers = .after_base }).raw());
    try std.testing.expectEqual(1, count("\u{1f44d}\u{1f3fb}", .{ .modifiers = .after_base }).raw());
    // A swatch continues no Indic conjunct: linker, swatch, consonant.
    try std.testing.expectEqual(1, count("\u{94d}\u{1f3fb}\u{915}", .{}).raw());
    try std.testing.expectEqual(3, count("\u{94d}\u{1f3fb}\u{915}", .{ .modifiers = .after_base }).raw());
    // A mark after a control: apart by GB5, joined when controls are Other.
    try std.testing.expectEqual(2, count("\t\u{301}", .{}).raw());
    try std.testing.expectEqual(1, count("\t\u{301}", .{ .controls = .as_other }).raw());
}

test "stepping back" {
    const text = "e\u{301}\u{1f469}\u{1f3fd}\u{200d}\u{1f680}\u{1f1e8}\u{1f1ed}\u{1f1e8}\r\n\u{915}\u{94d}\u{937}";
    var it: Iterator(.{}) = .initAt(text, .fromRaw(text.len));
    const want = [_][]const u8{ "\u{915}\u{94d}\u{937}", "\r\n", "\u{1f1e8}", "\u{1f1e8}\u{1f1ed}", "\u{1f469}\u{1f3fd}\u{200d}\u{1f680}", "e\u{301}" };
    for (want) |w| try std.testing.expectEqualStrings(w, it.prev().?);
    try std.testing.expectEqual(null, it.prev());
    try std.testing.expectEqualStrings("e\u{301}", it.next().?);
    // The start of the cluster that holds a byte, from inside a code point.
    try std.testing.expectEqual(1 + 2, boundaryBefore(text, .fromRaw(1 + 2 + 5), .{}).raw());
    try std.testing.expectEqual(3, boundaryAfter("e\u{301}x", .fromRaw(0), .{}).raw());
    // A prepend joins the pair of regional indicators after it.
    const flags = "\u{600}\u{1f1e6}\u{1f1e6}\u{1f1e6}";
    var back: Iterator(.{}) = .initAt(flags, .fromRaw(flags.len));
    try std.testing.expectEqualStrings("\u{1f1e6}", back.prev().?);
    try std.testing.expectEqualStrings("\u{600}\u{1f1e6}\u{1f1e6}", back.prev().?);
}
