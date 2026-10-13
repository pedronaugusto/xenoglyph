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
    std.debug.assert(xenoglyph.width.string(text, .{}).eql(.fromRaw(10)));
    // --- README:usage ---
    cursor();
    words();
    properties();
    stream();
    lines();
    try transform();
}

fn cursor() void {
    // --- README:cursor ---
    // A cursor at the end of "e" and a combining acute, a flag and "x".
    const text = "e\u{301}\u{1f1e8}\u{1f1ed}x";
    var at: xenoglyph.Bytes = .fromRaw(text.len);
    // Left a cluster at a time: the text before is read only as far as the
    // rules need, never from the start of the text.
    at = xenoglyph.grapheme.boundaryBefore(text, at, .{});
    std.debug.assert(at.eql(.fromRaw(11)));
    at = xenoglyph.grapheme.boundaryBefore(text, at, .{});
    std.debug.assert(at.eql(.fromRaw(3)));
    // Right again.
    std.debug.assert(xenoglyph.grapheme.boundaryAfter(text, at, .{}).eql(.fromRaw(11)));
    // An iterator steps both ways from any boundary.
    var it: xenoglyph.grapheme.Iterator(.{}) = .initAt(text, .fromRaw(text.len));
    std.debug.assert(std.mem.eql(u8, it.prev().?, "x"));
    std.debug.assert(std.mem.eql(u8, it.prev().?, "\u{1f1e8}\u{1f1ed}"));
    std.debug.assert(std.mem.eql(u8, it.next().?, "\u{1f1e8}\u{1f1ed}"));
    // --- README:cursor ---
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

fn transform() !void {
    // --- README:transform ---
    var out: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    // "e" and a combining acute compose to "é"; "ﬁ" stays, as it is canonical.
    try xenoglyph.normalize.write(.nfc, "cafe\u{301} \u{fb01}", &w);
    std.debug.assert(std.mem.eql(u8, w.buffered(), "caf\u{e9} \u{fb01}"));
    std.debug.assert(xenoglyph.normalize.equal(.nfkc, "\u{fb01}", "fi"));
    w = .fixed(&out);
    try xenoglyph.case.write(.upper, "stra\u{df}e", &w, .{});
    std.debug.assert(std.mem.eql(u8, w.buffered(), "STRASSE"));
    std.debug.assert(xenoglyph.case.equal(.default, "Ma\u{df}e", "MASSE", .{}));
    // Canonical caseless match normalizes too; identifier caseless match
    // uses NFKC_Casefold, which also drops default ignorables (a soft hyphen).
    std.debug.assert(xenoglyph.case.equal(.canonical, "\u{212b}NGSTR\u{f6}M", "a\u{30a}ngstro\u{308}m", .{}));
    std.debug.assert(xenoglyph.case.equal(.identifier, "\u{2167}_val\u{ad}ue", "viii_VALUE", .{}));
    w = .fixed(&out);
    try xenoglyph.normalize.write(.nfkc_casefold, "\u{fb01}LE\u{2460}", &w);
    std.debug.assert(std.mem.eql(u8, w.buffered(), "file1"));
    w = .fixed(&out);
    try xenoglyph.case.write(.lower, "D\u{130}YARBAKIR", &w, .{ .language = .turkic });
    std.debug.assert(std.mem.eql(u8, w.buffered(), "diyarbak\u{131}r"));
    // --- README:transform ---
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
        std.debug.assert(std.mem.eql(u8, b.span.of(text), want));
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
