//! Character encodings, both ways, streaming: the WHATWG Encoding Standard's
//! decoders and encoders, as its algorithms state them, with its labels,
//! BOM sniffing and error modes, and IBM code page 437 for zip names. A
//! decoder writes UTF-8 and an encoder reads it; either takes its input in
//! pieces of any size, holding the standard's state between them, and
//! nothing is allocated.
const std = @import("std");
const aegis = @import("aegis");
const classes = @import("classes.zig");
const data = @import("data.zig");
const utf8 = @import("utf8.zig");

const Writer = std.Io.Writer;
const tables = data.encoding;

pub const Encoding = classes.Encoding;

/// The encoding a label names (the standard's "get an encoding"): ASCII
/// whitespace around it ignored, ASCII case ignored. CP437 has no label in
/// the standard and is named by its value alone.
pub fn forLabel(label: []const u8) ?Encoding {
    const trimmed = std.mem.trim(u8, label, "\t\n\x0c\r ");
    var lower: [32]u8 = undefined;
    if (trimmed.len > lower.len) return null;
    for (trimmed, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    const key = lower[0..trimmed.len];
    var low: usize = 0;
    var high: usize = tables.labels.len;
    while (low < high) {
        const mid = (low + high) / 2;
        switch (std.mem.order(u8, tables.labels[mid][0], key)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return @fromBackingInt(@intCast(tables.labels[mid][1])),
        }
    }
    return null;
}

/// The encoding's name in the standard (`"windows-1252"`, `"Shift_JIS"`);
/// `"IBM437"` for CP437.
pub fn name(e: Encoding) []const u8 {
    return tables.names[@backingInt(e)];
}

/// The standard's "get an output encoding": UTF-8 for replacement and the
/// UTF-16 encodings, which a form or URL is never encoded in.
pub fn outputEncoding(e: Encoding) Encoding {
    return switch (e) {
        .replacement, .utf_16be, .utf_16le => .utf_8,
        else => e,
    };
}

/// Whether ASCII bytes are themselves in the encoding, both ways.
pub fn asciiCompatible(e: Encoding) bool {
    return switch (e) {
        .replacement, .utf_16be, .utf_16le, .iso_2022_jp => false,
        else => true,
    };
}

pub const DecodeOptions = struct {
    /// `.replacement` writes U+FFFD for each error, as the standard's
    /// default; `.fatal` stops at the first.
    mode: enum { replacement, fatal } = .replacement,
    /// `.sniff` is the standard's "decode": a BOM chooses UTF-8, UTF-16BE or
    /// UTF-16LE whatever the encoding given, and is dropped. `.utf_8` is "UTF-8
    /// decode": the encoding is UTF-8 and a UTF-8 BOM is dropped. `.none` is
    /// "decode without BOM".
    bom: enum { sniff, utf_8, none } = .sniff,
};

pub const EncodeOptions = struct {
    /// `.html` writes a code point the encoding lacks as `&#N;`, as the
    /// standard's html mode; `.fatal` stops at it.
    mode: enum { html, fatal } = .html,
};

pub const DecodeError = Writer.Error || error{
    /// Malformed input in `.fatal` mode: `Decoder.consumed` says how far.
    Malformed,
};

pub const EncodeError = Writer.Error || error{
    /// A code point the encoding lacks, in `.fatal` mode: `Encoder.unmappable`.
    Unmappable,
};

/// Decodes all of `bytes` to UTF-8 into `w`; returns the encoding used,
/// which a BOM may have chosen.
pub fn decode(encoding: Encoding, bytes: []const u8, w: *Writer, options: DecodeOptions) DecodeError!Encoding {
    var d: Decoder = .init(encoding, options);
    try d.decode(bytes, true, w);
    return d.encoding;
}

/// Encodes all of the UTF-8 `text` into `w`.
pub fn encode(encoding: Encoding, text: []const u8, w: *Writer, options: EncodeOptions) EncodeError!void {
    var e: Encoder = .init(encoding, options);
    try e.encode(text, true, w);
}

// ---------------------------------------------------------------------------
// Output

/// UTF-8 or bytes written straight into the writer's buffer, or through a
/// small one of its own where the writer has too little, so a code point is
/// not a call on the writer. What it wrote is the writer's at `flush`.
const Out = struct {
    w: *Writer,
    own: [256]u8 = undefined,
    /// Where the next bytes go: the writer's unused buffer, or `own`.
    dest: []u8 = &.{},
    len: usize = 0,
    /// Chosen once: a writer's buffer can grow as it is written to.
    direct: bool,

    /// A writer with a buffer this large is written into directly.
    const direct_min = 64;

    /// `dest` starts empty: the first `room` points it, once `own` is where
    /// it stays.
    fn init(w: *Writer) Out {
        return .{ .w = w, .direct = w.buffer.len >= direct_min };
    }

    inline fn room(o: *Out, n: usize) Writer.Error!void {
        if (o.len + n > o.dest.len) try o.refill(n);
    }

    /// Hands what was written to the writer and makes room for `n` more.
    fn refill(o: *Out, n: usize) Writer.Error!void {
        try o.flush();
        if (o.direct) o.dest = try o.w.writableSliceGreedy(@max(n, direct_min)) else o.dest = &o.own;
    }

    fn flush(o: *Out) Writer.Error!void {
        if (o.direct) {
            o.w.advance(o.len);
            o.dest = o.dest[o.len..];
        } else try o.w.writeAll(o.own[0..o.len]);
        o.len = 0;
    }

    fn bytes(o: *Out, run: []const u8) Writer.Error!void {
        if (run.len > o.dest.len - o.len) {
            if (run.len > 4 * o.own.len or !o.direct) {
                try o.flush();
                try o.w.writeAll(run);
                if (o.direct) o.dest = o.w.buffer[o.w.end..] else o.dest = &o.own;
                return;
            }
            try o.refill(run.len);
        }
        @memcpy(o.dest[o.len..][0..run.len], run);
        o.len += run.len;
    }

    inline fn codePoint(o: *Out, cp: u21) Writer.Error!void {
        try o.room(4);
        o.put(cp);
    }

    /// A code point as UTF-8, where `room(4)` made the room.
    inline fn put(o: *Out, cp: u21) void {
        if (cp < 0x80) {
            o.dest[o.len] = @intCast(cp);
            o.len += 1;
        } else if (cp < 0x800) {
            o.dest[o.len..][0..2].* = .{ @intCast(0xc0 | cp >> 6), @intCast(0x80 | (cp & 0x3f)) };
            o.len += 2;
        } else if (cp < 0x10000) {
            o.dest[o.len..][0..3].* = .{ @intCast(0xe0 | cp >> 12), @intCast(0x80 | ((cp >> 6) & 0x3f)), @intCast(0x80 | (cp & 0x3f)) };
            o.len += 3;
        } else {
            o.dest[o.len..][0..4].* = .{ @intCast(0xf0 | cp >> 18), @intCast(0x80 | ((cp >> 12) & 0x3f)), @intCast(0x80 | ((cp >> 6) & 0x3f)), @intCast(0x80 | (cp & 0x3f)) };
            o.len += 4;
        }
    }
};

/// Makes room for `n` bytes at `at.*` in `dest.*`, the copies of `out`'s
/// fields a loop holds.
inline fn reserve(out: *Out, dest: *[]u8, at: *usize, n: usize) Writer.Error!void {
    if (at.* + n <= dest.len) return;
    out.len = at.*;
    try out.refill(n);
    dest.* = out.dest;
    at.* = out.len;
}

/// `utf8.decode` with the two- and three-byte sequences most text is made
/// of read here, in the loop that asks.
inline fn readCodePoint(rest: []const u8) utf8.Decoded {
    const lead = rest[0];
    if (lead >= 0xc2 and lead <= 0xdf and rest.len >= 2 and rest[1] & 0xc0 == 0x80)
        return .{ .code_point = (@as(u21, lead & 0x1f) << 6) | (rest[1] & 0x3f), .len = 2 };
    if (lead >= 0xe1 and lead <= 0xef and lead != 0xed and rest.len >= 3 and rest[1] & 0xc0 == 0x80 and rest[2] & 0xc0 == 0x80)
        return .{ .code_point = (@as(u21, lead & 0x0f) << 12) | (@as(u21, rest[1] & 0x3f) << 6) | (rest[2] & 0x3f), .len = 3 };
    return utf8.decode(rest);
}

/// A code point's UTF-8 into four bytes of room; returns how many it took.
inline fn putUtf8(dest: *[4]u8, cp: u21) usize {
    if (cp < 0x80) {
        dest[0] = @intCast(cp);
        return 1;
    } else if (cp < 0x800) {
        dest[0..2].* = .{ @intCast(0xc0 | cp >> 6), @intCast(0x80 | (cp & 0x3f)) };
        return 2;
    } else if (cp < 0x10000) {
        dest[0..3].* = .{ @intCast(0xe0 | cp >> 12), @intCast(0x80 | ((cp >> 6) & 0x3f)), @intCast(0x80 | (cp & 0x3f)) };
        return 3;
    }
    dest.* = .{ @intCast(0xf0 | cp >> 18), @intCast(0x80 | ((cp >> 12) & 0x3f)), @intCast(0x80 | ((cp >> 6) & 0x3f)), @intCast(0x80 | (cp & 0x3f)) };
    return 4;
}

fn singleByte(comptime e: Encoding) bool {
    return @backingInt(e) >= @backingInt(Encoding.ibm866) and @backingInt(e) <= @backingInt(Encoding.x_mac_cyrillic) or e == .cp437;
}

/// Each single-byte encoding's bytes as UTF-8, packed: the bytes from the
/// lowest, the length in the top byte; 0 where a byte maps to nothing.
const single_byte_utf8 = blk: {
    @setEvalBranchQuota(200_000);
    var out: [tables.single_byte.len][256]u32 = undefined;
    for (tables.single_byte, 0..) |table, k| for (0..256) |b| {
        const cp: u21 = if (b < 0x80) b else table[b - 0x80];
        var bytes: [4]u8 = @splat(0);
        const n = if (cp == 0 and b != 0) 0 else putUtf8(&bytes, cp);
        out[k][b] = if (n == 0) 0 else (@as(u32, n) << 24) | (std.mem.readInt(u32, &bytes, .little) & 0xffffff);
    };
    break :blk out;
};

// ---------------------------------------------------------------------------
// Decoding

/// What one step of a decoder gives.
const Step = union(enum) {
    /// The byte was taken; nothing yet.
    more,
    one: u21,
    /// Big5's four pointers that decode to two code points.
    two: [2]u21,
    failed,
    /// At the end of the input: done.
    finished,
};

const Iso2022 = enum(u3) { ascii, roman, katakana, lead_byte, trail_byte, escape_start, escape };

/// A decoder of one encoding: `decode` takes input in pieces, the standard's
/// state held between them.
pub const Decoder = struct {
    /// The encoding decoded, once a BOM has chosen it.
    encoding: Encoding,
    options: DecodeOptions,
    /// Input bytes read; at an error in `.fatal` mode, those up to and
    /// including the byte the error was found at.
    consumed: u64 = 0,
    /// Bytes the decoder put back (the standard's "prepend"), read before the
    /// input, the next on top.
    queue: [8]u8 = undefined,
    queued: u8 = 0,
    /// A BOM's bytes while it is being sniffed.
    held: [3]u8 = undefined,
    held_len: u2 = 0,
    sniffed: bool = false,

    // The standard's state, by encoding.
    lead: u8 = 0,
    second: u8 = 0,
    third: u8 = 0,
    jis0212: bool = false,
    utf8_needed: u3 = 0,
    utf8_seen: u3 = 0,
    utf8_cp: u21 = 0,
    utf8_lower: u8 = 0x80,
    utf8_upper: u8 = 0xbf,
    iso_state: Iso2022 = .ascii,
    iso_output_state: Iso2022 = .ascii,
    iso_output: bool = false,
    utf16_lead_byte: ?u8 = null,
    utf16_lead_surrogate: ?u16 = null,
    replaced: bool = false,

    pub fn init(encoding: Encoding, options: DecodeOptions) Decoder {
        return .{ .encoding = if (options.bom == .utf_8) .utf_8 else encoding, .options = options, .sniffed = options.bom == .none };
    }

    /// Decodes `input`, the next piece of the stream, to UTF-8 into `w`;
    /// `last` when it is the stream's end. What a sequence split between
    /// pieces needs is held until the next.
    pub fn decode(d: *Decoder, input: []const u8, last: bool, w: *Writer) DecodeError!void {
        var out: Out = .init(w);
        var rest = input;
        if (!d.sniffed) {
            rest = d.sniff(rest, last);
            if (!d.sniffed) return;
        }
        switch (d.encoding) {
            // What came before a malformed sequence is written, then the error.
            inline else => |e| d.run(e, rest, last, &out) catch |err| {
                try out.flush();
                return err;
            },
        }
        try out.flush();
    }

    /// Holds the first bytes until they show whether a BOM starts the
    /// stream; returns the input left after them, the held bytes that are
    /// no BOM put back.
    fn sniff(d: *Decoder, input: []const u8, last: bool) []const u8 {
        const only_utf8 = d.options.bom == .utf_8;
        var i: usize = 0;
        while (true) {
            const held = d.held[0..d.held_len];
            if (bomOf(held, only_utf8) != null or !couldBeBom(held, only_utf8)) break;
            if (i == input.len) {
                if (last) break;
                return input[i..];
            }
            d.held[d.held_len] = input[i];
            d.held_len += 1;
            i += 1;
            d.consumed += 1;
        }
        d.sniffed = true;
        const held = d.held[0..d.held_len];
        var keep = held;
        if (bomOf(held, only_utf8)) |found| {
            d.encoding = found.encoding;
            keep = held[found.len..];
        }
        // Read from the input already: counted once, when held.
        d.prepend(keep);
        return input[i..];
    }

    fn couldBeBom(held: []const u8, only_utf8: bool) bool {
        const utf8_bom = "\xef\xbb\xbf";
        if (std.mem.startsWith(u8, utf8_bom, held)) return true;
        if (only_utf8) return false;
        return std.mem.startsWith(u8, "\xfe\xff", held) or std.mem.startsWith(u8, "\xff\xfe", held);
    }

    fn bomOf(held: []const u8, only_utf8: bool) ?struct { encoding: Encoding, len: usize } {
        if (std.mem.startsWith(u8, held, "\xef\xbb\xbf")) return .{ .encoding = .utf_8, .len = 3 };
        if (only_utf8) return null;
        if (std.mem.startsWith(u8, held, "\xfe\xff")) return .{ .encoding = .utf_16be, .len = 2 };
        if (std.mem.startsWith(u8, held, "\xff\xfe")) return .{ .encoding = .utf_16le, .len = 2 };
        return null;
    }

    /// Puts bytes back, `bytes[0]` to be read next.
    fn prepend(d: *Decoder, bytes: []const u8) void {
        var k = bytes.len;
        while (k > 0) {
            k -= 1;
            aegis.assert.pre(d.queued < d.queue.len, "a decoder puts back at most three bytes at a time");
            d.queue[d.queued] = bytes[k];
            d.queued += 1;
        }
    }

    /// Whether the decoder holds nothing between bytes: where a run of
    /// ASCII is copied as it is.
    inline fn idle(d: *const Decoder, comptime e: Encoding) bool {
        if (d.queued != 0) return false;
        return switch (e) {
            .utf_8 => d.utf8_needed == 0,
            .gbk, .gb18030 => d.lead == 0 and d.second == 0 and d.third == 0,
            .big5, .euc_jp, .shift_jis, .euc_kr => d.lead == 0,
            .utf_16be, .utf_16le => d.utf16_lead_byte == null and d.utf16_lead_surrogate == null,
            .iso_2022_jp, .replacement => false,
            else => true,
        };
    }

    fn run(d: *Decoder, comptime e: Encoding, input: []const u8, last: bool, out: *Out) DecodeError!void {
        var i: usize = 0;
        // The input read, counted once on the way out (an error included).
        const base = d.consumed;
        defer d.consumed = base + i;
        while (true) {
            if (comptime e != .iso_2022_jp and e != .replacement) if (i < input.len and d.idle(e)) {
                i = try fast(e, input, i, out);
            };
            if (e == .iso_2022_jp and i < input.len and d.queued == 0) i = try d.fastIso(input, i, out);
            const taken: Step = if (d.queued != 0) blk: {
                d.queued -= 1;
                break :blk d.step(e, d.queue[d.queued]);
            } else if (i < input.len) blk: {
                const b = input[i];
                i += 1;
                break :blk d.step(e, b);
            } else if (last) d.end(e) else return;
            switch (taken) {
                .more => {},
                .one => |cp| try out.codePoint(cp),
                .two => |pair| {
                    try out.codePoint(pair[0]);
                    try out.codePoint(pair[1]);
                },
                .failed => {
                    if (d.options.mode == .fatal) return error.Malformed;
                    try out.codePoint(utf8.replacement);
                },
                .finished => return,
            }
        }
    }

    /// While the decoder holds nothing: ASCII runs, and each sequence whole
    /// in the input that the standard's steps decode to one code point, read
    /// at once; returns where a byte needs the steps (an error, a sequence
    /// the input ends inside, Big5's pairs, gb18030's four bytes, EUC-JP's
    /// JIS X 0212), which leave the decoder holding nothing again after.
    inline fn fast(comptime e: Encoding, input: []const u8, start: usize, out: *Out) Writer.Error!usize {
        var i = start;
        // Where the output goes, held here: a byte stored through `out`
        // could be any of its fields, so the compiler would reload them all.
        var dest = out.dest;
        var at = out.len;
        if (comptime singleByte(e)) return fastSingle(e, input, start, out);
        decoding: while (i < input.len) {
            const b = input[i];
            const rest = input[i..];
            if (comptime asciiCompatible(e)) if (b < 0x80) {
                // Sixteen bytes stored whatever they are, and kept as far as
                // they are ASCII.
                if (rest.len >= 16) {
                    try reserve(out, &dest, &at, 16);
                    const V = @Vector(16, u8);
                    const v: V = rest[0..16].*;
                    dest[at..][0..16].* = v;
                    const k = @ctz(@as(u16, @bitCast(v >= @as(V, @splat(0x80)))));
                    at += k;
                    i += k;
                } else {
                    try reserve(out, &dest, &at, 1);
                    dest[at] = b;
                    at += 1;
                    i += 1;
                }
                continue;
            };
            if (e == .utf_8) {
                // Well-formed UTF-8 is copied as it is, up to where it is not.
                const n = utf8.wellFormed(rest);
                out.len = at;
                if (n == 0) return i;
                try out.bytes(rest[0..n]);
                dest = out.dest;
                at = out.len;
                i += n;
                continue;
            }
            try reserve(out, &dest, &at, 4);
            const cp: u21, const len: usize = switch (e) {
                .utf_8 => comptime unreachable,
                .x_user_defined => .{ 0xf780 + @as(u21, b) - 0x80, 1 },
                .utf_16be, .utf_16le => blk: {
                    if (rest.len < 2) break :decoding;
                    const unit = std.mem.readInt(u16, rest[0..2], if (e == .utf_16be) .big else .little);
                    if (unit < 0xd800 or unit > 0xdfff) break :blk .{ unit, 2 };
                    if (unit > 0xdbff or rest.len < 4) break :decoding;
                    const trail = std.mem.readInt(u16, rest[2..4], if (e == .utf_16be) .big else .little);
                    if (trail < 0xdc00 or trail > 0xdfff) break :decoding;
                    break :blk .{ 0x10000 + (@as(u21, unit - 0xd800) << 10) + (trail - 0xdc00), 4 };
                },
                .shift_jis => blk: {
                    if (b == 0x80) break :blk .{ 0x80, 1 };
                    if (b >= 0xa1 and b <= 0xdf) break :blk .{ 0xff61 - 0xa1 + @as(u21, b), 1 };
                    if (rest.len < 2 or !((b >= 0x81 and b <= 0x9f) or (b >= 0xe0 and b <= 0xfc))) break :decoding;
                    const t = rest[1];
                    if (!((t >= 0x40 and t <= 0x7e) or (t >= 0x80 and t <= 0xfc))) break :decoding;
                    const lead_offset: u8 = if (b < 0xa0) 0x81 else 0xc1;
                    const pointer = @as(usize, b - lead_offset) * 188 + (t - @as(u8, if (t < 0x7f) 0x40 else 0x41));
                    if (pointer >= 8836 and pointer <= 10715) break :blk .{ @intCast(0xe000 - 8836 + pointer), 2 };
                    if (pointer >= tables.jis0208.len or tables.jis0208[pointer] == 0) break :decoding;
                    break :blk .{ tables.jis0208[pointer], 2 };
                },
                .euc_jp => blk: {
                    if (rest.len < 2) break :decoding;
                    const t = rest[1];
                    if (b == 0x8e and t >= 0xa1 and t <= 0xdf) break :blk .{ 0xff61 - 0xa1 + @as(u21, t), 2 };
                    if (b < 0xa1 or b == 0xff or t < 0xa1 or t == 0xff) break :decoding;
                    const pointer = @as(usize, b - 0xa1) * 94 + (t - 0xa1);
                    if (tables.jis0208[pointer] == 0) break :decoding;
                    break :blk .{ tables.jis0208[pointer], 2 };
                },
                .euc_kr => blk: {
                    if (rest.len < 2 or b == 0x80 or b == 0xff) break :decoding;
                    const t = rest[1];
                    if (t < 0x41 or t == 0xff) break :decoding;
                    const pointer = @as(usize, b - 0x81) * 190 + (t - 0x41);
                    if (pointer >= tables.euc_kr.len or tables.euc_kr[pointer] == 0) break :decoding;
                    break :blk .{ tables.euc_kr[pointer], 2 };
                },
                .gbk, .gb18030 => blk: {
                    if (b == 0x80) break :blk .{ 0x20ac, 1 };
                    if (rest.len < 2 or b == 0xff) break :decoding;
                    const t = rest[1];
                    if (!((t >= 0x40 and t <= 0x7e) or (t >= 0x80 and t <= 0xfe))) break :decoding;
                    const pointer = @as(usize, b - 0x81) * 190 + (t - @as(u8, if (t < 0x7f) 0x40 else 0x41));
                    if (pointer >= tables.gb18030.len or tables.gb18030[pointer] == 0) break :decoding;
                    break :blk .{ tables.gb18030[pointer], 2 };
                },
                .big5 => blk: {
                    if (rest.len < 2 or b == 0x80 or b == 0xff) break :decoding;
                    const t = rest[1];
                    if (!((t >= 0x40 and t <= 0x7e) or (t >= 0xa1 and t <= 0xfe))) break :decoding;
                    const pointer = @as(usize, b - 0x81) * 157 + (t - @as(u8, if (t < 0x7f) 0x40 else 0x62));
                    switch (pointer) {
                        1133, 1135, 1164, 1166 => break :decoding,
                        else => {},
                    }
                    if (pointer >= tables.big5.len or tables.big5[pointer] == 0) break :decoding;
                    break :blk .{ big5CodePoint(pointer), 2 };
                },
                else => comptime unreachable,
            };
            at += putUtf8(dest[at..][0..4], cp);
            i += len;
        }
        out.len = at;
        return i;
    }

    /// `fast` for a single-byte encoding: each byte's UTF-8 from one table,
    /// ASCII included, sixteen bytes at a time where the room for them is
    /// made once.
    inline fn fastSingle(comptime e: Encoding, input: []const u8, start: usize, out: *Out) Writer.Error!usize {
        var i = start;
        var dest = out.dest;
        var at = out.len;
        const table = &single_byte_utf8[singleByteIndex(e)];
        single: {
            while (input.len - i >= 16) {
                try reserve(out, &dest, &at, 64);
                const V = @Vector(16, u8);
                const v: V = input[i..][0..16].*;
                if (@reduce(.Or, v) < 0x80) {
                    dest[at..][0..16].* = v;
                    at += 16;
                    i += 16;
                    continue;
                }
                inline for (0..16) |j| {
                    const p = table[input[i + j]];
                    if (p == 0) {
                        i += j;
                        break :single;
                    }
                    std.mem.writeInt(u32, dest[at..][0..4], p & 0xffffff, .little);
                    at += p >> 24;
                }
                i += 16;
            }
            while (i < input.len) : (i += 1) {
                const p = table[input[i]];
                if (p == 0) break;
                try reserve(out, &dest, &at, 4);
                std.mem.writeInt(u32, dest[at..][0..4], p & 0xffffff, .little);
                at += p >> 24;
            }
        }
        out.len = at;
        return i;
    }

    /// ISO-2022-JP's `fast`: in its ASCII state the bytes that are
    /// themselves (all below 0x80 but SO, SI and ESC), in its JIS X 0208
    /// state the pairs that decode; the state is the same throughout, as
    /// only an escape changes it.
    inline fn fastIso(d: *Decoder, input: []const u8, start: usize, out: *Out) Writer.Error!usize {
        var i = start;
        var dest = out.dest;
        var at = out.len;
        switch (d.iso_state) {
            .ascii => while (i < input.len) {
                const rest = input[i..];
                if (rest.len >= 16) {
                    try reserve(out, &dest, &at, 16);
                    const V = @Vector(16, u8);
                    const v: V = rest[0..16].*;
                    dest[at..][0..16].* = v;
                    const stop = (v >= @as(V, @splat(0x80))) | (v == @as(V, @splat(0x1b))) | (v == @as(V, @splat(0x0e))) | (v == @as(V, @splat(0x0f)));
                    const k = @ctz(@as(u16, @bitCast(stop)));
                    at += k;
                    i += k;
                    if (k < 16) break;
                } else {
                    const b = rest[0];
                    if (b >= 0x80 or b == 0x1b or b == 0x0e or b == 0x0f) break;
                    try reserve(out, &dest, &at, 1);
                    dest[at] = b;
                    at += 1;
                    i += 1;
                }
            },
            .lead_byte => while (i + 1 < input.len) {
                const l = input[i];
                const t = input[i + 1];
                if (l < 0x21 or l > 0x7e or t < 0x21 or t > 0x7e) break;
                const cp = tables.jis0208[@as(usize, l - 0x21) * 94 + (t - 0x21)];
                if (cp == 0) break;
                try reserve(out, &dest, &at, 4);
                at += putUtf8(dest[at..][0..4], cp);
                i += 2;
            },
            else => {},
        }
        // Each byte read outside an escape unsets the standard's output flag.
        if (i != start) d.iso_output = false;
        out.len = at;
        return i;
    }

    /// One byte through the standard's decoder of `e`.
    inline fn step(d: *Decoder, comptime e: Encoding, b: u8) Step {
        return switch (e) {
            .utf_8 => d.utf8Step(b),
            .gbk, .gb18030 => d.gb18030Step(b),
            .big5 => d.big5Step(b),
            .euc_jp => d.eucJpStep(b),
            .iso_2022_jp => d.iso2022Step(b),
            .shift_jis => d.shiftJisStep(b),
            .euc_kr => d.eucKrStep(b),
            .replacement => d.replacementStep(),
            .utf_16be => d.utf16Step(b, true),
            .utf_16le => d.utf16Step(b, false),
            .x_user_defined => .{ .one = if (b < 0x80) b else 0xf780 + @as(u21, b) - 0x80 },
            else => singleByteStep(e, b),
        };
    }

    /// The end of the input through the standard's decoder of `e`.
    fn end(d: *Decoder, comptime e: Encoding) Step {
        switch (e) {
            .utf_8 => if (d.utf8_needed != 0) {
                d.utf8_needed = 0;
                d.utf8_seen = 0;
                d.utf8_cp = 0;
                d.utf8_lower = 0x80;
                d.utf8_upper = 0xbf;
                return .failed;
            },
            .gbk, .gb18030 => if (d.lead != 0 or d.second != 0 or d.third != 0) {
                d.lead = 0;
                d.second = 0;
                d.third = 0;
                return .failed;
            },
            .big5, .euc_jp, .shift_jis, .euc_kr => if (d.lead != 0) {
                d.lead = 0;
                return .failed;
            },
            .iso_2022_jp => switch (d.iso_state) {
                .trail_byte => {
                    d.iso_state = .lead_byte;
                    return .failed;
                },
                .escape_start => {
                    d.iso_output = false;
                    d.iso_state = d.iso_output_state;
                    return .failed;
                },
                .escape => {
                    const l = d.lead;
                    d.lead = 0;
                    d.prepend(&.{l});
                    d.iso_output = false;
                    d.iso_state = d.iso_output_state;
                    return .failed;
                },
                else => {},
            },
            .utf_16be, .utf_16le => if (d.utf16_lead_byte != null or d.utf16_lead_surrogate != null) {
                d.utf16_lead_byte = null;
                d.utf16_lead_surrogate = null;
                return .failed;
            },
            else => {},
        }
        return .finished;
    }

    fn utf8Step(d: *Decoder, b: u8) Step {
        if (d.utf8_needed == 0) {
            switch (b) {
                0x00...0x7f => return .{ .one = b },
                0xc2...0xdf => {
                    d.utf8_needed = 1;
                    d.utf8_cp = b & 0x1f;
                },
                0xe0...0xef => {
                    if (b == 0xe0) d.utf8_lower = 0xa0;
                    if (b == 0xed) d.utf8_upper = 0x9f;
                    d.utf8_needed = 2;
                    d.utf8_cp = b & 0x0f;
                },
                0xf0...0xf4 => {
                    if (b == 0xf0) d.utf8_lower = 0x90;
                    if (b == 0xf4) d.utf8_upper = 0x8f;
                    d.utf8_needed = 3;
                    d.utf8_cp = b & 0x07;
                },
                else => return .failed,
            }
            return .more;
        }
        if (b < d.utf8_lower or b > d.utf8_upper) {
            d.utf8_cp = 0;
            d.utf8_needed = 0;
            d.utf8_seen = 0;
            d.utf8_lower = 0x80;
            d.utf8_upper = 0xbf;
            d.prepend(&.{b});
            return .failed;
        }
        d.utf8_lower = 0x80;
        d.utf8_upper = 0xbf;
        d.utf8_cp = (d.utf8_cp << 6) | (b & 0x3f);
        d.utf8_seen += 1;
        if (d.utf8_seen != d.utf8_needed) return .more;
        const cp = d.utf8_cp;
        d.utf8_cp = 0;
        d.utf8_needed = 0;
        d.utf8_seen = 0;
        return .{ .one = cp };
    }

    fn gb18030Step(d: *Decoder, b: u8) Step {
        if (d.third != 0) {
            if (b < 0x30 or b > 0x39) {
                d.prepend(&.{ d.second, d.third, b });
                d.lead = 0;
                d.second = 0;
                d.third = 0;
                return .failed;
            }
            const pointer = ((@as(u32, d.lead - 0x81) * 10 + (d.second - 0x30)) * 126 + (d.third - 0x81)) * 10 + (b - 0x30);
            d.lead = 0;
            d.second = 0;
            d.third = 0;
            return if (rangesCodePoint(pointer)) |cp| .{ .one = cp } else .failed;
        }
        if (d.second != 0) {
            if (b >= 0x81 and b <= 0xfe) {
                d.third = b;
                return .more;
            }
            d.prepend(&.{ d.second, b });
            d.lead = 0;
            d.second = 0;
            return .failed;
        }
        if (d.lead != 0) {
            if (b >= 0x30 and b <= 0x39) {
                d.second = b;
                return .more;
            }
            const l = d.lead;
            d.lead = 0;
            const offset: u8 = if (b < 0x7f) 0x40 else 0x41;
            if ((b >= 0x40 and b <= 0x7e) or (b >= 0x80 and b <= 0xfe)) {
                const pointer = @as(usize, l - 0x81) * 190 + (b - offset);
                const cp = tables.gb18030[pointer];
                if (cp != 0) return .{ .one = cp };
            }
            if (b < 0x80) d.prepend(&.{b});
            return .failed;
        }
        if (b < 0x80) return .{ .one = b };
        if (b == 0x80) return .{ .one = 0x20ac };
        if (b <= 0xfe) {
            d.lead = b;
            return .more;
        }
        return .failed;
    }

    fn big5Step(d: *Decoder, b: u8) Step {
        if (d.lead != 0) {
            const l = d.lead;
            d.lead = 0;
            const offset: u8 = if (b < 0x7f) 0x40 else 0x62;
            if ((b >= 0x40 and b <= 0x7e) or (b >= 0xa1 and b <= 0xfe)) {
                const pointer = @as(usize, l - 0x81) * 157 + (b - offset);
                switch (pointer) {
                    1133 => return .{ .two = .{ 0xca, 0x304 } },
                    1135 => return .{ .two = .{ 0xca, 0x30c } },
                    1164 => return .{ .two = .{ 0xea, 0x304 } },
                    1166 => return .{ .two = .{ 0xea, 0x30c } },
                    else => {},
                }
                if (pointer < tables.big5.len and tables.big5[pointer] != 0) return .{ .one = big5CodePoint(pointer) };
            }
            if (b < 0x80) d.prepend(&.{b});
            return .failed;
        }
        if (b < 0x80) return .{ .one = b };
        if (b >= 0x81 and b <= 0xfe) {
            d.lead = b;
            return .more;
        }
        return .failed;
    }

    fn eucJpStep(d: *Decoder, b: u8) Step {
        if (d.lead == 0x8e and b >= 0xa1 and b <= 0xdf) {
            d.lead = 0;
            return .{ .one = 0xff61 - 0xa1 + @as(u21, b) };
        }
        if (d.lead == 0x8f and b >= 0xa1 and b <= 0xfe) {
            d.jis0212 = true;
            d.lead = b;
            return .more;
        }
        if (d.lead != 0) {
            const l = d.lead;
            d.lead = 0;
            var cp: u21 = 0;
            if (l >= 0xa1 and l <= 0xfe and b >= 0xa1 and b <= 0xfe) {
                const pointer = @as(usize, l - 0xa1) * 94 + (b - 0xa1);
                if (d.jis0212) {
                    if (pointer < tables.jis0212.len) cp = tables.jis0212[pointer];
                } else if (pointer < tables.jis0208.len) cp = tables.jis0208[pointer];
            }
            d.jis0212 = false;
            if (cp != 0) return .{ .one = cp };
            if (b < 0x80) d.prepend(&.{b});
            return .failed;
        }
        if (b < 0x80) return .{ .one = b };
        if (b == 0x8e or b == 0x8f or (b >= 0xa1 and b <= 0xfe)) {
            d.lead = b;
            return .more;
        }
        return .failed;
    }

    fn iso2022Step(d: *Decoder, b: u8) Step {
        switch (d.iso_state) {
            .ascii => {
                if (b == 0x1b) {
                    d.iso_state = .escape_start;
                    return .more;
                }
                d.iso_output = false;
                if (b < 0x80 and b != 0x0e and b != 0x0f) return .{ .one = b };
                return .failed;
            },
            .roman => {
                if (b == 0x1b) {
                    d.iso_state = .escape_start;
                    return .more;
                }
                d.iso_output = false;
                if (b == 0x5c) return .{ .one = 0xa5 };
                if (b == 0x7e) return .{ .one = 0x203e };
                if (b < 0x80 and b != 0x0e and b != 0x0f) return .{ .one = b };
                return .failed;
            },
            .katakana => {
                if (b == 0x1b) {
                    d.iso_state = .escape_start;
                    return .more;
                }
                d.iso_output = false;
                if (b >= 0x21 and b <= 0x5f) return .{ .one = 0xff61 - 0x21 + @as(u21, b) };
                return .failed;
            },
            .lead_byte => {
                if (b == 0x1b) {
                    d.iso_state = .escape_start;
                    return .more;
                }
                d.iso_output = false;
                if (b >= 0x21 and b <= 0x7e) {
                    d.lead = b;
                    d.iso_state = .trail_byte;
                    return .more;
                }
                return .failed;
            },
            .trail_byte => {
                if (b == 0x1b) {
                    d.iso_state = .escape_start;
                    return .failed;
                }
                d.iso_state = .lead_byte;
                if (b >= 0x21 and b <= 0x7e) {
                    const pointer = @as(usize, d.lead - 0x21) * 94 + (b - 0x21);
                    const cp = if (pointer < tables.jis0208.len) tables.jis0208[pointer] else 0;
                    return if (cp != 0) .{ .one = cp } else .failed;
                }
                return .failed;
            },
            .escape_start => {
                if (b == 0x24 or b == 0x28) {
                    d.lead = b;
                    d.iso_state = .escape;
                    return .more;
                }
                d.prepend(&.{b});
                d.iso_output = false;
                d.iso_state = d.iso_output_state;
                return .failed;
            },
            .escape => {
                const l = d.lead;
                d.lead = 0;
                const next: ?Iso2022 = if (l == 0x28 and b == 0x42) .ascii else if (l == 0x28 and b == 0x4a) .roman else if (l == 0x28 and b == 0x49) .katakana else if (l == 0x24 and (b == 0x40 or b == 0x42)) .lead_byte else null;
                if (next) |state| {
                    d.iso_state = state;
                    d.iso_output_state = state;
                    const output = d.iso_output;
                    d.iso_output = true;
                    return if (output) .failed else .more;
                }
                d.prepend(&.{ l, b });
                d.iso_output = false;
                d.iso_state = d.iso_output_state;
                return .failed;
            },
        }
    }

    fn shiftJisStep(d: *Decoder, b: u8) Step {
        if (d.lead != 0) {
            const l = d.lead;
            d.lead = 0;
            const offset: u8 = if (b < 0x7f) 0x40 else 0x41;
            const lead_offset: u8 = if (l < 0xa0) 0x81 else 0xc1;
            if ((b >= 0x40 and b <= 0x7e) or (b >= 0x80 and b <= 0xfc)) {
                const pointer = @as(usize, l - lead_offset) * 188 + (b - offset);
                if (pointer >= 8836 and pointer <= 10715) return .{ .one = @intCast(0xe000 - 8836 + pointer) };
                if (pointer < tables.jis0208.len and tables.jis0208[pointer] != 0) return .{ .one = tables.jis0208[pointer] };
            }
            if (b < 0x80) d.prepend(&.{b});
            return .failed;
        }
        if (b <= 0x80) return .{ .one = b };
        if (b >= 0xa1 and b <= 0xdf) return .{ .one = 0xff61 - 0xa1 + @as(u21, b) };
        if ((b >= 0x81 and b <= 0x9f) or (b >= 0xe0 and b <= 0xfc)) {
            d.lead = b;
            return .more;
        }
        return .failed;
    }

    fn eucKrStep(d: *Decoder, b: u8) Step {
        if (d.lead != 0) {
            const l = d.lead;
            d.lead = 0;
            if (b >= 0x41 and b <= 0xfe) {
                const pointer = @as(usize, l - 0x81) * 190 + (b - 0x41);
                if (pointer < tables.euc_kr.len and tables.euc_kr[pointer] != 0) return .{ .one = tables.euc_kr[pointer] };
            }
            if (b < 0x80) d.prepend(&.{b});
            return .failed;
        }
        if (b < 0x80) return .{ .one = b };
        if (b >= 0x81 and b <= 0xfe) {
            d.lead = b;
            return .more;
        }
        return .failed;
    }

    fn replacementStep(d: *Decoder) Step {
        if (d.replaced) return .more;
        d.replaced = true;
        return .failed;
    }

    fn utf16Step(d: *Decoder, b: u8, big: bool) Step {
        const lead = d.utf16_lead_byte orelse {
            d.utf16_lead_byte = b;
            return .more;
        };
        d.utf16_lead_byte = null;
        const unit: u16 = if (big) @as(u16, lead) << 8 | b else @as(u16, b) << 8 | lead;
        if (d.utf16_lead_surrogate) |surrogate| {
            d.utf16_lead_surrogate = null;
            if (unit >= 0xdc00 and unit <= 0xdfff) return .{ .one = 0x10000 + (@as(u21, surrogate - 0xd800) << 10) + (unit - 0xdc00) };
            const hi: u8 = @intCast(unit >> 8);
            const lo: u8 = @truncate(unit);
            d.prepend(if (big) &.{ hi, lo } else &.{ lo, hi });
            return .failed;
        }
        if (unit >= 0xd800 and unit <= 0xdbff) {
            d.utf16_lead_surrogate = unit;
            return .more;
        }
        if (unit >= 0xdc00 and unit <= 0xdfff) return .failed;
        return .{ .one = unit };
    }
};

/// The position of a single-byte encoding's table in the generated lists.
fn singleByteIndex(comptime e: Encoding) usize {
    return if (e == .cp437) tables.single_byte.len - 1 else @backingInt(e) - @backingInt(Encoding.ibm866);
}

inline fn singleByteStep(comptime e: Encoding, b: u8) Step {
    if (b < 0x80) return .{ .one = b };
    const cp = tables.single_byte[singleByteIndex(e)][b - 0x80];
    return if (cp != 0) .{ .one = cp } else .failed;
}

/// index Big5 code point for a pointer it maps.
fn big5CodePoint(pointer: usize) u21 {
    const plane: u21 = @intCast(tables.big5_plane_2[pointer / 64] >> @intCast(pointer % 64) & 1);
    return plane << 17 | tables.big5[pointer];
}

/// index gb18030 ranges code point.
fn rangesCodePoint(pointer: u32) ?u21 {
    if ((pointer > 39419 and pointer < 189000) or pointer > 1237575) return null;
    if (pointer == 7457) return 0xe7c7;
    if (pointer >= 189000) return @intCast(0x10000 + pointer - 189000);
    const r = &tables.gb18030_ranges;
    var low: usize = 0;
    var high: usize = r.len;
    while (low + 1 < high) {
        const mid = (low + high) / 2;
        if (r[mid][0] <= pointer) low = mid else high = mid;
    }
    return @intCast(r[low][1] + pointer - r[low][0]);
}

/// index gb18030 ranges pointer.
fn rangesPointer(cp: u21) u32 {
    if (cp == 0xe7c7) return 7457;
    if (cp >= 0x10000) return 189000 + cp - 0x10000;
    const r = &tables.gb18030_ranges;
    var low: usize = 0;
    var high: usize = r.len;
    while (low + 1 < high) {
        const mid = (low + high) / 2;
        if (r[mid][1] <= cp) low = mid else high = mid;
    }
    return r[low][0] + cp - r[low][1];
}

// ---------------------------------------------------------------------------
// Encoding

const IsoEncode = enum(u2) { ascii, roman, jis0208 };

/// Up to four bytes an encoder step writes, or what it cannot encode.
const Bytes = struct {
    len: u3 = 0,
    b: [4]u8 = undefined,
    /// Encode this code point again after the bytes (ISO-2022-JP's switch).
    again: bool = false,
    /// The code point has no bytes in the encoding.
    unmappable: bool = false,
    /// The error is reported as U+FFFD, not the code point (ISO-2022-JP's
    /// SO, SI and ESC, which would change how the bytes after them read).
    as_replacement: bool = false,

    fn of(comptime n: u3, b: [n]u8) Bytes {
        var out: Bytes = .{ .len = n };
        @memcpy(out.b[0..n], &b);
        return out;
    }
};

/// An encoder of one encoding: `encode` takes UTF-8 in pieces, a code point
/// split between pieces held until the next.
pub const Encoder = struct {
    encoding: Encoding,
    options: EncodeOptions,
    /// The code point `encode` stopped at in `.fatal` mode.
    unmappable: u21 = 0,
    /// Input bytes read; at an unmappable code point in `.fatal` mode, those
    /// before it.
    consumed: u64 = 0,
    /// The start of a code point the last piece ended in.
    held: [4]u8 = undefined,
    held_len: u3 = 0,
    iso: IsoEncode = .ascii,

    /// An encoder of `encoding`; replacement, which encodes nothing, is
    /// UTF-8, as its output encoding is.
    pub fn init(encoding: Encoding, options: EncodeOptions) Encoder {
        return .{ .encoding = if (encoding == .replacement) .utf_8 else encoding, .options = options };
    }

    /// Encodes `input`, the next piece of a UTF-8 stream, into `w`; `last`
    /// when it is the stream's end. Ill-formed UTF-8 reads as U+FFFD, as
    /// xenoglyph decodes it everywhere.
    pub fn encode(e: *Encoder, input: []const u8, last: bool, w: *Writer) EncodeError!void {
        var out: Out = .init(w);
        switch (e.encoding) {
            // What came before an unmappable code point is written, then the error.
            inline else => |enc| e.run(enc, input, last, &out) catch |err| {
                try out.flush();
                return err;
            },
        }
        try out.flush();
    }

    fn run(e: *Encoder, comptime enc: Encoding, input: []const u8, last: bool, out: *Out) EncodeError!void {
        var i: usize = 0;
        // A code point the last piece began, completed from this one.
        if (e.held_len != 0) {
            var joined: [4]u8 = undefined;
            const kept = e.held_len;
            @memcpy(joined[0..kept], e.held[0..kept]);
            var have: usize = kept;
            var taken: usize = 0;
            while (have < 4 and taken < input.len and incomplete(joined[0..have])) {
                joined[have] = input[taken];
                have += 1;
                taken += 1;
            }
            if (!last and incomplete(joined[0..have])) {
                @memcpy(e.held[0..have], joined[0..have]);
                e.held_len = @intCast(have);
                e.consumed += taken;
                return;
            }
            e.held_len = 0;
            const got = utf8.decode(joined[0..have]);
            if (enc == .utf_8) {
                try out.bytes(if (got.code_point == utf8.replacement) "\xef\xbf\xbd" else joined[0..got.len]);
            } else try e.codePoint(enc, got.code_point, out);
            i = got.len - kept;
            e.consumed += i;
        }
        while (i < input.len) {
            const before = i;
            i = try e.fast(enc, input, i, out);
            e.consumed += i - before;
            if (i == input.len) break;
            const rest = input[i..];
            const got = utf8.decode(rest);
            if (!last and got.code_point == utf8.replacement and got.len == rest.len and rest.len < 4 and incomplete(rest)) {
                // A code point the next piece completes.
                @memcpy(e.held[0..rest.len], rest);
                e.held_len = @intCast(rest.len);
                e.consumed += rest.len;
                return;
            }
            if (enc == .utf_8) {
                if (got.code_point == utf8.replacement and !std.mem.startsWith(u8, rest, "\xef\xbf\xbd")) {
                    try out.bytes("\xef\xbf\xbd");
                } else try out.bytes(rest[0..got.len]);
            } else try e.codePoint(enc, got.code_point, out);
            i += got.len;
            e.consumed += got.len;
        }
        if (last and enc == .iso_2022_jp and e.iso != .ascii) {
            e.iso = .ascii;
            try out.bytes("\x1b\x28\x42");
        }
    }

    /// The code points that encode, read at once: well-formed UTF-8 copied
    /// for UTF-8, and for the rest ASCII sixteen bytes at a time (where it is
    /// itself) and each code point the encoding has written straight out.
    /// Returns where a code point needs `codePoint`: one the encoding lacks,
    /// ill-formed or unfinished input.
    inline fn fast(e: *Encoder, comptime enc: Encoding, input: []const u8, start: usize, out: *Out) Writer.Error!usize {
        if (enc == .utf_8) {
            const n = utf8.wellFormed(input[start..]);
            try out.bytes(input[start..][0..n]);
            return start + n;
        }
        var i = start;
        var dest = out.dest;
        var at = out.len;
        encoding: while (i < input.len) {
            const rest = input[i..];
            const plain_ascii = comptime asciiCompatible(enc) or enc == .iso_2022_jp;
            if (plain_ascii and rest[0] < 0x80 and rest.len >= 16 and (enc != .iso_2022_jp or e.iso == .ascii)) {
                try reserve(out, &dest, &at, 16);
                const V = @Vector(16, u8);
                const v: V = rest[0..16].*;
                dest[at..][0..16].* = v;
                var stop = v >= @as(V, @splat(0x80));
                // 0E, 0F and 1B are errors in ISO-2022-JP.
                if (enc == .iso_2022_jp) stop = stop | (v == @as(V, @splat(0x1b))) | (v == @as(V, @splat(0x0e))) | (v == @as(V, @splat(0x0f)));
                const k = @ctz(@as(u16, @bitCast(stop)));
                at += k;
                i += k;
                if (k != 0) continue;
            }
            const got = readCodePoint(rest);
            if (got.code_point == utf8.replacement and !std.mem.startsWith(u8, rest, "\xef\xbf\xbd")) break;
            if (comptime singleByte(enc)) {
                // One byte, ASCII or from the encoder's pages, straight out.
                const cp = got.code_point;
                const b: u8 = if (cp < 0x80) @intCast(cp) else blk: {
                    if (cp > 0xffff) break :encoding;
                    const encoder = SingleByteEncoder(singleByteIndex(enc));
                    const page = encoder.index[cp >> 8];
                    if (page == 0) break :encoding;
                    const found = encoder.pages[page - 1][cp & 0xff];
                    if (found == 0) break :encoding;
                    break :blk found;
                };
                try reserve(out, &dest, &at, 1);
                dest[at] = b;
                at += 1;
                i += got.len;
                continue;
            }
            while (true) {
                const r = e.step(enc, got.code_point);
                if (r.unmappable) break :encoding;
                try reserve(out, &dest, &at, 4);
                dest[at..][0..4].* = r.b;
                at += r.len;
                // ISO-2022-JP's escape, after which the code point again.
                if (!r.again) break;
            }
            i += got.len;
        }
        out.len = at;
        return i;
    }

    /// Whether `bytes` are the start of a well-formed sequence still short
    /// of its end.
    fn incomplete(bytes: []const u8) bool {
        const lead = bytes[0];
        const need: usize = switch (lead) {
            0xc2...0xdf => 2,
            0xe0...0xef => 3,
            0xf0...0xf4 => 4,
            else => return false,
        };
        if (bytes.len >= need) return false;
        // Every byte present must fit, so a later byte could complete it.
        var probe: [4]u8 = .{ lead, 0x80, 0x80, 0x80 };
        if (lead == 0xe0) probe[1] = 0xa0;
        if (lead == 0xf0) probe[1] = 0x90;
        @memcpy(probe[0..bytes.len], bytes);
        return utf8.decode(probe[0..need]).len == need;
    }

    /// Encodes one code point, and in html mode the reference for one the
    /// encoding lacks.
    fn codePoint(e: *Encoder, comptime enc: Encoding, cp: u21, out: *Out) EncodeError!void {
        var code = cp;
        while (true) {
            const r = e.step(enc, code);
            if (r.unmappable) {
                const reported: u21 = if (r.as_replacement) 0xfffd else code;
                if (e.options.mode == .fatal) {
                    e.unmappable = reported;
                    return error.Unmappable;
                }
                var digits: [7]u8 = undefined;
                var at: usize = digits.len;
                var rest: u21 = reported;
                while (true) {
                    at -= 1;
                    digits[at] = @intCast('0' + rest % 10);
                    rest /= 10;
                    if (rest == 0) break;
                }
                try e.codePoint(enc, '&', out);
                try e.codePoint(enc, '#', out);
                for (digits[at..]) |c| try e.codePoint(enc, c, out);
                try e.codePoint(enc, ';', out);
                return;
            }
            try out.bytes(r.b[0..r.len]);
            if (!r.again) return;
            code = cp;
        }
    }

    /// One code point through the standard's encoder of `enc`.
    inline fn step(e: *Encoder, comptime enc: Encoding, cp: u21) Bytes {
        return switch (enc) {
            .utf_8, .replacement => utf8Bytes(cp),
            .gbk, .gb18030 => gb18030Bytes(cp, enc == .gbk),
            .big5 => big5Bytes(cp),
            .euc_jp => eucJpBytes(cp),
            .iso_2022_jp => e.iso2022Bytes(cp),
            .shift_jis => shiftJisBytes(cp),
            .euc_kr => eucKrBytes(cp),
            .utf_16be, .utf_16le => utf16Bytes(cp, enc == .utf_16be),
            .x_user_defined => if (cp < 0x80) .of(1, .{@intCast(cp)}) else if (cp >= 0xf780 and cp <= 0xf7ff) .of(1, .{@intCast(cp - 0xf780 + 0x80)}) else .{ .unmappable = true },
            else => singleByteBytes(enc, cp),
        };
    }

    fn iso2022Bytes(e: *Encoder, cp: u21) Bytes {
        if ((e.iso == .ascii or e.iso == .roman) and (cp == 0x0e or cp == 0x0f or cp == 0x1b)) return .{ .unmappable = true, .as_replacement = true };
        if (e.iso == .ascii and cp < 0x80) return .of(1, .{@intCast(cp)});
        if (e.iso == .roman and ((cp < 0x80 and cp != 0x5c and cp != 0x7e) or cp == 0xa5 or cp == 0x203e)) {
            if (cp < 0x80) return .of(1, .{@intCast(cp)});
            return .of(1, .{if (cp == 0xa5) 0x5c else 0x7e});
        }
        if (cp < 0x80 and e.iso != .ascii) {
            e.iso = .ascii;
            return .{ .len = 3, .b = .{ 0x1b, 0x28, 0x42, 0 }, .again = true };
        }
        if ((cp == 0xa5 or cp == 0x203e) and e.iso != .roman) {
            e.iso = .roman;
            return .{ .len = 3, .b = .{ 0x1b, 0x28, 0x4a, 0 }, .again = true };
        }
        var c = cp;
        if (c == 0x2212) c = 0xff0d;
        if (c >= 0xff61 and c <= 0xff9f) c = tables.katakana[c - 0xff61];
        const pointer = tables.jis0208_encode.get(c);
        if (pointer == 0) {
            if (e.iso == .jis0208) {
                e.iso = .ascii;
                return .{ .len = 3, .b = .{ 0x1b, 0x28, 0x42, 0 }, .again = true };
            }
            return .{ .unmappable = true };
        }
        if (e.iso != .jis0208) {
            e.iso = .jis0208;
            return .{ .len = 3, .b = .{ 0x1b, 0x24, 0x42, 0 }, .again = true };
        }
        const p = pointer - 1;
        return .of(2, .{ @intCast(p / 94 + 0x21), @intCast(p % 94 + 0x21) });
    }
};

fn utf8Bytes(cp: u21) Bytes {
    var out: Bytes = .{};
    out.len = std.unicode.utf8Encode(cp, &out.b) catch return .of(3, .{ 0xef, 0xbf, 0xbd });
    return out;
}

fn utf16Bytes(cp: u21, big: bool) Bytes {
    if (cp < 0x10000) {
        const u: u16 = @intCast(cp);
        return if (big) .of(2, .{ @intCast(u >> 8), @truncate(u) }) else .of(2, .{ @truncate(u), @intCast(u >> 8) });
    }
    const v = cp - 0x10000;
    const hi: u16 = @intCast(0xd800 + (v >> 10));
    const lo: u16 = @intCast(0xdc00 + (v & 0x3ff));
    return if (big) .of(4, .{ @intCast(hi >> 8), @truncate(hi), @intCast(lo >> 8), @truncate(lo) }) else .of(4, .{ @truncate(hi), @intCast(hi >> 8), @truncate(lo), @intCast(lo >> 8) });
}

inline fn singleByteBytes(comptime enc: Encoding, cp: u21) Bytes {
    if (cp < 0x80) return .of(1, .{@intCast(cp)});
    if (cp > 0xffff) return .{ .unmappable = true };
    const encoder = SingleByteEncoder(singleByteIndex(enc));
    const page = encoder.index[cp >> 8];
    if (page == 0) return .{ .unmappable = true };
    const b = encoder.pages[page - 1][cp & 0xff];
    if (b == 0) return .{ .unmappable = true };
    return .of(1, .{b});
}

/// A single-byte encoding's encoder, built at compile time from its decoding
/// table, for the encodings a program uses: each 256 code points that hold
/// any of its characters a page of their bytes (0: none), and an index from
/// a code point's high byte to its page (0: none). Where two bytes decode to
/// one code point, the first is the index pointer the standard encodes.
fn SingleByteEncoder(comptime k: usize) type {
    @setEvalBranchQuota(100_000);
    const table = tables.single_byte[k];
    var by_high: [0x100]u8 = @splat(0);
    var count: u8 = 0;
    for (table) |cp| if (cp != 0 and by_high[cp >> 8] == 0) {
        count += 1;
        by_high[cp >> 8] = count;
    };
    var built: [count][0x100]u8 = @splat(@splat(0));
    for (table, 0..) |cp, b| if (cp != 0) {
        const at = &built[by_high[cp >> 8] - 1][cp & 0xff];
        if (at.* == 0) at.* = @intCast(b + 0x80);
    };
    const final_index = by_high;
    const final_pages = built;
    return struct {
        const index = final_index;
        const pages = final_pages;
    };
}

fn gb18030Bytes(cp: u21, gbk: bool) Bytes {
    if (cp < 0x80) return .of(1, .{@intCast(cp)});
    if (cp == 0xe5e5) return .{ .unmappable = true };
    if (gbk and cp == 0x20ac) return .of(1, .{0x80});
    const pointer = tables.gb18030_encode.get(cp);
    if (pointer != 0) {
        const p = pointer - 1;
        const trail = p % 190;
        const offset: u16 = if (trail < 0x3f) 0x40 else 0x41;
        return .of(2, .{ @intCast(p / 190 + 0x81), @intCast(trail + offset) });
    }
    if (gbk) return .{ .unmappable = true };
    var p = rangesPointer(cp);
    const b1 = p / (10 * 126 * 10);
    p %= 10 * 126 * 10;
    const b2 = p / (10 * 126);
    p %= 10 * 126;
    const b3 = p / 10;
    const b4 = p % 10;
    return .of(4, .{ @intCast(b1 + 0x81), @intCast(b2 + 0x30), @intCast(b3 + 0x81), @intCast(b4 + 0x30) });
}

fn big5Bytes(cp: u21) Bytes {
    if (cp < 0x80) return .of(1, .{@intCast(cp)});
    const pointer = tables.big5_encode.get(cp);
    if (pointer == 0) return .{ .unmappable = true };
    const p = pointer - 1;
    const trail = p % 157;
    const offset: u16 = if (trail < 0x3f) 0x40 else 0x62;
    return .of(2, .{ @intCast(p / 157 + 0x81), @intCast(trail + offset) });
}

fn eucJpBytes(cp: u21) Bytes {
    if (cp < 0x80) return .of(1, .{@intCast(cp)});
    if (cp == 0xa5) return .of(1, .{0x5c});
    if (cp == 0x203e) return .of(1, .{0x7e});
    if (cp >= 0xff61 and cp <= 0xff9f) return .of(2, .{ 0x8e, @intCast(cp - 0xff61 + 0xa1) });
    const c = if (cp == 0x2212) 0xff0d else cp;
    const pointer = tables.jis0208_encode.get(c);
    if (pointer == 0) return .{ .unmappable = true };
    const p = pointer - 1;
    return .of(2, .{ @intCast(p / 94 + 0xa1), @intCast(p % 94 + 0xa1) });
}

fn shiftJisBytes(cp: u21) Bytes {
    if (cp <= 0x80) return .of(1, .{@intCast(cp)});
    if (cp == 0xa5) return .of(1, .{0x5c});
    if (cp == 0x203e) return .of(1, .{0x7e});
    if (cp >= 0xff61 and cp <= 0xff9f) return .of(1, .{@intCast(cp - 0xff61 + 0xa1)});
    const c = if (cp == 0x2212) 0xff0d else cp;
    const first = tables.jis0208_encode.get(c);
    const pointer = if (first > 8272 and first <= 8836) shiftJisAlternate(@intCast(c)) else first;
    if (pointer == 0) return .{ .unmappable = true };
    const p = pointer - 1;
    const lead = p / 188;
    const lead_offset: u16 = if (lead < 0x1f) 0x81 else 0xc1;
    const trail = p % 188;
    const offset: u16 = if (trail < 0x3f) 0x40 else 0x41;
    return .of(2, .{ @intCast(lead + lead_offset), @intCast(trail + offset) });
}

/// index Shift_JIS pointer, plus one, for a code point whose first jis0208
/// pointer is one it excludes.
fn shiftJisAlternate(cp: u16) u16 {
    const list = &tables.shift_jis_alternates;
    var low: usize = 0;
    var high: usize = list.len;
    while (low < high) {
        const mid = (low + high) / 2;
        if (list[mid][0] < cp) low = mid + 1 else high = mid;
    }
    return list[low][1];
}

fn eucKrBytes(cp: u21) Bytes {
    if (cp < 0x80) return .of(1, .{@intCast(cp)});
    const pointer = tables.euc_kr_encode.get(cp);
    if (pointer == 0) return .{ .unmappable = true };
    const p = pointer - 1;
    return .of(2, .{ @intCast(p / 190 + 0x81), @intCast(p % 190 + 0x41) });
}

test "labels, names and a round trip" {
    try std.testing.expectEqual(Encoding.windows_1252, forLabel(" Latin1\n").?);
    try std.testing.expectEqual(Encoding.shift_jis, forLabel("sjis").?);
    try std.testing.expectEqual(@as(?Encoding, null), forLabel("cp437"));
    try std.testing.expectEqualStrings("Shift_JIS", name(.shift_jis));
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try encode(.shift_jis, "\u{65e5}\u{672c}", &w, .{});
    try std.testing.expectEqualSlices(u8, "\x93\xfa\x96\x7b", w.buffered());
    var back: [64]u8 = undefined;
    var w2: Writer = .fixed(&back);
    _ = try decode(.shift_jis, w.buffered(), &w2, .{});
    try std.testing.expectEqualStrings("\u{65e5}\u{672c}", w2.buffered());
}
