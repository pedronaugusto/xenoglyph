//! UTS #39 throughput: `bay bench`, or `zig-out/bench/security [--smoke]
//! [--row PREFIX]` by hand. A unit is 1,024 identifiers in one script, made
//! of the words of a sentence (bench/texts, and a Hebrew one): each given its
//! skeleton (left to right, and right to left for Hebrew), its restriction
//! level or its checks, or compared with the next for confusability, or with
//! itself, which reads both skeletons to their end. CI compiles this and
//! times nothing.
const std = @import("std");
const xenoglyph = @import("xenoglyph");
const shakedown = @import("shakedown");
const provenance = @import("preflight_bench_options");

const security = xenoglyph.security;
const bidi = xenoglyph.bidi;
const WorkloadError = std.Io.Writer.Error;

const identifiers = 1024;

/// Each script's sentence.
const texts = [_]struct { name: []const u8, sentence: []const u8 }{
    .{ .name = "latin", .sentence = @embedFile("texts/latin.txt") },
    .{ .name = "cyrillic", .sentence = @embedFile("texts/cyrillic.txt") },
    .{ .name = "japanese", .sentence = @embedFile("texts/japanese.txt") },
    .{ .name = "hebrew", .sentence = "\u{5e9}\u{5dc}\u{5d5}\u{5dd} \u{5e2}\u{5d5}\u{5dc}\u{5dd} \u{5d6}\u{5d4}\u{5d5} \u{5d8}\u{5e7}\u{5e1}\u{5d8} \u{5d1}\u{5e2}\u{5d1}\u{5e8}\u{5d9}\u{5ea} \u{5e2}\u{5dd} \u{5de}\u{5e1}\u{5e4}\u{5e8}\u{5d9}\u{5dd} \u{5db}\u{5d0}\u{5dc}\u{5d4}" },
};
const hebrew = 3;

const Context = struct {
    names: [texts.len][][]const u8,
    /// Buffers for two identifiers in display order.
    buffers: [2]security.Buffers,
    out: []u8,
    total: usize = 0,

    fn skeletons(comptime k: usize, comptime direction: security.Direction) fn (*Context, u64) WorkloadError!void {
        return struct {
            fn run(c: *Context, units: u64) WorkloadError!void {
                for (0..units) |_| for (c.names[k]) |name| {
                    var w: std.Io.Writer = .fixed(c.out);
                    try security.skeleton(name, &w, .{ .direction = direction }, c.buffers[0]);
                    c.total += w.end;
                    std.mem.doNotOptimizeAway(c.total);
                };
            }
        }.run;
    }

    fn confusables(comptime k: usize, comptime itself: bool) fn (*Context, u64) WorkloadError!void {
        return struct {
            fn run(c: *Context, units: u64) WorkloadError!void {
                const list = c.names[k];
                for (0..units) |_| for (list, 0..) |name, i| {
                    const other = if (itself) name else list[(i + 1) % list.len];
                    c.total += @intFromBool(security.confusable(name, other, .{}, c.buffers) != null);
                    std.mem.doNotOptimizeAway(c.total);
                };
            }
        }.run;
    }

    fn levels(comptime k: usize) fn (*Context, u64) WorkloadError!void {
        return struct {
            fn run(c: *Context, units: u64) WorkloadError!void {
                for (0..units) |_| for (c.names[k]) |name| {
                    c.total += @backingInt(security.restrictionLevel(name));
                    std.mem.doNotOptimizeAway(c.total);
                };
            }
        }.run;
    }

    fn checks(comptime k: usize) fn (*Context, u64) WorkloadError!void {
        return struct {
            fn run(c: *Context, units: u64) WorkloadError!void {
                for (0..units) |_| for (c.names[k]) |name| {
                    c.total += @as(u8, @bitCast(security.check(name, .highly_restrictive)));
                    std.mem.doNotOptimizeAway(c.total);
                };
            }
        }.run;
    }
};

const Row = shakedown.bench.Row(Context, WorkloadError);

const rows = blk: {
    var out: [5 * texts.len + 1]Row = undefined;
    for (texts, 0..) |t, k| {
        out[5 * k] = .{ .name = "skeleton " ++ t.name, .unit = "1024 identifiers", .run = Context.skeletons(k, .ltr) };
        out[5 * k + 1] = .{ .name = "confusable " ++ t.name, .unit = "1024 identifiers", .run = Context.confusables(k, false) };
        out[5 * k + 2] = .{ .name = "confusable with itself " ++ t.name, .unit = "1024 identifiers", .run = Context.confusables(k, true) };
        out[5 * k + 3] = .{ .name = "restriction level " ++ t.name, .unit = "1024 identifiers", .run = Context.levels(k) };
        out[5 * k + 4] = .{ .name = "check " ++ t.name, .unit = "1024 identifiers", .run = Context.checks(k) };
    }
    out[5 * texts.len] = .{ .name = "skeleton hebrew rtl", .unit = "1024 identifiers", .run = Context.skeletons(hebrew, .rtl) };
    break :blk out;
};

/// A sentence's words, a CJK run cut into four code points (a word longer
/// than twelve bytes with no space in it is one), without punctuation.
fn words(gpa: std.mem.Allocator, sentence: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var tokens = std.mem.tokenizeAny(u8, sentence, " \n,.;:!?()");
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

/// `identifiers` identifiers, each two of `from` joined by `_`, in an order
/// that does not follow theirs.
fn identifiersOf(gpa: std.mem.Allocator, from: []const []const u8) ![][]const u8 {
    const out = try gpa.alloc([]const u8, identifiers);
    for (out, 0..) |*name, i| name.* = try std.mem.concat(gpa, u8, &.{ from[i * 7 % from.len], "_", from[(i * 13 + 5) % from.len] });
    return out;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var c: Context = .{ .names = undefined, .buffers = undefined, .out = try arena.alloc(u8, 4096) };
    var longest: usize = 0;
    for (texts, 0..) |t, k| {
        c.names[k] = try identifiersOf(arena, try words(arena, t.sentence));
        for (c.names[k]) |name| longest = @max(longest, name.len);
    }
    for (&c.buffers) |*b| b.* = .{
        .levels = try arena.alloc(bidi.Level, longest),
        .scratch = try arena.alloc(bidi.Scratch, longest),
        .runs = try arena.alloc(bidi.Run, longest),
    };
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try shakedown.bench.run(WorkloadError, init.gpa, init.io, &writer.interface, &c, &rows, .{ .commit = provenance.commit, .cpu = provenance.cpu, .os = provenance.os }, try .fromArguments(args[1..]));
    try writer.interface.flush();
}
