//! What a project that depends on xenoglyph writes, built by `zig build
//! check-consumer` with fetching off: the package builds and runs with
//! nothing of its development present.
const std = @import("std");
const xenoglyph = @import("xenoglyph");

pub fn main() !void {
    if (xenoglyph.grapheme.count("e\u{301}\u{1f1e8}\u{1f1ed}", .{}) != 2) return error.Graphemes;
    if (xenoglyph.width.string("日本", .{}) != 4) return error.Width;
    if (xenoglyph.generalCategory('a') != .lowercase_letter) return error.Properties;
    var words = xenoglyph.words("one two");
    if (!std.mem.eql(u8, words.next().?, "one")) return error.Words;
}
