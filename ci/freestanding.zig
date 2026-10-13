//! Every public call builds for wasm32-freestanding in `zig build
//! check-freestanding`: xenoglyph needs no OS and no allocator.
const xenoglyph = @import("xenoglyph");

export fn xenoglyphGraphemes(text: [*]const u8, len: usize) usize {
    return xenoglyph.grapheme.count(text[0..len], .{}) + xenoglyph.grapheme.count(text[0..len], .terminal);
}

export fn xenoglyphWords(text: [*]const u8, len: usize) usize {
    var it = xenoglyph.words(text[0..len]);
    var n: usize = 0;
    while (it.next()) |w| n += @intFromBool(xenoglyph.word.isWordLike(w));
    return n;
}

export fn xenoglyphSentences(text: [*]const u8, len: usize) usize {
    var it = xenoglyph.sentences(text[0..len]);
    var n: usize = 0;
    while (it.nextSpan()) |_| n += 1;
    return n;
}

export fn xenoglyphWidth(text: [*]const u8, len: usize) usize {
    return xenoglyph.width.string(text[0..len], .{}) + xenoglyph.width.string(text[0..len], .{ .method = .codepoint, .ambiguous = .wide });
}

export fn xenoglyphStream(cp: u32) bool {
    var b: xenoglyph.grapheme.Breaker(.{}) = .{};
    return b.next(@truncate(cp));
}

export fn xenoglyphProperties(cp: u32) u32 {
    const c: u21 = @truncate(cp);
    return @as(u32, @backingInt(xenoglyph.generalCategory(c))) +
        @backingInt(xenoglyph.eastAsianWidth(c)) +
        @backingInt(xenoglyph.graphemeBreak(c)) +
        @backingInt(xenoglyph.indicConjunctBreak(c)) +
        @backingInt(xenoglyph.wordBreak(c)) +
        @backingInt(xenoglyph.sentenceBreak(c)) +
        @backingInt(xenoglyph.lineBreak(c)) +
        @backingInt(xenoglyph.script(c)) +
        @as(u8, @bitCast(xenoglyph.emoji(c))) +
        @as(u32, @bitCast(xenoglyph.core(c))) +
        @as(u32, @intCast(xenoglyph.scriptExtensions(c).len)) +
        xenoglyph.width.codepoint(c, .{});
}
