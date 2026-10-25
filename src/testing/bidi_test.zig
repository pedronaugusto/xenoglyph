//! UAX #9's conformance files, every line: BidiTest.txt, its cases of
//! classes at each paragraph direction its bits name, and
//! BidiCharacterTest.txt, its texts with levels and visual order; the tables
//! against BidiBrackets.txt and BidiMirroring.txt; and properties of
//! paragraphs and lines over arbitrary text.
const std = @import("std");
const ucd = @import("ucd");
const shake = @import("shakedown");
const bidi = @import("../bidi.zig");
const properties = @import("../properties.zig");
const utf8 = @import("../utf8.zig");

const BidiClass = bidi.BidiClass;
const max = 256;

const short_names = [_]struct { []const u8, BidiClass }{
    .{ "L", .left_to_right },            .{ "R", .right_to_left },             .{ "AL", .arabic_letter },
    .{ "EN", .european_number },         .{ "ES", .european_separator },       .{ "ET", .european_terminator },
    .{ "AN", .arabic_number },           .{ "CS", .common_separator },         .{ "NSM", .nonspacing_mark },
    .{ "BN", .boundary_neutral },        .{ "B", .paragraph_separator },       .{ "S", .segment_separator },
    .{ "WS", .white_space },             .{ "ON", .other_neutral },            .{ "LRE", .left_to_right_embedding },
    .{ "LRO", .left_to_right_override }, .{ "RLE", .right_to_left_embedding }, .{ "RLO", .right_to_left_override },
    .{ "PDF", .pop_directional_format }, .{ "LRI", .left_to_right_isolate },   .{ "RLI", .right_to_left_isolate },
    .{ "FSI", .first_strong_isolate },   .{ "PDI", .pop_directional_isolate },
};

fn classNamed(name: []const u8) !BidiClass {
    for (short_names) |e| if (std.mem.eql(u8, e[0], name)) return e[1];
    return error.UnknownClass;
}

/// Removed by X9: no level, and absent from the visual order.
fn removed(c: BidiClass) bool {
    return switch (c) {
        .boundary_neutral, .left_to_right_embedding, .right_to_left_embedding, .left_to_right_override, .right_to_left_override, .pop_directional_format => true,
        else => false,
    };
}

/// Each position's level after L1, from the line's runs.
fn lineLevels(runs: []const bidi.Run, out: []bidi.Level) void {
    for (runs) |r| @memset(out[r.span.start.raw()..r.span.end.raw()], r.level);
}

test "BidiTest.txt, every case at every paragraph direction it names" {
    var lines = std.mem.splitScalar(u8, ucd.bidi_test, '\n');
    var want_levels: [max]?bidi.Level = undefined;
    var want_count: usize = 0;
    var want_order: [max]usize = undefined;
    var order_count: usize = 0;
    var cases: usize = 0;
    var levels: [max]bidi.Level = undefined;
    var scratch: [max]bidi.Scratch = undefined;
    var runs: [max]bidi.Run = undefined;
    var after: [max]bidi.Level = undefined;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, if (std.mem.findScalar(u8, raw, '#')) |h| raw[0..h] else raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "@Levels:")) {
            want_count = 0;
            var it = std.mem.tokenizeAny(u8, line["@Levels:".len..], " \t");
            while (it.next()) |t| : (want_count += 1) want_levels[want_count] = if (std.mem.eql(u8, t, "x")) null else try std.fmt.parseInt(bidi.Level, t, 10);
            continue;
        }
        if (std.mem.startsWith(u8, line, "@Reorder:")) {
            order_count = 0;
            var it = std.mem.tokenizeAny(u8, line["@Reorder:".len..], " \t");
            while (it.next()) |t| : (order_count += 1) want_order[order_count] = try std.fmt.parseInt(usize, t, 10);
            continue;
        }
        if (line[0] == '@') continue;
        const semi = std.mem.findScalar(u8, line, ';').?;
        var classes: [max]BidiClass = undefined;
        var n: usize = 0;
        var names = std.mem.tokenizeAny(u8, line[0..semi], " \t");
        while (names.next()) |name| : (n += 1) classes[n] = try classNamed(name);
        try std.testing.expectEqual(want_count, n);
        const bits = try std.fmt.parseInt(u8, std.mem.trim(u8, line[semi + 1 ..], " \t"), 10);
        inline for (.{ .{ 1, bidi.Options{} }, .{ 2, bidi.Options{ .direction = .ltr } }, .{ 4, bidi.Options{ .direction = .rtl } } }) |mode| {
            if (bits & mode[0] != 0) {
                cases += 1;
                const para = bidi.resolveClasses(classes[0..n], mode[1], .{ .levels = &levels, .scratch = &scratch });
                const visual = bidi.reorderClasses(classes[0..n], levels[0..n], 0, n, para, &runs);
                lineLevels(visual, &after);
                for (0..n) |i| if (want_levels[i]) |want| {
                    if (after[i] != want) return fail("BidiTest.txt", line, mode[0], "level", i, want, after[i]);
                };
                var k: usize = 0;
                for (visual) |r| {
                    const from = r.span.start.raw();
                    const to = r.span.end.raw();
                    var j: usize = 0;
                    while (j < to - from) : (j += 1) {
                        const at = if (r.level & 1 == 1) to - 1 - j else from + j;
                        if (removed(classes[at])) continue;
                        if (k >= order_count or want_order[k] != at) return fail("BidiTest.txt", line, mode[0], "order", k, if (k < order_count) want_order[k] else 999, at);
                        k += 1;
                    }
                }
                try std.testing.expectEqual(order_count, k);
            }
        }
    }
    try std.testing.expect(cases > 400_000);
}

fn fail(file: []const u8, line: []const u8, mode: anytype, what: []const u8, i: usize, want: anytype, got: anytype) error{TestUnexpectedResult} {
    std.debug.print("{s}: '{s}' ({any}): {s} {d}: want {any}, got {any}\n", .{ file, line, mode, what, i, want, got });
    return error.TestUnexpectedResult;
}

test "BidiCharacterTest.txt, every line: paragraph level, levels and visual order" {
    var lines = std.mem.splitScalar(u8, ucd.bidi_character_test, '\n');
    var count: usize = 0;
    var levels: [max * 4]bidi.Level = undefined;
    var scratch: [max * 4]bidi.Scratch = undefined;
    var runs: [max * 4]bidi.Run = undefined;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, if (std.mem.findScalar(u8, raw, '#')) |h| raw[0..h] else raw, " \t\r");
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ';');
        var text: [max * 4]u8 = undefined;
        var len: usize = 0;
        var offsets: [max]usize = undefined;
        var classes: [max]BidiClass = undefined;
        var n: usize = 0;
        var codes = std.mem.tokenizeScalar(u8, fields.next().?, ' ');
        while (codes.next()) |c| : (n += 1) {
            const cp = try std.fmt.parseInt(u21, c, 16);
            offsets[n] = len;
            classes[n] = properties.bidiClass(cp);
            len += try std.unicode.utf8Encode(cp, text[len..]);
        }
        const direction: bidi.Options = switch (try std.fmt.parseInt(u2, fields.next().?, 10)) {
            0 => .{ .direction = .ltr },
            1 => .{ .direction = .rtl },
            else => .{},
        };
        const want_para = try std.fmt.parseInt(bidi.Level, fields.next().?, 10);
        const p: bidi.Paragraph = .resolve(text[0..len], .fromRaw(0), direction, .{ .levels = &levels, .scratch = &scratch });
        // One paragraph: the file's texts hold no separator but at their end.
        try std.testing.expectEqual(len, p.span.end.raw());
        if (p.level != want_para) return fail("BidiCharacterTest.txt", line, 0, "paragraph level", 0, want_para, p.level);
        const l = p.line(p.span, &runs);
        var after: [max * 4]bidi.Level = undefined;
        lineLevels(l.runs, &after);
        var levels_field = std.mem.tokenizeScalar(u8, fields.next().?, ' ');
        var i: usize = 0;
        while (levels_field.next()) |t| : (i += 1) {
            if (std.mem.eql(u8, t, "x")) continue;
            const want = try std.fmt.parseInt(bidi.Level, t, 10);
            if (after[offsets[i]] != want) return fail("BidiCharacterTest.txt", line, 0, "level", i, want, after[offsets[i]]);
        }
        var order_field = std.mem.tokenizeScalar(u8, fields.next().?, ' ');
        var visual = l.visual();
        var k: usize = 0;
        while (visual.next()) |at| {
            const index = std.mem.findScalar(usize, offsets[0..n], at.raw()).?;
            if (removed(classes[index])) continue;
            const want = try std.fmt.parseInt(usize, order_field.next() orelse return fail("BidiCharacterTest.txt", line, 0, "order length", k, 0, index), 10);
            if (want != index) return fail("BidiCharacterTest.txt", line, 0, "order", k, want, index);
            k += 1;
        }
        try std.testing.expect(order_field.next() == null);
        count += 1;
    }
    try std.testing.expect(count > 90_000);
}

test "the bracket and mirroring tables are BidiBrackets.txt and BidiMirroring.txt" {
    var brackets: usize = 0;
    var lines = std.mem.splitScalar(u8, ucd.bidi_brackets, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, if (std.mem.findScalar(u8, raw, '#')) |h| raw[0..h] else raw, " \t\r");
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, ';');
        const cp = try std.fmt.parseInt(u21, std.mem.trim(u8, f.next().?, " "), 16);
        const pair = try std.fmt.parseInt(u21, std.mem.trim(u8, f.next().?, " "), 16);
        const b = bidi.pairedBracket(cp).?;
        try std.testing.expectEqual(pair, b.pair);
        try std.testing.expectEqual(std.mem.eql(u8, std.mem.trim(u8, f.next().?, " "), "o"), b.opening);
        brackets += 1;
    }
    var mirrors: usize = 0;
    lines = std.mem.splitScalar(u8, ucd.bidi_mirroring, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, if (std.mem.findScalar(u8, raw, '#')) |h| raw[0..h] else raw, " \t\r");
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, ';');
        const cp = try std.fmt.parseInt(u21, std.mem.trim(u8, f.next().?, " "), 16);
        try std.testing.expectEqual(try std.fmt.parseInt(u21, std.mem.trim(u8, f.next().?, " "), 16), bidi.mirror(cp).?);
        mirrors += 1;
    }
    // Every other code point has neither.
    var with_bracket: usize = 0;
    var with_mirror: usize = 0;
    var cp: u21 = 0;
    while (cp < 0x110000) : (cp += 1) {
        if (bidi.pairedBracket(cp) != null) with_bracket += 1;
        if (bidi.mirror(cp) != null) with_mirror += 1;
    }
    try std.testing.expectEqual(brackets, with_bracket);
    try std.testing.expectEqual(mirrors, with_mirror);
}

fn paragraphsOf(_: void, c: *shake.Case) !void {
    const pieces = [_][]const u8{ "a", " ", "\u{5d0}", "\u{627}", "1", "\u{661}", "(", ")", "[", "]", "\u{2067}", "\u{2066}", "\u{2068}", "\u{2069}", "\u{202b}", "\u{202a}", "\u{202e}", "\u{202d}", "\u{202c}", "\u{300}", "\n", "\r\n", "\t", "+", "$", ",", "\u{200d}", "\xff", "\xe2\x81", "\u{2329}", "\u{3009}" };
    var text: std.ArrayList(u8) = .empty;
    for (0..shake.gen.intRange(c.source, usize, 0, 40)) |_| try text.appendSlice(c.gpa, shake.gen.oneOf(c.source, []const u8, &pieces));
    const bytes = text.items;
    const levels = try c.gpa.alloc(bidi.Level, bytes.len);
    const scratch = try c.gpa.alloc(bidi.Scratch, bytes.len);
    const runs = try c.gpa.alloc(bidi.Run, bytes.len);
    const options: bidi.Options = switch (shake.gen.intRange(c.source, u8, 0, 2)) {
        0 => .{},
        1 => .{ .direction = .ltr },
        else => .{ .direction = .rtl },
    };
    var start: usize = 0;
    while (start < bytes.len) {
        const p: bidi.Paragraph = .resolve(bytes, .fromRaw(start), options, .{ .levels = levels, .scratch = scratch });
        try std.testing.expect(p.span.end.compare(.fromRaw(start)) == .gt);
        // Every byte has a level no deeper than the deepest there is, and a
        // code point's bytes share it.
        var it = utf8.Iterator.init(p.span.of(bytes));
        var at: usize = 0;
        while (it.next()) |_| {
            const end = it.offset().raw();
            for (p.levels[at..end]) |lv| try std.testing.expectEqual(p.levels[at], lv);
            try std.testing.expect(p.levels[at] <= bidi.max_depth + 1);
            at = end;
        }
        // The runs cover the paragraph; a line's visual order visits each
        // code point once.
        var covered: usize = p.span.start.raw();
        var rs = p.runs();
        while (rs.next()) |r| {
            try std.testing.expectEqual(covered, r.span.start.raw());
            covered = r.span.end.raw();
        }
        try std.testing.expectEqual(p.span.end.raw(), covered);
        const l = p.line(p.span, runs);
        var seen: usize = 0;
        var visual = l.visual();
        var sum: usize = 0;
        while (visual.next()) |o| {
            seen += 1;
            sum += o.raw();
        }
        var want_seen: usize = 0;
        var want_sum: usize = 0;
        it = utf8.Iterator.init(p.span.of(bytes));
        const base = p.span.start.raw();
        var off: usize = base;
        while (it.next()) |_| {
            want_seen += 1;
            want_sum += off;
            const inside = it.offset().raw();
            off = base + inside;
        }
        try std.testing.expectEqual(want_seen, seen);
        try std.testing.expectEqual(want_sum, sum);
        start = p.span.end.raw();
    }
}

test "any text: every byte a level, runs covering each paragraph, each code point once in visual order" {
    try shake.check(std.testing.allocator, {}, paragraphsOf, .{ .cases = 3000 });
}
