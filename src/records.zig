//! The records segmentation and measuring read, internal to xenoglyph: a
//! code point's index into the cluster records, and the record, in one
//! lookup. The root does not export this file; `properties` gives the
//! values a caller may ask for.
const classes = @import("classes.zig");
const data = @import("data.zig");
const utf8 = @import("utf8.zig");

const cluster_data = data.cluster;
const max_code_point: u21 = 0x10ffff;

/// The record segmentation and measuring read: one lookup for every
/// property of a code point the hot path needs.
pub inline fn cluster(cp: u21) classes.Cluster {
    return clusterRecord(clusterIndex(cp));
}

/// The distinct cluster records; a code point's record index is its
/// position here.
pub const cluster_records = cluster_data.records;

/// The index of a code point's record in `cluster_records`.
pub inline fn clusterIndex(cp: u21) u8 {
    if (cp > max_code_point) return default_cluster_index;
    return cluster_data.table.get(cp);
}

pub inline fn clusterRecord(index: u8) classes.Cluster {
    return @bitCast(cluster_records[index]);
}

/// The record of a value past U+10FFFF: an unassigned code point's.
const default_cluster_index: u8 = for (cluster_records, 0..) |r, i| {
    if (r == @as(u16, @bitCast(classes.Cluster{}))) break i;
} else @compileError("no record for an unassigned code point");

/// The record indexes of the ASCII code points.
pub const ascii_cluster_indexes: [128]u8 = blk: {
    @setEvalBranchQuota(10_000);
    var indexes: [128]u8 = undefined;
    for (&indexes, 0..) |*i, cp| i.* = cluster_data.table.get(cp);
    break :blk indexes;
};

/// The record index of the code point that starts `bytes` (not empty), the
/// code point, and its length.
pub inline fn read(bytes: []const u8) struct { index: u8, code_point: u21, len: u3 } {
    const lead = bytes[0];
    if (lead < 0x80) return .{ .index = ascii_cluster_indexes[lead], .code_point = lead, .len = 1 };
    const d = utf8.decode(bytes);
    return .{ .index = clusterIndex(d.code_point), .code_point = d.code_point, .len = d.len };
}

/// The record index of the code point that holds byte `end - 1` of `bytes`
/// (0 < `end` <= `bytes.len`), as decoding from the start of `bytes` reads
/// it, and where that code point starts.
pub inline fn readBefore(bytes: []const u8, end: usize) struct { index: u8, start: usize } {
    const last = bytes[end - 1];
    if (last < 0x80) return .{ .index = ascii_cluster_indexes[last], .start = end - 1 };
    const start = codePointStart(bytes, end);
    return .{ .index = clusterIndex(utf8.decode(bytes[start..]).code_point), .start = start };
}

/// Where the code point that holds byte `end - 1` starts, as decoding from
/// the start of `bytes` finds it. A byte that is not a continuation byte
/// always starts a code point, since every sequence and every maximal
/// subpart starts with one and goes on only with continuation bytes; and a
/// sequence is at most four bytes. So the start is the last such byte in
/// the four before `end` when what it starts reaches `end - 1`, and
/// otherwise `end - 1` itself, a continuation byte nothing claims.
fn codePointStart(bytes: []const u8, end: usize) usize {
    const floor = end -| 4;
    var at = end;
    while (at > floor) {
        at -= 1;
        if (bytes[at] & 0xc0 != 0x80) return if (at + utf8.decode(bytes[at..]).len >= end) at else end - 1;
    }
    return end - 1;
}

/// What the line breaking rules read of a code point, in one lookup.
pub inline fn line(cp: u21) classes.Line {
    if (cp > max_code_point) return .{};
    return @bitCast(data.wrapping.records[data.wrapping.table.get(cp)]);
}
