//! The IDNA table (UTS #46): each code point's status in
//! IdnaMappingTable.txt with the Bidi_Class, Joining_Type, virama and mark
//! the validity rules read, the IDNA2008 derived property (RFC 5892), and
//! the mapped code points' mappings. Part of the generator; see
//! generate.zig.
const std = @import("std");
const classes = @import("classes");
const generate = @import("generate.zig");
const mappings = @import("mappings.zig");

const Allocator = std.mem.Allocator;
const code_points = generate.code_points;

pub fn idnaFile(gpa: Allocator, ucd: generate.Ucd, aliases: generate.Aliases, p: generate.Properties, d: mappings.UnicodeData) ![]const u8 {
    const records = try gpa.alloc(classes.Idna, code_points);
    @memset(records, .{ .status = .disallowed });

    // Bidi_Class: the @missing lines first, in order, then the data.
    const bidi = try generate.filled(gpa, classes.BidiClass, .left_to_right);
    const bidi_text = try ucd.read("extracted/DerivedBidiClass.txt");
    try missing(gpa, aliases, bidi_text, "bc", classes.BidiClass, bidi);
    try generate.enumerated(gpa, ucd, aliases, "extracted/DerivedBidiClass.txt", "bc", classes.BidiClass, bidi);
    const joining = try generate.filled(gpa, classes.JoiningType, .non_joining);
    try generate.enumerated(gpa, ucd, aliases, "extracted/DerivedJoiningType.txt", "jt", classes.JoiningType, joining);

    const mapped = try generate.filled(gpa, ?[]const u21, null);
    var lines: generate.Lines = .init(try ucd.read("idna/IdnaMappingTable.txt"));
    while (try lines.next()) |l| {
        const status = std.meta.stringToEnum(classes.IdnaStatus, l.field(0)) orelse {
            std.log.err("IdnaMappingTable.txt: unknown status {s}", .{l.field(0)});
            return error.UnknownStatus;
        };
        const mapping: ?[]const u21 = if (status == .mapped) try parseCodes(gpa, l.field(1)) else null;
        for (l.first..@as(usize, l.last) + 1) |cp| {
            records[cp].status = status;
            mapped[cp] = mapping;
        }
    }
    const derived = try idna2008(gpa, ucd, p);
    for (records, 0..) |*r, cp| {
        r.idna2008 = derived[cp];
        r.bidi = bidi[cp];
        r.joining = joining[cp];
        r.virama = d.ccc[cp] == 9;
        r.mark = switch (p.general_category[cp]) {
            .nonspacing_mark, .spacing_mark, .enclosing_mark => true,
            else => false,
        };
    }

    // The mapped code points, sorted, each with its mapping in the pool.
    var keys: std.ArrayList(u21) = .empty;
    var targets: std.ArrayList(u32) = .empty;
    var pool: std.ArrayList(u21) = .empty;
    var seen: std.StringHashMapUnmanaged(u16) = .empty;
    for (mapped, 0..) |m, cp| {
        const run = m orelse continue;
        const key = std.mem.sliceAsBytes(run);
        const start: u16 = seen.get(key) orelse blk: {
            if (pool.items.len + run.len > std.math.maxInt(u16)) return error.PoolTooLarge;
            const s: u16 = @intCast(pool.items.len);
            try pool.appendSlice(gpa, run);
            try seen.put(gpa, key, s);
            break :blk s;
        };
        try keys.append(gpa, @intCast(cp));
        try targets.append(gpa, @bitCast(classes.Mapping{ .start = start, .len = @intCast(run.len) }));
    }

    var out: std.Io.Writer.Allocating = .init(gpa);
    const w = &out.writer;
    try generate.header(w, "IDNA processing (UTS #46), as `classes.Idna` records, and the mappings of the mapped code points", "idna/IdnaMappingTable.txt, extracted/DerivedBidiClass.txt, extracted/DerivedJoiningType.txt, extracted/DerivedGeneralCategory.txt, UnicodeData.txt, and for IDNA2008 (RFC 5892) DerivedNormalizationProps.txt, DerivedCoreProperties.txt, PropList.txt, Blocks.txt, HangulSyllableType.txt");
    try w.writeAll("\n");
    try generate.recordTable(gpa, classes.Idna, .smallest, records, w, "table", "records");
    try w.print("\n/// The mapped code points, sorted.\npub const mapped_code_points = [{d}]u21{{\n", .{keys.items.len});
    try generate.numbers(w, keys.items);
    try w.print("}};\n\n/// Their mappings, as `classes.Mapping` bits.\npub const mappings = [{d}]u32{{\n", .{targets.items.len});
    try generate.numbers(w, targets.items);
    try w.print("}};\n\n/// The code points the mappings name.\npub const pool = [{d}]u21{{\n", .{pool.items.len});
    try generate.numbers(w, pool.items);
    try w.writeAll("};\n");
    return out.toOwnedSlice();
}

/// Each code point's IDNA2008 derived property, by RFC 5892 §3's algorithm
/// over the categories of §2, read from this version's UCD.
fn idna2008(gpa: Allocator, ucd: generate.Ucd, p: generate.Properties) ![]classes.Idna2008 {
    // B, Unstable: NFKC(CaseFold(NFKC(cp))) differs from cp. The UCD's
    // Changes_When_NFKC_Casefolded is that, but for also removing
    // Default_Ignorable_Code_Point characters, which C makes DISALLOWED
    // all the same.
    const unstable = try generate.filled(gpa, bool, false);
    var normalization: generate.Lines = .init(try ucd.read("DerivedNormalizationProps.txt"));
    while (try normalization.next()) |l| {
        if (!std.mem.eql(u8, l.field(0), "Changes_When_NFKC_Casefolded")) continue;
        for (l.first..@as(usize, l.last) + 1) |cp| unstable[cp] = true;
    }
    // C, IgnorableProperties (with Default_Ignorable_Code_Point from the
    // core properties), and H, JoinControl, from PropList.txt.
    const white_space = try generate.filled(gpa, bool, false);
    const noncharacter = try generate.filled(gpa, bool, false);
    const join_control = try generate.filled(gpa, bool, false);
    var props: generate.Lines = .init(try ucd.read("PropList.txt"));
    while (try props.next()) |l| {
        const out = if (std.mem.eql(u8, l.field(0), "White_Space"))
            white_space
        else if (std.mem.eql(u8, l.field(0), "Noncharacter_Code_Point"))
            noncharacter
        else if (std.mem.eql(u8, l.field(0), "Join_Control"))
            join_control
        else
            continue;
        for (l.first..@as(usize, l.last) + 1) |cp| out[cp] = true;
    }
    // D, IgnorableBlocks.
    const ignorable_block = try generate.filled(gpa, bool, false);
    var found: usize = 0;
    var blocks: generate.Lines = .init(try ucd.read("Blocks.txt"));
    while (try blocks.next()) |l| {
        const name = l.field(0);
        const ignorable = std.mem.eql(u8, name, "Combining Diacritical Marks for Symbols") or
            std.mem.eql(u8, name, "Musical Symbols") or
            std.mem.eql(u8, name, "Ancient Greek Musical Notation");
        if (!ignorable) continue;
        found += 1;
        for (l.first..@as(usize, l.last) + 1) |cp| ignorable_block[cp] = true;
    }
    if (found != 3) return error.IgnorableBlocksMissing;
    // I, OldHangulJamo: Hangul_Syllable_Type L, V or T.
    const old_jamo = try generate.filled(gpa, bool, false);
    var hangul: generate.Lines = .init(try ucd.read("HangulSyllableType.txt"));
    while (try hangul.next()) |l| {
        const t = l.field(0);
        if (!std.mem.eql(u8, t, "L") and !std.mem.eql(u8, t, "V") and !std.mem.eql(u8, t, "T")) continue;
        for (l.first..@as(usize, l.last) + 1) |cp| old_jamo[cp] = true;
    }

    const out = try gpa.alloc(classes.Idna2008, code_points);
    for (out, 0..) |*v, cp_index| {
        const cp: u21 = @intCast(cp_index);
        const gc = p.general_category[cp];
        v.* = if (exception(cp)) |e|
            e
        else if (gc == .unassigned and !noncharacter[cp])
            // J, Unassigned (G, BackwardCompatible, is empty).
            .unassigned
        else if (cp == '-' or (cp >= '0' and cp <= '9') or (cp >= 'a' and cp <= 'z'))
            // E, LDH.
            .pvalid
        else if (join_control[cp])
            .contextj
        else if (unstable[cp] or p.core[cp].default_ignorable_code_point or white_space[cp] or noncharacter[cp] or ignorable_block[cp] or old_jamo[cp])
            .disallowed
        else switch (gc) {
            // A, LetterDigits.
            .lowercase_letter, .uppercase_letter, .other_letter, .decimal_number, .modifier_letter, .nonspacing_mark, .spacing_mark => .pvalid,
            else => .disallowed,
        };
    }
    return out;
}

/// F, Exceptions (RFC 5892 §2.6): the code points whose value is fixed
/// by the RFC, whatever their properties.
fn exception(cp: u21) ?classes.Idna2008 {
    return switch (cp) {
        0x00df, 0x03c2, 0x06fd, 0x06fe, 0x0f0b, 0x3007 => .pvalid,
        0x00b7, 0x0375, 0x05f3, 0x05f4, 0x30fb, 0x0660...0x0669, 0x06f0...0x06f9 => .contexto,
        0x0640, 0x07fa, 0x302e, 0x302f, 0x3031...0x3035, 0x303b => .disallowed,
        else => null,
    };
}

/// Applies the `# @missing: <range>; <value>` lines of `text`, in order.
fn missing(gpa: Allocator, aliases: generate.Aliases, text: []const u8, property: []const u8, comptime E: type, out: []E) !void {
    const marker = "# @missing:";
    var raw_lines = std.mem.splitScalar(u8, text, '\n');
    while (raw_lines.next()) |raw| {
        if (!std.mem.startsWith(u8, raw, marker)) continue;
        var it: generate.Lines = .init(raw[marker.len..]);
        const l = (try it.next()) orelse continue;
        const v = try aliases.value(gpa, E, property, l.field(0));
        for (l.first..@as(usize, l.last) + 1) |cp| out[cp] = v;
    }
}

fn parseCodes(gpa: Allocator, text: []const u8) ![]const u21 {
    var list: std.ArrayList(u21) = .empty;
    var codes = std.mem.tokenizeScalar(u8, text, ' ');
    while (codes.next()) |code| try list.append(gpa, try std.fmt.parseInt(u21, code, 16));
    return list.toOwnedSlice(gpa);
}
