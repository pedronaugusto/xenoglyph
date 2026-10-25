//! Every public call builds for wasm32-freestanding in `zig build
//! check-freestanding`: xenoglyph needs no OS and no allocator.
const std = @import("std");
const xenoglyph = @import("xenoglyph");

export fn xenoglyphGraphemes(text: [*]const u8, len: usize) usize {
    const both = xenoglyph.grapheme.count(text[0..len], .{}).add(xenoglyph.grapheme.count(text[0..len], .terminal)) catch return 0;
    return both.raw();
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
    const both = xenoglyph.width.string(text[0..len], .{}).add(xenoglyph.width.string(text[0..len], .{ .method = .codepoint, .ambiguous = .wide })) catch return 0;
    return both.raw();
}

export fn xenoglyphBackward(text: [*]const u8, len: usize) usize {
    if (len == 0) return 0;
    var it: xenoglyph.grapheme.Iterator(.terminal) = .initAt(text[0..len], .fromRaw(len));
    var n: usize = 0;
    while (it.prevSpan()) |_| n += 1;
    const before = xenoglyph.grapheme.boundaryBefore(text[0..len], .fromRaw(len), .{});
    if (!xenoglyph.grapheme.boundaryAfter(text[0..len], before, .{}).eql(.fromRaw(len))) return 0;
    return n;
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
        @as(u32, @intCast(xenoglyph.scriptExtensions(c).len));
}

export fn xenoglyphColumns(cp: u32) usize {
    return xenoglyph.width.codepoint(@truncate(cp), .{}).raw();
}

export fn xenoglyphLines(text: [*]const u8, len: usize) usize {
    var it = xenoglyph.lines(text[0..len]);
    var n: usize = 0;
    while (it.nextBreak()) |b| n += @intFromBool(b.mandatory);
    return n;
}

export fn xenoglyphNormalize(text: [*]const u8, len: usize, out: [*]u8, out_len: usize) isize {
    var w: std.Io.Writer = .fixed(out[0..out_len]);
    xenoglyph.normalize.write(.nfc, text[0..len], &w) catch return -1;
    xenoglyph.normalize.write(.nfkd, text[0..len], &w) catch return -1;
    xenoglyph.normalize.write(.nfkc_casefold, text[0..len], &w) catch return -1;
    if (!xenoglyph.normalize.isNormalized(.nfd, text[0..len])) return -2;
    return @intCast(w.buffered().len);
}

export fn xenoglyphCase(text: [*]const u8, len: usize, out: [*]u8, out_len: usize) isize {
    var w: std.Io.Writer = .fixed(out[0..out_len]);
    inline for (.{ .lower, .upper, .title, .fold }) |mapping| {
        xenoglyph.case.write(mapping, text[0..len], &w, .{ .language = .turkic }) catch return -1;
    }
    if (xenoglyph.case.equal(.default, text[0..len], "x", .{})) return -2;
    if (xenoglyph.case.equal(.canonical, text[0..len], "x", .{})) return -3;
    if (xenoglyph.case.equal(.identifier, text[0..len], "x", .{})) return -4;
    return @intCast(w.buffered().len);
}

export fn xenoglyphBidi(text: [*]const u8, len: usize, levels: [*]xenoglyph.bidi.Level, scratch: [*]xenoglyph.bidi.Scratch, runs: [*]xenoglyph.bidi.Run) usize {
    const bytes = text[0..len];
    const p: xenoglyph.bidi.Paragraph = .resolve(bytes, .fromRaw(0), .{}, .{ .levels = levels[0..len], .scratch = scratch[0..len] });
    const l = p.line(p.span, runs[0..len]);
    var it = l.visual();
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n + @intFromBool(xenoglyph.bidi.mirror('(') != null) + @intFromBool(xenoglyph.bidi.pairedBracket('[') != null);
}
