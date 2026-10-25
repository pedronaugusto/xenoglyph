//! Collation throughput: `bay bench`, or `zig-out/bench/collation [--smoke]
//! [--row PREFIX]` by hand. A unit is 1,024 names in one language, made of
//! the words of a sentence of bench/texts (CJK cut into four code points),
//! sorted by `compare` or each given its sort key; or one comparison of two
//! texts of 16 KiB that differ only in their last accent, which every level
//! reads to its end. CI compiles this and times nothing.
const std = @import("std");
const xenoglyph = @import("xenoglyph");
const shakedown = @import("shakedown");
const provenance = @import("preflight_bench_options");

const collation = xenoglyph.collation;
const WorkloadError = std.Io.Writer.Error;

const names = 1024;
const size = 16 * 1024;

/// Each language's sentence, from bench/texts.
const texts = [_]struct { name: []const u8, sentence: []const u8 }{
    .{ .name = "latin", .sentence = @embedFile("texts/latin.txt") },
    .{ .name = "central", .sentence = @embedFile("texts/central.txt") },
    .{ .name = "cyrillic", .sentence = @embedFile("texts/cyrillic.txt") },
    .{ .name = "japanese", .sentence = @embedFile("texts/japanese.txt") },
    .{ .name = "simplified", .sentence = @embedFile("texts/simplified.txt") },
    .{ .name = "korean", .sentence = @embedFile("texts/korean.txt") },
};

/// The lists the rows sort: one per language, then file names with numbers.
const lists = texts.len + 1;
const file_names = texts.len;

const Context = struct {
    /// Each list as made, and the copy a unit sorts.
    list: [lists][][]const u8,
    work: [][]const u8,
    /// The late-difference texts.
    late: [2][]const u8,
    key: []u8,
    total: usize = 0,

    fn sort(comptime k: usize, comptime options: collation.Options) fn (*Context, u64) WorkloadError!void {
        return struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return collation.compare(a, b, options) == .lt;
            }

            fn run(c: *Context, units: u64) WorkloadError!void {
                for (0..units) |_| {
                    @memcpy(c.work, c.list[k]);
                    std.mem.sort([]const u8, c.work, {}, less);
                    c.total += c.work[0].len;
                    std.mem.doNotOptimizeAway(c.total);
                }
            }
        }.run;
    }

    fn keys(comptime k: usize) fn (*Context, u64) WorkloadError!void {
        return struct {
            fn run(c: *Context, units: u64) WorkloadError!void {
                for (0..units) |_| for (c.list[k]) |name| {
                    var w: std.Io.Writer = .fixed(c.key);
                    try collation.sortKey(name, &w, .{});
                    c.total += w.end;
                    std.mem.doNotOptimizeAway(c.total);
                };
            }
        }.run;
    }

    fn lateDifference(c: *Context, units: u64) WorkloadError!void {
        for (0..units) |_| {
            c.total += @backingInt(collation.compare(c.late[0], c.late[1], .{}));
            std.mem.doNotOptimizeAway(c.total);
        }
    }
};

const Row = shakedown.bench.Row(Context, WorkloadError);

const rows = blk: {
    var out: [2 * texts.len + 3]Row = undefined;
    for (texts, 0..) |t, k| {
        out[2 * k] = .{ .name = "sort " ++ t.name, .unit = "1024 names", .run = Context.sort(k, .{}) };
        out[2 * k + 1] = .{ .name = "sort key " ++ t.name, .unit = "1024 names", .run = Context.keys(k) };
    }
    out[2 * texts.len] = .{ .name = "sort latin shifted quaternary", .unit = "1024 names", .run = Context.sort(0, .{ .strength = .quaternary, .alternate = .shifted }) };
    out[2 * texts.len + 1] = .{ .name = "sort file names numeric", .unit = "1024 names", .run = Context.sort(file_names, .{ .numeric = true }) };
    out[2 * texts.len + 2] = .{ .name = "compare late difference", .unit = "16KiB", .run = Context.lateDifference };
    break :blk out;
};

/// A sentence's words, a CJK run cut into four code points: a word longer
/// than twelve bytes with no space in it is one.
fn words(gpa: std.mem.Allocator, sentence: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var tokens = std.mem.tokenizeAny(u8, sentence, " \n");
    while (tokens.next()) |token| {
        if (token.len <= 12) {
            try out.append(gpa, token);
            continue;
        }
        var it = (try std.unicode.Utf8View.init(token)).iterator();
        while (true) {
            const start = it.i;
            for (0..4) |_| _ = it.nextCodepointSlice() orelse break;
            if (it.i == start) break;
            try out.append(gpa, token[start..it.i]);
        }
    }
    return out.items;
}

/// `names` names, each two of `from` with a space between, in an order
/// that does not follow theirs.
fn namesOf(gpa: std.mem.Allocator, from: []const []const u8) ![][]const u8 {
    const out = try gpa.alloc([]const u8, names);
    for (out, 0..) |*name, i| name.* = try std.mem.concat(gpa, u8, &.{ from[i * 7 % from.len], " ", from[(i * 13 + 5) % from.len] });
    return out;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var c: Context = .{ .list = undefined, .work = try arena.alloc([]const u8, names), .late = undefined, .key = try arena.alloc(u8, 4096) };
    for (texts, 0..) |t, k| c.list[k] = try namesOf(arena, try words(arena, t.sentence));
    c.list[file_names] = try arena.alloc([]const u8, names);
    for (c.list[file_names], 0..) |*name, i| name.* = try arena.print("file{d}.txt", .{i * 7919 % 100_000});
    var text: std.ArrayList(u8) = .empty;
    while (text.items.len < size) try text.appendSlice(arena, texts[0].sentence);
    try text.appendSlice(arena, "e");
    c.late[0] = text.items;
    c.late[1] = try std.mem.concat(arena, u8, &.{ text.items[0 .. text.items.len - 1], "\u{e9}" });
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try shakedown.bench.run(WorkloadError, init.gpa, init.io, &writer.interface, &c, &rows, .{ .commit = provenance.commit, .cpu = provenance.cpu, .os = provenance.os }, try .fromArguments(args[1..]));
    try writer.interface.flush();
}
