const std = @import("std");
const xenoglyph = @import("xenoglyph");

pub fn main() !void {
    // --- README:usage ---
    // A family emoji, a flag, a decomposed é and a Devanagari conjunct:
    // four clusters, whatever their code points.
    const text = "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467} \u{1f1e8}\u{1f1ed} e\u{301} \u{915}\u{94d}\u{937}";
    var clusters = xenoglyph.graphemes(text);
    var count: usize = 0;
    while (clusters.next()) |cluster| {
        // Each cluster is a slice of `text`; nothing was allocated.
        if (!std.mem.eql(u8, cluster, " ")) count += 1;
    }
    std.debug.assert(count == 4);
    // Terminal columns: each of the four is 2, 2, 1 and 2, and a space 1.
    std.debug.assert(xenoglyph.width.string(text, .{}) == 10);
    // --- README:usage ---
    words();
    properties();
    stream();
    lines();
}

fn words() void {
    // --- README:words ---
    var it = xenoglyph.words("Can't stop: 3.14 is \u{3c0}!");
    var found: [5][]const u8 = undefined;
    var n: usize = 0;
    while (it.next()) |segment| {
        // Segments include the spaces and punctuation between words.
        if (xenoglyph.word.isWordLike(segment)) {
            found[n] = segment;
            n += 1;
        }
    }
    std.debug.assert(n == 5);
    std.debug.assert(std.mem.eql(u8, found[0], "Can't"));
    std.debug.assert(std.mem.eql(u8, found[2], "3.14"));
    var sentences = xenoglyph.sentences("It works. Mr. Smith agrees? Yes.");
    std.debug.assert(std.mem.eql(u8, sentences.next().?, "It works. "));
    // --- README:words ---
}

fn properties() void {
    // --- README:properties ---
    std.debug.assert(xenoglyph.generalCategory('A') == .uppercase_letter);
    std.debug.assert(xenoglyph.script(0x3b1) == .greek);
    std.debug.assert(xenoglyph.eastAsianWidth(0x3042) == .wide);
    std.debug.assert(xenoglyph.emoji(0x1f600).presentation);
    std.debug.assert(xenoglyph.core(0x5f).xid_continue);
    std.debug.assert(xenoglyph.lineBreak(' ') == .space);
    // Code points shared by scripts list them all.
    std.debug.assert(xenoglyph.scriptExtensions(0x0964).len > 1);
    // --- README:properties ---
}

fn lines() void {
    // --- README:lines ---
    // Where a line may break, and where it must.
    const text = "A (quick) test\u{2014}costs $12.50.\nNext";
    var it = xenoglyph.lines(text);
    // A bracket stays with its word, a dash breaks on either side, a price
    // holds together, and the line feed ends a line whatever the width.
    for ([_][]const u8{ "A ", "(quick) ", "test", "\u{2014}", "costs ", "$12.50.\n" }) |want| {
        const b = it.nextBreak().?;
        std.debug.assert(std.mem.eql(u8, text[b.span.start..b.span.end], want));
        std.debug.assert(b.mandatory == (want[want.len - 1] == '\n'));
    }
    // --- README:lines ---
}

fn stream() void {
    // --- README:stream ---
    // Code points arriving one at a time, as a terminal receives them:
    // `next` says whether each starts a cluster.
    var breaker: xenoglyph.grapheme.Breaker(.terminal) = .{};
    std.debug.assert(breaker.next(0x1f44d)); // thumbs up starts one
    std.debug.assert(!breaker.next(0x1f3fd)); // its skin tone joins it
    std.debug.assert(breaker.next('a'));
    std.debug.assert(breaker.next(0x1f3fd)); // a skin tone after a letter stands alone
    // --- README:stream ---
}
