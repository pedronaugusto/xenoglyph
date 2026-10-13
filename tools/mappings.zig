//! The normalization (UAX #15) and case tables: from UnicodeData.txt,
//! DerivedNormalizationProps.txt, SpecialCasing.txt, CaseFolding.txt and
//! PropList.txt. Part of the generator; see generate.zig.
const std = @import("std");
const classes = @import("classes");
const generate = @import("generate.zig");

const Allocator = std.mem.Allocator;
const code_points = generate.code_points;

/// What UnicodeData.txt says of each code point that the tables need.
pub const UnicodeData = struct {
    ccc: []u8,
    /// The decomposition mapping, one level, and whether it is a
    /// compatibility one (tagged); null where there is none.
    decomposition: []?Raw,
    upper: []u21,
    lower: []u21,
    title: []u21,

    pub const Raw = struct { compatibility: bool, code_points: []const u21 };

    pub fn read(gpa: Allocator, ucd: generate.Ucd) !UnicodeData {
        var d: UnicodeData = .{
            .ccc = try generate.filled(gpa, u8, 0),
            .decomposition = try generate.filled(gpa, ?Raw, null),
            .upper = try gpa.alloc(u21, code_points),
            .lower = try gpa.alloc(u21, code_points),
            .title = try gpa.alloc(u21, code_points),
        };
        for (d.upper, d.lower, d.title, 0..) |*u, *l, *t, cp| {
            u.* = @intCast(cp);
            l.* = @intCast(cp);
            t.* = @intCast(cp);
        }
        var lines = std.mem.splitScalar(u8, try ucd.read("UnicodeData.txt"), '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var f: [15][]const u8 = undefined;
            var parts = std.mem.splitScalar(u8, line, ';');
            for (&f) |*field| field.* = parts.next() orelse return error.ShortLine;
            // Ranges (`<CJK Ideograph, First>`) take every default.
            if (std.mem.endsWith(u8, f[1], "First>") or std.mem.endsWith(u8, f[1], "Last>")) continue;
            const cp = try std.fmt.parseInt(u21, f[0], 16);
            d.ccc[cp] = try std.fmt.parseInt(u8, f[3], 10);
            if (f[5].len > 0) {
                var list: std.ArrayList(u21) = .empty;
                var codes = std.mem.tokenizeScalar(u8, f[5], ' ');
                var compatibility = false;
                while (codes.next()) |code| {
                    if (code[0] == '<') {
                        compatibility = true;
                        continue;
                    }
                    try list.append(gpa, try std.fmt.parseInt(u21, code, 16));
                }
                d.decomposition[cp] = .{ .compatibility = compatibility, .code_points = try list.toOwnedSlice(gpa) };
            }
            if (f[12].len > 0) d.upper[cp] = try std.fmt.parseInt(u21, f[12], 16);
            if (f[13].len > 0) d.lower[cp] = try std.fmt.parseInt(u21, f[13], 16);
            if (f[14].len > 0) d.title[cp] = try std.fmt.parseInt(u21, f[14], 16);
        }
        return d;
    }
};

const hangul_base = 0xac00;
const hangul_count = 11172;

/// Appends the full decomposition of `cp`: canonical mappings only, or
/// with `compatibility` every mapping, applied until none applies. Hangul
/// syllables decompose by the algorithm of chapter 3.12.
fn expand(d: UnicodeData, cp: u21, compatibility: bool, out: *std.ArrayList(u21), gpa: Allocator) !void {
    if (cp >= hangul_base and cp < hangul_base + hangul_count) {
        const s = cp - hangul_base;
        try out.append(gpa, 0x1100 + s / 588);
        try out.append(gpa, 0x1161 + (s % 588) / 28);
        if (s % 28 != 0) try out.append(gpa, 0x11a7 + s % 28);
        return;
    }
    if (d.decomposition[cp]) |raw| if (compatibility or !raw.compatibility) {
        for (raw.code_points) |m| try expand(d, m, compatibility, out, gpa);
        return;
    };
    try out.append(gpa, cp);
}

/// A pool of code point runs that stores each distinct run once.
const Pool = struct {
    items: std.ArrayList(u21) = .empty,
    seen: std.StringHashMapUnmanaged(u16) = .empty,

    fn add(p: *Pool, gpa: Allocator, run: []const u21) !classes.Mapping {
        if (run.len == 0) return .{};
        const key = std.mem.sliceAsBytes(run);
        if (p.seen.get(key)) |start| return .{ .start = start, .len = @intCast(run.len) };
        if (p.items.items.len + run.len > std.math.maxInt(u16)) return error.PoolTooLarge;
        const start: u16 = @intCast(p.items.items.len);
        try p.items.appendSlice(gpa, run);
        // The key is a copy: the pool moves as it grows.
        try p.seen.put(gpa, try gpa.dupe(u8, key), start);
        return .{ .start = start, .len = @intCast(run.len) };
    }
};

pub fn normalizationFile(gpa: Allocator, ucd: generate.Ucd, d: UnicodeData) ![]const u8 {
    // Quick check and composition exclusions.
    const quick = try generate.filled(gpa, classes.QuickCheck, .{});
    const excluded = try generate.filled(gpa, bool, false);
    var lines: generate.Lines = .init(try ucd.read("DerivedNormalizationProps.txt"));
    while (try lines.next()) |l| {
        const name = l.field(0);
        const value = l.field(1);
        for (l.first..@as(usize, l.last) + 1) |cp| {
            if (std.mem.eql(u8, name, "Full_Composition_Exclusion")) excluded[cp] = true //
            else if (std.mem.eql(u8, name, "NFD_QC")) quick[cp].nfd_no = true //
            else if (std.mem.eql(u8, name, "NFKD_QC")) quick[cp].nfkd_no = true //
            else if (std.mem.eql(u8, name, "NFC_QC")) {
                if (value[0] == 'N') quick[cp].nfc_no = true else quick[cp].nfc_maybe = true;
            } else if (std.mem.eql(u8, name, "NFKC_QC")) {
                if (value[0] == 'N') quick[cp].nfkc_no = true else quick[cp].nfkc_maybe = true;
            }
        }
    }

    // Full decompositions, each distinct run once in the pool; index 0 is
    // none. Hangul syllables are left to the algorithm.
    var pool: Pool = .{};
    var records: std.ArrayList(u64) = .empty;
    try records.append(gpa, 0);
    const index = try gpa.alloc(u32, code_points);
    @memset(index, 0);
    var run: std.ArrayList(u21) = .empty;
    for (0..code_points) |i| {
        const cp: u21 = @intCast(i);
        if (d.decomposition[cp] == null) continue;
        var record: classes.Decomposition = .{};
        if (!d.decomposition[cp].?.compatibility) {
            run.clearRetainingCapacity();
            try expand(d, cp, false, &run, gpa);
            record.canonical = try pool.add(gpa, run.items);
        }
        run.clearRetainingCapacity();
        try expand(d, cp, true, &run, gpa);
        record.compatibility = try pool.add(gpa, run.items);
        index[i] = @intCast(records.items.len);
        try records.append(gpa, @bitCast(record));
    }

    // Primary composites: a canonical mapping to two code points that is not
    // excluded, keyed by its two code points.
    const Pair = struct { key: u64, composite: u21 };
    var pairs: std.ArrayList(Pair) = .empty;
    for (d.decomposition, 0..) |raw, cp| {
        const r = raw orelse continue;
        if (r.compatibility or r.code_points.len != 2 or excluded[cp]) continue;
        try pairs.append(gpa, .{ .key = (@as(u64, r.code_points[0]) << 21) | r.code_points[1], .composite = @intCast(cp) });
    }
    std.mem.sort(Pair, pairs.items, {}, struct {
        fn less(_: void, a: Pair, b: Pair) bool {
            return a.key < b.key;
        }
    }.less);

    var out: std.Io.Writer.Allocating = .init(gpa);
    const w = &out.writer;
    try generate.header(w, "Canonical combining classes, decompositions, compositions and quick checks", "UnicodeData.txt, DerivedNormalizationProps.txt");
    try w.writeAll("\n/// Canonical_Combining_Class.\n");
    const ccc = try gpa.alloc(u32, code_points);
    for (ccc, d.ccc) |*c, v| c.* = v;
    try generate.writeShape(w, try generate.shape(gpa, ccc, 1, .smallest), "ccc", "u8");
    try w.writeAll("\n/// The index of a code point's `classes.Decomposition` in `decompositions`;\n/// 0 is none.\n");
    try generate.writeShape(w, try generate.shape(gpa, index, 2, .smallest), "decomposition", "u16");
    try w.print("\n/// {d} bytes: the decompositions, as `classes.Decomposition` bits.\npub const decompositions = [{d}]u64{{\n", .{ records.items.len * 8, records.items.len });
    try generate.numbers(w, records.items);
    try w.print("}};\n\n/// {d} bytes: the code points the decompositions name.\npub const pool = [{d}]u21{{\n", .{ pool.items.items.len * 4, pool.items.items.len });
    try generate.numbers(w, pool.items.items);
    try w.writeAll("};\n\n/// `classes.QuickCheck` bits.\n");
    const qc = try gpa.alloc(u32, code_points);
    for (qc, quick) |*q, v| q.* = @as(u8, @bitCast(v));
    try generate.writeShape(w, try generate.shape(gpa, qc, 1, .smallest), "quick_check", "u8");
    try w.print("\n/// {d} bytes: the primary composites, by their first code point shifted\n/// left 21 bits and their second, sorted.\npub const pair_keys = [{d}]u64{{\n", .{ pairs.items.len * 12, pairs.items.len });
    for (pairs.items) |pair| try w.print("    {d},\n", .{pair.key});
    try w.print("}};\n\npub const pair_composites = [{d}]u21{{\n", .{pairs.items.len});
    for (pairs.items) |pair| try w.print("    {d},\n", .{pair.composite});
    try w.writeAll("};\n");
    return out.toOwnedSlice();
}

fn parseCodes(gpa: Allocator, text: []const u8) ![]const u21 {
    var list: std.ArrayList(u21) = .empty;
    var codes = std.mem.tokenizeScalar(u8, text, ' ');
    while (codes.next()) |code| try list.append(gpa, try std.fmt.parseInt(u21, code, 16));
    return list.toOwnedSlice(gpa);
}

fn delta(to: u21, from: usize) i24 {
    return @intCast(@as(i32, to) - @as(i32, @intCast(from)));
}

pub fn caseFile(gpa: Allocator, ucd: generate.Ucd, p: generate.Properties, d: UnicodeData) ![]const u8 {
    const fold = try gpa.alloc(u21, code_points);
    for (fold, 0..) |*f, cp| f.* = @intCast(cp);
    // Full mappings: SpecialCasing.txt's unconditional lines, and the F lines
    // of CaseFolding.txt.
    const Full = struct { lower: ?[]const u21 = null, upper: ?[]const u21 = null, title: ?[]const u21 = null, fold: ?[]const u21 = null };
    var full: std.array_hash_map.Auto(u21, Full) = .empty;
    var raw_lines = std.mem.splitScalar(u8, try ucd.read("SpecialCasing.txt"), '\n');
    while (raw_lines.next()) |raw| {
        const data = generate.trim(if (std.mem.findScalar(u8, raw, '#')) |hash| raw[0..hash] else raw);
        if (data.len == 0) continue;
        var f: [5][]const u8 = @splat("");
        var parts = std.mem.splitScalar(u8, data, ';');
        for (&f) |*field| field.* = generate.trim(parts.next() orelse "");
        if (f[4].len != 0) continue; // a condition: the casing code applies it
        const cp = try std.fmt.parseInt(u21, f[0], 16);
        const got = try full.getOrPut(gpa, cp);
        if (!got.found_existing) got.value_ptr.* = .{};
        got.value_ptr.lower = try parseCodes(gpa, f[1]);
        got.value_ptr.title = try parseCodes(gpa, f[2]);
        got.value_ptr.upper = try parseCodes(gpa, f[3]);
    }
    raw_lines = std.mem.splitScalar(u8, try ucd.read("CaseFolding.txt"), '\n');
    while (raw_lines.next()) |raw| {
        const data = generate.trim(if (std.mem.findScalar(u8, raw, '#')) |hash| raw[0..hash] else raw);
        if (data.len == 0) continue;
        var parts = std.mem.splitScalar(u8, data, ';');
        const cp = try std.fmt.parseInt(u21, generate.trim(parts.next().?), 16);
        const status = generate.trim(parts.next().?);
        const mapping = try parseCodes(gpa, generate.trim(parts.next().?));
        switch (status[0]) {
            'C', 'S' => fold[cp] = mapping[0],
            'F' => {
                const got = try full.getOrPut(gpa, cp);
                if (!got.found_existing) got.value_ptr.* = .{};
                got.value_ptr.fold = mapping;
            },
            'T' => {}, // Turkic: the casing code applies it
            else => return error.UnknownStatus,
        }
    }
    const soft_dotted = try generate.filled(gpa, bool, false);
    var lines: generate.Lines = .init(try ucd.read("PropList.txt"));
    while (try lines.next()) |l| if (std.mem.eql(u8, l.field(0), "Soft_Dotted")) {
        @memset(soft_dotted[l.first .. @as(usize, l.last) + 1], true);
    };

    const records = try gpa.alloc(classes.Case, code_points);
    for (records, 0..) |*r, cp| r.* = .{
        .lower = delta(d.lower[cp], cp),
        .upper = delta(d.upper[cp], cp),
        .title = delta(d.title[cp], cp),
        .fold = delta(fold[cp], cp),
        .special = full.contains(@intCast(cp)),
        .cased = p.core[cp].cased,
        .case_ignorable = p.core[cp].case_ignorable,
        .soft_dotted = soft_dotted[cp],
    };

    // The special list, sorted by code point.
    const keys = try gpa.dupe(u21, full.keys());
    std.mem.sort(u21, keys, {}, std.sort.asc(u21));
    var pool: Pool = .{};
    var specials: std.ArrayList(u128) = .empty;
    for (keys) |cp| {
        const m = full.get(cp).?;
        const s: classes.Special = .{
            .lower = try pool.add(gpa, m.lower orelse &.{}),
            .upper = try pool.add(gpa, m.upper orelse &.{}),
            .title = try pool.add(gpa, m.title orelse &.{}),
            .fold = try pool.add(gpa, m.fold orelse &.{}),
        };
        try specials.append(gpa, @bitCast(s));
    }

    var out: std.Io.Writer.Allocating = .init(gpa);
    const w = &out.writer;
    try generate.header(w, "Case mappings and folding, as `classes.Case` records", "UnicodeData.txt, SpecialCasing.txt, CaseFolding.txt, PropList.txt, DerivedCoreProperties.txt");
    try w.writeAll("\n");
    try generate.recordTable(gpa, classes.Case, .smallest, records, w, "table", "records");
    try w.print("\n/// The code points with full mappings, sorted.\npub const special_code_points = [{d}]u21{{\n", .{keys.len});
    try generate.numbers(w, keys);
    try w.print("}};\n\n/// Their mappings, as `classes.Special` bits.\npub const specials = [{d}]u128{{\n", .{specials.items.len});
    try generate.numbers(w, specials.items);
    try w.print("}};\n\n/// The code points the mappings name.\npub const pool = [{d}]u21{{\n", .{pool.items.items.len});
    try generate.numbers(w, pool.items.items);
    try w.writeAll("};\n");
    return out.toOwnedSlice();
}
