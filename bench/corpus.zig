//! The texts the benchmarks read, built the same on every run: words of
//! each kind drawn by a fixed seed and joined by spaces and punctuation
//! into 64 KiB, cut at a code point boundary.
const std = @import("std");

pub const size: usize = 64 * 1024;

pub const Kind = enum { ascii, latin, cjk, devanagari, emoji, mixed };

const ascii_words = [_][]const u8{ "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "terminal", "width", "grapheme", "cluster", "Unicode", "2026", "3.14", "can't", "e.g.", "example.com" };
// Accents both composed and decomposed.
const latin_words = [_][]const u8{ "café", "cafe\u{301}", "naïve", "Ångström", "A\u{30a}ngstro\u{308}m", "façade", "smörgåsbord", "jalapeño", "Dvořák", "Zürich" };
const cjk_words = [_][]const u8{ "日本語", "中文", "漢字", "東京", "한국어", "가나다", "テキスト", "ひらがな", "全角", "文字幅" };
const devanagari_words = [_][]const u8{ "हिन्दी", "क्षत्रिय", "संस्कृत", "नमस्ते", "विद्यार्थी", "ज्ञान", "श्री", "द्वार" };
const emoji_words = [_][]const u8{ "\u{1f600}", "\u{1f44b}\u{1f3fd}", "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}\u{200d}\u{1f466}", "\u{1f1fa}\u{1f1f8}", "\u{1f1ef}\u{1f1f5}", "\u{2764}\u{fe0f}", "1\u{fe0f}\u{20e3}", "\u{1f3f3}\u{fe0f}\u{200d}\u{1f308}", "\u{1f9d1}\u{1f3fb}\u{200d}\u{1f4bb}", "\u{263a}" };
const separators = [_][]const u8{ " ", " ", " ", " ", ", ", ". ", "? ", "\n", "! " };

fn wordsOf(kind: Kind, r: std.Random) []const []const u8 {
    return switch (kind) {
        .ascii => &ascii_words,
        .latin => &latin_words,
        .cjk => &cjk_words,
        .devanagari => &devanagari_words,
        .emoji => &emoji_words,
        .mixed => switch (r.uintLessThan(u8, 10)) {
            0...4 => &ascii_words,
            5 => &latin_words,
            6 => &cjk_words,
            7 => &devanagari_words,
            else => &emoji_words,
        },
    };
}

/// A text of `kind`, about `size` bytes.
pub fn build(gpa: std.mem.Allocator, kind: Kind) ![]u8 {
    var prng: std.Random.DefaultPrng = .init(0x9e3779b97f4a7c15 +% @as(u64, @backingInt(kind)));
    const r = prng.random();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    while (out.items.len < size) {
        const words = wordsOf(kind, r);
        try out.appendSlice(gpa, words[r.uintLessThan(usize, words.len)]);
        try out.appendSlice(gpa, separators[r.uintLessThan(usize, separators.len)]);
    }
    var end: usize = size;
    while (end < out.items.len and end > 0 and out.items[end] & 0xc0 == 0x80) end -= 1;
    out.shrinkRetainingCapacity(end);
    return out.toOwnedSlice(gpa);
}
