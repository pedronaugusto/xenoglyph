//! Punycode (RFC 3492): a string of code points as ASCII letters, digits
//! and hyphens, the encoding an internationalized domain label takes after
//! "xn--". Nothing allocates.
const std = @import("std");
const Writer = std.Io.Writer;

const base = 36;
const t_min = 1;
const t_max = 26;
const skew = 38;
const damp = 700;
const initial_bias = 72;
const initial_n = 0x80;
const delimiter = '-';

/// Why Punycode did not decode.
pub const DecodeError = error{
    /// Not Punycode: a byte past ASCII among the basic code points, a digit
    /// that is not one, a sequence cut short, or a value that is not a
    /// Unicode scalar value.
    Invalid,
    /// A value past what the encoding allows.
    Overflow,
    /// More code points than `out` holds.
    NoSpaceLeft,
};

/// Decodes `input` (the part after "xn--") into `out`: the code points, in
/// order. Digits are read in either case.
pub fn decode(input: []const u8, out: []u21) DecodeError![]u21 {
    // The basic code points are those before the last delimiter, if any.
    const basic_end = std.mem.findScalarLast(u8, input, delimiter) orelse 0;
    if (basic_end > out.len) return error.NoSpaceLeft;
    for (input[0..basic_end], 0..) |c, k| {
        if (c >= 0x80) return error.Invalid;
        out[k] = c;
    }
    var len: usize = basic_end;
    var n: u32 = initial_n;
    var i: u32 = 0;
    var bias: u32 = initial_bias;
    var at: usize = if (basic_end > 0) basic_end + 1 else 0;
    while (at < input.len) {
        const old_i = i;
        var w: u32 = 1;
        var k: u32 = base;
        while (true) : (k += base) {
            if (at >= input.len) return error.Invalid;
            const digit = digitValue(input[at]) orelse return error.Invalid;
            at += 1;
            i = std.math.add(u32, i, std.math.mul(u32, digit, w) catch return error.Overflow) catch return error.Overflow;
            const t = threshold(k, bias);
            if (digit < t) break;
            w = std.math.mul(u32, w, base - t) catch return error.Overflow;
        }
        const count: u32 = @intCast(len + 1);
        bias = adapt(i - old_i, count, old_i == 0);
        n = std.math.add(u32, n, i / count) catch return error.Overflow;
        i %= count;
        if (n > 0x10ffff or (n >= 0xd800 and n <= 0xdfff)) return error.Invalid;
        if (len == out.len) return error.NoSpaceLeft;
        @memmove(out[i + 1 .. len + 1], out[i..len]);
        out[i] = @intCast(n);
        len += 1;
        i += 1;
    }
    return out[0..len];
}

/// Why Punycode could not be written.
pub const EncodeError = Writer.Error || error{
    /// A value past what the encoding allows: a string far longer than any
    /// label.
    Overflow,
};

/// Writes the Punycode of `input` (without "xn--"), lower case.
pub fn encode(input: []const u21, w: *Writer) EncodeError!void {
    var basic: u32 = 0;
    for (input) |cp| if (cp < 0x80) {
        try w.writeByte(@intCast(cp));
        basic += 1;
    };
    if (basic > 0) try w.writeByte(delimiter);
    const total = std.math.cast(u32, input.len) orelse return error.Overflow;
    var handled = basic;
    var n: u32 = initial_n;
    var delta: u32 = 0;
    var bias: u32 = initial_bias;
    while (handled < total) {
        // The smallest code point not yet handled.
        var m: u32 = std.math.maxInt(u32);
        for (input) |cp| if (cp >= n and cp < m) {
            m = cp;
        };
        delta = std.math.add(u32, delta, std.math.mul(u32, m - n, handled + 1) catch return error.Overflow) catch return error.Overflow;
        n = m;
        for (input) |cp| {
            if (cp < n) delta = std.math.add(u32, delta, 1) catch return error.Overflow;
            if (cp != n) continue;
            var q = delta;
            var k: u32 = base;
            while (true) : (k += base) {
                const t = threshold(k, bias);
                if (q < t) break;
                try w.writeByte(digitChar(t + (q - t) % (base - t)));
                q = (q - t) / (base - t);
            }
            try w.writeByte(digitChar(q));
            bias = adapt(delta, handled + 1, handled == basic);
            delta = 0;
            handled += 1;
        }
        delta = std.math.add(u32, delta, 1) catch return error.Overflow;
        n = std.math.add(u32, n, 1) catch return error.Overflow;
    }
}

fn threshold(k: u32, bias: u32) u32 {
    if (k <= bias) return t_min;
    if (k >= bias + t_max) return t_max;
    return k - bias;
}

fn adapt(delta_in: u32, count: u32, first: bool) u32 {
    var delta = if (first) delta_in / damp else delta_in / 2;
    delta += delta / count;
    var k: u32 = 0;
    while (delta > ((base - t_min) * t_max) / 2) : (k += base) delta /= base - t_min;
    return k + (base - t_min + 1) * delta / (delta + skew);
}

fn digitValue(c: u8) ?u32 {
    return switch (c) {
        'a'...'z' => c - 'a',
        'A'...'Z' => c - 'A',
        '0'...'9' => c - '0' + 26,
        else => null,
    };
}

fn digitChar(d: u32) u8 {
    return @intCast(if (d < 26) 'a' + d else '0' + d - 26);
}

const testing = std.testing;

fn roundTrip(text: []const u21, encoded: []const u8) !void {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try encode(text, &w);
    try testing.expectEqualStrings(encoded, w.buffered());
    var out: [128]u21 = undefined;
    try testing.expectEqualSlices(u21, text, try decode(encoded, &out));
}

test "the samples of RFC 3492 section 7.1 encode and decode" {
    // (A) Arabic (Egyptian).
    try roundTrip(&.{ 0x0644, 0x064A, 0x0647, 0x0645, 0x0627, 0x0628, 0x062A, 0x0643, 0x0644, 0x0645, 0x0648, 0x0634, 0x0639, 0x0631, 0x0628, 0x064A, 0x061F }, "egbpdaj6bu4bxfgehfvwxn");
    // (B) Chinese (simplified).
    try roundTrip(&.{ 0x4ED6, 0x4EEC, 0x4E3A, 0x4EC0, 0x4E48, 0x4E0D, 0x8BF4, 0x4E2D, 0x6587 }, "ihqwcrb4cv8a8dqg056pqjye");
    // (L) 3<nen>B<gumi><kinpachi><sensei>: basic code points kept, in place.
    try roundTrip(&.{ '3', 0x5E74, 'B', 0x7D44, 0x91D1, 0x516B, 0x5148, 0x751F }, "3B-ww4c5e180e575a65lsy2b");
    // (S) -> $1.00 <-: all basic, ending with the delimiter.
    try roundTrip(&.{ '-', '>', ' ', '$', '1', '.', '0', '0', ' ', '<', '-' }, "-> $1.00 <--");
}

test "upper case digits decode as lower case ones" {
    var out: [16]u21 = undefined;
    try testing.expectEqualSlices(u21, &.{0xFC}, try decode("TDA", &out));
}

test "what is not Punycode is refused" {
    var out: [16]u21 = undefined;
    // A digit that says more follow, and none does.
    try testing.expectError(error.Invalid, decode("a-b", &out));
    try testing.expectError(error.Invalid, decode("\xc3\xbc-tda", &out));
    try testing.expectError(error.Invalid, decode("tda!", &out));
    try testing.expectError(error.Invalid, decode("99999999999999999", &out) catch |err| switch (err) {
        error.Overflow => error.Invalid,
        else => err,
    });
    // A value past U+10FFFF.
    try testing.expectError(error.Invalid, decode("zzzzzzzz", &out) catch |err| switch (err) {
        error.Overflow => error.Invalid,
        else => err,
    });
    try testing.expectError(error.NoSpaceLeft, decode("tda", out[0..0]));
}
