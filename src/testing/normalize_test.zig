//! NormalizationTest.txt, every line and every code point: each of the five
//! columns normalizes as the file says in all four forms, and every code
//! point Part 1 does not list is its own normal form in all four.
//! NFKC_Casefold of every code point is DerivedNormalizationProps.txt's, and
//! its quick check's `no` is sound.
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

/// NFKC_Casefold or NFKC_Simple_Casefold of every code point, and whether it
/// changes it, as DerivedNormalizationProps.txt gives them: for
/// NFKC_Casefold the file's Changes_When_NFKC_Casefolded, for the simple one,
/// which has no such property, where the file lists a mapping.
const Casefold = struct {
    /// Each code point's mapping, as a start and length in `pool`; null
    /// where the file lists none and it is the code point itself.
    mapping: []?[2]u32,
    pool: std.ArrayList(u21),
    changes: []bool,

    fn read(gpa: std.mem.Allocator, property: []const u8) !Casefold {
        var c: Casefold = .{ .mapping = try gpa.alloc(?[2]u32, 0x110000), .pool = .empty, .changes = try gpa.alloc(bool, 0x110000) };
        @memset(c.mapping, null);
        @memset(c.changes, false);
        var lines = std.mem.splitScalar(u8, ucd.derived_normalization_props, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, if (std.mem.findScalar(u8, raw, '#')) |h| raw[0..h] else raw, " ");
            if (line.len == 0) continue;
            var fields = std.mem.splitScalar(u8, line, ';');
            const range = std.mem.trim(u8, fields.next().?, " ");
            const name = std.mem.trim(u8, fields.next().?, " ");
            const dots = std.mem.find(u8, range, "..");
            const first = try std.fmt.parseInt(u21, if (dots) |d| range[0..d] else range, 16);
            const last = if (dots) |d| try std.fmt.parseInt(u21, range[d + 2 ..], 16) else first;
            const simple = std.mem.eql(u8, property, "NFKC_SCF");
            if (!simple and std.mem.eql(u8, name, "Changes_When_NFKC_Casefolded")) {
                @memset(c.changes[first .. @as(usize, last) + 1], true);
            } else if (std.mem.eql(u8, name, property)) {
                if (simple) @memset(c.changes[first .. @as(usize, last) + 1], true);
                const start: u32 = @intCast(c.pool.items.len);
                var codes = std.mem.tokenizeScalar(u8, std.mem.trim(u8, fields.next().?, " "), ' ');
                while (codes.next()) |code| try c.pool.append(gpa, try std.fmt.parseInt(u21, code, 16));
                const len: u32 = @intCast(c.pool.items.len - start);
                @memset(c.mapping[first .. @as(usize, last) + 1], .{ start, len });
            }
        }
        return c;
    }

    fn of(c: *const Casefold, cp: u21, self: *[1]u21) []const u21 {
        const m = c.mapping[cp] orelse {
            self[0] = cp;
            return self;
        };
        return c.pool.items[m[0]..][0..m[1]];
    }
};

fn everyCodePoint(comptime form: normalize.Form, property: []const u8, want_mapped: usize) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const c = try Casefold.read(arena.allocator(), property);
    var mapped: usize = 0;
    for (0..0x110000) |i| {
        if (i >= 0xd800 and i <= 0xdfff) continue;
        const cp: u21 = @intCast(i);
        var buffer: [4]u8 = undefined;
        const s = buffer[0..try std.unicode.utf8Encode(cp, &buffer)];
        var self: [1]u21 = undefined;
        const want = c.of(cp, &self);
        var want_bytes: [18 * 4]u8 = undefined;
        var len: usize = 0;
        for (want) |m| len += try std.unicode.utf8Encode(m, want_bytes[len..]);
        // Through the iterator, `write`, `isNormalized` and the quick check.
        try expectForm(form, s, want_bytes[0..len], i);
        const changes = !std.mem.eql(u21, want, &.{cp});
        try std.testing.expectEqual(c.changes[i], changes);
        // U+0345 is the one code point a mapping both changes and writes.
        const written = form == .nfkc_simple_casefold and cp == 0x345;
        try std.testing.expectEqual(changes and !written, normalize.quickCheck(form, s) == .no);
        mapped += @intFromBool(changes);
    }
    try std.testing.expectEqual(want_mapped, mapped);
}

test "NFKC_Casefold of every code point is DerivedNormalizationProps.txt's" {
    try everyCodePoint(.nfkc_casefold, "NFKC_CF", 10671);
}

test "NFKC_Simple_Casefold of every code point is DerivedNormalizationProps.txt's" {
    try everyCodePoint(.nfkc_simple_casefold, "NFKC_SCF", 10633);
}

fn quickCheckSound(comptime form: normalize.Form, property: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const c = try Casefold.read(arena.allocator(), property);
    for (0..0x110000) |i| {
        if (i >= 0xd800 and i <= 0xdfff) continue;
        // NFKC_Casefold's mappings, decomposed, are unchanged by it. (Not
        // so NFKC_Simple_Casefold's: U+0130 stands for itself as `I` and
        // U+0307, which compose back.)
        if (form == .nfkc_casefold) {
            var buffer: [18]u21 = undefined;
            for (normalize.decompose(@intCast(i), form, &buffer)) |part| try std.testing.expect(!c.changes[part]);
        }
        // What either writes for a code point holds none the quick check refuses.
        var bytes: [4]u8 = undefined;
        var it: normalize.Iterator(form) = .init(bytes[0..try std.unicode.utf8Encode(@intCast(i), &bytes)]);
        while (it.next()) |out| {
            var one: [4]u8 = undefined;
            try std.testing.expect(normalize.quickCheck(form, one[0..try std.unicode.utf8Encode(out, &one)]) != .no);
        }
    }
    // And so is every composite canonical composition makes of what is
    // unchanged: the Hangul syllables, and each primary composite of two
    // unchanged code points.
    for (0xac00..0xd7a4) |i| try std.testing.expect(!c.changes[i]);
    var composites: usize = 0;
    var lines = std.mem.splitScalar(u8, ucd.unicode_data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields: [6][]const u8 = undefined;
        var parts = std.mem.splitScalar(u8, line, ';');
        for (&fields) |*f| f.* = parts.next().?;
        if (fields[5].len == 0 or fields[5][0] == '<') continue;
        var codes = std.mem.tokenizeScalar(u8, fields[5], ' ');
        const first = try std.fmt.parseInt(u21, codes.next().?, 16);
        const second = try std.fmt.parseInt(u21, codes.next() orelse continue, 16);
        const composite = try std.fmt.parseInt(u21, fields[0], 16);
        if (normalize.compose(first, second) != composite) continue;
        composites += 1;
        if (!c.changes[first] and !c.changes[second]) try std.testing.expect(!c.changes[composite]);
    }
    try std.testing.expectEqual(961, composites);
}

test "toNFKC_Casefold writes no code point NFKC_Casefold changes, so the quick check's no is sound" {
    try quickCheckSound(.nfkc_casefold, "NFKC_CF");
}

test "toNFKC_Simple_Casefold writes no code point NFKC_Simple_Casefold changes, so the quick check's no is sound" {
    try quickCheckSound(.nfkc_simple_casefold, "NFKC_SCF");
}

fn splitmix(state: *u64) u64 {
    state.* +%= 0x9e3779b97f4a7c15;
    var z = state.*;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

fn hashSimpleCasefold(hash: *std.crypto.hash.sha2.Sha256, text: []const u8) !void {
    var out: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try normalize.write(.nfkc_simple_casefold, text, &w);
    hash.update(w.buffered());
    hash.update("\xff");
}

test "toNFKC_Simple_Casefold of code points and strings is ICU4C's nfkc_scf normalizer's" {
    var lines = std.mem.tokenizeScalar(u8, ucd.nfkc_scf_icu4c_digests, '\n');
    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    var seed: u64 = 0;
    var count: usize = 0;
    var alphabet: std.ArrayList(u21) = .empty;
    defer alphabet.deinit(std.testing.allocator);
    var checked: usize = 0;
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const name = fields.next().?;
        if (std.mem.eql(u8, name, "inputs")) {
            while (fields.next()) |range| {
                const dash = std.mem.findScalar(u8, range, '-');
                const first = try std.fmt.parseInt(u21, range[0 .. dash orelse range.len], 16);
                const last = if (dash) |d| try std.fmt.parseInt(u21, range[d + 1 ..], 16) else first;
                for (first..@as(usize, last) + 1) |cp| {
                    var bytes: [4]u8 = undefined;
                    try hashSimpleCasefold(&hash, bytes[0..try std.unicode.utf8Encode(@intCast(cp), &bytes)]);
                }
            }
        } else if (std.mem.eql(u8, name, "seed")) {
            seed = try std.fmt.parseInt(u64, fields.next().?, 10);
        } else if (std.mem.eql(u8, name, "count")) {
            count = try std.fmt.parseInt(usize, fields.next().?, 10);
        } else if (std.mem.eql(u8, name, "alphabet")) {
            while (fields.next()) |f| try alphabet.append(std.testing.allocator, try std.fmt.parseInt(u21, f, 16));
            var state = seed;
            for (0..count) |_| {
                var text: [32]u8 = undefined;
                var len: usize = 0;
                for (0..splitmix(&state) % 9) |_| len += try std.unicode.utf8Encode(alphabet.items[splitmix(&state) % alphabet.items.len], text[len..]);
                try hashSimpleCasefold(&hash, text[0..len]);
            }
        } else {
            try std.testing.expectEqualStrings(fields.next().?, &std.fmt.bytesToHex(hash.finalResult(), .lower));
            hash = .init(.{});
            checked += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), checked);
}
