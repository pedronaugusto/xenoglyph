//! Collation against CLDR's root collation conformance tests: every line of
//! CollationTest_CLDR_NON_IGNORABLE.txt and _SHIFTED.txt sorts after the one
//! before it, by `compare` and by `sortKey`.
const std = @import("std");
const ucd = @import("ucd");
const collation = @import("../collation.zig");

/// A test line's code points as UTF-8; null for a line with a lone
/// surrogate, which UTF-8 cannot hold.
fn utf8Of(line: []const u8, buffer: []u8) !?[]const u8 {
    var n: usize = 0;
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    while (fields.next()) |f| {
        const cp = try std.fmt.parseInt(u21, f, 16);
        if (cp >= 0xd800 and cp <= 0xdfff) return null;
        n += try std.unicode.utf8Encode(cp, buffer[n..]);
    }
    return buffer[0..n];
}

fn keyOf(text: []const u8, options: collation.Options, buffer: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    try collation.sortKey(text, &w, options);
    return w.buffered();
}

fn conformance(file: []const u8, options: collation.Options) !void {
    var lines = std.mem.splitScalar(u8, file, '\n');
    var buffers: [2][64]u8 = undefined;
    var keys: [2][512]u8 = undefined;
    var previous: ?[]const u8 = null;
    var previous_key: []const u8 = &.{};
    var which: usize = 0;
    var checked: usize = 0;
    var skipped: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const text = try utf8Of(line, &buffers[which]) orelse {
            skipped += 1;
            continue;
        };
        const key = try keyOf(text, options, &keys[which]);
        if (previous) |p| {
            // In order at the test's levels (lines equal there are in no
            // particular order), and the sort keys in the same order.
            const order = collation.compare(p, text, options);
            if (order == .gt) {
                std.debug.print("out of order: {x} then {x}\n", .{ p, text });
                return error.TestUnexpectedResult;
            }
            try std.testing.expectEqual(order, std.mem.order(u8, previous_key, key));
            checked += 1;
        }
        previous = text;
        previous_key = key;
        which ^= 1;
    }
    try std.testing.expectEqual(@as(usize, 30), skipped);
    try std.testing.expect(checked > 200_000);
}

test "CollationTest_CLDR_NON_IGNORABLE.txt: every line sorts after the one before" {
    try conformance(ucd.collation_test_non_ignorable, .{ .strength = .tertiary });
}

test "CollationTest_CLDR_SHIFTED.txt: every line sorts after the one before" {
    try conformance(ucd.collation_test_shifted, .{ .strength = .quaternary, .alternate = .shifted });
}

/// The interop strings: `count` of them, each of 0 to 10 code points of
/// `alphabet`, drawn by splitmix64 from `seed`, as ICU4C's harness draws them.
fn interopStrings(gpa: std.mem.Allocator, seed: u64, count: usize, alphabet: []const u21) ![][]const u8 {
    var state = seed;
    const strings = try gpa.alloc([]const u8, count);
    for (strings) |*s| {
        var text: std.ArrayList(u8) = .empty;
        for (0..splitmix(&state) % 11) |_| {
            var b: [4]u8 = undefined;
            try text.appendSlice(gpa, b[0..try std.unicode.utf8Encode(alphabet[splitmix(&state) % alphabet.len], &b)]);
        }
        s.* = try text.toOwnedSlice(gpa);
    }
    return strings;
}

fn splitmix(state: *u64) u64 {
    state.* +%= 0x9e3779b97f4a7c15;
    var z = state.*;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// The options an interop line names: strength, alternate, case first,
/// case level, numeric.
fn interopOptions(fields: *std.mem.TokenIterator(u8, .scalar)) !collation.Options {
    return .{
        .strength = std.meta.stringToEnum(collation.Strength, fields.next().?) orelse return error.BadLine,
        .alternate = if (std.mem.eql(u8, fields.next().?, "shifted")) .shifted else .non_ignorable,
        .case_first = std.meta.stringToEnum(@FieldType(collation.Options, "case_first"), fields.next().?) orelse return error.BadLine,
        .case_level = std.mem.eql(u8, fields.next().?, "case-level"),
        .numeric = std.mem.eql(u8, fields.next().?, "numeric"),
    };
}

/// The SHA-256 of the strings' order under `options`, as the harness takes
/// it: each index, each run of equal strings ascending and followed by
/// 0xffffffff, little-endian u32s.
fn orderDigest(strings: []const []const u8, order: []u32, options: collation.Options) [32]u8 {
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const By = struct {
        strings: []const []const u8,
        options: collation.Options,
        fn less(by: @This(), a: u32, b: u32) bool {
            return switch (collation.compare(by.strings[a], by.strings[b], by.options)) {
                .lt => true,
                .gt => false,
                .eq => a < b,
            };
        }
    };
    std.mem.sort(u32, order, By{ .strings = strings, .options = options }, By.less);
    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    for (order, 0..) |o, i| {
        hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, o)));
        if (i + 1 == order.len or collation.compare(strings[o], strings[order[i + 1]], options) != .eq)
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, 0xffffffff)));
    }
    return hash.finalResult();
}

test "every option set orders the interop strings as ICU4C's root collator does" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lines = std.mem.tokenizeScalar(u8, ucd.collation_icu4c_digests, '\n');
    var seed: u64 = 0;
    var count: usize = 0;
    var alphabet: std.ArrayList(u21) = .empty;
    var strings: [][]const u8 = &.{};
    var order: []u32 = &.{};
    var checked: usize = 0;
    var differ: usize = 0;
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const first = fields.next().?;
        if (std.mem.eql(u8, first, "seed")) {
            seed = try std.fmt.parseInt(u64, fields.next().?, 10);
        } else if (std.mem.eql(u8, first, "count")) {
            count = try std.fmt.parseInt(usize, fields.next().?, 10);
        } else if (std.mem.eql(u8, first, "alphabet")) {
            while (fields.next()) |f| try alphabet.append(gpa, try std.fmt.parseInt(u21, f, 16));
        } else if (std.mem.eql(u8, first, "strings")) {
            strings = try interopStrings(gpa, seed, count, alphabet.items);
            order = try gpa.alloc(u32, count);
            var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
            for (strings) |s| {
                hash.update(s);
                hash.update("\xff");
            }
            try std.testing.expectEqualStrings(fields.next().?, &std.fmt.bytesToHex(hash.finalResult(), .lower));
        } else {
            fields = std.mem.tokenizeScalar(u8, line, ' ');
            const options = try interopOptions(&fields);
            const digest = std.fmt.bytesToHex(orderDigest(strings, order, options), .lower);
            if (!std.mem.eql(u8, fields.next().?, &digest)) {
                std.debug.print("differs from ICU4C: {s}\n", .{line[0 .. line.len - 65]});
                differ += 1;
            }
            checked += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 120), checked);
    try std.testing.expectEqual(@as(usize, 0), differ);
}

const shakedown = @import("shakedown");
const normalize = @import("../normalize.zig");
const gen = shakedown.gen;

/// Code points collation treats specially: letters in both cases, accents
/// (also ones that block or extend a contraction), contraction starters,
/// digits of several scripts, spaces and punctuation (variable), symbols,
/// ignorables, Han and Tangut (implicit weights), unassigned, U+FFFE.
const interesting = [_]u21{
    'a',    'A',    'b',    'B',    'e',     'z',    0xe9,   0xc9,    0x301,   0x300,   0x308,   0x323,  0x334,
    0x418,  0x438,  0x306,  0xe40,  0xe01,   0xfb2,  0xf71,  0xf80,   0x1b05,  0x1b35,  '0',     '1',    '7',
    '9',    0x661,  0x966,  0xff11, 0x1d7ce, 0x2070, ' ',    '-',     '\'',    '.',     '!',     '$',    '+',
    0x1,    0xad,   0x200b, 0x4e00, 0x9fa5,  0xf900, 0x3400, 0x20000, 0x17000, 0x18d00, 0x1b170, 0xe000, 0x50000,
    0xfffe, 0xfffd, 0xac00, 0x1100, 0x1161,  0x3042, 0x30a2, 0x3041,  0xff71,  0x5d0,   0x5d1,   0x591,
};

fn generated(case: *shakedown.Case) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..gen.intRange(case.source, usize, 0, 12)) |_| {
        var buffer: [4]u8 = undefined;
        const cp = if (gen.intRange(case.source, u8, 0, 9) == 0)
            gen.intRange(case.source, u21, 0, 0x10ffff)
        else
            gen.oneOf(case.source, u21, &interesting);
        if (cp >= 0xd800 and cp <= 0xdfff) continue;
        try out.appendSlice(case.gpa, buffer[0..try std.unicode.utf8Encode(cp, &buffer)]);
    }
    return out.items;
}

fn optionsOf(case: *shakedown.Case) collation.Options {
    return .{
        .strength = gen.oneOf(case.source, collation.Strength, std.enums.values(collation.Strength)),
        .alternate = if (gen.boolean(case.source)) .shifted else .non_ignorable,
        .case_first = gen.oneOf(case.source, @FieldType(collation.Options, "case_first"), &.{ .off, .upper, .lower }),
        .case_level = gen.boolean(case.source),
        .numeric = gen.boolean(case.source),
    };
}

fn keysAgree(_: void, case: *shakedown.Case) anyerror!void {
    const o = optionsOf(case);
    const a = try generated(case);
    const b = try generated(case);
    var ka: std.Io.Writer.Allocating = .init(case.gpa);
    var kb: std.Io.Writer.Allocating = .init(case.gpa);
    try collation.sortKey(a, &ka.writer, o);
    try collation.sortKey(b, &kb.writer, o);
    const order = collation.compare(a, b, o);
    try std.testing.expectEqual(order, std.mem.order(u8, ka.written(), kb.written()));
    try std.testing.expectEqual(order.invert(), collation.compare(b, a, o));
    // A level decides only where every level before it was equal.
    var weaker = o;
    weaker.strength = .primary;
    weaker.case_level = false;
    const first = collation.compare(a, b, weaker);
    if (first != .eq) try std.testing.expectEqual(first, order);
}

test "sort keys order texts as compare does, under any options, and a level decides only after those before it" {
    try shakedown.check(std.testing.allocator, {}, keysAgree, .{ .cases = 3000 });
}

fn equivalent(_: void, case: *shakedown.Case) anyerror!void {
    const o = optionsOf(case);
    const a = try generated(case);
    var nfc: std.Io.Writer.Allocating = .init(case.gpa);
    try normalize.write(.nfc, a, &nfc.writer);
    // Canonically equivalent texts are equal at every strength.
    try std.testing.expectEqual(std.math.Order.eq, collation.compare(a, nfc.written(), o));
}

test "canonically equivalent texts compare equal at every strength" {
    try shakedown.check(std.testing.allocator, {}, equivalent, .{ .cases = 2000 });
}

fn numbers(_: void, case: *shakedown.Case) anyerror!void {
    const x = gen.int(case.source, u64);
    const y = if (gen.boolean(case.source)) x else gen.int(case.source, u64);
    var buffers: [2][64]u8 = undefined;
    var texts: [2][]const u8 = undefined;
    for ([_]u64{ x, y }, 0..) |v, k| {
        // With leading zeros, in ASCII or Arabic-Indic digits, before and after letters.
        const zeros = gen.intRange(case.source, usize, 0, 3);
        var w: std.Io.Writer = .fixed(&buffers[k]);
        try w.writeAll("p");
        for (0..zeros) |_| try w.writeByte('0');
        var digits: [20]u8 = undefined;
        const decimal = try std.mem.print(&digits, "{d}", .{v});
        const arabic = gen.boolean(case.source);
        for (decimal) |c| if (arabic) {
            var b: [2]u8 = undefined;
            _ = try std.unicode.utf8Encode(0x660 + @as(u21, c - '0'), &b);
            try w.writeAll(&b);
        } else try w.writeByte(c);
        try w.writeAll("q");
        texts[k] = w.buffered();
    }
    try std.testing.expectEqual(std.math.order(x, y), collation.compare(texts[0], texts[1], .{ .strength = .primary, .numeric = true }));
}

test "under numeric, runs of digits order as the numbers they write, leading zeros and script aside" {
    try shakedown.check(std.testing.allocator, {}, numbers, .{ .cases = 2000 });
}

test "options do what they say on a few texts" {
    const order = collation.compare;
    try std.testing.expectEqual(std.math.Order.lt, order("a", "A", .{}));
    try std.testing.expectEqual(std.math.Order.gt, order("a", "A", .{ .case_first = .upper }));
    try std.testing.expectEqual(std.math.Order.eq, order("a", "A", .{ .strength = .secondary }));
    try std.testing.expectEqual(std.math.Order.lt, order("a", "A", .{ .strength = .primary, .case_level = true }));
    try std.testing.expectEqual(std.math.Order.lt, order("cote", "c\u{f4}te", .{}));
    try std.testing.expectEqual(std.math.Order.eq, order("cote", "c\u{f4}te", .{ .strength = .primary }));
    try std.testing.expectEqual(std.math.Order.lt, order("a10", "a9", .{}));
    try std.testing.expectEqual(std.math.Order.gt, order("a10", "a9", .{ .numeric = true }));
    try std.testing.expectEqual(std.math.Order.lt, order("a9", "a10", .{ .numeric = true }));
    // Shifted sets punctuation aside: "di-silva" sorts with "disilva".
    try std.testing.expectEqual(std.math.Order.lt, order("di-silva", "dis", .{}));
    try std.testing.expectEqual(std.math.Order.gt, order("di-silva", "dis", .{ .alternate = .shifted }));
    try std.testing.expectEqual(std.math.Order.eq, order("di-silva", "disilva", .{ .alternate = .shifted }));
    try std.testing.expectEqual(std.math.Order.lt, order("di-silva", "disilva", .{ .alternate = .shifted, .strength = .quaternary }));
    // Canonical equivalents are equal even at the identical level.
    try std.testing.expectEqual(std.math.Order.eq, order("\u{e9}", "e\u{301}", .{ .strength = .identical }));
    try std.testing.expectEqual(std.math.Order.lt, order("\u{4e00}", "\u{4e01}", .{}));
}
