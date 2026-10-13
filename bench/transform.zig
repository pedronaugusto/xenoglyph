//! Normalization and case mapping throughput: `bay bench`, or
//! `zig-out/bench/transform [--smoke] [--row PREFIX]` by hand. A unit is one
//! pass over a 64 KiB text, written to a writer that discards it, so MB/s is
//! 65.5 / (ms a unit). CI compiles this and times nothing.
const std = @import("std");
const xenoglyph = @import("xenoglyph");
const shakedown = @import("shakedown");
const provenance = @import("preflight_bench_options");
const corpus = @import("corpus.zig");

const WorkloadError = std.Io.Writer.Error;

const Context = struct {
    texts: [@typeInfo(corpus.Kind).@"enum".field_names.len][]const u8,
    /// The accented Latin text decomposed, so that NFC has work to do.
    decomposed: []const u8 = "",
    sink: std.Io.Writer.Discarding,

    fn text(c: *const Context, kind: corpus.Kind) []const u8 {
        return c.texts[@backingInt(kind)];
    }

    fn normal(comptime form: xenoglyph.normalize.Form, comptime kind: ?corpus.Kind) fn (*Context, u64) WorkloadError!void {
        return struct {
            fn run(c: *Context, units: u64) WorkloadError!void {
                const input = if (kind) |k| c.text(k) else c.decomposed;
                for (0..units) |_| try xenoglyph.normalize.write(form, input, &c.sink.writer);
            }
        }.run;
    }

    fn mapped(comptime mapping: xenoglyph.case.Mapping, comptime kind: corpus.Kind) fn (*Context, u64) WorkloadError!void {
        return struct {
            fn run(c: *Context, units: u64) WorkloadError!void {
                for (0..units) |_| try xenoglyph.case.write(mapping, c.text(kind), &c.sink.writer, .{});
            }
        }.run;
    }
};

const Row = shakedown.bench.Row(Context, WorkloadError);

const rows = [_]Row{
    .{ .name = "nfc of mixed", .unit = "64KiB", .run = Context.normal(.nfc, .mixed) },
    .{ .name = "nfc of decomposed latin", .unit = "64KiB", .run = Context.normal(.nfc, null) },
    .{ .name = "nfd of latin", .unit = "64KiB", .run = Context.normal(.nfd, .latin) },
    .{ .name = "nfkc of mixed", .unit = "64KiB", .run = Context.normal(.nfkc, .mixed) },
    .{ .name = "nfd of cjk", .unit = "64KiB", .run = Context.normal(.nfd, .cjk) },
    .{ .name = "lower ascii", .unit = "64KiB", .run = Context.mapped(.lower, .ascii) },
    .{ .name = "upper latin", .unit = "64KiB", .run = Context.mapped(.upper, .latin) },
    .{ .name = "fold mixed", .unit = "64KiB", .run = Context.mapped(.fold, .mixed) },
    .{ .name = "title mixed", .unit = "64KiB", .run = Context.mapped(.title, .mixed) },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var discard: [256]u8 = undefined;
    var c: Context = .{ .texts = undefined, .sink = .init(&discard) };
    for (&c.texts, 0..) |*t, i| t.* = try corpus.build(arena, @fromBackingInt(@intCast(i)));
    var decomposed: std.Io.Writer.Allocating = .init(arena);
    try xenoglyph.normalize.write(.nfd, c.text(.latin), &decomposed.writer);
    c.decomposed = decomposed.written();
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try shakedown.bench.run(WorkloadError, init.gpa, init.io, &writer.interface, &c, &rows, .{ .commit = provenance.commit, .cpu = provenance.cpu, .os = provenance.os }, try .fromArguments(args[1..]));
    try writer.interface.flush();
}
