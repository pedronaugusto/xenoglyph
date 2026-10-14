//! UTS #46's conformance test, IdnaTestV2.txt, in full: toUnicode and
//! toASCII with Nontransitional Processing and every check on. A line with
//! a status expects a failure (which one is not compared, as the file
//! allows); one without expects the result it gives. Transitional
//! Processing, deprecated, is not implemented and its columns are not read.
const std = @import("std");
const ucd = @import("ucd");
const idna = @import("../idna.zig");
const utf8 = @import("../utf8.zig");

const testing = std.testing;

/// A column with `\uXXXX` and `\x{XXXX}` escapes made UTF-8; `""` is the
/// empty string.
fn unescape(column: []const u8, out: []u8) ![]const u8 {
    if (std.mem.eql(u8, column, "\"\"")) return out[0..0];
    var w: std.Io.Writer = .fixed(out);
    var i: usize = 0;
    while (i < column.len) {
        if (column[i] == '\\' and i + 1 < column.len and (column[i + 1] == 'u' or column[i + 1] == 'x')) {
            var hex: []const u8 = undefined;
            if (column[i + 1] == 'u') {
                hex = column[i + 2 .. i + 6];
                i += 6;
            } else {
                const close = std.mem.findScalarPos(u8, column, i, '}').?;
                hex = column[i + 3 .. close];
                i = close + 1;
            }
            const cp = try std.fmt.parseInt(u21, hex, 16);
            var bytes: [4]u8 = undefined;
            // An escaped surrogate is ill-formed input: write it as the
            // three bytes UTF-8 would give, which decode as U+FFFD.
            const n = if (cp >= 0xd800 and cp <= 0xdfff) blk: {
                bytes[0] = 0xe0 | @as(u8, @intCast(cp >> 12));
                bytes[1] = 0x80 | @as(u8, @intCast((cp >> 6) & 0x3f));
                bytes[2] = 0x80 | @as(u8, @intCast(cp & 0x3f));
                break :blk 3;
            } else try std.unicode.utf8Encode(cp, &bytes);
            try w.writeAll(bytes[0..n]);
        } else {
            try w.writeByte(column[i]);
            i += 1;
        }
    }
    return w.buffered();
}

/// Whether `actual` is `expected`, a U+FFFD in `actual` standing for any
/// one code point of `expected` (the file's rule for an implementation that
/// writes U+FFFD for what it refuses).
fn sameName(actual: []const u8, expected: []const u8) bool {
    var a: usize = 0;
    var e: usize = 0;
    while (a < actual.len and e < expected.len) {
        const x = utf8.decode(actual[a..]);
        const y = utf8.decode(expected[e..]);
        if (x.code_point != y.code_point and x.code_point != utf8.replacement) return false;
        a += x.len;
        e += y.len;
    }
    return a == actual.len and e == expected.len;
}

test "IdnaTestV2.txt: toUnicode and toAsciiN on every line" {
    var lines = std.mem.splitScalar(u8, ucd.idna_test, '\n');
    var number: usize = 0;
    var checked: usize = 0;
    var failed: usize = 0;
    while (lines.next()) |raw| {
        number += 1;
        const data = std.mem.trim(u8, if (std.mem.findScalar(u8, raw, '#')) |hash| raw[0..hash] else raw, " \t\r");
        if (data.len == 0) continue;
        var columns: [7][]const u8 = @splat("");
        var parts = std.mem.splitScalar(u8, data, ';');
        for (&columns) |*c| c.* = std.mem.trim(u8, parts.next() orelse "", " \t");
        var source_buf: [1024]u8 = undefined;
        const source = try unescape(columns[0], &source_buf);
        var unicode_buf: [1024]u8 = undefined;
        const want_unicode = if (columns[1].len == 0) source else try unescape(columns[1], &unicode_buf);
        const unicode_fails = columns[2].len != 0 and !std.mem.eql(u8, columns[2], "[]");
        var ascii_buf: [1024]u8 = undefined;
        const want_ascii = if (columns[3].len == 0) want_unicode else try unescape(columns[3], &ascii_buf);
        const ascii_status = if (columns[4].len == 0) columns[2] else columns[4];
        const ascii_fails = ascii_status.len != 0 and !std.mem.eql(u8, ascii_status, "[]");
        checked += 1;

        var out: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&out);
        const u = try idna.toUnicode(source, &w, .{});
        var wrong = u.any() != unicode_fails or !sameName(w.buffered(), want_unicode);
        if (wrong) std.debug.print("line {d}: toUnicode gave {s} {any}, the file {s} {s}\n", .{ number, w.buffered(), u, want_unicode, columns[2] });

        w = .fixed(&out);
        const a = try idna.toAscii(source, &w, .{});
        const ascii_wrong = a.any() != ascii_fails or (!ascii_fails and !sameName(w.buffered(), want_ascii));
        if (ascii_wrong) std.debug.print("line {d}: toAscii gave {s} {any}, the file {s} {s}\n", .{ number, w.buffered(), a, want_ascii, ascii_status });
        wrong = wrong or ascii_wrong;
        if (wrong) failed += 1;
    }
    try testing.expect(checked > 6000);
    try testing.expectEqual(@as(usize, 0), failed);
}
