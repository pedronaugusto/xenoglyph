//! IDNA2008 (RFC 5890 to 5893) without mapping: the derived property table
//! against IANA's, JSON-Schema-Test-Suite's idn-hostname cases, each rule of
//! RFC 5892 Appendix A, and a fuzz of `check2008`.
const std = @import("std");
const ucd = @import("ucd");
const shakedown = @import("shakedown");
const idna = @import("../idna.zig");
const classes = @import("../classes.zig");

const testing = std.testing;

// IANA's newest table is for Unicode 12.0.0; derived from 18.0.0, every code
// point it assigns a value keeps that value, so the comparison admits no
// exception.
test "the derived properties agree with IANA's table for Unicode 12.0.0 wherever it assigns one" {
    var lines = std.mem.splitScalar(u8, ucd.iana_idna_properties, '\n');
    _ = lines.next(); // the header
    var compared: usize = 0;
    var differ: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ',');
        const range = fields.next().?;
        const property = fields.next().?;
        if (std.mem.eql(u8, property, "UNASSIGNED")) continue;
        const want: classes.Idna2008 = if (std.mem.eql(u8, property, "PVALID"))
            .pvalid
        else if (std.mem.eql(u8, property, "CONTEXTJ"))
            .contextj
        else if (std.mem.eql(u8, property, "CONTEXTO"))
            .contexto
        else if (std.mem.eql(u8, property, "DISALLOWED"))
            .disallowed
        else
            return error.UnknownProperty;
        const dash = std.mem.findScalar(u8, range, '-');
        const first = try std.fmt.parseInt(u21, if (dash) |d| range[0..d] else range, 16);
        const last = if (dash) |d| try std.fmt.parseInt(u21, range[d + 1 ..], 16) else first;
        var cp = first;
        while (cp <= last) : (cp += 1) {
            compared += 1;
            const got = idna.status2008(cp);
            if (got == want) continue;
            differ += 1;
            if (differ <= 40) std.debug.print("U+{X:0>4}: IANA {t}, derived {t}\n", .{ cp, want, got });
        }
    }
    try testing.expectEqual(@as(usize, 0), differ);
    try testing.expect(compared > 100_000);
}

test "JSON-Schema-Test-Suite's idn-hostname cases" {
    const Case = struct { description: []const u8, data: std.json.Value, valid: bool };
    const Group = struct { description: []const u8, schema: std.json.Value, tests: []const Case };
    const parsed = try std.json.parseFromSlice([]const Group, testing.allocator, ucd.json_schema_idn_hostname, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var checked: usize = 0;
    for (parsed.value) |group| for (group.tests) |case| {
        const text = switch (case.data) {
            .string => |s| s,
            else => continue,
        };
        const failures = try idna.check2008(text);
        testing.expectEqual(case.valid, !failures.any()) catch |err| {
            std.debug.print("{s}: {s} ({any})\n", .{ case.description, text, failures });
            return err;
        };
        checked += 1;
    };
    try testing.expectEqual(@as(usize, 50), checked);
}

fn expectValid(name: []const u8) !void {
    const f = try idna.check2008(name);
    testing.expect(!f.any()) catch |err| {
        std.debug.print("refused: {s} {any}\n", .{ name, f });
        return err;
    };
}

fn expectFails(name: []const u8, comptime field: []const u8) !void {
    const f = try idna.check2008(name);
    testing.expect(@field(f, field)) catch |err| {
        std.debug.print("{s}: wanted {s}, got {any}\n", .{ name, field, f });
        return err;
    };
}

test "RFC 5892's exceptions and categories, each as the table holds it" {
    // F: the exceptions, whatever their properties.
    for ([_]u21{ 0x00df, 0x03c2, 0x06fd, 0x06fe, 0x0f0b, 0x3007 }) |cp| try testing.expectEqual(classes.Idna2008.pvalid, idna.status2008(cp));
    for ([_]u21{ 0x00b7, 0x0375, 0x05f3, 0x05f4, 0x30fb, 0x0660, 0x0669, 0x06f0, 0x06f9 }) |cp| try testing.expectEqual(classes.Idna2008.contexto, idna.status2008(cp));
    for ([_]u21{ 0x0640, 0x07fa, 0x302e, 0x302f, 0x3031, 0x3035, 0x303b }) |cp| try testing.expectEqual(classes.Idna2008.disallowed, idna.status2008(cp));
    // E, LDH, and the rest of ASCII; H, JoinControl; B, Unstable (capitals
    // fold); C, IgnorableProperties; D, IgnorableBlocks; I, OldHangulJamo;
    // J, Unassigned (a noncharacter is DISALLOWED, not UNASSIGNED).
    for ("-09az") |c| try testing.expectEqual(classes.Idna2008.pvalid, idna.status2008(c));
    for ("AZ_.: ~") |c| try testing.expectEqual(classes.Idna2008.disallowed, idna.status2008(c));
    try testing.expectEqual(classes.Idna2008.contextj, idna.status2008(0x200c));
    try testing.expectEqual(classes.Idna2008.contextj, idna.status2008(0x200d));
    try testing.expectEqual(classes.Idna2008.disallowed, idna.status2008(0x00c0));
    try testing.expectEqual(classes.Idna2008.disallowed, idna.status2008(0x00ad));
    try testing.expectEqual(classes.Idna2008.disallowed, idna.status2008(0x20d0));
    try testing.expectEqual(classes.Idna2008.disallowed, idna.status2008(0x1d165));
    try testing.expectEqual(classes.Idna2008.disallowed, idna.status2008(0x1100));
    try testing.expectEqual(classes.Idna2008.pvalid, idna.status2008(0xac00));
    try testing.expectEqual(classes.Idna2008.disallowed, idna.status2008(0xfdd0));
    try testing.expectEqual(classes.Idna2008.unassigned, idna.status2008(0x0378));
    try testing.expectEqual(classes.Idna2008.pvalid, idna.status2008(0x00e9));
    try testing.expectEqual(classes.Idna2008.pvalid, idna.status2008(0x4e2d));
}

test "each ContextJ and ContextO rule, held and broken" {
    // A.1 and A.2: a joiner after a virama, a non-joiner between joining letters.
    try expectValid("\u{915}\u{94d}\u{200d}\u{937}");
    try expectFails("\u{915}\u{200d}\u{937}", "context");
    try expectValid("\u{628}\u{64a}\u{200c}\u{628}\u{64a}");
    try expectFails("a\u{200c}b", "context");
    // A.3: MIDDLE DOT between two l.
    try expectValid("l\u{b7}l");
    try expectFails("l\u{b7}a", "context");
    // A.4: KERAIA before Greek.
    try expectValid("\u{3b1}\u{375}\u{3b2}");
    try expectFails("\u{3b1}\u{375}a", "context");
    // A.5 and A.6: GERESH and GERSHAYIM after Hebrew.
    try expectValid("\u{5d0}\u{5f3}\u{5d1}");
    try expectValid("\u{5d0}\u{5f4}\u{5d1}");
    try expectFails("a\u{5f3}\u{5d1}", "context");
    // A.7: KATAKANA MIDDLE DOT with Hiragana, Katakana or Han in the label.
    try expectValid("\u{30fb}\u{3041}");
    try expectFails("abc\u{30fb}def", "context");
    // A.8 and A.9: the two Arabic digit sets unmixed.
    try expectValid("\u{628}\u{660}\u{628}");
    try expectFails("\u{660}\u{6f0}", "context");
}

test "a label's form: hyphens, marks, NFC, A-labels and lengths" {
    try expectValid("example.com");
    try expectValid("example.com.");
    try expectValid("b\u{fc}cher.example");
    try expectValid("xn--bcher-kva.example");
    try expectValid("XN--BCHER-KVA.example");
    try expectFails("ab--c", "hyphens");
    try expectFails("-ab", "hyphens");
    try expectFails("ab-", "hyphens");
    try expectFails("\u{301}a", "leading_mark");
    try expectFails("bu\u{308}cher", "not_normalized");
    try expectFails("B\u{fc}cher", "disallowed");
    try expectFails("xn--X", "punycode");
    try expectFails("xn--abc-", "punycode");
    try expectFails("a..b", "length");
    try expectFails("", "length");
    try expectFails(".", "length");
    const label64: [64]u8 = @splat('a');
    try expectFails(&label64, "length");
    try expectValid(label64[0..63]);
    // Four labels of 63 and their dots: 255 bytes, past 253.
    var long: [256]u8 = @splat('a');
    for ([_]usize{ 63, 127, 191, 255 }) |i| long[i] = '.';
    try expectFails(&long, "length");
    try expectFails("\x80", "disallowed");
    // A Bidi domain name: every label keeps the Bidi rule.
    try expectValid("\u{5d0}\u{5d1}.example");
    try expectFails("\u{5d0}a.example", "bidi");
}

test "fuzz: check2008 refuses or accepts any bytes, and an accepted name's A-label form is accepted" {
    const seeds = [_][]const u8{ "b\u{fc}cher.example", "xn--bcher-kva.example", "l\u{b7}l", "\u{5d0}\u{5f3}\u{5d1}", "\u{915}\u{94d}\u{200d}\u{937}", "\u{30fb}\u{3041}.jp" };
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var buffer: [96]u8 = undefined;
            const s = if (shakedown.gen.boolean(case.source)) shakedown.gen.mutated(case.source, &buffer, &seeds) else shakedown.gen.bytesInto(case.source, buffer[0..shakedown.gen.intRange(case.source, usize, 0, buffer.len)]);
            const f = idna.check2008(s) catch return;
            if (f.any()) return;
            // Each label as its A-label, checked again.
            var ace_buffer: [512]u8 = undefined;
            var w: std.Io.Writer = .fixed(&ace_buffer);
            var labels = std.mem.splitScalar(u8, s, '.');
            var first = true;
            while (labels.next()) |label| {
                if (!first) try w.writeByte('.');
                first = false;
                var cps: [96]u21 = undefined;
                var n: usize = 0;
                var view = (try std.unicode.Utf8View.init(label)).iterator();
                var non_ascii = false;
                while (view.nextCodepoint()) |cp| : (n += 1) {
                    cps[n] = cp;
                    if (cp >= 0x80) non_ascii = true;
                }
                if (!non_ascii) {
                    try w.writeAll(label);
                    continue;
                }
                try w.writeAll("xn--");
                try idna.punycode.encode(cps[0..n], &w);
            }
            const again = try idna.check2008(w.buffered());
            testing.expect(!again.any()) catch |err| {
                std.debug.print("{s} accepted, its A-label form {s} refused: {any}\n", .{ s, w.buffered(), again });
                return err;
            };
        }
    }.one, .{ .cases = 5000, .seed = 0x5892 });
}
