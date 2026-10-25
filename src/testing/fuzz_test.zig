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
const security_test = @import("security_test.zig");

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
        try std.testing.expectEqual(start, span.start.raw());
        try std.testing.expect(span.end.compare(span.start) == .gt);
        try ends.append(std.testing.allocator, span.end.raw());
        start = span.end.raw();
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
    try expectBackward(rules, bytes, ends.items);
    // Measured whole, each cluster is 0 to 2 columns, and the string's
    // columns are their sum.
    var total: usize = 0;
    var again: grapheme.Iterator(rules) = .init(bytes);
    while (again.next()) |g| total += width.cluster(g, .{}).raw();
    try std.testing.expectEqual(total, width.string(bytes, .{ .rules = rules }).raw());
}

/// Read backward, a text's clusters are the ones read forward (`ends`, the
/// end of each): by `prev` from the end, and by `boundaryBefore` from every
/// byte offset, inside a code point or an ill-formed sequence too; and
/// read forward from any boundary, by `initAt` and `boundaryAfter`, they
/// are the ones read from the start.
fn expectBackward(comptime rules: grapheme.Rules, bytes: []const u8, ends: []const usize) !void {
    var it: grapheme.Iterator(rules) = .initAt(bytes, .fromRaw(bytes.len));
    var k = ends.len;
    while (k > 0) {
        k -= 1;
        const span = it.prevSpan().?;
        try std.testing.expectEqual(ends[k], span.end.raw());
        try std.testing.expectEqual(if (k == 0) 0 else ends[k - 1], span.start.raw());
        try std.testing.expectEqual(ends[k], grapheme.boundaryAfter(bytes, span.start, rules).raw());
    }
    try std.testing.expectEqual(null, it.prevSpan());
    var before: usize = 0;
    var next: usize = 0;
    for (1..bytes.len + 1) |offset| {
        try std.testing.expectEqual(before, grapheme.boundaryBefore(bytes, .fromRaw(offset), rules).raw());
        if (offset == ends[next]) {
            before = offset;
            next += 1;
        }
    }
    // Forward from a boundary in the middle, and back and forth there.
    if (ends.len > 1) {
        const middle = ends.len / 2;
        var from: grapheme.Iterator(rules) = .initAt(bytes, .fromRaw(ends[middle - 1]));
        for (ends[middle..]) |e| try std.testing.expectEqual(e, from.nextSpan().?.end.raw());
        try std.testing.expectEqual(null, from.nextSpan());
        try std.testing.expectEqual(ends[ends.len - 2], from.prevSpan().?.start.raw());
        try std.testing.expectEqual(bytes.len, from.nextSpan().?.end.raw());
    }
}

/// Code points the backward rules read context for, and what breaks that
/// context: dense, so long runs of regional indicators, Extend, Indic
/// linkers and ZWJ sequences form, among ill-formed bytes.
const contextual = [_]u21{
    0x1f1e6, 0x1f1e8, 0x1f1ed, 0x1f1e6, 0x600,   0x915,  0x937, 0x94d, 0x93c, 0x9cd, 0x300, 0x200d, 0x200d,
    0x1f468, 0x1f469, 0x2764,  0x1f3fb, 0x1f44d, 0xfe0f, 'a',   '\r',  '\n',  '\t',  0x903, 0x1100, 0x1161,
};

fn denseText(case: *shakedown.Case) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const mark = case.source.begin();
    defer case.source.end(mark);
    while (out.items.len < 256 and case.source.more(12)) {
        if (gen.intRange(case.source, u8, 0, 15) == 0) {
            try out.append(case.gpa, gen.oneOf(case.source, u8, &.{ 0x80, 0xbf, 0xe0, 0xf0, 0xf4, 0x9f, 0xc2, 0xff }));
            continue;
        }
        // A code point repeated, so runs form.
        var buffer: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(gen.oneOf(case.source, u21, &contextual), &buffer) catch unreachable; // unreachable: the list holds only scalar values
        for (0..gen.intRange(case.source, u8, 1, 5)) |_| try out.appendSlice(case.gpa, buffer[0..n]);
    }
    return out.items;
}

fn denseGraphemes(_: void, case: *shakedown.Case) anyerror!void {
    const bytes = try denseText(case);
    case.note("text: {any}", .{bytes});
    try segmentsWith(.{}, bytes);
    try segmentsWith(.{ .modifiers = .after_base }, bytes);
    try segmentsWith(.{ .controls = .as_other }, bytes);
    try segmentsWith(grapheme.Rules.terminal, bytes);
    // Forward, the clusters are the rules read literally.
    const decoded: oracle.Decoded = try .init(case.gpa, bytes);
    var g: grapheme.Iterator(.{}) = .init(bytes);
    var clusters = try expectCover(bytes, &g);
    defer clusters.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(usize, try oracle.graphemes(case.gpa, decoded), clusters.items);
}

test "grapheme clusters of text dense in the context the rules read are the same read backward" {
    try shakedown.check(std.testing.allocator, {}, denseGraphemes, .{ .cases = 2000 });
}

fn graphemes(_: void, case: *shakedown.Case) anyerror!void {
    const bytes = try text(case);
    try segmentsWith(.{}, bytes);
    try segmentsWith(.{ .modifiers = .after_base }, bytes);
    try segmentsWith(.{ .controls = .as_other }, bytes);
    try segmentsWith(grapheme.Rules.terminal, bytes);
}

test "grapheme clusters cover any text, agree with the breaker, read the same backward and sum to its width" {
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
        try std.testing.expectEqual(start, got.span.start.raw());
        try std.testing.expectEqual(want.end, got.span.end.raw());
        try std.testing.expectEqual(want.mandatory, got.mandatory);
        start = got.span.end.raw();
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
        sum += width.codepoint(cp, .{}).raw();
        wide += width.codepoint(cp, .{ .ambiguous = .wide }).raw();
    }
    try std.testing.expectEqual(sum, width.string(bytes, .{ .method = .codepoint }).raw());
    try std.testing.expectEqual(wide, width.string(bytes, .{ .method = .codepoint, .ambiguous = .wide }).raw());
    try std.testing.expect(width.string(bytes, .{}).compare(width.string(bytes, .{ .ambiguous = .wide })) != .gt);
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

fn wellFormedPrefix(_: void, case: *shakedown.Case) anyerror!void {
    // Text mostly well-formed, so the sixteen-byte chunks run, with its
    // ill-formed bytes anywhere, a chunk's edges included.
    var bytes: std.ArrayList(u8) = .empty;
    for (0..gen.intRange(case.source, usize, 0, 12)) |_| try bytes.appendSlice(case.gpa, try text(case));
    try std.testing.expectEqual(decodedPrefix(bytes.items), utf8.wellFormed(bytes.items));
}

fn decodedPrefix(bytes: []const u8) usize {
    var at: usize = 0;
    while (at < bytes.len) {
        const d = utf8.decode(bytes[at..]);
        if (d.code_point == utf8.replacement and !std.mem.startsWith(u8, bytes[at..], "\xef\xbf\xbd")) break;
        at += d.len;
    }
    return at;
}

test "the well-formed prefix finds every sequence of two bytes, and of three on each lead, across a chunk's edge" {
    var buffer: [40]u8 = undefined;
    for (12..19) |offset| {
        for (0..0x10000) |pair| {
            @memset(&buffer, 'a');
            std.mem.writeInt(u16, buffer[offset..][0..2], @intCast(pair), .big);
            try std.testing.expectEqual(decodedPrefix(&buffer), utf8.wellFormed(&buffer));
        }
        for (0xc0..0x100) |lead| for (0..0x100) |second| for ([_]u8{ 0x41, 0x80, 0xbf, 0xc0 }) |third| {
            @memset(&buffer, 'a');
            buffer[offset..][0..4].* = .{ @intCast(lead), @intCast(second), third, 0x80 };
            try std.testing.expectEqual(decodedPrefix(&buffer), utf8.wellFormed(&buffer));
        };
    }
}

test "the well-formed prefix of any text is where decoding first meets an ill-formed sequence" {
    try shakedown.check(std.testing.allocator, {}, wellFormedPrefix, .{ .cases = 3000 });
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
const marks = [_]u21{ 0x345, 0x300, 0x301, 0x302, 0x303, 0x307, 0x308, 0x30a, 0x323, 0x327, 0x328, 0x331, 0x345, 0x5b0, 0x5bf, 0x93c, 0x94d, 0xe38, 0x1dce, 0x302a, 0x302b, 0x1d167, 0x344, 0xf73, 0xf75 };
const bases = [_]u21{ 'a', 'e', 'o', 'A', 0x3b1, 0x3b9, 0x928, 0x1100, 0x1161, 0x11a8, 0xac00, 0xac01, 0x1e0b, 0x212b, 0xfb01, 0x2460, 0xfdfa, 0x1f1, 0xb47, 0xb3e };

fn markText(case: *shakedown.Case, max_len: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    // Runs of a base and up to 100 marks, so some pass the 32 a run holds
    // in the iterator's buffer.
    while (out.items.len < max_len and case.source.more(3)) {
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
    const bytes = if (gen.boolean(case.source)) try markText(case, 1200) else try text(case);
    case.note("text: {any}", .{bytes});
    const decoded: oracle.Decoded = try .init(case.gpa, bytes);
    inline for (.{ .nfd, .nfc, .nfkd, .nfkc, .nfkc_casefold }) |form| {
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
        try std.testing.expect(xenoglyph.case.equal(.default, bytes, try caseOf(.fold, case.gpa, bytes, options), options));
    }
}

test "folding, lowercasing and uppercasing any text are idempotent in every language" {
    try shakedown.check(std.testing.allocator, {}, caseMappings, .{ .cases = 1000 });
}

/// What the caseless matches treat specially: letters whose folding expands
/// or is Turkic, the iota subscript that folds to a starter, compatibility
/// characters that bring case or marks, default ignorables, Greek with
/// ypogegrammeni, and the marks around them.
const caseless_specials = [_]u21{ 'I', 'i', 0x130, 0x131, 0x345, 0x313, 0x301, 0x308, 0x323, 0x3b1, 0x391, 0x1f80, 0x1fb3, 0x1fbe, 0x37a, 0xdf, 0x1e9e, 0xfb01, 0x2122, 0x3392, 0xa8, 0xff76, 0xff9e, 0x2160, 0x212b, 0xc5, 0xad, 0x200b, 0x34f, 0xe0001, 0x1100, 0x1161, 0xac00, 0x3a3, 0x149 };

fn caselessText(case: *shakedown.Case) ![]const u8 {
    // Runs of marks past the 32 the ordering buffers.
    if (gen.intRange(case.source, u8, 0, 3) == 0) return markText(case, 600);
    var out: std.ArrayList(u8) = .empty;
    while (out.items.len < 200 and case.source.more(16)) {
        if (gen.intRange(case.source, u8, 0, 3) != 0) {
            var buffer: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(gen.oneOf(case.source, u21, &caseless_specials), &buffer) catch unreachable; // unreachable: the list holds scalar values
            try out.appendSlice(case.gpa, buffer[0..len]);
        } else try piece(case.source, &out, case.gpa);
    }
    return out.items;
}

/// A text that may match `a`: it again in another case or normal form, or
/// another text.
fn variant(case: *shakedown.Case, a: []const u8, options: xenoglyph.case.Options) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(case.gpa);
    switch (gen.intRange(case.source, u8, 0, 8)) {
        0 => try xenoglyph.case.write(.upper, a, &out.writer, options),
        1 => try xenoglyph.case.write(.lower, a, &out.writer, options),
        2 => try xenoglyph.case.write(.fold, a, &out.writer, options),
        3 => try xenoglyph.normalize.write(.nfd, a, &out.writer),
        4 => try xenoglyph.normalize.write(.nfc, a, &out.writer),
        5 => try xenoglyph.normalize.write(.nfkd, a, &out.writer),
        6 => try xenoglyph.normalize.write(.nfkc_casefold, a, &out.writer),
        7 => try xenoglyph.case.write(.title, a, &out.writer, options),
        else => return caselessText(case),
    }
    return out.written();
}

fn caselessMatches(_: void, case: *shakedown.Case) anyerror!void {
    const options: xenoglyph.case.Options = .{ .language = gen.oneOf(case.source, xenoglyph.case.Language, &.{ .none, .turkic }) };
    const a = try caselessText(case);
    const b = try variant(case, a, options);
    case.note("a: {any}\nb: {any}", .{ a, b });
    inline for (.{ .default, .canonical, .identifier }) |match| {
        const want = std.mem.eql(u21, try oracle.caseless(case.gpa, match, a, options), try oracle.caseless(case.gpa, match, b, options));
        try std.testing.expectEqual(want, xenoglyph.case.equal(match, a, b, options));
        try std.testing.expect(xenoglyph.case.equal(match, a, a, options));
    }
}

test "the caseless matches agree with folding and normalizing the whole text step by step" {
    try shakedown.check(std.testing.allocator, {}, caselessMatches, .{ .cases = 1500 });
}

fn punycodeRoundTrip(_: void, case: *shakedown.Case) anyerror!void {
    var code_points: [64]u21 = undefined;
    var n: usize = 0;
    while (n < code_points.len and case.source.more(8)) {
        const cp = if (gen.boolean(case.source)) gen.oneOf(case.source, u21, &interesting) else gen.intRange(case.source, u21, 0, 0x10ffff);
        if (cp >= 0xd800 and cp <= 0xdfff) continue;
        code_points[n] = cp;
        n += 1;
    }
    var encoded: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&encoded);
    try xenoglyph.punycode.encode(code_points[0..n], &w);
    for (w.buffered()) |c| try std.testing.expect(c < 0x80);
    var decoded: [64]u21 = undefined;
    try std.testing.expectEqualSlices(u21, code_points[0..n], try xenoglyph.punycode.decode(w.buffered(), &decoded));
    // Any bytes decode or are refused; what decodes encodes back to the
    // same, lower case.
    const bytes = try gen.string(case.source, case.gpa, .{ .kind = .bytes, .max_len = 32 });
    const got = xenoglyph.punycode.decode(bytes, &decoded) catch return;
    for (got) |cp| try std.testing.expect(cp <= 0x10ffff and (cp < 0xd800 or cp > 0xdfff));
}

test "Punycode encodes any code points and decodes them back, and decodes any bytes or refuses them" {
    try shakedown.check(std.testing.allocator, {}, punycodeRoundTrip, .{ .cases = 3000 });
}

fn domainNames(_: void, case: *shakedown.Case) anyerror!void {
    var name: std.ArrayList(u8) = .empty;
    const mark = case.source.begin();
    while (name.items.len < 96 and case.source.more(10)) {
        switch (gen.intRange(case.source, u8, 0, 9)) {
            0, 1 => try name.append(case.gpa, '.'),
            2 => try name.appendSlice(case.gpa, "xn--"),
            else => try piece(case.source, &name, case.gpa),
        }
    }
    case.source.end(mark);
    const idna = xenoglyph.idna;
    for ([_]idna.Options{ .{}, idna.Options.url }) |options| {
        var out: [8192]u8 = undefined;
        var w: std.Io.Writer = .fixed(&out);
        const failures = try idna.toAscii(name.items, &w, options);
        if (failures.any()) {
            try std.testing.expectEqual(@as(usize, 0), w.end);
            continue;
        }
        const ascii = w.buffered();
        for (ascii) |c| try std.testing.expect(c < 0x80);
        // Processing is idempotent: the ASCII form processes to itself,
        // and shows without a failure.
        var again: [8192]u8 = undefined;
        var w2: std.Io.Writer = .fixed(&again);
        try std.testing.expect(!(try idna.toAscii(ascii, &w2, options)).any());
        try std.testing.expectEqualStrings(ascii, w2.buffered());
        w2 = .fixed(&again);
        try std.testing.expect(!(try idna.toUnicode(ascii, &w2, options)).any());
    }
}

test "a name toAscii accepts is ASCII, processes to itself, and shows without a failure" {
    try shakedown.check(std.testing.allocator, {}, domainNames, .{ .cases = 3000 });
}

fn skeletonOf(gpa: std.mem.Allocator, bytes: []const u8, direction: xenoglyph.security.Direction) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    try xenoglyph.security.skeleton(bytes, &w.writer, .{ .direction = direction }, try security_test.buffersFor(gpa, bytes));
    return w.written();
}

fn security(_: void, case: *shakedown.Case) anyerror!void {
    const s = xenoglyph.security;
    const a = try text(case);
    const b = try text(case);
    for (std.enums.values(s.Direction)) |direction| {
        const k = try skeletonOf(case.gpa, a, direction);
        // A skeleton is in NFD, without default ignorables.
        try std.testing.expect(xenoglyph.normalize.isNormalized(.nfd, k));
        var it: utf8.Iterator = .init(k);
        while (it.next()) |cp| try std.testing.expect(!xenoglyph.core(cp).default_ignorable_code_point);
        if (direction == .logical) try std.testing.expectEqualStrings(k, try skeletonOf(case.gpa, k, .logical));
    }
    // Every text is confusable with itself, and confusability is symmetric.
    const ba = try security_test.buffersFor(case.gpa, a);
    const bb = try security_test.buffersFor(case.gpa, b);
    try std.testing.expect(s.confusable(a, a, .{}, .{ ba, try security_test.buffersFor(case.gpa, a) }) != null);
    try std.testing.expectEqual(s.confusable(a, b, .{}, .{ ba, bb }), s.confusable(b, a, .{}, .{ bb, ba }));
    // A text meets its own level, and no stricter one unless it is that one.
    const level = s.restrictionLevel(a);
    try std.testing.expect(!s.check(a, level).restriction_level);
    try std.testing.expectEqual(level == .unrestricted, s.check(a, .ascii_only).restricted);
}

test "skeletons of any text are NFD without ignorables, confusability is reflexive and symmetric, a text meets its own level" {
    try shakedown.check(std.testing.allocator, {}, security, .{ .cases = 2000 });
}
