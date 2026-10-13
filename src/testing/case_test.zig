//! Case mapping against the UCD, for every code point: the simple mappings
//! against UnicodeData.txt, the full ones against SpecialCasing.txt and
//! CaseFolding.txt, and the five Changes_When properties of
//! DerivedCoreProperties.txt, which the UCD derives by mapping each code
//! point's NFD, as the mappings and normalization here must reproduce.
const std = @import("std");
const ucd = @import("ucd");
const case = @import("../case.zig");
const normalize = @import("../normalize.zig");
const properties = @import("../properties.zig");

const gpa = std.testing.allocator;

fn codes(text: []const u8, out: []u21) ![]const u21 {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |code| : (n += 1) out[n] = try std.fmt.parseInt(u21, code, 16);
    return out[0..n];
}

/// The mapping of `input` as code points.
fn mapped(comptime mapping: case.Mapping, input: []const u8, out: []u21) []const u21 {
    var it: case.Iterator(mapping) = .init(input, .{});
    var n: usize = 0;
    while (it.next()) |cp| : (n += 1) out[n] = cp;
    return out[0..n];
}

fn encoded(cps: []const u21, out: []u8) []const u8 {
    var n: usize = 0;
    for (cps) |cp| n += std.unicode.utf8Encode(cp, out[n..]) catch unreachable; // unreachable: scalar values only
    return out[0..n];
}

test "simple and full mappings of every code point" {
    const Full = struct { lower: [3]u21 = undefined, upper: [3]u21 = undefined, title: [3]u21 = undefined, lens: [3]usize = .{ 0, 0, 0 }, fold: [3]u21 = undefined, fold_len: usize = 0 };
    const full = try gpa.alloc(Full, 0x110000);
    defer gpa.free(full);
    @memset(full, .{});
    var lines = std.mem.splitScalar(u8, ucd.special_casing, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, if (std.mem.findScalar(u8, raw, '#')) |h| raw[0..h] else raw, " ");
        if (line.len == 0) continue;
        var f: [5][]const u8 = @splat("");
        var parts = std.mem.splitScalar(u8, line, ';');
        for (&f) |*x| x.* = std.mem.trim(u8, parts.next() orelse "", " ");
        if (f[4].len != 0) continue;
        const cp = try std.fmt.parseInt(u21, f[0], 16);
        full[cp].lens[0] = (try codes(f[1], &full[cp].lower)).len;
        full[cp].lens[2] = (try codes(f[2], &full[cp].title)).len;
        full[cp].lens[1] = (try codes(f[3], &full[cp].upper)).len;
    }
    const simple_fold = try gpa.alloc(u21, 0x110000);
    defer gpa.free(simple_fold);
    for (simple_fold, 0..) |*s, cp| s.* = @intCast(cp);
    lines = std.mem.splitScalar(u8, ucd.case_folding, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0 or raw[0] == '#') continue;
        var parts = std.mem.splitScalar(u8, raw, ';');
        const cp = try std.fmt.parseInt(u21, std.mem.trim(u8, parts.next().?, " "), 16);
        const status = std.mem.trim(u8, parts.next().?, " ");
        var buffer: [3]u21 = undefined;
        const m = try codes(std.mem.trim(u8, parts.next().?, " "), &buffer);
        switch (status[0]) {
            'C', 'S' => simple_fold[cp] = m[0],
            'F' => {
                full[cp].fold = buffer;
                full[cp].fold_len = m.len;
            },
            else => {},
        }
    }
    var simple: [3][]u21 = undefined;
    for (&simple) |*s| {
        s.* = try gpa.alloc(u21, 0x110000);
        for (s.*, 0..) |*x, cp| x.* = @intCast(cp);
    }
    defer for (simple) |s| gpa.free(s);
    lines = std.mem.splitScalar(u8, ucd.unicode_data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f: [15][]const u8 = undefined;
        var parts = std.mem.splitScalar(u8, line, ';');
        for (&f) |*x| x.* = parts.next().?;
        const cp = try std.fmt.parseInt(u21, f[0], 16);
        if (f[13].len > 0) simple[0][cp] = try std.fmt.parseInt(u21, f[13], 16);
        if (f[12].len > 0) simple[1][cp] = try std.fmt.parseInt(u21, f[12], 16);
        if (f[14].len > 0) simple[2][cp] = try std.fmt.parseInt(u21, f[14], 16);
    }
    for (0..0x110000) |i| {
        const cp: u21 = @intCast(i);
        try std.testing.expectEqual(simple[0][i], case.simpleLower(cp));
        try std.testing.expectEqual(simple[1][i], case.simpleUpper(cp));
        try std.testing.expectEqual(simple[2][i], case.simpleTitle(cp));
        try std.testing.expectEqual(simple_fold[i], case.simpleFold(cp));
        if (i >= 0xd800 and i <= 0xdfff) continue;
        var buffer: [4]u8 = undefined;
        const s = buffer[0 .. std.unicode.utf8Encode(cp, &buffer) catch unreachable]; // unreachable: surrogates skipped
        var out: [8]u21 = undefined;
        const want_lower: []const u21 = if (full[i].lens[0] != 0) full[i].lower[0..full[i].lens[0]] else simple[0][i .. i + 1];
        const want_upper: []const u21 = if (full[i].lens[1] != 0) full[i].upper[0..full[i].lens[1]] else simple[1][i .. i + 1];
        const want_fold: []const u21 = if (full[i].fold_len != 0) full[i].fold[0..full[i].fold_len] else simple_fold[i .. i + 1];
        try std.testing.expectEqualSlices(u21, want_lower, mapped(.lower, s, &out));
        try std.testing.expectEqualSlices(u21, want_upper, mapped(.upper, s, &out));
        try std.testing.expectEqualSlices(u21, want_fold, mapped(.fold, s, &out));
    }
}

test "the Changes_When properties are what the mappings do to each code point's NFD" {
    for (0..0x110000) |i| {
        if (i >= 0xd800 and i <= 0xdfff) continue;
        const cp: u21 = @intCast(i);
        var buffer: [4]u8 = undefined;
        const s = buffer[0 .. std.unicode.utf8Encode(cp, &buffer) catch unreachable]; // unreachable: surrogates skipped
        var nfd_cps: [18]u21 = undefined;
        var n: usize = 0;
        var it: normalize.Iterator(.nfd) = .init(s);
        while (it.next()) |x| : (n += 1) nfd_cps[n] = x;
        var nfd_bytes: [72]u8 = undefined;
        const nfd = encoded(nfd_cps[0..n], &nfd_bytes);
        var out: [64]u21 = undefined;
        const core = properties.core(cp);
        const lower = !std.mem.eql(u21, nfd_cps[0..n], mapped(.lower, nfd, &out));
        const upper = !std.mem.eql(u21, nfd_cps[0..n], mapped(.upper, nfd, &out));
        const title = !std.mem.eql(u21, nfd_cps[0..n], mapped(.title, nfd, &out));
        const fold = !std.mem.eql(u21, nfd_cps[0..n], mapped(.fold, nfd, &out));
        try std.testing.expectEqual(core.changes_when_lowercased, lower);
        try std.testing.expectEqual(core.changes_when_uppercased, upper);
        try std.testing.expectEqual(core.changes_when_titlecased, title);
        try std.testing.expectEqual(core.changes_when_casefolded, fold);
        // Changes_When_Casemapped reads the code point itself, not its NFD.
        var raw: [64]u21 = undefined;
        const mapped_any = !std.mem.eql(u21, &.{cp}, mapped(.lower, s, &raw)) or
            !std.mem.eql(u21, &.{cp}, mapped(.upper, s, &raw)) or
            !std.mem.eql(u21, &.{cp}, mapped(.title, s, &raw));
        try std.testing.expectEqual(core.changes_when_casemapped, mapped_any);
    }
}
