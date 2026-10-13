//! Segmentation throughput: `bay bench`, or `zig-out/bench/segment [--smoke]
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
    .{ .name = "words ascii", .unit = "64KiB", .run = Context.words(.ascii) },
    .{ .name = "words mixed", .unit = "64KiB", .run = Context.words(.mixed) },
    .{ .name = "sentences ascii", .unit = "64KiB", .run = Context.sentences(.ascii) },
    .{ .name = "sentences mixed", .unit = "64KiB", .run = Context.sentences(.mixed) },
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
