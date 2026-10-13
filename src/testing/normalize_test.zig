//! NormalizationTest.txt, every line and every code point: each of the five
//! columns normalizes as the file says in all four forms, and every code
//! point Part 1 does not list is its own normal form in all four.
const std = @import("std");
const ucd = @import("ucd");
const normalize = @import("../normalize.zig");

fn encode(field: []const u8, out: []u8) ![]const u8 {
    var len: usize = 0;
    var codes = std.mem.tokenizeScalar(u8, field, ' ');
    while (codes.next()) |code| len += try std.unicode.utf8Encode(try std.fmt.parseInt(u21, code, 16), out[len..]);
    return out[0..len];
}

fn expectForm(comptime form: normalize.Form, input: []const u8, want: []const u8, line: usize) !void {
    var it: normalize.Iterator(form) = .init(input);
    var expected: @import("../utf8.zig").Iterator = .init(want);
    while (true) {
        const got = it.next();
        const w = expected.next();
        if (got != w) {
            std.debug.print("line {d}: {t} of {any}: got {?x}, want {?x}\n", .{ line, form, input, got, w });
            return error.TestUnexpectedResult;
        }
        if (got == null) break;
    }
    var out: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);
    try normalize.write(form, input, &writer);
    try std.testing.expectEqualStrings(want, writer.buffered());
    try std.testing.expectEqual(std.mem.eql(u8, input, want), normalize.isNormalized(form, input));
    if (normalize.quickCheck(form, input) == .yes) try std.testing.expectEqualStrings(want, input);
}

test "NormalizationTest.txt, every line" {
    var lines = std.mem.splitScalar(u8, ucd.normalization_test, '\n');
    var number: usize = 0;
    var cases: usize = 0;
    while (lines.next()) |line| {
        number += 1;
        if (line.len == 0 or line[0] == '#' or line[0] == '@') continue;
        var fields = std.mem.splitScalar(u8, line, ';');
        var buffers: [5][256]u8 = undefined;
        var c: [5][]const u8 = undefined;
        for (&c, &buffers) |*column, *buffer| column.* = try encode(fields.next().?, buffer);
        // NFC: c2 == toNFC(c1..c3), c4 == toNFC(c4, c5). NFD: c3 == toNFD(c1..c3),
        // c5 == toNFD(c4, c5). NFKC: c4 == toNFKC(any). NFKD: c5 == toNFKD(any).
        for (c[0..3]) |x| {
            try expectForm(.nfc, x, c[1], number);
            try expectForm(.nfd, x, c[2], number);
        }
        for (c[3..5]) |x| {
            try expectForm(.nfc, x, c[3], number);
            try expectForm(.nfd, x, c[4], number);
        }
        for (c) |x| {
            try expectForm(.nfkc, x, c[3], number);
            try expectForm(.nfkd, x, c[4], number);
        }
        cases += 1;
    }
    try std.testing.expectEqual(20171, cases);
}

test "every code point Part 1 does not list is its own normal form" {
    const listed = try std.testing.allocator.alloc(bool, 0x110000);
    defer std.testing.allocator.free(listed);
    @memset(listed, false);
    var lines = std.mem.splitScalar(u8, ucd.normalization_test, '\n');
    var part: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "@Part")) part = line[5] - '0';
        if (part != 1 or line.len == 0 or line[0] == '#' or line[0] == '@') continue;
        listed[try std.fmt.parseInt(u21, line[0..std.mem.findScalar(u8, line, ';').?], 16)] = true;
    }
    var unlisted: usize = 0;
    for (listed, 0..) |l, i| {
        if (l or (i >= 0xd800 and i <= 0xdfff)) continue;
        var buffer: [4]u8 = undefined;
        const s = buffer[0..try std.unicode.utf8Encode(@intCast(i), &buffer)];
        inline for (.{ .nfc, .nfd, .nfkc, .nfkd }) |form| try expectForm(form, s, s, i);
        unlisted += 1;
    }
    try std.testing.expect(unlisted > 1_000_000);
}
