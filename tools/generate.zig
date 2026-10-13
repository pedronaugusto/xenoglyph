//! Writes xenoglyph's lookup tables from the Unicode Character Database.
//!
//! `generate <ucd directory> <output directory>` reads the UCD files xenoglyph
//! uses and writes one Zig source file of tables per property into the
//! output directory. With `--check` it writes nothing: it compares what it
//! would write with what is there, byte for byte, and fails naming every
//! file that differs, is missing, or is there and not generated. `bay
//! generate` and `bay check-tables` run it on `ucd/` and `src/data/`.
//!
//! Each table is two stages: the code point's high bits pick a block, its
//! low bits the entry in the block, and equal blocks are stored once. The
//! block size is the one that makes the table smallest. A table whose
//! values are wider than a byte stores one byte per entry indexing a list
//! of the distinct values, when there are at most 256 of them.
const std = @import("std");
const classes = @import("classes");
const mappings = @import("mappings.zig");

const Allocator = std.mem.Allocator;
pub const code_points = 0x110000;

const version = "18.0.0";

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    var paths: [2][]const u8 = undefined;
    var given: usize = 0;
    var check = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            check = true;
        } else if (given < 2) {
            paths[given] = arg;
            given += 1;
        } else return usage();
    }
    if (given != 2) return usage();

    const cwd = std.Io.Dir.cwd();
    var ucd_dir = try cwd.openDir(io, paths[0], .{});
    defer ucd_dir.close(io);
    const ucd: Ucd = .{ .dir = ucd_dir, .io = io, .gpa = gpa };
    const files = try generate(gpa, ucd);

    if (!check) {
        try cwd.createDirPath(io, paths[1]);
        var out = try cwd.openDir(io, paths[1], .{});
        defer out.close(io);
        for (files) |file| try out.writeFile(io, .{ .sub_path = file.name, .data = file.bytes });
        return;
    }
    var out = cwd.openDir(io, paths[1], .{ .iterate = true }) catch |err| {
        std.log.err("{s}: {t}; run `bay generate`", .{ paths[1], err });
        return error.TablesDiffer;
    };
    defer out.close(io);
    var differ = false;
    for (files) |file| {
        const have = out.readFileAlloc(io, file.name, gpa, .limited(64 << 20)) catch |err| {
            std.log.err("{s}/{s}: {t}", .{ paths[1], file.name, err });
            differ = true;
            continue;
        };
        if (!std.mem.eql(u8, have, file.bytes)) {
            std.log.err("{s}/{s} is not what the generator writes from {s}", .{ paths[1], file.name, paths[0] });
            differ = true;
        }
    }
    var it = out.iterate();
    while (try it.next(io)) |entry| {
        const known = for (files) |file| {
            if (std.mem.eql(u8, file.name, entry.name)) break true;
        } else false;
        if (!known) {
            std.log.err("{s}/{s} is not a file the generator writes", .{ paths[1], entry.name });
            differ = true;
        }
    }
    if (differ) {
        std.log.err("the tables differ from the UCD; `bay generate` writes them", .{});
        return error.TablesDiffer;
    }
}

fn usage() error{Usage} {
    std.log.err("usage: generate <ucd directory> <output directory> [--check]", .{});
    return error.Usage;
}

const File = struct { name: []const u8, bytes: []const u8 };

/// Every table, in the order written.
fn generate(gpa: Allocator, ucd: Ucd) ![]const File {
    const aliases = try Aliases.read(gpa, ucd);
    const p = try Properties.read(gpa, ucd, aliases);
    var files: std.ArrayList(File) = .empty;
    try files.append(gpa, .{ .name = "cluster.zig", .bytes = try clusterFile(gpa, p) });
    try files.append(gpa, .{ .name = "general_category.zig", .bytes = try enumFile(gpa, "General_Category", "extracted/DerivedGeneralCategory.txt", p.general_category) });
    try files.append(gpa, .{ .name = "east_asian_width.zig", .bytes = try enumFile(gpa, "East_Asian_Width", "EastAsianWidth.txt", p.east_asian_width) });
    try files.append(gpa, .{ .name = "word_break.zig", .bytes = try enumFile(gpa, "Word_Break", "auxiliary/WordBreakProperty.txt", p.word_break) });
    try files.append(gpa, .{ .name = "sentence_break.zig", .bytes = try enumFile(gpa, "Sentence_Break", "auxiliary/SentenceBreakProperty.txt", p.sentence_break) });
    try files.append(gpa, .{ .name = "line_break.zig", .bytes = try enumFile(gpa, "Line_Break", "LineBreak.txt", p.line_break) });
    try files.append(gpa, .{ .name = "emoji.zig", .bytes = try emojiFile(gpa, p) });
    try files.append(gpa, .{ .name = "core.zig", .bytes = try coreFile(gpa, p) });
    try files.append(gpa, .{ .name = "script.zig", .bytes = try scriptFile(gpa, p, aliases) });
    try files.append(gpa, .{ .name = "wrapping.zig", .bytes = try lineFile(gpa, p) });
    const ud = try mappings.UnicodeData.read(gpa, ucd);
    try files.append(gpa, .{ .name = "normalization.zig", .bytes = try mappings.normalizationFile(gpa, ucd, ud) });
    try files.append(gpa, .{ .name = "casing.zig", .bytes = try mappings.caseFile(gpa, ucd, p, ud) });
    for (files.items) |*file| file.bytes = try formatted(gpa, file.name, file.bytes);
    return files.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Reading the UCD

pub const Ucd = struct {
    dir: std.Io.Dir,
    io: std.Io,
    gpa: Allocator,

    pub fn read(u: Ucd, path: []const u8) ![]const u8 {
        return u.dir.readFileAlloc(u.io, path, u.gpa, .limited(64 << 20)) catch |err| {
            std.log.err("ucd/{s}: {t}", .{ path, err });
            return err;
        };
    }
};

/// One data line: its first and last code point and its fields after the
/// first, trimmed. Comments and blank lines are skipped.
pub const Line = struct {
    first: u21,
    last: u21,
    fields: [4][]const u8,
    count: usize,

    pub fn field(l: Line, i: usize) []const u8 {
        return if (i < l.count) l.fields[i] else "";
    }
};

pub const Lines = struct {
    rest: std.mem.SplitIterator(u8, .scalar),

    pub fn init(text: []const u8) Lines {
        return .{ .rest = std.mem.splitScalar(u8, text, '\n') };
    }

    pub fn next(it: *Lines) !?Line {
        while (it.rest.next()) |raw| {
            const data = if (std.mem.findScalar(u8, raw, '#')) |hash| raw[0..hash] else raw;
            const line = trim(data);
            if (line.len == 0) continue;
            var parts = std.mem.splitScalar(u8, line, ';');
            const range = trim(parts.next().?);
            var l: Line = .{ .first = 0, .last = 0, .fields = @splat(""), .count = 0 };
            if (std.mem.find(u8, range, "..")) |dots| {
                l.first = try std.fmt.parseInt(u21, range[0..dots], 16);
                l.last = try std.fmt.parseInt(u21, range[dots + 2 ..], 16);
            } else {
                l.first = try std.fmt.parseInt(u21, range, 16);
                l.last = l.first;
            }
            while (parts.next()) |f| {
                if (l.count == l.fields.len) return error.TooManyFields;
                l.fields[l.count] = trim(f);
                l.count += 1;
            }
            return l;
        }
        return null;
    }
};

pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

/// A property value name as UAX #44 LM3 compares them: lower case, with no
/// spaces, hyphens or underscores.
fn loose(gpa: Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (name) |c| switch (c) {
        ' ', '-', '_' => {},
        else => try out.append(gpa, std.ascii.toLower(c)),
    };
    return out.toOwnedSlice(gpa);
}

/// PropertyValueAliases.txt: every alias of a value, by property, to the
/// value's long name.
const Aliases = struct {
    /// "<property>:<loose alias>" to the long name.
    long: std.StringHashMapUnmanaged([]const u8),
    /// Every script, its short and long names, in file order.
    scripts: []const [2][]const u8,

    fn read(gpa: Allocator, ucd: Ucd) !Aliases {
        var a: Aliases = .{ .long = .empty, .scripts = &.{} };
        var scripts: std.ArrayList([2][]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, try ucd.read("PropertyValueAliases.txt"), '\n');
        while (lines.next()) |raw| {
            const data = if (std.mem.findScalar(u8, raw, '#')) |hash| raw[0..hash] else raw;
            if (trim(data).len == 0) continue;
            var fields = std.mem.splitScalar(u8, data, ';');
            const property = trim(fields.next().?);
            const short = trim(fields.next() orelse continue);
            const long = trim(fields.next() orelse continue);
            if (std.mem.eql(u8, property, "sc")) try scripts.append(gpa, .{ short, long });
            for ([_][]const u8{ short, long }) |name| {
                try a.long.put(gpa, try gpa.print("{s}:{s}", .{ property, try loose(gpa, name) }), long);
            }
            while (fields.next()) |other| {
                const name = trim(other);
                if (name.len == 0) continue;
                try a.long.put(gpa, try gpa.print("{s}:{s}", .{ property, try loose(gpa, name) }), long);
            }
        }
        a.scripts = try scripts.toOwnedSlice(gpa);
        return a;
    }

    /// The value of `E` that `name` names, by the aliases of `property`.
    fn value(a: Aliases, gpa: Allocator, comptime E: type, property: []const u8, name: []const u8) !E {
        const key = try gpa.print("{s}:{s}", .{ property, try loose(gpa, name) });
        const long = a.long.get(key) orelse {
            std.log.err("{s}={s} is not in PropertyValueAliases.txt", .{ property, name });
            return error.UnknownValue;
        };
        const want = try loose(gpa, long);
        inline for (@typeInfo(E).@"enum".field_names) |field| {
            if (std.mem.eql(u8, try loose(gpa, field), want)) return @field(E, field);
        }
        std.log.err("{s}={s} ({s}) has no value in {s}", .{ property, name, long, @typeName(E) });
        return error.UnknownValue;
    }
};

/// Every property xenoglyph tabulates, one entry per code point.
pub const Properties = struct {
    general_category: []classes.GeneralCategory,
    east_asian_width: []classes.EastAsianWidth,
    grapheme_break: []classes.GraphemeBreak,
    conjunct: []classes.IndicConjunctBreak,
    word_break: []classes.WordBreak,
    sentence_break: []classes.SentenceBreak,
    line_break: []classes.LineBreak,
    emoji: []classes.Emoji,
    core: []classes.Core,
    /// Index into `Aliases.scripts`.
    script: []u8,
    /// Script_Extensions, as the indexes of its scripts, sorted; null where
    /// it is the Script property alone.
    extensions: []?[]const u8,

    fn read(gpa: Allocator, ucd: Ucd, aliases: Aliases) !Properties {
        var p: Properties = .{
            .general_category = try filled(gpa, classes.GeneralCategory, .unassigned),
            .east_asian_width = try filled(gpa, classes.EastAsianWidth, .neutral),
            .grapheme_break = try filled(gpa, classes.GraphemeBreak, .other),
            .conjunct = try filled(gpa, classes.IndicConjunctBreak, .none),
            .word_break = try filled(gpa, classes.WordBreak, .other),
            .sentence_break = try filled(gpa, classes.SentenceBreak, .other),
            .line_break = try filled(gpa, classes.LineBreak, .unknown),
            .emoji = try filled(gpa, classes.Emoji, .{}),
            .core = try filled(gpa, classes.Core, .{}),
            .script = try filled(gpa, u8, 0),
            .extensions = try filled(gpa, ?[]const u8, null),
        };
        try enumerated(gpa, ucd, aliases, "extracted/DerivedGeneralCategory.txt", "gc", classes.GeneralCategory, p.general_category);
        try enumerated(gpa, ucd, aliases, "EastAsianWidth.txt", "ea", classes.EastAsianWidth, p.east_asian_width);
        try enumerated(gpa, ucd, aliases, "auxiliary/GraphemeBreakProperty.txt", "GCB", classes.GraphemeBreak, p.grapheme_break);
        try enumerated(gpa, ucd, aliases, "auxiliary/WordBreakProperty.txt", "WB", classes.WordBreak, p.word_break);
        try enumerated(gpa, ucd, aliases, "auxiliary/SentenceBreakProperty.txt", "SB", classes.SentenceBreak, p.sentence_break);
        try enumerated(gpa, ucd, aliases, "LineBreak.txt", "lb", classes.LineBreak, p.line_break);

        var lines: Lines = .init(try ucd.read("DerivedCoreProperties.txt"));
        while (try lines.next()) |l| {
            const name = l.field(0);
            if (std.mem.eql(u8, name, "InCB")) {
                const v = try aliases.value(gpa, classes.IndicConjunctBreak, "InCB", l.field(1));
                for (l.first..@as(usize, l.last) + 1) |cp| p.conjunct[cp] = v;
                continue;
            }
            if (std.mem.eql(u8, name, "Grapheme_Link")) continue;
            const want = try loose(gpa, name);
            var known = false;
            const core_info = @typeInfo(classes.Core).@"struct";
            inline for (core_info.field_names, core_info.field_types) |field_name, T| {
                if (T == bool and std.mem.eql(u8, try loose(gpa, field_name), want)) {
                    for (l.first..@as(usize, l.last) + 1) |cp| @field(p.core[cp], field_name) = true;
                    known = true;
                }
            }
            if (!known) {
                std.log.err("DerivedCoreProperties.txt: {s} is not a field of Core", .{name});
                return error.UnknownProperty;
            }
        }

        lines = .init(try ucd.read("emoji/emoji-data.txt"));
        while (try lines.next()) |l| {
            const name = l.field(0);
            for (l.first..@as(usize, l.last) + 1) |cp| {
                const e = &p.emoji[cp];
                if (std.mem.eql(u8, name, "Emoji")) e.emoji = true //
                else if (std.mem.eql(u8, name, "Emoji_Presentation")) e.presentation = true //
                else if (std.mem.eql(u8, name, "Emoji_Modifier")) e.modifier = true //
                else if (std.mem.eql(u8, name, "Emoji_Modifier_Base")) e.modifier_base = true //
                else if (std.mem.eql(u8, name, "Emoji_Component")) e.component = true //
                else if (std.mem.eql(u8, name, "Extended_Pictographic")) e.extended_pictographic = true //
                else {
                    std.log.err("emoji-data.txt: unknown property {s}", .{name});
                    return error.UnknownProperty;
                }
            }
        }
        // A sequence line is "<base> FE0E ; text style;" or the same with
        // FE0F; the base is the line's first field.
        var sequences = std.mem.splitScalar(u8, try ucd.read("emoji/emoji-variation-sequences.txt"), '\n');
        while (sequences.next()) |raw| {
            const data = trim(if (std.mem.findScalar(u8, raw, '#')) |hash| raw[0..hash] else raw);
            if (data.len == 0) continue;
            var codes = std.mem.tokenizeScalar(u8, trim(data[0..std.mem.findScalar(u8, data, ';').?]), ' ');
            const base = try std.fmt.parseInt(u21, codes.next().?, 16);
            const selector = try std.fmt.parseInt(u21, codes.next().?, 16);
            if (selector != 0xfe0e and selector != 0xfe0f) return error.UnknownSelector;
            p.emoji[base].variation_base = true;
        }

        // Scripts: index 0 is Unknown, the default.
        const unknown = for (aliases.scripts, 0..) |s, i| {
            if (std.mem.eql(u8, s[1], "Unknown")) break i;
        } else return error.NoUnknownScript;
        const order = try scriptOrder(gpa, aliases, unknown);
        @memset(p.script, 0);
        lines = .init(try ucd.read("Scripts.txt"));
        while (try lines.next()) |l| {
            const s = try scriptIndex(gpa, aliases, order, l.field(0));
            for (l.first..@as(usize, l.last) + 1) |cp| p.script[cp] = s;
        }
        lines = .init(try ucd.read("ScriptExtensions.txt"));
        while (try lines.next()) |l| {
            var list: std.ArrayList(u8) = .empty;
            var names = std.mem.tokenizeScalar(u8, l.field(0), ' ');
            while (names.next()) |name| try list.append(gpa, try scriptIndex(gpa, aliases, order, name));
            std.mem.sort(u8, list.items, {}, std.sort.asc(u8));
            const set = try list.toOwnedSlice(gpa);
            for (l.first..@as(usize, l.last) + 1) |cp| p.extensions[cp] = set;
        }
        return p;
    }
};

pub fn filled(gpa: Allocator, comptime T: type, value: T) ![]T {
    const s = try gpa.alloc(T, code_points);
    @memset(s, value);
    return s;
}

fn enumerated(gpa: Allocator, ucd: Ucd, aliases: Aliases, path: []const u8, property: []const u8, comptime E: type, out: []E) !void {
    var lines: Lines = .init(try ucd.read(path));
    while (try lines.next()) |l| {
        const v = try aliases.value(gpa, E, property, l.field(0));
        for (l.first..@as(usize, l.last) + 1) |cp| out[cp] = v;
    }
}

/// The scripts in the order of the generated enum: Unknown first, then by
/// long name. Each entry is an index into `Aliases.scripts`.
fn scriptOrder(gpa: Allocator, aliases: Aliases, unknown: usize) ![]const usize {
    var order: std.ArrayList(usize) = .empty;
    for (aliases.scripts, 0..) |_, i| if (i != unknown) try order.append(gpa, i);
    const Less = struct {
        fn less(a: Aliases, x: usize, y: usize) bool {
            return std.mem.lessThan(u8, a.scripts[x][1], a.scripts[y][1]);
        }
    };
    std.mem.sort(usize, order.items, aliases, Less.less);
    try order.insert(gpa, 0, unknown);
    if (order.items.len > 256) return error.TooManyScripts;
    return order.toOwnedSlice(gpa);
}

fn scriptIndex(gpa: Allocator, aliases: Aliases, order: []const usize, name: []const u8) !u8 {
    const want = try loose(gpa, name);
    for (order, 0..) |s, i| {
        if (std.mem.eql(u8, try loose(gpa, aliases.scripts[s][0]), want) or
            std.mem.eql(u8, try loose(gpa, aliases.scripts[s][1]), want)) return @intCast(i);
    }
    std.log.err("script {s} is not in PropertyValueAliases.txt", .{name});
    return error.UnknownValue;
}

// ---------------------------------------------------------------------------
// Derived values

/// A code point's columns, as `width.codepoint` documents them.
fn columns(p: Properties, cp: usize) u2 {
    const gc = p.general_category[cp];
    if (gc == .control or gc == .surrogate or gc == .line_separator or gc == .paragraph_separator) return 0;
    if (cp == 0xad) return 1;
    if (p.core[cp].default_ignorable_code_point) return 0;
    if (gc == .nonspacing_mark or gc == .enclosing_mark) return 0;
    if (p.grapheme_break[cp] == .v or p.grapheme_break[cp] == .t) return 0;
    if (p.east_asian_width[cp] == .wide or p.east_asian_width[cp] == .fullwidth) return 2;
    if (p.grapheme_break[cp] == .regional_indicator) return 2;
    return 1;
}

fn clusterOf(p: Properties, cp: usize) classes.Cluster {
    const e = p.emoji[cp];
    return .{
        .grapheme_break = p.grapheme_break[cp],
        .conjunct = p.conjunct[cp],
        .extended_pictographic = e.extended_pictographic,
        .modifier = e.modifier,
        .modifier_base = e.modifier_base,
        .variation_base = e.variation_base,
        .width = columns(p, cp),
        .ambiguous = p.east_asian_width[cp] == .ambiguous,
    };
}

// ---------------------------------------------------------------------------
// Tables

/// How a table is laid out: two stages (`top` indexes blocks of `entries`
/// directly) or three (`top` indexes runs of `middle`, which index blocks
/// of `entries`).
pub const Shape = struct {
    middle_shift: u5,
    leaf_shift: u5,
    top: []const u32,
    middle: []const u32,
    entries: []const u32,
    entry_bytes: usize,

    fn three(s: Shape) bool {
        return s.middle_shift != 0;
    }

    fn bytesFor(count: usize) usize {
        return if (count <= 256) 1 else 2;
    }

    fn topBytes(s: Shape) usize {
        return if (s.three()) bytesFor(s.middle.len >> s.middle_shift) else bytesFor(s.entries.len >> s.leaf_shift);
    }

    fn size(s: Shape) usize {
        return s.top.len * s.topBytes() + s.middle.len * bytesFor(s.entries.len >> s.leaf_shift) + s.entries.len * s.entry_bytes;
    }
};

pub const Stages = enum { two, smallest };

/// The smallest table of `values` (one per code point) of the shapes `stages` allows.
pub fn shape(gpa: Allocator, values: []const u32, entry_bytes: usize, allowed: Stages) !Shape {
    var best: ?Shape = null;
    var leaf: u5 = 3;
    while (leaf <= 10) : (leaf += 1) {
        const leaves = try dedup(gpa, values, leaf);
        const two: Shape = .{ .middle_shift = 0, .leaf_shift = leaf, .top = leaves.index, .middle = &.{}, .entries = leaves.blocks, .entry_bytes = entry_bytes };
        if (best == null or two.size() < best.?.size()) best = two;
        if (allowed == .two) continue;
        var middle: u5 = 2;
        while (middle + leaf <= 14) : (middle += 1) {
            const runs = try dedup(gpa, leaves.index, middle);
            const s: Shape = .{ .middle_shift = middle, .leaf_shift = leaf, .top = runs.index, .middle = runs.blocks, .entries = leaves.blocks, .entry_bytes = entry_bytes };
            if (s.size() < best.?.size()) best = s;
        }
    }
    return best.?;
}

/// `values` cut into blocks of `1 << shift`, each distinct block once, and
/// for each block of `values` the index of its copy.
fn dedup(gpa: Allocator, values: []const u32, shift: u5) !struct { index: []const u32, blocks: []const u32 } {
    const len = @as(usize, 1) << shift;
    var seen: std.StringHashMapUnmanaged(u32) = .empty;
    var index: std.ArrayList(u32) = .empty;
    var blocks: std.ArrayList(u32) = .empty;
    var at: usize = 0;
    while (at < values.len) : (at += len) {
        const block = values[at..][0..len];
        const got = try seen.getOrPut(gpa, std.mem.sliceAsBytes(block));
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(blocks.items.len >> shift);
            try blocks.appendSlice(gpa, block);
        }
        try index.append(gpa, got.value_ptr.*);
    }
    return .{ .index = try index.toOwnedSlice(gpa), .blocks = try blocks.toOwnedSlice(gpa) };
}

fn typeFor(bytes: usize) []const u8 {
    return if (bytes == 1) "u8" else "u16";
}

/// Writes the table `name` of shape `s`, whose entries are `entry`s.
pub fn writeShape(w: *std.Io.Writer, s: Shape, name: []const u8, entry: []const u8) !void {
    const top = typeFor(s.topBytes());
    if (s.three()) {
        const middle = typeFor(Shape.bytesFor(s.entries.len >> s.leaf_shift));
        try w.print("pub const {s}: lookup.Trie({s}, {s}, {s}, {d}, {d}) = .{{ .top = &{s}_top, .middle = &{s}_middle, .entries = &{s}_entries }};\n\n", .{ name, top, middle, entry, s.middle_shift, s.leaf_shift, name, name, name });
        try w.print("/// {d} bytes: {d} runs of {d} blocks, {d} blocks of {d} entries.\n", .{ s.size(), s.middle.len >> s.middle_shift, @as(usize, 1) << s.middle_shift, s.entries.len >> s.leaf_shift, @as(usize, 1) << s.leaf_shift });
        try w.print("const {s}_top = [{d}]{s}{{\n", .{ name, s.top.len, top });
        try numbers(w, s.top);
        try w.print("}};\n\nconst {s}_middle = [{d}]{s}{{\n", .{ name, s.middle.len, middle });
        try numbers(w, s.middle);
    } else {
        try w.print("pub const {s}: lookup.Stages({s}, {s}, {d}) = .{{ .blocks = &{s}_top, .entries = &{s}_entries }};\n\n", .{ name, top, entry, s.leaf_shift, name, name });
        try w.print("/// {d} bytes: {d} blocks of {d} entries.\n", .{ s.size(), s.entries.len >> s.leaf_shift, @as(usize, 1) << s.leaf_shift });
        try w.print("const {s}_top = [{d}]{s}{{\n", .{ name, s.top.len, top });
        try numbers(w, s.top);
    }
    try w.print("}};\n\nconst {s}_entries = [{d}]{s}{{\n", .{ name, s.entries.len, entry });
    try numbers(w, s.entries);
    try w.writeAll("};\n");
}

pub fn numbers(w: *std.Io.Writer, values: anytype) !void {
    var column: usize = 0;
    for (values) |v| {
        var buffer: [48]u8 = undefined;
        const text = std.mem.print(&buffer, "{d},", .{v}) catch unreachable; // unreachable: a u128 and a comma fit 48 bytes
        if (column == 0) {
            try w.writeAll("   ");
            column = 3;
        }
        if (column + 1 + text.len > 100) {
            try w.writeAll("\n   ");
            column = 3;
        }
        try w.writeAll(" ");
        try w.writeAll(text);
        column += 1 + text.len;
    }
    if (column != 0) try w.writeAll("\n");
}

pub fn header(w: *std.Io.Writer, what: []const u8, sources: []const u8) !void {
    try w.print(
        \\//! {s}, from the Unicode Character Database {s} ({s}).
        \\//!
        \\//! Generated by tools/generate.zig; `bay generate` writes it again and
        \\//! `bay check-tables` checks it. Do not edit. The Unicode data is under
        \\//! the Unicode License v3: see ../UNICODE-LICENSE.txt.
        \\
        \\const lookup = @import("../table.zig");
        \\
    , .{ what, version, sources });
}

fn enumFile(gpa: Allocator, what: []const u8, source: []const u8, values: anytype) ![]const u8 {
    const raw = try gpa.alloc(u32, code_points);
    for (values, raw) |v, *r| r.* = @backingInt(v);
    var out: std.Io.Writer.Allocating = .init(gpa);
    const w = &out.writer;
    try header(w, what, source);
    try w.writeAll("\n");
    try writeShape(w, try shape(gpa, raw, 1, .smallest), "table", "u8");
    return out.toOwnedSlice();
}

fn emojiFile(gpa: Allocator, p: Properties) ![]const u8 {
    const raw = try gpa.alloc(u32, code_points);
    for (p.emoji, raw) |v, *r| r.* = @as(u8, @bitCast(v));
    var out: std.Io.Writer.Allocating = .init(gpa);
    const w = &out.writer;
    try header(w, "The emoji properties as `classes.Emoji` bits", "emoji/emoji-data.txt, emoji/emoji-variation-sequences.txt");
    try w.writeAll("\n");
    try writeShape(w, try shape(gpa, raw, 1, .smallest), "table", "u8");
    return out.toOwnedSlice();
}

/// A table of `Record`s too wide for a byte: each entry indexes `records`.
pub fn recordFile(gpa: Allocator, comptime Record: type, allowed: Stages, what: []const u8, sources: []const u8, values: []const Record) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    const w = &out.writer;
    try header(w, what, sources);
    try w.writeAll("\n");
    try recordTable(gpa, Record, allowed, values, w, "table", "records");
    return out.toOwnedSlice();
}

/// Writes the table `name` of `Record`s (one per code point), each entry the
/// index of its record in `records_name`: a byte when there are at most 256
/// distinct records, two bytes otherwise.
pub fn recordTable(gpa: Allocator, comptime Record: type, allowed: Stages, values: []const Record, w: *std.Io.Writer, name: []const u8, records_name: []const u8) !void {
    const Bits = @typeInfo(Record).@"struct".backing_integer.?;
    var index: std.AutoHashMapUnmanaged(Bits, u32) = .empty;
    var records: std.ArrayList(Bits) = .empty;
    const raw = try gpa.alloc(u32, code_points);
    for (values, raw) |v, *r| {
        const bits: Bits = @bitCast(v);
        const got = try index.getOrPut(gpa, bits);
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(records.items.len);
            try records.append(gpa, bits);
        }
        r.* = got.value_ptr.*;
    }
    if (records.items.len > 65536) return error.TooManyRecords;
    const wide = records.items.len > 256;
    try writeShape(w, try shape(gpa, raw, if (wide) 2 else 1, allowed), name, if (wide) "u16" else "u8");
    try w.print("\n/// {d} bytes: the distinct records, which an entry indexes.\npub const {s} = [{d}]u{d}{{\n", .{ records.items.len * @sizeOf(Bits), records_name, records.items.len, @bitSizeOf(Bits) });
    try numbers(w, records.items);
    try w.writeAll("};\n");
}

fn clusterFile(gpa: Allocator, p: Properties) ![]const u8 {
    const values = try gpa.alloc(classes.Cluster, code_points);
    for (values, 0..) |*v, cp| v.* = clusterOf(p, cp);
    return recordFile(gpa, classes.Cluster, .two, "What segmenting and measuring a grapheme cluster need of a code point, as `classes.Cluster` records", "auxiliary/GraphemeBreakProperty.txt, DerivedCoreProperties.txt, emoji/emoji-data.txt, emoji/emoji-variation-sequences.txt, EastAsianWidth.txt, extracted/DerivedGeneralCategory.txt", values);
}

fn lineOf(p: Properties, cp: usize) classes.Line {
    const gc = p.general_category[cp];
    const class: classes.LineBreak = switch (p.line_break[cp]) {
        .ambiguous, .surrogate, .unknown => .alphabetic,
        .complex_context => if (gc == .nonspacing_mark or gc == .spacing_mark) .combining_mark else .alphabetic,
        .conditional_japanese_starter => .nonstarter,
        else => |c| c,
    };
    const ea = p.east_asian_width[cp];
    return .{
        .class = class,
        .initial = gc == .initial_punctuation,
        .final = gc == .final_punctuation,
        .east_asian = ea == .fullwidth or ea == .wide or ea == .halfwidth,
        .pictographic_unassigned = p.emoji[cp].extended_pictographic and gc == .unassigned,
        .dotted_circle = cp == 0x25cc,
    };
}

fn lineFile(gpa: Allocator, p: Properties) ![]const u8 {
    const values = try gpa.alloc(classes.Line, code_points);
    for (values, 0..) |*v, cp| v.* = lineOf(p, cp);
    return recordFile(gpa, classes.Line, .two, "What the line breaking rules need of a code point, as `classes.Line` records", "LineBreak.txt, extracted/DerivedGeneralCategory.txt, EastAsianWidth.txt, emoji/emoji-data.txt", values);
}

fn coreFile(gpa: Allocator, p: Properties) ![]const u8 {
    return recordFile(gpa, classes.Core, .smallest, "The binary properties of DerivedCoreProperties.txt as `classes.Core` records", "DerivedCoreProperties.txt", p.core);
}

fn scriptFile(gpa: Allocator, p: Properties, aliases: Aliases) ![]const u8 {
    const unknown = for (aliases.scripts, 0..) |s, i| {
        if (std.mem.eql(u8, s[1], "Unknown")) break i;
    } else unreachable; // unreachable: Properties.read found it
    const order = try scriptOrder(gpa, aliases, unknown);
    var out: std.Io.Writer.Allocating = .init(gpa);
    const w = &out.writer;
    try header(w, "Script and Script_Extensions", "Scripts.txt, ScriptExtensions.txt, PropertyValueAliases.txt");
    try w.writeAll("\n/// Script (UAX #24): the long names of PropertyValueAliases.txt, in lower\n/// case, `unknown` first and the rest in order of name.\npub const Script = enum(u8) {\n");
    for (order) |s| {
        const lower = try std.ascii.allocLowerString(gpa, aliases.scripts[s][1]);
        try w.print("    {f},\n", .{std.zig.fmtId(lower)});
    }
    try w.writeAll(
        \\
        \\    /// The script's four-letter ISO 15924 code, as PropertyValueAliases.txt
        \\    /// gives it.
        \\    pub fn code(s: Script) *const [4]u8 {
        \\        return &codes[@intFromEnum(s)];
        \\    }
        \\};
        \\
        \\const codes = [_][4]u8{
        \\
    );
    for (order) |s| try w.print("    \"{s}\".*,\n", .{aliases.scripts[s][0]});
    try w.writeAll("};\n\n/// Script: an entry is a `Script`.\n");
    const raw = try gpa.alloc(u32, code_points);
    for (p.script, raw) |v, *r| r.* = v;
    try writeShape(w, try shape(gpa, raw, 1, .smallest), "table", "u8");

    // Script_Extensions: each distinct set once, in order of first use; 0
    // stands for the Script property alone.
    var sets: std.ArrayList([]const u8) = .empty;
    const ext = try gpa.alloc(u32, code_points);
    for (p.extensions, ext) |e, *r| {
        const set = e orelse {
            r.* = 0;
            continue;
        };
        const i = for (sets.items, 0..) |known, i| {
            if (std.mem.eql(u8, known, set)) break i;
        } else blk: {
            try sets.append(gpa, set);
            break :blk sets.items.len - 1;
        };
        r.* = @intCast(i + 1);
    }
    try w.writeAll("\n/// Script_Extensions: an entry is 0 where it is the Script alone, and\n/// otherwise one more than the index of its set in `sets`.\n");
    try writeShape(w, try shape(gpa, ext, if (sets.items.len < 256) 1 else 2, .smallest), "extensions", if (sets.items.len < 256) "u8" else "u16");
    try w.print("\n/// The distinct Script_Extensions sets, each sorted.\npub const sets = [{d}][]const Script{{\n", .{sets.items.len});
    for (sets.items) |set| {
        try w.writeAll("    &.{");
        for (set, 0..) |member, i| {
            const lower = try std.ascii.allocLowerString(gpa, aliases.scripts[order[member]][1]);
            try w.print("{s}.{f}", .{ if (i == 0) " " else ", ", std.zig.fmtId(lower) });
        }
        try w.writeAll(" },\n");
    }
    try w.writeAll("};\n");
    return out.toOwnedSlice();
}

/// `source` as `zig fmt` writes it, so the files pass the format check.
fn formatted(gpa: Allocator, name: []const u8, source: []const u8) ![]const u8 {
    var tree = try std.zig.Ast.parse(gpa, try gpa.dupeSentinel(u8, source, 0), .{});
    if (tree.errors.len != 0) {
        std.log.err("{s}: the generated source does not parse", .{name});
        return error.InvalidSource;
    }
    return tree.renderAlloc(gpa);
}
