//! Every table against the UCD file it comes from, for every code point:
//! the files are parsed here again, apart from the generator, and each
//! lookup must give what the file says. The widths are derived from the
//! raw properties by the rules `width.zig` states.
const std = @import("std");
const ucd = @import("ucd");
const properties = @import("../properties.zig");
const width = @import("../width.zig");

const gpa = std.testing.allocator;
const all = 0x110000;

const Line = struct { first: u21, last: u21, value: []const u8, second: []const u8 };

fn lines(text: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, text, '\n');
}

fn parseLine(raw: []const u8) !?Line {
    const data = std.mem.trim(u8, if (std.mem.findScalar(u8, raw, '#')) |hash| raw[0..hash] else raw, " \t\r");
    if (data.len == 0) return null;
    var fields = std.mem.splitScalar(u8, data, ';');
    const range = std.mem.trim(u8, fields.next().?, " ");
    const value = std.mem.trim(u8, fields.next() orelse "", " ");
    const second = std.mem.trim(u8, fields.next() orelse "", " ");
    if (std.mem.find(u8, range, "..")) |dots| {
        return .{ .first = try std.fmt.parseInt(u21, range[0..dots], 16), .last = try std.fmt.parseInt(u21, range[dots + 2 ..], 16), .value = value, .second = second };
    }
    const cp = try std.fmt.parseInt(u21, range, 16);
    return .{ .first = cp, .last = cp, .value = value, .second = second };
}

/// UAX #44 LM3: case, spaces, hyphens and underscores do not count.
fn looseEql(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and (a[i] == '_' or a[i] == ' ' or a[i] == '-')) i += 1;
        while (j < b.len and (b[j] == '_' or b[j] == ' ' or b[j] == '-')) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[j])) return false;
        i += 1;
        j += 1;
    }
}

/// The value of `E` that `name`, an alias of `property` in
/// PropertyValueAliases.txt, names.
fn valueOf(comptime E: type, property: []const u8, name: []const u8) !E {
    var it = lines(ucd.property_value_aliases);
    while (it.next()) |raw| {
        const data = if (std.mem.findScalar(u8, raw, '#')) |hash| raw[0..hash] else raw;
        var fields = std.mem.splitScalar(u8, data, ';');
        if (!std.mem.eql(u8, std.mem.trim(u8, fields.next() orelse continue, " "), property)) continue;
        var names: [4][]const u8 = undefined;
        var n: usize = 0;
        while (fields.next()) |f| : (n += 1) {
            if (n == names.len) break;
            names[n] = std.mem.trim(u8, f, " ");
        }
        const matches = for (names[0..n]) |alias| {
            if (looseEql(alias, name)) break true;
        } else false;
        if (!matches) continue;
        inline for (@typeInfo(E).@"enum".field_names) |field| if (looseEql(field, names[1])) return @field(E, field);
        return error.NoSuchValue;
    }
    return error.NoSuchValue;
}

fn expectEnumFile(comptime E: type, text: []const u8, property: []const u8, default: E, lookup: fn (u21) E) !void {
    const want = try gpa.alloc(E, all);
    defer gpa.free(want);
    @memset(want, default);
    var it = lines(text);
    while (it.next()) |raw| {
        const l = try parseLine(raw) orelse continue;
        const v = try valueOf(E, property, l.value);
        @memset(want[l.first .. @as(usize, l.last) + 1], v);
    }
    for (want, 0..) |w, cp| {
        if (lookup(@intCast(cp)) != w) {
            std.debug.print("{s} of U+{X:0>4}: {t}, the file says {t}\n", .{ property, cp, lookup(@intCast(cp)), w });
            return error.TestUnexpectedResult;
        }
    }
}

test "Joining_Type of every code point" {
    try expectEnumFile(properties.JoiningType, ucd.joining_type, "jt", .non_joining, properties.joiningType);
}

test "Bidi_Class of every code point, the defaults of the @missing lines included" {
    const want = try gpa.alloc(properties.BidiClass, all);
    defer gpa.free(want);
    @memset(want, .left_to_right);
    const marker = "# @missing:";
    var it = lines(ucd.bidi_class);
    while (it.next()) |raw| {
        const missing = std.mem.startsWith(u8, raw, marker);
        const l = try parseLine(if (missing) raw[marker.len..] else raw) orelse continue;
        @memset(want[l.first .. @as(usize, l.last) + 1], try valueOf(properties.BidiClass, "bc", l.value));
    }
    for (want, 0..) |w, cp| try std.testing.expectEqual(w, properties.bidiClass(@intCast(cp)));
}

test "General_Category of every code point" {
    try expectEnumFile(properties.GeneralCategory, ucd.general_category, "gc", .unassigned, properties.generalCategory);
}

test "East_Asian_Width of every code point" {
    try expectEnumFile(properties.EastAsianWidth, ucd.east_asian_width, "ea", .neutral, properties.eastAsianWidth);
}

test "Grapheme_Cluster_Break of every code point" {
    try expectEnumFile(properties.GraphemeBreak, ucd.grapheme_break_property, "GCB", .other, properties.graphemeBreak);
}

test "Word_Break of every code point" {
    try expectEnumFile(properties.WordBreak, ucd.word_break_property, "WB", .other, properties.wordBreak);
}

test "Sentence_Break of every code point" {
    try expectEnumFile(properties.SentenceBreak, ucd.sentence_break_property, "SB", .other, properties.sentenceBreak);
}

test "Line_Break of every code point" {
    try expectEnumFile(properties.LineBreak, ucd.line_break, "lb", .unknown, properties.lineBreak);
}

test "Script of every code point" {
    try expectEnumFile(properties.Script, ucd.scripts, "sc", .unknown, properties.script);
}

test "Script_Extensions of every code point" {
    const listed = try gpa.alloc(bool, all);
    defer gpa.free(listed);
    @memset(listed, false);
    var it = lines(ucd.script_extensions);
    while (it.next()) |raw| {
        const l = try parseLine(raw) orelse continue;
        var want: [64]properties.Script = undefined;
        var n: usize = 0;
        var names = std.mem.tokenizeScalar(u8, l.value, ' ');
        while (names.next()) |name| : (n += 1) want[n] = try valueOf(properties.Script, "sc", name);
        std.mem.sort(properties.Script, want[0..n], {}, struct {
            fn less(_: void, a: properties.Script, b: properties.Script) bool {
                return @backingInt(a) < @backingInt(b);
            }
        }.less);
        for (l.first..@as(usize, l.last) + 1) |cp| {
            listed[cp] = true;
            try std.testing.expectEqualSlices(properties.Script, want[0..n], properties.scriptExtensions(@intCast(cp)));
        }
    }
    for (listed, 0..) |l, cp| {
        if (l) continue;
        const got = properties.scriptExtensions(@intCast(cp));
        try std.testing.expectEqual(1, got.len);
        try std.testing.expectEqual(properties.script(@intCast(cp)), got[0]);
    }
    try std.testing.expectEqualStrings("Latn", properties.Script.latin.code());
}

test "Indic_Conjunct_Break and the derived core properties of every code point" {
    const want = try gpa.alloc(properties.Core, all);
    defer gpa.free(want);
    @memset(want, .{});
    const conjunct = try gpa.alloc(properties.IndicConjunctBreak, all);
    defer gpa.free(conjunct);
    @memset(conjunct, .none);
    var it = lines(ucd.derived_core_properties);
    var seen: usize = 0;
    while (it.next()) |raw| {
        const l = try parseLine(raw) orelse continue;
        if (std.mem.eql(u8, l.value, "InCB")) {
            @memset(conjunct[l.first .. @as(usize, l.last) + 1], try valueOf(properties.IndicConjunctBreak, "InCB", l.second));
            continue;
        }
        if (std.mem.eql(u8, l.value, "Grapheme_Link")) continue;
        const info = @typeInfo(properties.Core).@"struct";
        var found = false;
        inline for (info.field_names, info.field_types) |field, T| {
            if (T == bool and looseEql(field, l.value)) {
                for (want[l.first .. @as(usize, l.last) + 1]) |*w| @field(w, field) = true;
                found = true;
            }
        }
        try std.testing.expect(found);
        seen += 1;
    }
    try std.testing.expect(seen > 10_000);
    for (want, conjunct, 0..) |w, c, cp| {
        try std.testing.expectEqual(w, properties.core(@intCast(cp)));
        try std.testing.expectEqual(c, properties.indicConjunctBreak(@intCast(cp)));
    }
}

test "emoji properties of every code point" {
    const want = try gpa.alloc(properties.Emoji, all);
    defer gpa.free(want);
    @memset(want, .{});
    var it = lines(ucd.emoji_data);
    while (it.next()) |raw| {
        const l = try parseLine(raw) orelse continue;
        for (want[l.first .. @as(usize, l.last) + 1]) |*e| {
            if (std.mem.eql(u8, l.value, "Emoji")) e.emoji = true //
            else if (std.mem.eql(u8, l.value, "Emoji_Presentation")) e.presentation = true //
            else if (std.mem.eql(u8, l.value, "Emoji_Modifier")) e.modifier = true //
            else if (std.mem.eql(u8, l.value, "Emoji_Modifier_Base")) e.modifier_base = true //
            else if (std.mem.eql(u8, l.value, "Emoji_Component")) e.component = true //
            else if (std.mem.eql(u8, l.value, "Extended_Pictographic")) e.extended_pictographic = true //
            else return error.TestUnexpectedResult;
        }
    }
    var sequences = lines(ucd.emoji_variation_sequences);
    while (sequences.next()) |raw| {
        if (raw.len == 0 or raw[0] == '#') continue;
        var codes = std.mem.tokenizeScalar(u8, raw, ' ');
        want[try std.fmt.parseInt(u21, codes.next().?, 16)].variation_base = true;
    }
    for (want, 0..) |w, cp| try std.testing.expectEqual(w, properties.emoji(@intCast(cp)));
}

test "width.codepoint of every code point, from the raw properties by the stated rules" {
    const ignorable = try gpa.alloc(bool, all);
    defer gpa.free(ignorable);
    @memset(ignorable, false);
    var it = lines(ucd.derived_core_properties);
    while (it.next()) |raw| {
        const l = try parseLine(raw) orelse continue;
        if (std.mem.eql(u8, l.value, "Default_Ignorable_Code_Point")) @memset(ignorable[l.first .. @as(usize, l.last) + 1], true);
    }
    for (0..all) |i| {
        const cp: u21 = @intCast(i);
        const gc = properties.generalCategory(cp);
        const ea = properties.eastAsianWidth(cp);
        const gcb = properties.graphemeBreak(cp);
        const want: u2 = if (gc == .control or gc == .surrogate or gc == .line_separator or gc == .paragraph_separator)
            0
        else if (cp == 0xad)
            1
        else if (ignorable[i])
            0
        else if (gc == .nonspacing_mark or gc == .enclosing_mark)
            0
        else if (gcb == .v or gcb == .t)
            0
        else if (ea == .wide or ea == .fullwidth)
            2
        else if (gcb == .regional_indicator)
            2
        else
            1;
        try std.testing.expectEqual(want, width.codepoint(cp, .{}).raw());
        const wide_want: u2 = if (want == 1 and ea == .ambiguous) 2 else want;
        try std.testing.expectEqual(wide_want, width.codepoint(cp, .{ .ambiguous = .wide }).raw());
    }
}

test "values past U+10FFFF get the defaults" {
    for ([_]u21{ 0x110000, 0x1fffff }) |cp| {
        try std.testing.expectEqual(.unassigned, properties.generalCategory(cp));
        try std.testing.expectEqual(.other, properties.graphemeBreak(cp));
        try std.testing.expectEqual(.unknown, properties.script(cp));
        try std.testing.expectEqual(1, properties.scriptExtensions(cp).len);
        try std.testing.expectEqual(properties.Emoji{}, properties.emoji(cp));
        try std.testing.expectEqual(1, width.codepoint(cp, .{}).raw());
    }
}
