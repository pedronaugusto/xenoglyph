//! Encodings against the WHATWG Encoding Standard's data and encoding_rs:
//! encoding_rs's vectors (generated from the standard's indexes) byte for
//! byte both ways, every label of encodings.json, the single-byte tables
//! and CP437, BOM sniffing and error modes, and streaming in pieces of any
//! size giving what one piece gives; and against encoding_rs over every input
//! of one and two bytes (and the longer ones each decoder reads) and every
//! scalar, by the digests bench/rivals/encoding_rs writes.
const std = @import("std");
const ucd = @import("ucd");
const shake = @import("shakedown");
const encoding = @import("../encoding.zig");
const Encoding = encoding.Encoding;

fn decodeAll(gpa: std.mem.Allocator, e: Encoding, bytes: []const u8, options: encoding.DecodeOptions) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    _ = try encoding.decode(e, bytes, &out.writer, options);
    return out.toOwnedSlice();
}

fn encodeAll(gpa: std.mem.Allocator, e: Encoding, text: []const u8, options: encoding.EncodeOptions) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try encoding.encode(e, text, &out.writer, options);
    return out.toOwnedSlice();
}

fn expectSame(want: []const u8, got: []const u8, what: []const u8) !void {
    if (std.mem.eql(u8, want, got)) return;
    const at = std.mem.findDiff(u8, want, got) orelse @min(want.len, got.len);
    std.debug.print("{s}: differ at byte {d} (want {d} bytes, got {d}): want {any} got {any}\n", .{ what, at, want.len, got.len, want[at..@min(at + 12, want.len)], got[at..@min(at + 12, got.len)] });
    return error.TestUnexpectedResult;
}

test "encoding_rs's vectors, byte for byte, both ways" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { Encoding, []const u8, []const u8, ?[]const u8, ?[]const u8, []const u8 }{
        .{ .big5, ucd.encoding_rs_big5_in, ucd.encoding_rs_big5_in_ref, ucd.encoding_rs_big5_out, ucd.encoding_rs_big5_out_ref, "big5" },
        .{ .euc_kr, ucd.encoding_rs_euc_kr_in, ucd.encoding_rs_euc_kr_in_ref, ucd.encoding_rs_euc_kr_out, ucd.encoding_rs_euc_kr_out_ref, "euc_kr" },
        .{ .gb18030, ucd.encoding_rs_gb18030_in, ucd.encoding_rs_gb18030_in_ref, ucd.encoding_rs_gb18030_out, ucd.encoding_rs_gb18030_out_ref, "gb18030" },
        .{ .iso_2022_jp, ucd.encoding_rs_iso_2022_jp_in, ucd.encoding_rs_iso_2022_jp_in_ref, ucd.encoding_rs_iso_2022_jp_out, ucd.encoding_rs_iso_2022_jp_out_ref, "iso_2022_jp" },
        .{ .euc_jp, ucd.encoding_rs_jis0208_in, ucd.encoding_rs_jis0208_in_ref, ucd.encoding_rs_jis0208_out, ucd.encoding_rs_jis0208_out_ref, "jis0208" },
        .{ .euc_jp, ucd.encoding_rs_jis0212_in, ucd.encoding_rs_jis0212_in_ref, null, null, "jis0212" },
        .{ .shift_jis, ucd.encoding_rs_shift_jis_in, ucd.encoding_rs_shift_jis_in_ref, ucd.encoding_rs_shift_jis_out, ucd.encoding_rs_shift_jis_out_ref, "shift_jis" },
    };
    for (cases) |c| {
        const decoded = try decodeAll(gpa, c[0], c[1], .{ .bom = .none });
        defer gpa.free(decoded);
        try expectSame(c[2], decoded, c[5]);
        if (c[3]) |text| {
            const encoded = try encodeAll(gpa, c[0], text, .{ .mode = .fatal });
            defer gpa.free(encoded);
            try expectSame(c[4].?, encoded, c[5]);
        }
    }
}

test "every label of encodings.json names its encoding, whatever its case and surrounding whitespace" {
    const Json = []const struct { encodings: []const struct { labels: []const []const u8, name: []const u8 }, heading: []const u8 };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(Json, arena.allocator(), ucd.whatwg_encodings, .{});
    var k: usize = 0;
    var count: usize = 0;
    for (parsed) |heading| for (heading.encodings) |e| {
        const want: Encoding = @fromBackingInt(@intCast(k));
        try std.testing.expectEqualStrings(e.name, encoding.name(want));
        for (e.labels) |label| {
            try std.testing.expectEqual(want, encoding.forLabel(label).?);
            var upper: [64]u8 = undefined;
            const shouted = try std.mem.print(&upper, "\t {s}\x0c\n", .{label});
            for (shouted) |*c| c.* = std.ascii.toUpper(c.*);
            try std.testing.expectEqual(want, encoding.forLabel(shouted).?);
            count += 1;
        }
        k += 1;
    };
    try std.testing.expect(count > 200);
    try std.testing.expectEqual(@as(?Encoding, null), encoding.forLabel("utf8 " ++ "x"));
    try std.testing.expectEqual(@as(?Encoding, null), encoding.forLabel("\u{a0}utf-8"));
}

test "CP437 decodes and encodes every byte, as zip names hold them" {
    const gpa = std.testing.allocator;
    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, i| b.* = @intCast(i);
    const text = try decodeAll(gpa, .cp437, &all, .{ .mode = .fatal, .bom = .none });
    defer gpa.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text[0x80..], "\u{c7}\u{fc}\u{e9}"));
    try std.testing.expect(std.mem.endsWith(u8, text, "\u{25a0}\u{a0}"));
    const back = try encodeAll(gpa, .cp437, text, .{ .mode = .fatal });
    defer gpa.free(back);
    try std.testing.expectEqualSlices(u8, &all, back);
}

test "BOM sniffing, error modes and the replacement encoding" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.testing.expectEqual(Encoding.utf_16le, try encoding.decode(.windows_1252, "\xff\xfeA\x00", &out.writer, .{}));
    try std.testing.expectEqualStrings("A", out.written());
    out.clearRetainingCapacity();
    try std.testing.expectEqual(Encoding.utf_8, try encoding.decode(.windows_1252, "\xef\xbb\xbf\xc3\xa9", &out.writer, .{ .bom = .utf_8 }));
    try std.testing.expectEqualStrings("\u{e9}", out.written());
    out.clearRetainingCapacity();
    // Without BOM handling a BOM is text.
    _ = try encoding.decode(.utf_8, "\xef\xbb\xbfx", &out.writer, .{ .bom = .none });
    try std.testing.expectEqualStrings("\u{feff}x", out.written());
    out.clearRetainingCapacity();
    var d: encoding.Decoder = .init(.shift_jis, .{ .mode = .fatal });
    try std.testing.expectError(error.Malformed, d.decode("ab\x81\x20", true, &out.writer));
    try std.testing.expectEqualStrings("ab", out.written());
    try std.testing.expectEqual(@as(u64, 4), d.consumed);
    out.clearRetainingCapacity();
    _ = try encoding.decode(.replacement, "anything", &out.writer, .{});
    try std.testing.expectEqualStrings("\u{fffd}", out.written());
    out.clearRetainingCapacity();
    try encoding.encode(.windows_1252, "\u{3042}!", &out.writer, .{});
    try std.testing.expectEqualStrings("&#12354;!", out.written());
    out.clearRetainingCapacity();
    var e: encoding.Encoder = .init(.iso_8859_2, .{ .mode = .fatal });
    try std.testing.expectError(error.Unmappable, e.encode("ok\u{3042}", true, &out.writer));
    try std.testing.expectEqual(@as(u21, 0x3042), e.unmappable);
    try std.testing.expectEqualStrings("ok", out.written());
    out.clearRetainingCapacity();
    // ISO-2022-JP writes its references in ASCII, switching back to it.
    try encoding.encode(.iso_2022_jp, "\u{65e5}\u{1f600}", &out.writer, .{});
    try std.testing.expectEqualStrings("\x1b$BF|\x1b(B&#128512;", out.written());
}

const every = std.enums.values(Encoding);

fn pieces(_: void, c: *shake.Case) !void {
    const e = shake.gen.oneOf(c.source, Encoding, every);
    // Bytes the decoders treat specially, and arbitrary ones.
    const parts = [_][]const u8{ "a", "\x1b$B", "\x1b(J", "\x1b(I", "\x1b(B", "F|", "\x81", "\x30", "\x81\x30\x81\x30", "\xa1\xa1", "\x8e\xa1", "\x8f\xa1\xa1", "\xfe\xff", "\xff\xfe", "\xef\xbb\xbf", "\xd8\x3d\xde\x00", "\xc3\xa9", "\xe3\x81\x82", "\xf0\x9f\x98\x80", "\xe0\x80", "\x80", "\xff", "\x00", "\x5c", "\x7e" };
    var input: std.ArrayList(u8) = .empty;
    for (0..shake.gen.intRange(c.source, usize, 0, 24)) |_| try input.appendSlice(c.gpa, shake.gen.oneOf(c.source, []const u8, &parts));
    for (0..shake.gen.intRange(c.source, usize, 0, 4)) |_| try input.append(c.gpa, shake.gen.int(c.source, u8));
    const bytes = input.items;
    const bom = shake.gen.oneOf(c.source, @FieldType(encoding.DecodeOptions, "bom"), &.{ .sniff, .utf_8, .none });
    const whole = try decodeAll(c.gpa, e, bytes, .{ .bom = bom });
    // The same input in random pieces decodes the same.
    var d: encoding.Decoder = .init(e, .{ .bom = bom });
    var out: std.Io.Writer.Allocating = .init(c.gpa);
    var at: usize = 0;
    while (at < bytes.len) {
        const n = shake.gen.intRange(c.source, usize, 0, bytes.len - at);
        try d.decode(bytes[at..][0..n], false, &out.writer);
        at += n;
    }
    try d.decode("", true, &out.writer);
    try std.testing.expectEqualSlices(u8, whole, out.written());
    // What it decodes to is UTF-8, and encodes, in pieces too, as in one.
    try std.testing.expect(std.unicode.utf8ValidateSlice(whole));
    const enc = encoding.outputEncoding(d.encoding);
    const encoded = try encodeAll(c.gpa, enc, whole, .{});
    var en: encoding.Encoder = .init(enc, .{});
    var out2: std.Io.Writer.Allocating = .init(c.gpa);
    at = 0;
    while (at < whole.len) {
        const n = shake.gen.intRange(c.source, usize, 0, whole.len - at);
        try en.encode(whole[at..][0..n], false, &out2.writer);
        at += n;
    }
    try en.encode("", true, &out2.writer);
    try std.testing.expectEqualSlices(u8, encoded, out2.written());
    // Text with no reference in it decodes back from what it encoded to,
    // where the encoder needed none (html mode leaves `&#` in the text).
    if (std.mem.find(u8, encoded, "&#") == null and std.mem.find(u8, whole, "\u{fffd}") == null) {
        const back = try decodeAll(c.gpa, enc, encoded, .{ .bom = .none });
        try std.testing.expectEqualSlices(u8, whole, back);
    }
}

test "any input, in pieces of any size, decodes and encodes as in one piece" {
    try shake.check(std.testing.allocator, {}, pieces, .{ .cases = 5000 });
}

/// Calls `f.input(bytes)` with each decoding input for `e`, the set
/// bench/rivals/encoding_rs builds: every input of one and two bytes, and
/// the longer ones each kind of decoder reads.
fn inputs(e: Encoding, f: anytype) !void {
    for (0..256) |a| try f.input(&.{@intCast(a)});
    switch (e) {
        .utf_8, .gbk, .gb18030, .big5, .euc_jp, .iso_2022_jp, .shift_jis, .euc_kr, .utf_16be, .utf_16le => {},
        else => return,
    }
    for (0..256) |a| for (0..256) |b| try f.input(&.{ @intCast(a), @intCast(b) });
    switch (e) {
        .utf_8 => {
            for (0xe0..0xf0) |a| for (0..256) |b| for (0..256) |c| try f.input(&.{ @intCast(a), @intCast(b), @intCast(c) });
            for (0xf0..0xf5) |a| for (0..256) |b| for (0..256) |c| for ([_]u8{ 0x41, 0x80, 0x8f, 0x90, 0xbf, 0xc0 }) |d|
                try f.input(&.{ @intCast(a), @intCast(b), @intCast(c), d });
        },
        .gbk, .gb18030 => for (0x81..0xff) |a| for (0x30..0x3a) |b| {
            for (0x81..0xff) |c| for (0x30..0x3a) |d| try f.input(&.{ @intCast(a), @intCast(b), @intCast(c), @intCast(d) });
            for (0..256) |c| try f.input(&.{ @intCast(a), @intCast(b), @intCast(c) });
        },
        .euc_jp => for (0..256) |b| for (0..256) |c| try f.input(&.{ 0x8f, @intCast(b), @intCast(c) }),
        .iso_2022_jp => {
            const escapes = [_][]const u8{ "\x1b(B", "\x1b(J", "\x1b(I", "\x1b$@", "\x1b$B", "\x1b$(" };
            var v: [8]u8 = undefined;
            for (escapes) |esc| {
                @memcpy(v[0..3], esc);
                for (0..256) |b| {
                    v[3] = @intCast(b);
                    try f.input(v[0..4]);
                    for (0..256) |c| {
                        v[4] = @intCast(c);
                        try f.input(v[0..5]);
                    }
                }
                // Two escapes in a row, and one at the end.
                for (escapes) |second| {
                    @memcpy(v[3..6], second);
                    try f.input(v[0..6]);
                    v[6] = 'a';
                    try f.input(v[0..7]);
                }
            }
            for (0..256) |b| for (0..256) |c| try f.input(&.{ 0x1b, @intCast(b), @intCast(c) });
        },
        .utf_16be, .utf_16le => for ([_]u16{ 0xd800, 0xdab5, 0xdbff, 0xdc00 }) |lead| {
            const endian: std.builtin.Endian = if (e == .utf_16be) .big else .little;
            var v: [4]u8 = undefined;
            std.mem.writeInt(u16, v[0..2], lead, endian);
            for (0..0x10000) |unit| {
                std.mem.writeInt(u16, v[2..4], @intCast(unit), endian);
                try f.input(&v);
            }
            for (0..256) |b| {
                v[2] = @intCast(b);
                try f.input(v[0..3]);
            }
        },
        else => {},
    }
}

const Decoded = struct {
    e: Encoding,
    hash: std.crypto.hash.sha2.Sha256 = .init(.{}),
    buffer: [64]u8 = undefined,

    fn input(d: *Decoded, bytes: []const u8) !void {
        var w: std.Io.Writer = .fixed(&d.buffer);
        _ = try encoding.decode(d.e, bytes, &w, .{ .bom = .none });
        d.hash.update(w.buffered());
        d.hash.update("\xff");
    }
};

test "every encoding decodes and encodes as encoding_rs does, over every input of one and two bytes and every scalar" {
    const gpa = std.testing.allocator;
    // Every scalar value, in order, as UTF-8.
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(gpa);
    for (0..0x110000) |cp| {
        if (cp >= 0xd800 and cp <= 0xdfff) continue;
        var b: [4]u8 = undefined;
        try all.appendSlice(gpa, b[0..try std.unicode.utf8Encode(@intCast(cp), &b)]);
    }
    var encoded: std.Io.Writer.Allocating = .init(gpa);
    defer encoded.deinit();
    var lines = std.mem.tokenizeScalar(u8, ucd.encoding_rs_digests, '\n');
    var checked: usize = 0;
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const e = encoding.forLabel(fields.next().?).?;
        var d: Decoded = .{ .e = e };
        try inputs(e, &d);
        const decode_hex = std.fmt.bytesToHex(d.hash.finalResult(), .lower);
        try std.testing.expectEqualStrings(fields.next().?, &decode_hex);
        const want_encoded = fields.next().?;
        if (encoding.outputEncoding(e) == e) {
            encoded.clearRetainingCapacity();
            try encoding.encode(e, all.items, &encoded.writer, .{});
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(encoded.written(), &digest, .{});
            try std.testing.expectEqualStrings(want_encoded, &std.fmt.bytesToHex(digest, .lower));
        } else try std.testing.expectEqualStrings("-", want_encoded);
        checked += 1;
    }
    try std.testing.expectEqual(@as(usize, 40), checked);
}
