//! Segmentation and line breaking throughput: `bay bench`, or `zig-out/bench/segment [--smoke]
//! [--row PREFIX]` by hand. A unit is one pass over a 64 KiB text, so
//! MB/s is 65.5 / (ms a unit). CI compiles this and times nothing.
const std = @import("std");
const xenoglyph = @import("xenoglyph");
const shakedown = @import("shakedown");
const provenance = @import("preflight_bench_options");
const corpus = @import("corpus.zig");

const WorkloadError = error{};

const Context = struct {
    texts: [@typeInfo(corpus.Kind).@"enum".field_names.len][]const u8,
    count: usize = 0,

    fn text(c: *const Context, kind: corpus.Kind) []const u8 {
        return c.texts[@backingInt(kind)];
    }

    fn graphemes(comptime kind: corpus.Kind) fn (*Context, u64) WorkloadError!void {
        return struct {
            fn run(c: *Context, units: u64) WorkloadError!void {
                for (0..units) |_| {
                    var it = xenoglyph.graphemes(c.text(kind));
                    while (it.nextSpan()) |_| c.count += 1;
                    std.mem.doNotOptimizeAway(c.count);
                }
            }
        }.run;
    }

    fn graphemesBackward(comptime kind: corpus.Kind) fn (*Context, u64) WorkloadError!void {
        return struct {
            fn run(c: *Context, units: u64) WorkloadError!void {
                for (0..units) |_| {
                    const input = c.text(kind);
                    var it: xenoglyph.grapheme.Iterator(.{}) = .initAt(input, .fromRaw(input.len));
                    while (it.prevSpan()) |_| c.count += 1;
                    std.mem.doNotOptimizeAway(c.count);
                }
            }
        }.run;
    }

    fn words(comptime kind: corpus.Kind) fn (*Context, u64) WorkloadError!void {
        return struct {
            fn run(c: *Context, units: u64) WorkloadError!void {
                for (0..units) |_| {
                    var it = xenoglyph.words(c.text(kind));
                    while (it.nextSpan()) |_| c.count += 1;
                    std.mem.doNotOptimizeAway(c.count);
                }
            }
        }.run;
    }

    fn lines(comptime kind: corpus.Kind) fn (*Context, u64) WorkloadError!void {
        return struct {
            fn run(c: *Context, units: u64) WorkloadError!void {
                for (0..units) |_| {
                    var it = xenoglyph.lines(c.text(kind));
                    while (it.nextBreak()) |b| c.count += 1 + @as(usize, @intFromBool(b.mandatory));
                    std.mem.doNotOptimizeAway(c.count);
                }
            }
        }.run;
    }

    fn sentences(comptime kind: corpus.Kind) fn (*Context, u64) WorkloadError!void {
        return struct {
            fn run(c: *Context, units: u64) WorkloadError!void {
                for (0..units) |_| {
                    var it = xenoglyph.sentences(c.text(kind));
                    while (it.nextSpan()) |_| c.count += 1;
                    std.mem.doNotOptimizeAway(c.count);
                }
            }
        }.run;
    }
};

const Row = shakedown.bench.Row(Context, WorkloadError);

const rows = [_]Row{
    .{ .name = "graphemes ascii", .unit = "64KiB", .run = Context.graphemes(.ascii) },
    .{ .name = "graphemes latin", .unit = "64KiB", .run = Context.graphemes(.latin) },
    .{ .name = "graphemes cjk", .unit = "64KiB", .run = Context.graphemes(.cjk) },
    .{ .name = "graphemes devanagari", .unit = "64KiB", .run = Context.graphemes(.devanagari) },
    .{ .name = "graphemes emoji", .unit = "64KiB", .run = Context.graphemes(.emoji) },
    .{ .name = "graphemes mixed", .unit = "64KiB", .run = Context.graphemes(.mixed) },
    .{ .name = "graphemes backward ascii", .unit = "64KiB", .run = Context.graphemesBackward(.ascii) },
    .{ .name = "graphemes backward latin", .unit = "64KiB", .run = Context.graphemesBackward(.latin) },
    .{ .name = "graphemes backward devanagari", .unit = "64KiB", .run = Context.graphemesBackward(.devanagari) },
    .{ .name = "graphemes backward emoji", .unit = "64KiB", .run = Context.graphemesBackward(.emoji) },
    .{ .name = "graphemes backward mixed", .unit = "64KiB", .run = Context.graphemesBackward(.mixed) },
    .{ .name = "words ascii", .unit = "64KiB", .run = Context.words(.ascii) },
    .{ .name = "words mixed", .unit = "64KiB", .run = Context.words(.mixed) },
    .{ .name = "sentences ascii", .unit = "64KiB", .run = Context.sentences(.ascii) },
    .{ .name = "sentences mixed", .unit = "64KiB", .run = Context.sentences(.mixed) },
    .{ .name = "lines ascii", .unit = "64KiB", .run = Context.lines(.ascii) },
    .{ .name = "lines cjk", .unit = "64KiB", .run = Context.lines(.cjk) },
    .{ .name = "lines mixed", .unit = "64KiB", .run = Context.lines(.mixed) },
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var c: Context = .{ .texts = undefined };
    for (&c.texts, 0..) |*t, i| t.* = try corpus.build(init.arena.allocator(), @fromBackingInt(@intCast(i)));
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try shakedown.bench.run(WorkloadError, init.gpa, init.io, &writer.interface, &c, &rows, .{ .commit = provenance.commit, .cpu = provenance.cpu, .os = provenance.os }, try .fromArguments(args[1..]));
    try writer.interface.flush();
}
