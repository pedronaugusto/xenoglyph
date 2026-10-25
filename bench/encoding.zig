//! Encoding throughput: `bay bench`, or `zig-out/bench/encoding [--smoke]
//! [--row PREFIX]` by hand. A unit is one text of 16 KiB or a little more of
//! UTF-8 (a sentence of bench/texts repeated) in the language each encoding
//! is for: decoding the text's bytes in that encoding to UTF-8, or encoding
//! the UTF-8 to it, each whole, as one call. bench/rivals/encoding_rs runs
//! the same rows through encoding_rs. CI compiles this and times nothing.
const std = @import("std");
const xenoglyph = @import("xenoglyph");
const shakedown = @import("shakedown");
const provenance = @import("preflight_bench_options");

const encoding = xenoglyph.encoding;
const Encoding = encoding.Encoding;
const WorkloadError = std.Io.Writer.Error || encoding.DecodeError || encoding.EncodeError;

const size = 16 * 1024;

/// Each text, from bench/texts, and the encodings its rows use; the rival
/// reads the same files and lists the same rows.
const texts = [_]struct { name: []const u8, sentence: []const u8, encodings: []const Encoding }{
    .{ .name = "latin", .sentence = @embedFile("texts/latin.txt"), .encodings = &.{ .windows_1252, .iso_8859_15 } },
    .{ .name = "central", .sentence = @embedFile("texts/central.txt"), .encodings = &.{ .windows_1250, .iso_8859_2 } },
    .{ .name = "cyrillic", .sentence = @embedFile("texts/cyrillic.txt"), .encodings = &.{ .windows_1251, .koi8_r, .ibm866 } },
    .{ .name = "japanese", .sentence = @embedFile("texts/japanese.txt"), .encodings = &.{ .shift_jis, .euc_jp, .iso_2022_jp, .utf_16le, .utf_8 } },
    .{ .name = "simplified", .sentence = @embedFile("texts/simplified.txt"), .encodings = &.{ .gb18030, .gbk } },
    .{ .name = "traditional", .sentence = @embedFile("texts/traditional.txt"), .encodings = &.{.big5} },
    .{ .name = "korean", .sentence = @embedFile("texts/korean.txt"), .encodings = &.{.euc_kr} },
};

const count = blk: {
    var n: usize = 0;
    for (texts) |t| n += t.encodings.len;
    break :blk n;
};

/// Each row's encoding and text, in `rows` order.
const cases = blk: {
    var out: [count]struct { usize, Encoding } = undefined;
    var n: usize = 0;
    for (texts, 0..) |t, k| for (t.encodings) |e| {
        out[n] = .{ k, e };
        n += 1;
    };
    break :blk out;
};

const Context = struct {
    /// Each text as UTF-8, and each case's text in its encoding.
    text: [texts.len][]const u8,
    bytes: [count][]const u8,
    out: []u8,
    total: usize = 0,

    fn decode(comptime n: usize) fn (*Context, u64) WorkloadError!void {
        return struct {
            fn run(c: *Context, units: u64) WorkloadError!void {
                for (0..units) |_| {
                    var w: std.Io.Writer = .fixed(c.out);
                    _ = try encoding.decode(cases[n][1], c.bytes[n], &w, .{ .bom = .none });
                    c.total += w.end;
                    std.mem.doNotOptimizeAway(c.total);
                }
            }
        }.run;
    }

    fn encode(comptime n: usize) fn (*Context, u64) WorkloadError!void {
        return struct {
            fn run(c: *Context, units: u64) WorkloadError!void {
                for (0..units) |_| {
                    var w: std.Io.Writer = .fixed(c.out);
                    try encoding.encode(cases[n][1], c.text[cases[n][0]], &w, .{});
                    c.total += w.end;
                    std.mem.doNotOptimizeAway(c.total);
                }
            }
        }.run;
    }
};

const Row = shakedown.bench.Row(Context, WorkloadError);

const rows = blk: {
    var out: [2 * count]Row = undefined;
    var n: usize = 0;
    for (cases, 0..) |c, k| {
        const label = texts[c[0]].name ++ " " ++ encoding.name(c[1]);
        out[n] = .{ .name = "decode " ++ label, .unit = "16KiB", .run = Context.decode(k) };
        n += 1;
        // UTF-16 has no encoder: its output encoding is UTF-8.
        if (encoding.outputEncoding(c[1]) == c[1]) {
            out[n] = .{ .name = "encode " ++ label, .unit = "16KiB", .run = Context.encode(k) };
            n += 1;
        }
    }
    break :blk out[0..n].*;
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var c: Context = .{ .text = undefined, .bytes = undefined, .out = try arena.alloc(u8, 4 * size) };
    for (texts, 0..) |t, k| {
        var text: std.ArrayList(u8) = .empty;
        while (text.items.len < size) try text.appendSlice(arena, t.sentence);
        c.text[k] = text.items;
    }
    for (cases, 0..) |case, n| {
        var w: std.Io.Writer.Allocating = .init(arena);
        if (case[1] == .utf_16le) {
            // No encoder writes UTF-16; the bytes are the text's code units.
            var it = std.unicode.Utf8View.initUnchecked(c.text[case[0]]).iterator();
            while (it.nextCodepoint()) |cp| {
                var units: [2]u16 = undefined;
                const len = try std.unicode.utf16CodepointSequenceLength(cp);
                if (len == 1) units[0] = @intCast(cp) else {
                    units[0] = @intCast(0xd800 + ((cp - 0x10000) >> 10));
                    units[1] = @intCast(0xdc00 + ((cp - 0x10000) & 0x3ff));
                }
                for (units[0..len]) |u| try w.writer.writeInt(u16, u, .little);
            }
        } else {
            // Every text is wholly in each of its encodings.
            try encoding.encode(case[1], c.text[case[0]], &w.writer, .{ .mode = .fatal });
        }
        c.bytes[n] = w.written();
    }
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try shakedown.bench.run(WorkloadError, init.gpa, init.io, &writer.interface, &c, &rows, .{ .commit = provenance.commit, .cpu = provenance.cpu, .os = provenance.os }, try .fromArguments(args[1..]));
    try writer.interface.flush();
}
