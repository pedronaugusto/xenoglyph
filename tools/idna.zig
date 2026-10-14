//! The IDNA table (UTS #46): each code point's status in
//! IdnaMappingTable.txt with the Bidi_Class, Joining_Type, virama and mark
//! the validity rules read, and the mapped code points' mappings. Part of
//! the generator; see generate.zig.
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
    for (records, 0..) |*r, cp| {
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
    try generate.header(w, "IDNA processing (UTS #46), as `classes.Idna` records, and the mappings of the mapped code points", "idna/IdnaMappingTable.txt, extracted/DerivedBidiClass.txt, extracted/DerivedJoiningType.txt, extracted/DerivedGeneralCategory.txt, UnicodeData.txt");
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
