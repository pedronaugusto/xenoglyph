//! Unicode's own conformance files, every line: GraphemeBreakTest.txt,
//! WordBreakTest.txt and SentenceBreakTest.txt (UAX #29), and the emoji
//! sequences of emoji-test.txt (UTS #51).
const std = @import("std");
const ucd = @import("ucd");
const grapheme = @import("../grapheme.zig");
const word = @import("../word.zig");
const sentence = @import("../sentence.zig");
const width = @import("../width.zig");
const breaking = @import("../line.zig");
const properties = @import("../properties.zig");

const max_code_points = 256;

/// One line of a break test: its code points, the text they encode, and
/// where each code point starts and whether a boundary stands before it.
const Case = struct {
    code_points: [max_code_points]u21 = undefined,
    /// Byte offset of each code point, and of the end at `count`.
    offsets: [max_code_points + 1]usize = undefined,
    /// `boundary[i]`: a boundary before code point i; `boundary[count]`:
    /// at the end.
    boundary: [max_code_points + 1]bool = undefined,
    count: usize = 0,
    text: [max_code_points * 4]u8 = undefined,
    len: usize = 0,

    fn bytes(c: *const Case) []const u8 {
        return c.text[0..c.len];
    }
};

/// Parses "÷ 0020 × 0308 ÷" (the comment after `#` dropped).
fn parse(line: []const u8) !?Case {
    const data = std.mem.trim(u8, if (std.mem.findScalar(u8, line, '#')) |hash| line[0..hash] else line, " \t\r");
    if (data.len == 0) return null;
    var c: Case = .{};
    var tokens = std.mem.tokenizeAny(u8, data, " \t");
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, "÷")) {
            c.boundary[c.count] = true;
        } else if (std.mem.eql(u8, token, "×")) {
            c.boundary[c.count] = false;
        } else {
            const cp = try std.fmt.parseInt(u21, token, 16);
            c.code_points[c.count] = cp;
            c.offsets[c.count] = c.len;
            c.len += try std.unicode.utf8Encode(cp, c.text[c.len..]);
            c.count += 1;
        }
    }
    c.offsets[c.count] = c.len;
    return c;
}

/// The boundaries an iterator finds, as a set of byte offsets compared with
/// the case's.
fn expectSegments(c: *const Case, it: anytype, line: usize) !void {
    var want: std.ArrayList(usize) = .empty;
    defer want.deinit(std.testing.allocator);
    for (1..c.count + 1) |i| if (c.boundary[i]) try want.append(std.testing.allocator, c.offsets[i]);
    var got: std.ArrayList(usize) = .empty;
    defer got.deinit(std.testing.allocator);
    var start: usize = 0;
    while (it.nextSpan()) |span| {
        if (span.start != start or span.end <= span.start) return error.TestUnexpectedResult;
        try got.append(std.testing.allocator, span.end);
        start = span.end;
    }
    std.testing.expectEqualSlices(usize, want.items, got.items) catch |err| {
        std.debug.print("line {d}: {s}\n", .{ line, c.bytes() });
        return err;
    };
}

fn eachLine(text: []const u8, comptime f: fn (*const Case, usize) anyerror!void) !usize {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    var cases: usize = 0;
    while (lines.next()) |line| {
        number += 1;
        const c = try parse(line) orelse continue;
        try f(&c, number);
        cases += 1;
    }
    return cases;
}

fn graphemeCase(c: *const Case, line: usize) !void {
    var it: grapheme.Iterator(.{}) = .init(c.bytes());
    try expectSegments(c, &it, line);
    // The breaker over code points agrees with the iterator.
    var b: grapheme.Breaker(.{}) = .{};
    for (c.code_points[0..c.count], 0..) |cp, i| {
        if (b.next(cp) != c.boundary[i]) {
            std.debug.print("line {d}: breaker at code point {d}\n", .{ line, i });
            return error.TestUnexpectedResult;
        }
    }
}

test "GraphemeBreakTest.txt, every line" {
    const cases = try eachLine(ucd.grapheme_break_test, graphemeCase);
    try std.testing.expectEqual(853, cases);
}

/// The UTS #51 tailoring: the file's boundaries, with one more before an
/// emoji modifier that does not follow an Emoji_Modifier_Base.
fn modifierCase(c: *const Case, line: usize) !void {
    var b: grapheme.Breaker(.{ .modifiers = .after_base }) = .{};
    for (c.code_points[0..c.count], 0..) |cp, i| {
        var want = c.boundary[i];
        if (i > 0 and properties.emoji(cp).modifier and !properties.emoji(c.code_points[i - 1]).modifier_base) want = true;
        if (b.next(cp) != want) {
            std.debug.print("line {d}: modifier tailoring at code point {d}\n", .{ line, i });
            return error.TestUnexpectedResult;
        }
    }
}

test "GraphemeBreakTest.txt under the emoji modifier tailoring" {
    _ = try eachLine(ucd.grapheme_break_test, modifierCase);
}

/// Controls read as Other: the lines with no control, CR or LF keep the
/// file's boundaries.
fn noControlCase(c: *const Case, line: usize) !void {
    for (c.code_points[0..c.count]) |cp| switch (properties.graphemeBreak(cp)) {
        .control, .cr, .lf => return,
        else => {},
    };
    var it: grapheme.Iterator(.{ .controls = .as_other }) = .init(c.bytes());
    try expectSegments(c, &it, line);
}

test "GraphemeBreakTest.txt with controls read as Other" {
    _ = try eachLine(ucd.grapheme_break_test, noControlCase);
}

fn wordCase(c: *const Case, line: usize) !void {
    var it: word.Iterator = .init(c.bytes());
    try expectSegments(c, &it, line);
}

test "WordBreakTest.txt, every line" {
    const cases = try eachLine(ucd.word_break_test, wordCase);
    try std.testing.expectEqual(1944, cases);
}

fn sentenceCase(c: *const Case, line: usize) !void {
    var it: sentence.Iterator = .init(c.bytes());
    try expectSegments(c, &it, line);
}

test "SentenceBreakTest.txt, every line" {
    const cases = try eachLine(ucd.sentence_break_test, sentenceCase);
    try std.testing.expectEqual(512, cases);
}

test "emoji-test.txt: every sequence is one cluster, and a qualified one two columns" {
    var lines = std.mem.splitScalar(u8, ucd.emoji_test, '\n');
    var sequences: usize = 0;
    var wide: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const semicolon = std.mem.findScalar(u8, line, ';') orelse continue;
        const hash = std.mem.findScalar(u8, line, '#').?;
        const status = std.mem.trim(u8, line[semicolon + 1 .. hash], " ");
        var text: [64]u8 = undefined;
        var len: usize = 0;
        var codes = std.mem.tokenizeScalar(u8, line[0..semicolon], ' ');
        while (codes.next()) |code| len += try std.unicode.utf8Encode(try std.fmt.parseInt(u21, code, 16), text[len..]);
        const s = text[0..len];
        if (grapheme.count(s, .{}) != 1 or grapheme.count(s, .{ .modifiers = .after_base }) != 1) {
            std.debug.print("{s}: {d} clusters\n", .{ line, grapheme.count(s, .{}) });
            return error.TestUnexpectedResult;
        }
        sequences += 1;
        if (std.mem.eql(u8, status, "fully-qualified") or std.mem.eql(u8, status, "component")) {
            if (width.cluster(s, .{}) != 2 or width.string(s, .{}) != 2) {
                std.debug.print("{s}: {d} columns\n", .{ line, width.cluster(s, .{}) });
                return error.TestUnexpectedResult;
            }
            wide += 1;
        }
    }
    try std.testing.expectEqual(5244, sequences);
    try std.testing.expectEqual(3972, wide);
}

fn lineCase(c: *const Case, number: usize) !void {
    var it: breaking.Iterator = .init(c.bytes());
    try expectSegments(c, &it, number);
}

test "LineBreakTest.txt, every line" {
    const cases = try eachLine(ucd.line_break_test, lineCase);
    try std.testing.expectEqual(19346, cases);
}
