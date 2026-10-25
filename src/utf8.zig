//! Decoding UTF-8 the way a terminal or an editor must: any bytes at all,
//! with each maximal subpart of an ill-formed sequence read as one U+FFFD
//! that consumes only its own bytes (the Unicode Standard's "substitution of
//! maximal subparts", chapter 3.9). A byte that ends an ill-formed sequence
//! by not continuing it is where the next code point starts, so
//! `"\xe4\xb8a"` is U+FFFD then `a`.
const std = @import("std");
const domains = @import("domains.zig");

/// U+FFFD REPLACEMENT CHARACTER, what an ill-formed subpart decodes to.
pub const replacement: u21 = 0xfffd;

/// One code point and the bytes it took.
pub const Decoded = struct {
    code_point: u21,
    /// 1 to 4; an ill-formed subpart takes 1 to 3.
    len: u3,
};

/// The code point that starts `bytes`, which must not be empty.
pub inline fn decode(bytes: []const u8) Decoded {
    const lead = bytes[0];
    if (lead < 0x80) return .{ .code_point = lead, .len = 1 };
    return decodeMultibyte(bytes);
}

/// How many bytes follow a lead byte, and the range the first of them must
/// be in: the ranges past the lead rule out overlong forms, surrogates and
/// values past U+10FFFF.
const Shape = struct { more: u2, low: u8, high: u8 };

fn shapeOf(lead: u8) ?Shape {
    return switch (lead) {
        0xc2...0xdf => .{ .more = 1, .low = 0x80, .high = 0xbf },
        0xe0 => .{ .more = 2, .low = 0xa0, .high = 0xbf },
        0xe1...0xec, 0xee, 0xef => .{ .more = 2, .low = 0x80, .high = 0xbf },
        0xed => .{ .more = 2, .low = 0x80, .high = 0x9f },
        0xf0 => .{ .more = 3, .low = 0x90, .high = 0xbf },
        0xf1...0xf3 => .{ .more = 3, .low = 0x80, .high = 0xbf },
        0xf4 => .{ .more = 3, .low = 0x80, .high = 0x8f },
        else => null,
    };
}

fn decodeMultibyte(bytes: []const u8) Decoded {
    const lead = bytes[0];
    const shape = shapeOf(lead) orelse return .{ .code_point = replacement, .len = 1 };
    // The well-formed case, straight through; any shortfall is found below.
    if (bytes.len > shape.more) {
        const b1 = bytes[1];
        if (b1 >= shape.low and b1 <= shape.high) switch (shape.more) {
            1 => return .{ .code_point = (@as(u21, lead & 0x1f) << 6) | (b1 & 0x3f), .len = 2 },
            2 => if (bytes[2] & 0xc0 == 0x80) return .{
                .code_point = (@as(u21, lead & 0x0f) << 12) | (@as(u21, b1 & 0x3f) << 6) | (bytes[2] & 0x3f),
                .len = 3,
            },
            3 => if (bytes[2] & 0xc0 == 0x80 and bytes[3] & 0xc0 == 0x80) return .{
                .code_point = (@as(u21, lead & 0x07) << 18) | (@as(u21, b1 & 0x3f) << 12) | (@as(u21, bytes[2] & 0x3f) << 6) | (bytes[3] & 0x3f),
                .len = 4,
            },
            else => unreachable, // unreachable: a lead takes one to three more bytes
        };
    }
    // Ill-formed: the maximal subpart is the lead and the continuation
    // bytes that still fit, the first in its narrowed range.
    var k: u3 = 1;
    while (k <= shape.more) : (k += 1) {
        if (k >= bytes.len) break;
        const b = bytes[k];
        const low: u8 = if (k == 1) shape.low else 0x80;
        const high: u8 = if (k == 1) shape.high else 0xbf;
        if (b < low or b > high) break;
    }
    return .{ .code_point = replacement, .len = k };
}

/// How many bytes `bytes` starts with that are well-formed UTF-8: whole
/// code points, up to the first ill-formed or unfinished sequence.
pub fn wellFormed(bytes: []const u8) usize {
    // Sixteen bytes at a time, each checked against the three before it: a
    // continuation byte exactly where a lead calls for one, no byte that is
    // never in UTF-8, and the second bytes E0, ED, F0 and F4 narrow. A chunk
    // that fails, and the end, are finished one sequence at a time from the
    // last code point boundary before them.
    const V = @Vector(16, u8);
    const B = @Vector(16, bool);
    var prev: V = @splat(0);
    var i: usize = 0;
    while (i + 16 <= bytes.len) : (i += 16) {
        const v: V = bytes[i..][0..16].*;
        const prev1 = @shuffle(u8, prev, v, shifted(1));
        if (@reduce(.Or, v) < 0x80) {
            // ASCII, after nothing unfinished.
            const prev2 = @shuffle(u8, prev, v, shifted(2));
            const prev3 = @shuffle(u8, prev, v, shifted(3));
            if (prev1[0] < 0xc0 and prev2[0] < 0xe0 and prev3[0] < 0xf0) {
                prev = v;
                continue;
            }
            break;
        }
        const prev2 = @shuffle(u8, prev, v, shifted(2));
        const prev3 = @shuffle(u8, prev, v, shifted(3));
        const splat = struct {
            inline fn of(x: u8) V {
                return @splat(x);
            }
        }.of;
        const continuation = v & splat(0xc0) == splat(0x80);
        const wanted = or3(prev1 >= splat(0xc0), prev2 >= splat(0xe0), prev3 >= splat(0xf0));
        const never = or2(v == splat(0xc0), v == splat(0xc1)) | (v >= splat(0xf5));
        const narrow = or3(
            and2(prev1 == splat(0xe0), v < splat(0xa0)),
            and2(prev1 == splat(0xed), v > splat(0x9f)),
            or2(and2(prev1 == splat(0xf0), v < splat(0x90)), and2(prev1 == splat(0xf4), v > splat(0x8f))),
        );
        const bad: B = (continuation != wanted) | never | narrow;
        if (@reduce(.Or, bad)) break;
        prev = v;
    }
    // Back to the start of a sequence the chunks left unfinished.
    var k = i;
    var back: usize = 1;
    while (back <= 3 and back <= i) : (back += 1) {
        const lead = bytes[i - back];
        if (lead & 0xc0 == 0x80) continue;
        if (lead >= 0xc0) k = i - back;
        break;
    }
    return k + wellFormedScalar(bytes[k..]);
}

inline fn or2(a: @Vector(16, bool), b: @Vector(16, bool)) @Vector(16, bool) {
    return @select(bool, a, a, b);
}

inline fn or3(a: @Vector(16, bool), b: @Vector(16, bool), c: @Vector(16, bool)) @Vector(16, bool) {
    return or2(or2(a, b), c);
}

inline fn and2(a: @Vector(16, bool), b: @Vector(16, bool)) @Vector(16, bool) {
    return @select(bool, a, b, a);
}

/// The `@shuffle` mask that gives each byte of a chunk the byte `n` before
/// it, from the chunk before where it starts.
fn shifted(comptime n: usize) @Vector(16, i32) {
    var mask: [16]i32 = undefined;
    for (&mask, 0..) |*m, j| m.* = if (j < n) @intCast(16 - n + j) else ~@as(i32, @intCast(j - n));
    return mask;
}

fn wellFormedScalar(bytes: []const u8) usize {
    var i: usize = 0;
    while (i < bytes.len) {
        const lead = bytes[i];
        if (lead < 0x80) {
            i += 1;
            continue;
        }
        const shape = shapeOf(lead) orelse return i;
        if (bytes.len - i <= shape.more) return i;
        const b1 = bytes[i + 1];
        if (b1 < shape.low or b1 > shape.high) return i;
        if (shape.more >= 2 and bytes[i + 2] & 0xc0 != 0x80) return i;
        if (shape.more == 3 and bytes[i + 3] & 0xc0 != 0x80) return i;
        i += @as(usize, shape.more) + 1;
    }
    return i;
}

/// The code points of a string, decoded as `decode` does.
pub const Iterator = struct {
    bytes: []const u8,
    /// Private: where the next code point starts; `offset` reads it.
    index: usize = 0,

    pub fn init(bytes: []const u8) Iterator {
        return .{ .bytes = bytes };
    }

    /// Where the next code point starts.
    pub fn offset(it: *const Iterator) domains.Bytes {
        return .fromRaw(it.index);
    }

    /// The next code point, or null at the end.
    pub fn next(it: *Iterator) ?u21 {
        if (it.index >= it.bytes.len) return null;
        const d = decode(it.bytes[it.index..]);
        it.index += d.len;
        return d.code_point;
    }
};

/// Whether `bytes` is entirely printable ASCII (U+0020 to U+007E), which
/// every algorithm here reads one byte a code point, a cluster and a column.
pub fn printableAscii(bytes: []const u8) bool {
    const V = @Vector(16, u8);
    var i: usize = 0;
    while (i + 16 <= bytes.len) : (i += 16) {
        const v: V = bytes[i..][0..16].*;
        const low = v < @as(V, @splat(0x20));
        const high = v > @as(V, @splat(0x7e));
        if (@reduce(.Or, low) or @reduce(.Or, high)) return false;
    }
    for (bytes[i..]) |b| if (b < 0x20 or b > 0x7e) return false;
    return true;
}

/// Writes the code points an iterator gives (anything with `next() ?u21`)
/// as UTF-8, a buffer at a time.
pub fn encode(it: anytype, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var buffer: [256]u8 = undefined;
    var len: usize = 0;
    while (it.next()) |cp| {
        if (len + 4 > buffer.len) {
            try w.writeAll(buffer[0..len]);
            len = 0;
        }
        len += std.unicode.utf8Encode(cp, buffer[len..]) catch unreachable; // unreachable: the iterators give scalar values
    }
    try w.writeAll(buffer[0..len]);
}
