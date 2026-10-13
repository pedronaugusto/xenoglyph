//! Width throughput: `bay bench`, or `zig-out/bench/width [--smoke]
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
    columns: usize = 0,

    fn string(comptime kind: corpus.Kind, comptime options: xenoglyph.width.Options) fn (*Context, u64) WorkloadError!void {
        return struct {
            fn run(c: *Context, units: u64) WorkloadError!void {
                for (0..units) |_| {
                    c.columns +%= xenoglyph.width.string(c.texts[@backingInt(kind)], options);
                    std.mem.doNotOptimizeAway(c.columns);
                }
            }
        }.run;
    }

    /// Splits the text into clusters and measures each, as a renderer that
    /// places them one by one does.
    fn clusters(comptime kind: corpus.Kind) fn (*Context, u64) WorkloadError!void {
        return struct {
            fn run(c: *Context, units: u64) WorkloadError!void {
                for (0..units) |_| {
                    var it: xenoglyph.grapheme.Iterator(.{ .modifiers = .after_base }) = .init(c.texts[@backingInt(kind)]);
                    while (it.next()) |g| c.columns +%= xenoglyph.width.cluster(g, .{});
                    std.mem.doNotOptimizeAway(c.columns);
                }
            }
        }.run;
    }
};

const Row = shakedown.bench.Row(Context, WorkloadError);

const rows = [_]Row{
    .{ .name = "string ascii", .unit = "64KiB", .run = Context.string(.ascii, .{}) },
    .{ .name = "string latin", .unit = "64KiB", .run = Context.string(.latin, .{}) },
    .{ .name = "string cjk", .unit = "64KiB", .run = Context.string(.cjk, .{}) },
    .{ .name = "string emoji", .unit = "64KiB", .run = Context.string(.emoji, .{}) },
    .{ .name = "string mixed", .unit = "64KiB", .run = Context.string(.mixed, .{}) },
    .{ .name = "string mixed by code point", .unit = "64KiB", .run = Context.string(.mixed, .{ .method = .codepoint }) },
    .{ .name = "clusters mixed", .unit = "64KiB", .run = Context.clusters(.mixed) },
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
