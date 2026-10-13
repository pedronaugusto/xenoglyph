//! Properties over generated text, through shakedown: seeded cases in every
//! `bay test`, and the fuzzer's inputs under `bay test --fuzz`. The text
//! mixes the code points the rules treat specially (controls, marks,
//! joiners, selectors, modifiers, regional indicators, jamo, Indic
//! consonants and linkers, prepends, terminators, quotes) with arbitrary
//! bytes, so ill-formed UTF-8 meets every rule.
const std = @import("std");
const shakedown = @import("shakedown");
const xenoglyph = @import("../xenoglyph.zig");
const grapheme = xenoglyph.grapheme;
const width = xenoglyph.width;
const utf8 = xenoglyph.utf8;
const oracle = @import("oracle.zig");

const gen = shakedown.gen;

/// Code points the rules read differently, each class a few of them.
const interesting = [_]u21{
    'a',     'Z',     '0',     ' ',     '.',     '?',     '\'',    '"',     ',',     ':',     '_',     '(',      ')',
    '\r',    '\n',    '\t',    0x0b,    0x85,    0xa0,    0xad,    0x300,   0x301,   0x36f,   0x5d0,   0x5f3,    0x600,
    0x903,   0x915,   0x937,   0x93f,   0x94d,   0x9cd,   0x995,   0xe33,   0x1100,  0x1161,  0x11a8,  0xac00,   0xac01,
    0x1cf5,  0x200b,  0x200c,  0x200d,  0x2018,  0x2019,  0x2028,  0x202f,  0x2060,  0x20e3,  0x2601,  0x263a,   0x2764,
    0x3002,  0x30a2,  0x3099,  0x4e00,  0xfe0e,  0xfe0f,  0xfeff,  0xff0e,  0xfffd,  0x1f1e6, 0x1f1e8, 0x1f1ed,  0x1f3fb,
    0x1f3ff, 0x1f44d, 0x1f468, 0x1f469, 0x1f590, 0x1f600, 0x1f680, 0xe0067, 0xe007f, 0x11a3a, 0x16d63, 0x10ffff, '-',
    '$',     '%',     '/',     '!',     '[',     0xab,    0xbb,    0x2010,  0x2014,  0x2026,  0x201c,  0x201d,   0x3000,
    0x3001,  0x300c,  0x300d,  0xfffc,  0x1b05,  0x1b44,  0x1b3a,  0x25cc,  0xa9c0,  0x11f04, 0x1f3fb, 0x1fffd,
};

fn piece(s: *shakedown.Source, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    switch (gen.intRange(s, u8, 0, 9)) {
        0...5 => {
            var buffer: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(gen.oneOf(s, u21, &interesting), &buffer) catch unreachable; // unreachable: the list holds only scalar values
            try out.appendSlice(gpa, buffer[0..n]);
        },
        6, 7 => {
            const cp = gen.intRange(s, u21, 0, 0x10ffff);
            if (cp >= 0xd800 and cp <= 0xdfff) return;
            var buffer: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buffer) catch unreachable; // unreachable: surrogates are skipped above
            try out.appendSlice(gpa, buffer[0..n]);
        },
        else => try out.append(gpa, gen.int(s, u8)),
    }
}

fn text(case: *shakedown.Case) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const mark = case.source.begin();
    defer case.source.end(mark);
    while (out.items.len < 256 and case.source.more(12)) try piece(case.source, &out, case.gpa);
    return out.items;
}

/// The spans an iterator yields cover the text in order, each nonempty, and
/// each boundary is where a code point starts.
fn expectCover(bytes: []const u8, it: anytype) !std.ArrayList(usize) {
    var ends: std.ArrayList(usize) = .empty;
    var start: usize = 0;
    while (it.nextSpan()) |span| {
        try std.testing.expectEqual(start, span.start);
        try std.testing.expect(span.end > span.start);
        try ends.append(std.testing.allocator, span.end);
        start = span.end;
    }
    try std.testing.expectEqual(bytes.len, start);
    // Every boundary falls where the decoder starts a code point.
    var d: utf8.Iterator = .init(bytes);
    var starts: std.ArrayList(usize) = .empty;
    defer starts.deinit(std.testing.allocator);
    while (true) {
        try starts.append(std.testing.allocator, d.index);
        if (d.next() == null) break;
    }
    for (ends.items) |e| try std.testing.expect(std.mem.findScalar(usize, starts.items, e) != null);
    return ends;
}

fn segmentsWith(comptime rules: grapheme.Rules, bytes: []const u8) !void {
    var it: grapheme.Iterator(rules) = .init(bytes);
    var ends = try expectCover(bytes, &it);
    defer ends.deinit(std.testing.allocator);
    // The breaker over the decoded code points finds the same boundaries.
    var b: grapheme.Breaker(rules) = .{};
    var d: utf8.Iterator = .init(bytes);
    var found: usize = 0;
    var first = true;
    while (true) {
        const at = d.index;
        const cp = d.next() orelse break;
        if (b.next(cp) and !first) {
            try std.testing.expectEqual(ends.items[found], at);
            found += 1;
        }
        first = false;
    }
    if (bytes.len > 0) try std.testing.expectEqual(ends.items.len - 1, found);
    // Measured whole, each cluster is 0 to 2 columns, and the string's
    // columns are their sum.
    var total: usize = 0;
    var again: grapheme.Iterator(rules) = .init(bytes);
    while (again.next()) |g| total += width.cluster(g, .{});
    try std.testing.expectEqual(total, width.string(bytes, .{ .rules = rules }));
}

fn graphemes(_: void, case: *shakedown.Case) anyerror!void {
    const bytes = try text(case);
    try segmentsWith(.{}, bytes);
    try segmentsWith(.{ .modifiers = .after_base }, bytes);
    try segmentsWith(.{ .controls = .as_other }, bytes);
    try segmentsWith(grapheme.Rules.terminal, bytes);
}

test "grapheme clusters cover any text, agree with the breaker and sum to its width" {
    try shakedown.check(std.testing.allocator, {}, graphemes, .{ .cases = 2000 });
}

fn againstOracle(_: void, case: *shakedown.Case) anyerror!void {
    const bytes = try text(case);
    case.note("text: {any}", .{bytes});
    const decoded: oracle.Decoded = try .init(case.gpa, bytes);
    var g: grapheme.Iterator(.{}) = .init(bytes);
    var clusters = try expectCover(bytes, &g);
    defer clusters.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(usize, try oracle.graphemes(case.gpa, decoded), clusters.items);
    var w = xenoglyph.words(bytes);
    var words = try expectCover(bytes, &w);
    defer words.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(usize, try oracle.words(case.gpa, decoded), words.items);
    var s = xenoglyph.sentences(bytes);
    var sentences = try expectCover(bytes, &s);
    defer sentences.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(usize, try oracle.sentences(case.gpa, decoded), sentences.items);
    var want_lines = try oracle.lines(case.gpa, decoded);
    var l = xenoglyph.lines(bytes);
    var start: usize = 0;
    for (want_lines) |want| {
        const got = l.nextBreak() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(start, got.span.start);
        try std.testing.expectEqual(want.end, got.span.end);
        try std.testing.expectEqual(want.mandatory, got.mandatory);
        start = got.span.end;
    }
    try std.testing.expectEqual(null, l.nextBreak());
    want_lines = undefined;
}

// Word and sentence boundaries are not always cluster boundaries: the
// default rules put a word boundary inside a cluster after a Prepend (GB9b,
// "aaa" U+0600 U+07B2), before a SpacingMark that is not Word_Break Extend
// (GB9a, "a" U+0E33), before a consonant a lone linker joins (GB9c,
// U+094D U+0915), and a sentence boundary before a skin tone after a full
// stop (". U+1F3FB"). xenoglyph keeps to the rules, so the oracle, not
// the clusters, is what the segments are held to.
test "graphemes, words, sentences and lines of any text are the rules read literally" {
    try shakedown.check(std.testing.allocator, {}, againstOracle, .{ .cases = 3000 });
}

fn widths(_: void, case: *shakedown.Case) anyerror!void {
    const bytes = try text(case);
    var d: utf8.Iterator = .init(bytes);
    var sum: usize = 0;
    var wide: usize = 0;
    while (d.next()) |cp| {
        sum += width.codepoint(cp, .{});
        wide += width.codepoint(cp, .{ .ambiguous = .wide });
    }
    try std.testing.expectEqual(sum, width.string(bytes, .{ .method = .codepoint }));
    try std.testing.expectEqual(wide, width.string(bytes, .{ .method = .codepoint, .ambiguous = .wide }));
    try std.testing.expect(width.string(bytes, .{}) <= width.string(bytes, .{ .ambiguous = .wide }));
}

test "measured by code point, a string's width is the sum of its code points'" {
    try shakedown.check(std.testing.allocator, {}, widths, .{ .cases = 2000 });
}

/// The longest prefix of `bytes` (at most the sequence its lead asks for)
/// that some well-formed sequence begins with, found by trying every
/// completion: the maximal subpart, by its definition.
fn maximalSubpart(bytes: []const u8) usize {
    const want = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return 1;
    var best: usize = 1;
    var k: usize = 1;
    while (k <= @min(want, bytes.len)) : (k += 1) {
        var sequence: [4]u8 = undefined;
        @memcpy(sequence[0..k], bytes[0..k]);
        if (completes(&sequence, k, want)) best = k else break;
    }
    return best;
}

fn completes(sequence: *[4]u8, have: usize, want: usize) bool {
    if (have == want) {
        _ = stdDecode(sequence[0..want]) catch return false;
        return true;
    }
    var b: u8 = 0x80;
    while (b <= 0xbf) : (b += 1) {
        sequence[have] = b;
        if (completes(sequence, have + 1, want)) return true;
    }
    return false;
}

fn decoding(_: void, case: *shakedown.Case) anyerror!void {
    const bytes = try gen.string(case.source, case.gpa, .{ .kind = .bytes, .max_len = 64 });
    var at: usize = 0;
    while (at < bytes.len) {
        const d = utf8.decode(bytes[at..]);
        const valid = blk: {
            const n = std.unicode.utf8ByteSequenceLength(bytes[at]) catch break :blk false;
            if (n > bytes.len - at) break :blk false;
            _ = stdDecode(bytes[at..][0..n]) catch break :blk false;
            break :blk true;
        };
        if (valid) {
            const n = std.unicode.utf8ByteSequenceLength(bytes[at]) catch unreachable; // unreachable: valid above
            try std.testing.expectEqual(n, d.len);
            try std.testing.expectEqual(try stdDecode(bytes[at..][0..n]), d.code_point);
        } else {
            try std.testing.expectEqual(utf8.replacement, d.code_point);
            try std.testing.expectEqual(maximalSubpart(bytes[at..]), d.len);
        }
        at += d.len;
    }
}

test "decoding agrees with std on well-formed UTF-8 and takes maximal subparts of the rest" {
    try shakedown.check(std.testing.allocator, {}, decoding, .{ .cases = 4000 });
}

/// std's decoding of one whole sequence of `bytes.len` bytes.
fn stdDecode(bytes: []const u8) !u21 {
    return switch (bytes.len) {
        1 => if (bytes[0] < 0x80) bytes[0] else error.Utf8InvalidStartByte,
        2 => std.unicode.utf8Decode2(bytes[0..2].*),
        3 => std.unicode.utf8Decode3(bytes[0..3].*),
        4 => std.unicode.utf8Decode4(bytes[0..4].*),
        else => error.Utf8InvalidStartByte,
    };
}

/// Marks of many classes, some that compose, joiners, Hangul jamo and
/// syllables, compatibility characters, and a few letters.
const marks = [_]u21{ 0x300, 0x301, 0x302, 0x303, 0x307, 0x308, 0x30a, 0x323, 0x327, 0x328, 0x331, 0x345, 0x5b0, 0x5bf, 0x93c, 0x94d, 0xe38, 0x1dce, 0x302a, 0x302b, 0x1d167, 0x344, 0xf73, 0xf75 };
const bases = [_]u21{ 'a', 'e', 'o', 'A', 0x3b1, 0x3b9, 0x928, 0x1100, 0x1161, 0x11a8, 0xac00, 0xac01, 0x1e0b, 0x212b, 0xfb01, 0x2460, 0xfdfa, 0x1f1, 0xb47, 0xb3e };

fn markText(case: *shakedown.Case) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    // Runs of a base and up to 100 marks, so some pass the 32 a run holds
    // in the iterator's buffer.
    while (out.items.len < 1200 and case.source.more(3)) {
        var buffer: [4]u8 = undefined;
        var len = std.unicode.utf8Encode(gen.oneOf(case.source, u21, &bases), &buffer) catch unreachable; // unreachable: the list holds scalar values
        if (gen.boolean(case.source)) try out.appendSlice(case.gpa, buffer[0..len]);
        for (0..gen.intRange(case.source, u8, 0, 100)) |_| {
            len = std.unicode.utf8Encode(gen.oneOf(case.source, u21, &marks), &buffer) catch unreachable; // unreachable: the list holds scalar values
            try out.appendSlice(case.gpa, buffer[0..len]);
        }
    }
    return out.items;
}

fn normalForms(_: void, case: *shakedown.Case) anyerror!void {
    const bytes = if (gen.boolean(case.source)) try markText(case) else try text(case);
    case.note("text: {any}", .{bytes});
    const decoded: oracle.Decoded = try .init(case.gpa, bytes);
    inline for (.{ .nfd, .nfc, .nfkd, .nfkc }) |form| {
        const want = try oracle.normalized(case.gpa, form, decoded);
        var it: xenoglyph.normalize.Iterator(form) = .init(bytes);
        for (want) |w| try std.testing.expectEqual(@as(?u21, w), it.next());
        try std.testing.expectEqual(null, it.next());
        // `write`, a region between ASCII bytes at a time, gives the same.
        var out: std.Io.Writer.Allocating = .init(case.gpa);
        try xenoglyph.normalize.write(form, bytes, &out.writer);
        var written: utf8.Iterator = .init(out.written());
        for (want) |w| try std.testing.expectEqual(@as(?u21, w), written.next());
        try std.testing.expectEqual(null, written.next());
        try std.testing.expectEqual(std.mem.eql(u8, bytes, out.written()), xenoglyph.normalize.isNormalized(form, bytes));
    }
}

test "normal forms of any text, long runs of marks included, are the algorithm done plainly" {
    try shakedown.check(std.testing.allocator, {}, normalForms, .{ .cases = 1500 });
}

/// Letters with special casings and the marks their contexts read.
const casing = [_]u21{ 'I', 'i', 'J', 0x130, 0x131, 0x307, 0x301, 0x323, 0x3a3, 0x3c3, 0x391, '.', ' ', 0xdf, 0x1e9e, 0xfb01, 0x149, 0x390, 0x1f88, 0x1c4, 0x1c5, 0x1c6, 0x12e, 0xcc, 0x345, 0x10d0, 0x1c90, 0x2c65, 0xa7c6 };

fn caseText(case: *shakedown.Case) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    while (out.items.len < 200 and case.source.more(16)) {
        if (gen.boolean(case.source)) {
            var buffer: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(gen.oneOf(case.source, u21, &casing), &buffer) catch unreachable; // unreachable: the list holds scalar values
            try out.appendSlice(case.gpa, buffer[0..len]);
        } else try piece(case.source, &out, case.gpa);
    }
    return out.items;
}

fn caseOf(comptime mapping: xenoglyph.case.Mapping, gpa: std.mem.Allocator, bytes: []const u8, options: xenoglyph.case.Options) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    try xenoglyph.case.write(mapping, bytes, &out.writer, options);
    // The writer gives what the iterator gives.
    var it: xenoglyph.case.Iterator(mapping) = .init(bytes, options);
    var again: utf8.Iterator = .init(out.written());
    while (it.next()) |cp| try std.testing.expectEqual(@as(?u21, cp), again.next());
    try std.testing.expectEqual(null, again.next());
    return out.written();
}

fn caseMappings(_: void, case: *shakedown.Case) anyerror!void {
    const bytes = try caseText(case);
    case.note("text: {any}", .{bytes});
    inline for (.{ .none, .turkic, .lithuanian }) |language| {
        const options: xenoglyph.case.Options = .{ .language = language };
        inline for (.{ .fold, .lower, .upper }) |mapping| {
            const once = try caseOf(mapping, case.gpa, bytes, options);
            try std.testing.expectEqualStrings(once, try caseOf(mapping, case.gpa, once, options));
        }
        _ = try caseOf(.title, case.gpa, bytes, options);
        try std.testing.expect(xenoglyph.case.equalFold(bytes, try caseOf(.fold, case.gpa, bytes, options), options));
    }
}

test "folding, lowercasing and uppercasing any text are idempotent in every language" {
    try shakedown.check(std.testing.allocator, {}, caseMappings, .{ .cases = 1000 });
}
