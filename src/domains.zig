//! The quantities xenoglyph measures, each a distinct aegis domain, so that
//! a byte offset is never taken for a column count or a cluster count, and
//! none of them for a code point (a `u21`).
const std = @import("std");
const aegis = @import("aegis");

/// A number of bytes of UTF-8 text: a length, or an offset from the start
/// of a text.
pub const Bytes = aegis.units.Bytes(usize);

/// A byte range of a text, as the iterators give them.
pub const Span = struct {
    start: Bytes,
    end: Bytes,

    /// The bytes the range covers.
    pub fn len(s: Span) Bytes {
        return s.end.sub(s.start) catch aegis.assert.never("a span ends where it starts or after");
    }

    /// The part of `text` the range covers; `text` is the text the span was
    /// taken from.
    pub fn of(s: Span, text: []const u8) []const u8 {
        return text[s.start.raw()..s.end.raw()];
    }

    /// A span from raw offsets, `start` at most `end`.
    pub fn fromRaw(start: usize, end: usize) Span {
        aegis.assert.pre(start <= end, "a span ends where it starts or after");
        return .{ .start = .fromRaw(start), .end = .fromRaw(end) };
    }
};

/// The domain of terminal cells.
pub const Cell = struct {};
/// A number of terminal columns: what text takes on a monospace grid.
pub const Columns = aegis.units.Count(Cell, usize);

/// The domain of grapheme clusters.
pub const Cluster = struct {};
/// A number of grapheme clusters.
pub const Clusters = aegis.units.Count(Cluster, usize);

test "domains do not mix" {
    const s: Span = .fromRaw(2, 5);
    try std.testing.expectEqual(3, s.len().raw());
    try std.testing.expectEqualStrings("llo", s.of("hello"));
    comptime std.debug.assert(Columns != Clusters);
    comptime std.debug.assert(Bytes != Columns);
}
