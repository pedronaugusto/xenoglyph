//! Bidi throughput: `bay bench`, or `zig-out/bench/bidi [--smoke] [--row
//! PREFIX]` by hand. A unit is one paragraph of 16 KiB or a little more
//! (whole sentences, no separator) in English, Hebrew, Arabic, or the three
//! mixed: resolving its levels, or resolving it and reordering its lines
//! (broken at the last space before each 80 bytes, as an engine's line
//! breaker would). bench/rivals/bidi.c runs the same rows through SheenBidi
//! and ICU. CI compiles this and times nothing.
const std = @import("std");
const xenoglyph = @import("xenoglyph");
const shakedown = @import("shakedown");
const provenance = @import("preflight_bench_options");

const bidi = xenoglyph.bidi;
const WorkloadError = error{};

/// The sentences each paragraph repeats; bench/rivals/bidi.c holds the same.
const sentences = [_][]const u8{
    "The quick brown fox jumps over the lazy dog, 42 times. ",
    "\u{5e9}\u{5dc}\u{5d5}\u{5dd} \u{5e2}\u{5d5}\u{5dc}\u{5dd}, \u{5d6}\u{5d4}\u{5d5} \u{5d8}\u{5e7}\u{5e1}\u{5d8} \u{5d1}\u{5e2}\u{5d1}\u{5e8}\u{5d9}\u{5ea} \u{5e2}\u{5dd} \u{5de}\u{5e1}\u{5e4}\u{5e8}\u{5d9}\u{5dd} 123 (\u{5db}\u{5d0}\u{5dc}\u{5d4}). ",
    "\u{645}\u{631}\u{62d}\u{628}\u{627} \u{628}\u{627}\u{644}\u{639}\u{627}\u{644}\u{645}\u{60c} \u{647}\u{630}\u{627} \u{646}\u{635} \u{639}\u{631}\u{628}\u{64a} \u{645}\u{639} \u{623}\u{631}\u{642}\u{627}\u{645} \u{661}\u{662}\u{663} (\u{645}\u{62b}\u{644} \u{647}\u{630}\u{647}). ",
    "The word \u{5e9}\u{5dc}\u{5d5}\u{5dd} means peace (\u{5e9}\u{5c1}\u{5b8}\u{5dc}\u{5d5}\u{5b9}\u{5dd}) and \u{645}\u{631}\u{62d}\u{628}\u{627} means hello, 2026. ",
};
const names = [_][]const u8{ "english", "hebrew", "arabic", "mixed" };
const size = 16 * 1024;

const Context = struct {
    texts: [sentences.len][]const u8,
    /// Each text's line ends.
    breaks: [sentences.len][]const usize,
    levels: []bidi.Level,
    scratch: []bidi.Scratch,
    runs: []bidi.Run,
    count: usize = 0,

    fn resolve(comptime k: usize) fn (*Context, u64) WorkloadError!void {
        return struct {
            fn run(c: *Context, units: u64) WorkloadError!void {
                for (0..units) |_| {
                    const p: bidi.Paragraph = .resolve(c.texts[k], .fromRaw(0), .{}, .{ .levels = c.levels, .scratch = c.scratch });
                    c.count += p.level;
                    std.mem.doNotOptimizeAway(c.count);
                }
            }
        }.run;
    }

    fn lines(comptime k: usize) fn (*Context, u64) WorkloadError!void {
        return struct {
            fn run(c: *Context, units: u64) WorkloadError!void {
                for (0..units) |_| {
                    const p: bidi.Paragraph = .resolve(c.texts[k], .fromRaw(0), .{}, .{ .levels = c.levels, .scratch = c.scratch });
                    var start: usize = 0;
                    for (c.breaks[k]) |end| {
                        const l = p.line(.fromRaw(start, end), c.runs);
                        c.count += l.runs.len;
                        start = end;
                    }
                    std.mem.doNotOptimizeAway(c.count);
                }
            }
        }.run;
    }
};

/// Line ends at the last space before each 80 bytes.
fn breaksOf(gpa: std.mem.Allocator, text: []const u8) ![]const usize {
    var out: std.ArrayList(usize) = .empty;
    var start: usize = 0;
    while (start < text.len) {
        var end = @min(start + 80, text.len);
        if (end < text.len) {
            while (end > start and text[end - 1] != ' ') end -= 1;
            if (end == start) end = @min(start + 80, text.len);
        }
        try out.append(gpa, end);
        start = end;
    }
    return out.toOwnedSlice(gpa);
}

const Row = shakedown.bench.Row(Context, WorkloadError);

const rows = blk: {
    var out: [2 * sentences.len]Row = undefined;
    for (0..sentences.len) |k| {
        out[k] = .{ .name = "bidi resolve " ++ names[k], .unit = "16KiB", .run = Context.resolve(k) };
        out[sentences.len + k] = .{ .name = "bidi lines " ++ names[k], .unit = "16KiB", .run = Context.lines(k) };
    }
    break :blk out;
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var c: Context = .{ .texts = undefined, .breaks = undefined, .levels = undefined, .scratch = undefined, .runs = undefined };
    var longest: usize = 0;
    for (sentences, 0..) |s, k| {
        var text: std.ArrayList(u8) = .empty;
        while (text.items.len < size) try text.appendSlice(arena, s);
        c.texts[k] = text.items;
        c.breaks[k] = try breaksOf(arena, text.items);
        longest = @max(longest, text.items.len);
    }
    c.levels = try arena.alloc(bidi.Level, longest);
    c.scratch = try arena.alloc(bidi.Scratch, longest);
    c.runs = try arena.alloc(bidi.Run, longest);
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try shakedown.bench.run(WorkloadError, init.gpa, init.io, &writer.interface, &c, &rows, .{ .commit = provenance.commit, .cpu = provenance.cpu, .os = provenance.os }, try .fromArguments(args[1..]));
    try writer.interface.flush();
}
