//! UTS #39: its own examples for resolved script sets, skeletons and the
//! classes of confusables, restriction levels and the checks; skeletons
//! idempotent on generated text.
const std = @import("std");
const security = @import("../security.zig");
const ucd = @import("ucd");

const bidi = @import("../bidi.zig");

/// Buffers for a skeleton of `text` in display order, from `gpa`.
pub fn buffersFor(gpa: std.mem.Allocator, text: []const u8) !security.Buffers {
    return .{
        .levels = try gpa.alloc(bidi.Level, text.len),
        .scratch = try gpa.alloc(bidi.Scratch, text.len),
        .runs = try gpa.alloc(bidi.Run, text.len),
    };
}

fn skeletonIn(gpa: std.mem.Allocator, text: []const u8, direction: security.Direction) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    try security.skeleton(text, &w.writer, .{ .direction = direction }, try buffersFor(gpa, text));
    return w.written();
}

fn confusableIn(gpa: std.mem.Allocator, a: []const u8, b: []const u8, direction: security.Direction) !?security.Confusability {
    return security.confusable(a, b, .{ .direction = direction }, .{ try buffersFor(gpa, a), try buffersFor(gpa, b) });
}

test "resolved script sets as UTS #39's Table 1a gives them" {
    const circle = security.resolvedScripts("Circle");
    try std.testing.expect(circle.contains(.latin) and circle.containsWritingSystem(.traditional_han_with_latin));
    try std.testing.expect(!circle.contains(.cyrillic) and !circle.containsWritingSystem(.japanese));
    try std.testing.expect(security.resolvedScripts("\u{421}\u{456}\u{433}\u{441}\u{4c0}\u{435}").contains(.cyrillic));
    try std.testing.expect(security.resolvedScripts("\u{421}ir\u{441}l\u{435}").isEmpty());
    try std.testing.expect(security.resolvedScripts("Circ1e").contains(.latin));
    try std.testing.expect(security.resolvedScripts("C\u{1d5c2}\u{1d5cb}\u{1d5bc}\u{1d5c5}\u{1d5be}").contains(.latin));
    try std.testing.expect(security.resolvedScripts("\u{1d5a2}\u{1d5c2}\u{1d5cb}\u{1d5bc}\u{1d5c5}\u{1d5be}").isAll());
    const shime = security.resolvedScripts("\u{3006}\u{5207}");
    try std.testing.expect(shime.contains(.han) and !shime.contains(.hiragana));
    for (std.enums.values(security.WritingSystem)) |w| try std.testing.expect(shime.containsWritingSystem(w));
    const ne = security.resolvedScripts("\u{306d}\u{30ac}");
    try std.testing.expect(ne.containsWritingSystem(.japanese) and !ne.contains(.hiragana) and !ne.contains(.katakana));
}

test "UTS #39's bidi skeleton example: LTR-confusable, not RTL-confusable" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const s1 = "A1<\u{5e9}\u{5c2}";
    const s2 = "\u{391}\u{5e9}\u{5ba}>1";
    const want = "Al<\u{5e9}\u{307}";
    for ([_][]const u8{ s1, s2 }) |s| {
        const k = try skeletonIn(gpa, s, .ltr);
        try std.testing.expectEqualStrings(want, k);
    }
    const r1 = try skeletonIn(gpa, s1, .rtl);
    const r2 = try skeletonIn(gpa, s2, .rtl);
    try std.testing.expect(!std.mem.eql(u8, r1, r2));
    // In logical order the two differ, as ICU's uspoof_getSkeleton has them.
    const l2 = try skeletonIn(gpa, s2, .logical);
    try std.testing.expectEqualStrings("A\u{5e9}\u{307}>l", l2);
}

test "the three classes of confusables, with UTS #39's examples" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    try std.testing.expectEqual(security.Confusability.single_script, (try confusableIn(gpa, "\u{1c9}eto", "ljeto", .ltr)).?);
    try std.testing.expectEqual(security.Confusability.mixed_script, (try confusableIn(gpa, "paypal", "p\u{430}yp\u{430}l", .ltr)).?);
    try std.testing.expectEqual(security.Confusability.whole_script, (try confusableIn(gpa, "scope", "\u{455}\u{441}\u{43e}\u{440}\u{435}", .ltr)).?);
    try std.testing.expectEqual(@as(?security.Confusability, null), try confusableIn(gpa, "scope", "slope", .ltr));
    // Default ignorables are no part of a skeleton.
    try std.testing.expectEqual(security.Confusability.single_script, (try confusableIn(gpa, "ab", "a\u{ad}b", .ltr)).?);
}

test "restriction levels" {
    const level = security.restrictionLevel;
    try std.testing.expectEqual(security.RestrictionLevel.ascii_only, level("circle"));
    try std.testing.expectEqual(security.RestrictionLevel.single_script, level("caf\u{e9}"));
    try std.testing.expectEqual(security.RestrictionLevel.single_script, level("\u{441}\u{456}\u{433}\u{441}\u{4cf}\u{435}"));
    // Latin with Han is single-script through Hntl; with kana it is Japanese.
    try std.testing.expectEqual(security.RestrictionLevel.single_script, level("abc\u{6f22}"));
    try std.testing.expectEqual(security.RestrictionLevel.highly_restrictive, level("abc\u{3072}\u{30ab}"));
    try std.testing.expectEqual(security.RestrictionLevel.moderately_restrictive, level("abc\u{3b1}\u{5d0}"[0..3] ++ "\u{5d0}"));
    try std.testing.expectEqual(security.RestrictionLevel.minimally_restrictive, level("abc\u{3b1}"));
    try std.testing.expectEqual(security.RestrictionLevel.minimally_restrictive, level("\u{3a9}mega"));
    try std.testing.expectEqual(security.RestrictionLevel.unrestricted, level("a\u{2100}"));
}

test "the checks find what they name" {
    const check = security.check;
    try std.testing.expect(!check("circle", .highly_restrictive).any());
    try std.testing.expect(check("1\u{9ea}", .minimally_restrictive).mixed_numbers);
    try std.testing.expect(!check("1\u{9ea}"[0..1], .minimally_restrictive).mixed_numbers);
    try std.testing.expect(check("a\u{301}\u{301}", .minimally_restrictive).repeated_mark);
    try std.testing.expect(!check("a\u{301}\u{300}", .minimally_restrictive).repeated_mark);
    try std.testing.expect(check("a\u{300}\u{301}\u{302}\u{303}\u{304}", .minimally_restrictive).long_mark_run);
    try std.testing.expect(check("i\u{307}", .minimally_restrictive).hidden_overlay);
    try std.testing.expect(!check("a\u{307}", .minimally_restrictive).hidden_overlay);
    try std.testing.expect(check("\u{3a9}mega", .highly_restrictive).restriction_level);
    try std.testing.expect(!check("\u{3a9}mega", .minimally_restrictive).restriction_level);
    try std.testing.expect(check("a\u{2100}", .unrestricted).restricted);
}

test "Identifier_Status and Identifier_Type" {
    try std.testing.expectEqual(security.IdentifierStatus.allowed, security.identifierStatus('a'));
    try std.testing.expectEqual(security.IdentifierStatus.restricted, security.identifierStatus(0x2100));
    try std.testing.expect(security.identifierType('a').recommended);
    try std.testing.expect(security.identifierType(0xe000).not_character);
    try std.testing.expect(security.identifierType(0x200d).default_ignorable);
}

const shakedown = @import("shakedown");
const gen = shakedown.gen;

/// Confusable and bidi-relevant code points: Latin, Cyrillic, Greek and
/// their look-alikes, digits of several systems, Hebrew and Arabic (right
/// to left, with marks), brackets that mirror, marks, default ignorables
/// and directional formats.
const interesting = [_]u21{
    'a',    'e',    'i',    'l',     'o',    'p',    '1',     '0',    '(',   ')',   '<',   ' ',    '-',    0x430,
    0x435,  0x43e,  0x440,  0x456,   0x4cf,  0x3bf,  0x3b1,   0x391,  0x131, 0x1c9, 0x9ea, 0x660,  0x6f0,  0x5d0,
    0x5e9,  0x5c2,  0x5ba,  0x627,   0x644,  0x64b,  0x301,   0x307,  0x300, 0x323, 0xad,  0x200b, 0x200d, 0x202e,
    0x2067, 0x2069, 0xff41, 0x1d5ba, 0x2160, 0xfb01, 0x1f130, 0x2116,
};

fn generated(case: *shakedown.Case) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..gen.intRange(case.source, usize, 0, 10)) |_| {
        var buffer: [4]u8 = undefined;
        const cp = if (gen.intRange(case.source, u8, 0, 7) == 0)
            gen.intRange(case.source, u21, 0, 0x10ffff)
        else
            gen.oneOf(case.source, u21, &interesting);
        if (cp >= 0xd800 and cp <= 0xdfff) continue;
        try out.appendSlice(case.gpa, buffer[0..try std.unicode.utf8Encode(cp, &buffer)]);
    }
    return out.items;
}

fn idempotent(_: void, case: *shakedown.Case) anyerror!void {
    const text = try generated(case);
    const once = try skeletonIn(case.gpa, text, .logical);
    try std.testing.expectEqualStrings(once, try skeletonIn(case.gpa, once, .logical));
    // A text that a left-to-right paragraph shows in logical order has the
    // same skeleton either way.
    const ltr = try skeletonIn(case.gpa, text, .ltr);
    var reordering = false;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| switch (@import("../properties.zig").bidiClass(cp)) {
        .left_to_right, .european_number, .european_separator, .european_terminator, .common_separator, .nonspacing_mark, .boundary_neutral, .white_space, .other_neutral, .segment_separator => {},
        else => reordering = true,
    };
    if (!reordering) try std.testing.expectEqualStrings(once, ltr);
}

test "skeletons are idempotent, and a text shown in logical order has its logical skeleton" {
    try shakedown.check(std.testing.allocator, {}, idempotent, .{ .cases = 3000 });
}

fn splitmix(state: *u64) u64 {
    state.* +%= 0x9e3779b97f4a7c15;
    var z = state.*;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

fn appendCodePoint(gpa: std.mem.Allocator, out: *std.ArrayList(u8), cp: u21) !void {
    var b: [4]u8 = undefined;
    try out.appendSlice(gpa, b[0..try std.unicode.utf8Encode(cp, &b)]);
}

/// What the interop compares of each pair, in the order the file lists the digests.
const Kinds = struct {
    logical: std.crypto.hash.sha2.Sha256 = .init(.{}),
    ltr: std.crypto.hash.sha2.Sha256 = .init(.{}),
    rtl: std.crypto.hash.sha2.Sha256 = .init(.{}),
    confusable: std.crypto.hash.sha2.Sha256 = .init(.{}),
    restriction: std.crypto.hash.sha2.Sha256 = .init(.{}),
    checks: std.crypto.hash.sha2.Sha256 = .init(.{}),
};

fn hashSkeleton(gpa: std.mem.Allocator, hash: *std.crypto.hash.sha2.Sha256, text: []const u8, direction: security.Direction) !void {
    hash.update(try skeletonIn(gpa, text, direction));
    hash.update("\xff");
}

/// The pairs' digests, as the harness draws the pairs.
fn pairs(gpa: std.mem.Allocator, seed: u64, count: usize, groups: []const []const u21) !Kinds {
    var kinds: Kinds = .{};
    var state = seed;
    var a: std.ArrayList(u8) = .empty;
    var b: std.ArrayList(u8) = .empty;
    for (0..count) |_| {
        a.clearRetainingCapacity();
        b.clearRetainingCapacity();
        for (0..1 + splitmix(&state) % 8) |_| {
            const g = groups[splitmix(&state) % groups.len];
            try appendCodePoint(gpa, &a, g[splitmix(&state) % g.len]);
            try appendCodePoint(gpa, &b, g[splitmix(&state) % g.len]);
        }
        try hashSkeleton(gpa, &kinds.logical, a.items, .logical);
        try hashSkeleton(gpa, &kinds.ltr, a.items, .ltr);
        try hashSkeleton(gpa, &kinds.rtl, a.items, .rtl);
        const c: u8 = if (try confusableIn(gpa, a.items, b.items, .ltr)) |class| 1 + @as(u8, @backingInt(class)) else 0;
        kinds.confusable.update(&.{c});
        kinds.restriction.update(&.{@backingInt(security.restrictionLevel(a.items))});
        const f = security.check(a.items, .ascii_only);
        const x: u8 = @as(u8, @intFromBool(f.restricted)) | (@as(u8, @intFromBool(f.mixed_numbers)) << 1) | (@as(u8, @intFromBool(f.repeated_mark)) << 2) | (@as(u8, @intFromBool(f.hidden_overlay)) << 3);
        kinds.checks.update(&.{x});
    }
    return kinds;
}

test "skeletons, confusables, restriction levels and checks as ICU4C's spoof checker gives them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lines = std.mem.tokenizeScalar(u8, ucd.security_icu4c_digests, '\n');
    var seed: u64 = 0;
    var count: usize = 0;
    var groups: std.ArrayList([]const u21) = .empty;
    var kinds: ?Kinds = null;
    var checked: usize = 0;
    var differ: usize = 0;
    var text: std.ArrayList(u8) = .empty;
    var single: std.crypto.hash.sha2.Sha256 = .init(.{});
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
                    text.clearRetainingCapacity();
                    try appendCodePoint(gpa, &text, @intCast(cp));
                    try hashSkeleton(gpa, &single, text.items, .logical);
                }
            }
            continue;
        }
        if (std.mem.eql(u8, name, "seed")) {
            seed = try std.fmt.parseInt(u64, fields.next().?, 10);
            continue;
        }
        if (std.mem.eql(u8, name, "count")) {
            count = try std.fmt.parseInt(usize, fields.next().?, 10);
            continue;
        }
        if (std.mem.eql(u8, name, "alphabet")) {
            while (fields.next()) |group| {
                var members: std.ArrayList(u21) = .empty;
                var it = std.mem.tokenizeScalar(u8, group, '/');
                while (it.next()) |m| try members.append(gpa, try std.fmt.parseInt(u21, m, 16));
                try groups.append(gpa, members.items);
            }
            kinds = try pairs(gpa, seed, count, groups.items);
            continue;
        }
        const want = fields.next().?;
        var hash = if (std.mem.eql(u8, name, "skeleton")) single else inline for (@typeInfo(Kinds).@"struct".field_names) |field| {
            if (std.mem.eql(u8, name, field)) break @field(kinds.?, field);
        } else return error.UnknownDigest;
        const got = std.fmt.bytesToHex(hash.finalResult(), .lower);
        if (!std.mem.eql(u8, want, &got)) {
            std.debug.print("differs from ICU4C: {s}\n", .{name});
            differ += 1;
        }
        checked += 1;
    }
    try std.testing.expectEqual(@as(usize, 7), checked);
    try std.testing.expectEqual(@as(usize, 0), differ);
}

test "ASCII's prototypes are starters in NFD, so ASCII maps byte by byte" {
    const normalize = @import("../normalize.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for (0x20..0x7f) |c| {
        const k = try skeletonIn(arena.allocator(), &.{@intCast(c)}, .logical);
        try std.testing.expect(normalize.isNormalized(.nfd, k));
        var it = std.unicode.Utf8View.initUnchecked(k).iterator();
        while (it.nextCodepoint()) |cp| try std.testing.expectEqual(@as(u8, 0), normalize.combiningClass(cp));
    }
}
