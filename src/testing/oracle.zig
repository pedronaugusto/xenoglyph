//! UAX #29's rules read literally, as the oracle the iterators are held to:
//! each position is decided on its own, from the whole text around it, by
//! the rules in their order, with WB4 and SB5 applied as section 6.2
//! rewrites them. No state is carried, no segment start stands in for the
//! start of the text, and no lookahead is cached. Quadratic, for tests.
const std = @import("std");
const xenoglyph = @import("../xenoglyph.zig");

const WordBreak = xenoglyph.WordBreak;
const SentenceBreak = xenoglyph.SentenceBreak;

/// The code points of `bytes`, decoded as the iterators decode, and the
/// byte offset of each, with the end last.
pub const Decoded = struct {
    code_points: []u21,
    offsets: []usize,

    pub fn init(gpa: std.mem.Allocator, bytes: []const u8) !Decoded {
        var cps: std.ArrayList(u21) = .empty;
        var offsets: std.ArrayList(usize) = .empty;
        var it: xenoglyph.utf8.Iterator = .init(bytes);
        while (true) {
            try offsets.append(gpa, it.index);
            const cp = it.next() orelse break;
            try cps.append(gpa, cp);
        }
        return .{ .code_points = try cps.toOwnedSlice(gpa), .offsets = try offsets.toOwnedSlice(gpa) };
    }
};

/// The byte offsets of every boundary after the start: the end of each
/// segment, as an iterator's spans give them.
pub fn graphemes(gpa: std.mem.Allocator, d: Decoded) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    const cps = d.code_points;
    if (cps.len == 0) return &.{};
    for (1..cps.len) |i| if (graphemeBoundary(cps, i)) try out.append(gpa, d.offsets[i]);
    if (cps.len > 0) try out.append(gpa, d.offsets[cps.len]);
    return out.toOwnedSlice(gpa);
}

fn graphemeBoundary(cps: []const u21, i: usize) bool {
    const gcb = xenoglyph.graphemeBreak;
    const p = gcb(cps[i - 1]);
    const c = gcb(cps[i]);
    if (p == .cr and c == .lf) return false; // GB3
    if (p == .control or p == .cr or p == .lf) return true; // GB4
    if (c == .control or c == .cr or c == .lf) return true; // GB5
    if (p == .l and (c == .l or c == .v or c == .lv or c == .lvt)) return false; // GB6
    if ((p == .lv or p == .v) and (c == .v or c == .t)) return false; // GB7
    if ((p == .lvt or p == .t) and c == .t) return false; // GB8
    if (c == .extend or c == .zwj) return false; // GB9
    if (c == .spacing_mark) return false; // GB9a
    if (p == .prepend) return false; // GB9b
    if (xenoglyph.indicConjunctBreak(cps[i]) == .consonant) { // GB9c
        var k = i;
        while (k > 0 and xenoglyph.indicConjunctBreak(cps[k - 1]) == .extend) k -= 1;
        if (k > 0 and xenoglyph.indicConjunctBreak(cps[k - 1]) == .linker) return false;
    }
    if (p == .zwj and xenoglyph.emoji(cps[i]).extended_pictographic) { // GB11
        var k = i - 1;
        while (k > 0 and gcb(cps[k - 1]) == .extend) k -= 1;
        if (k > 0 and xenoglyph.emoji(cps[k - 1]).extended_pictographic) return false;
    }
    if (p == .regional_indicator and c == .regional_indicator) { // GB12, GB13
        var run: usize = 0;
        var k = i;
        while (k > 0 and gcb(cps[k - 1]) == .regional_indicator) : (k -= 1) run += 1;
        if (run % 2 == 1) return false;
    }
    return true; // GB999
}

pub fn words(gpa: std.mem.Allocator, d: Decoded) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    const cps = d.code_points;
    if (cps.len == 0) return &.{};
    for (1..cps.len) |i| if (wordBoundary(cps, i)) try out.append(gpa, d.offsets[i]);
    if (cps.len > 0) try out.append(gpa, d.offsets[cps.len]);
    return out.toOwnedSlice(gpa);
}

fn wb(cp: u21) WordBreak {
    return xenoglyph.wordBreak(cp);
}

fn wordIgnored(c: WordBreak) bool {
    return c == .extend or c == .format or c == .zwj;
}

fn wordNewline(c: WordBreak) bool {
    return c == .newline or c == .cr or c == .lf;
}

/// WB4: the index of the character that the run of ignored characters
/// ending at `k` belongs to, which is `k` itself unless it is ignored and
/// follows something other than the start or a line break; null before the
/// start.
fn wordLeft(cps: []const u21, end: ?usize) ?usize {
    var k = end orelse return null;
    while (wordIgnored(wb(cps[k]))) {
        if (k == 0 or wordNewline(wb(cps[k - 1]))) return k;
        k -= 1;
    }
    return k;
}

fn before(k: ?usize) ?usize {
    const i = k orelse return null;
    return if (i == 0) null else i - 1;
}

fn wordRight(cps: []const u21, start: usize) ?WordBreak {
    var k = start;
    while (k < cps.len) : (k += 1) if (!wordIgnored(wb(cps[k]))) return wb(cps[k]);
    return null;
}

fn wordAt(cps: []const u21, k: ?usize) ?WordBreak {
    return if (k) |i| wb(cps[i]) else null;
}

fn sentenceAt(cps: []const u21, k: ?usize) ?SentenceBreak {
    return if (k) |i| sb(cps[i]) else null;
}

fn ah(c: ?WordBreak) bool {
    return c == .a_letter or c == .hebrew_letter;
}

fn wordBoundary(cps: []const u21, i: usize) bool {
    const p = wb(cps[i - 1]);
    const c = wb(cps[i]);
    if (p == .cr and c == .lf) return false; // WB3
    if (wordNewline(p)) return true; // WB3a
    if (wordNewline(c)) return true; // WB3b
    if (p == .zwj and xenoglyph.emoji(cps[i]).extended_pictographic) return false; // WB3c
    if (p == .w_seg_space and c == .w_seg_space) return false; // WB3d
    if (wordIgnored(c)) return false; // WB4
    const l1 = wordLeft(cps, i - 1);
    const l2 = wordLeft(cps, before(l1));
    const a = wordAt(cps, l1);
    const b = wordAt(cps, l2);
    const r = wordRight(cps, i + 1);
    const mid = struct {
        fn letter(x: ?WordBreak) bool {
            return x == .mid_letter or x == .mid_num_let or x == .single_quote;
        }
        fn num(x: ?WordBreak) bool {
            return x == .mid_num or x == .mid_num_let or x == .single_quote;
        }
    };
    if (ah(a) and ah(c)) return false; // WB5
    if (ah(a) and mid.letter(c) and ah(r)) return false; // WB6
    if (ah(b) and mid.letter(a) and ah(c)) return false; // WB7
    if (a == .hebrew_letter and c == .single_quote) return false; // WB7a
    if (a == .hebrew_letter and c == .double_quote and r == .hebrew_letter) return false; // WB7b
    if (b == .hebrew_letter and a == .double_quote and c == .hebrew_letter) return false; // WB7c
    if (a == .numeric and c == .numeric) return false; // WB8
    if (ah(a) and c == .numeric) return false; // WB9
    if (a == .numeric and ah(c)) return false; // WB10
    if (b == .numeric and mid.num(a) and c == .numeric) return false; // WB11
    if (a == .numeric and mid.num(c) and r == .numeric) return false; // WB12
    if (a == .katakana and c == .katakana) return false; // WB13
    if ((ah(a) or a == .numeric or a == .katakana or a == .extend_num_let) and c == .extend_num_let) return false; // WB13a
    if (a == .extend_num_let and (ah(c) or c == .numeric or c == .katakana)) return false; // WB13b
    if (a == .regional_indicator and c == .regional_indicator) { // WB15, WB16
        var run: usize = 0;
        var k = l1;
        while (k) |at| {
            if (wb(cps[at]) != .regional_indicator) break;
            run += 1;
            k = wordLeft(cps, before(at));
        }
        if (run % 2 == 1) return false;
    }
    return true; // WB999
}

pub fn sentences(gpa: std.mem.Allocator, d: Decoded) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    const cps = d.code_points;
    if (cps.len == 0) return &.{};
    for (1..cps.len) |i| if (sentenceBoundary(cps, i)) try out.append(gpa, d.offsets[i]);
    if (cps.len > 0) try out.append(gpa, d.offsets[cps.len]);
    return out.toOwnedSlice(gpa);
}

fn sb(cp: u21) SentenceBreak {
    return xenoglyph.sentenceBreak(cp);
}

fn paraSep(c: ?SentenceBreak) bool {
    return c == .sep or c == .cr or c == .lf;
}

fn saTerm(c: ?SentenceBreak) bool {
    return c == .s_term or c == .a_term;
}

fn sentenceLeft(cps: []const u21, end: ?usize) ?usize {
    var k = end orelse return null;
    while (sb(cps[k]) == .extend or sb(cps[k]) == .format) {
        if (k == 0 or paraSep(sb(cps[k - 1]))) return k;
        k -= 1;
    }
    return k;
}

/// The run SATerm Close* Sp* ParaSep? that ends at `end`, read backwards.
const Run = struct { term: SentenceBreak, spaces: bool, separator: bool };

fn runEndingAt(cps: []const u21, end: ?usize, allow_separator: bool) ?Run {
    var k = end;
    var run: Run = .{ .term = .other, .spaces = false, .separator = false };
    if (allow_separator) if (k) |at| if (paraSep(sb(cps[at]))) {
        run.separator = true;
        k = sentenceLeft(cps, before(at));
    };
    while (k) |at| {
        if (sb(cps[at]) != .sp) break;
        run.spaces = true;
        k = sentenceLeft(cps, before(at));
    }
    while (k) |at| {
        if (sb(cps[at]) != .close) break;
        k = sentenceLeft(cps, before(at));
    }
    const at = k orelse return null;
    if (!saTerm(sb(cps[at]))) return null;
    run.term = sb(cps[at]);
    return run;
}

fn sentenceBoundary(cps: []const u21, i: usize) bool {
    const p = sb(cps[i - 1]);
    const c = sb(cps[i]);
    if (p == .cr and c == .lf) return false; // SB3
    if (paraSep(p)) return true; // SB4
    if (c == .extend or c == .format) return false; // SB5
    const l1 = sentenceLeft(cps, i - 1);
    const l2 = sentenceLeft(cps, before(l1));
    const a = sentenceAt(cps, l1);
    const b = sentenceAt(cps, l2);
    if (a == .a_term and c == .numeric) return false; // SB6
    if ((b == .upper or b == .lower) and a == .a_term and c == .upper) return false; // SB7
    if (runEndingAt(cps, l1, false)) |run| {
        if (run.term == .a_term) { // SB8
            var k = i;
            while (k < cps.len) : (k += 1) {
                const x = sb(cps[k]);
                if (x == .lower) return false;
                if (x == .o_letter or x == .upper or paraSep(x) or saTerm(x)) break;
            }
        }
        if (c == .s_continue or saTerm(c)) return false; // SB8a
        if (!run.spaces and (c == .close or c == .sp or paraSep(c))) return false; // SB9
        if (c == .sp or paraSep(c)) return false; // SB10
    }
    if (runEndingAt(cps, l1, true) != null) return true; // SB11
    return false; // SB998
}
