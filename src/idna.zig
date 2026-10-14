//! Internationalized domain names as UTS #46 processes them, with
//! Nontransitional Processing: `toAscii` gives the name DNS looks up
//! (`Bücher.de` is `xn--bcher-kva.de`), `toUnicode` the name to show. Each
//! maps the name through the IDNA Mapping Table, normalizes it to NFC,
//! decodes its Punycode labels and checks every label (hyphens, combining
//! marks, the Bidi rule of RFC 5893, the ContextJ rules of RFC 5892), and
//! says what failed. Nothing allocates: a name is worked on in buffers on
//! the stack, up to `max_code_points`.
const std = @import("std");
const Writer = std.Io.Writer;
const classes = @import("classes.zig");
const data = @import("data.zig");
const normalize = @import("normalize.zig");
const utf8 = @import("utf8.zig");
pub const punycode = @import("punycode.zig");

const Status = classes.IdnaStatus;
const Bidi = classes.BidiClass;
const Joining = classes.JoiningType;

/// The most code points a name may have once mapped and normalized: past
/// any name DNS holds (253 bytes), so a name past it is refused whole
/// (`error.NameTooLong`).
pub const max_code_points = 1024;

/// The processing flags of UTS #46. The defaults are its conformance
/// settings, the strict ones; `url` is the WHATWG URL Standard's.
pub const Options = struct {
    /// UseSTD3ASCIIRules: the ASCII in a label only `a`-`z`, `0`-`9` and
    /// `-`, and no empty label but a trailing root label.
    std3_rules: bool = true,
    /// CheckHyphens: no label with `-` at either end, or in its third and
    /// fourth positions.
    check_hyphens: bool = true,
    /// CheckBidi: in a name with right-to-left text, every label keeps the
    /// Bidi rule (RFC 5893).
    check_bidi: bool = true,
    /// CheckJoiners: ZERO WIDTH (NON-)JOINER only where the ContextJ rules
    /// (RFC 5892 Appendix A) allow it.
    check_joiners: bool = true,
    /// VerifyDnsLength, for `toAscii`: the name 1 to 253 bytes, each label 1
    /// to 63, and no empty root label (no trailing dot).
    verify_dns_length: bool = true,
    /// IgnoreInvalidPunycode: a label after `xn--` that does not decode is
    /// kept as it is, no failure.
    ignore_invalid_punycode: bool = false,

    /// The URL Standard's "domain to ASCII" (with beStrict false): no STD3
    /// rules, no hyphen checks and no DNS lengths.
    pub const url: Options = .{ .std3_rules = false, .check_hyphens = false, .verify_dns_length = false };
};

/// What failed in a name. Any failure fails `toAscii`; `toUnicode` writes
/// the name all the same.
pub const Failures = packed struct(u16) {
    /// A code point the IDNA Mapping Table disallows (ill-formed UTF-8
    /// among them), or one it maps or ignores in a label that came as
    /// Punycode.
    disallowed: bool = false,
    /// UseSTD3ASCIIRules: ASCII other than `a`-`z`, `0`-`9` and `-`, or an
    /// empty label other than a trailing root label.
    std3: bool = false,
    /// CheckHyphens: `-` at either end of a label, or in its third and
    /// fourth positions.
    hyphens: bool = false,
    /// Without CheckHyphens: a label from Punycode that begins `xn--`.
    xn_prefix: bool = false,
    /// A label that begins with a combining mark.
    leading_mark: bool = false,
    /// A label from Punycode that is not in NFC, or holds a full stop.
    not_normalized: bool = false,
    /// A label after `xn--` that is not ASCII, does not decode, or decodes
    /// to nothing or to ASCII alone.
    punycode: bool = false,
    /// CheckBidi: a label breaks the Bidi rule.
    bidi: bool = false,
    /// CheckJoiners: a ZERO WIDTH (NON-)JOINER the ContextJ rules refuse.
    joiners: bool = false,
    /// VerifyDnsLength: an empty label, one past 63 bytes, or a name past
    /// 253.
    dns_length: bool = false,
    _: u6 = 0,

    /// Whether anything failed.
    pub fn any(f: Failures) bool {
        return @as(u16, @bitCast(f)) != 0;
    }
};

pub const Error = Writer.Error || error{
    /// Past `max_code_points` once mapped, or past what the ASCII form
    /// holds: no DNS name is near it.
    NameTooLong,
};

/// UTS #46 ToASCII: the name as DNS looks it up, written to `w` when
/// nothing failed; what failed otherwise, and nothing written.
pub fn toAscii(name: []const u8, w: *Writer, options: Options) Error!Failures {
    var work: Work = undefined;
    var failures = try work.process(name, options);
    var buffer: [max_code_points * 4]u8 = undefined;
    var out: Writer = .fixed(&buffer);
    var labels = work.labels();
    var first = true;
    while (labels.next()) |label| {
        if (!first) out.writeByte('.') catch return error.NameTooLong;
        first = false;
        const start = out.end;
        if (ascii(label.code_points)) {
            for (label.code_points) |cp| out.writeByte(@intCast(cp)) catch return error.NameTooLong;
        } else {
            out.writeAll("xn--") catch return error.NameTooLong;
            punycode.encode(label.code_points, &out) catch |err| switch (err) {
                error.WriteFailed => return error.NameTooLong,
                error.Overflow => failures.punycode = true,
            };
        }
        if (options.verify_dns_length) {
            const len = out.end - start;
            if (len == 0 or len > 63) failures.dns_length = true;
        }
    }
    if (options.verify_dns_length and (out.end == 0 or out.end > 253)) failures.dns_length = true;
    if (failures.any()) return failures;
    try w.writeAll(out.buffered());
    return failures;
}

/// UTS #46 ToUnicode: the name to show, always written to `w`, and what
/// failed. A label after `xn--` that did not decode is written as it came.
pub fn toUnicode(name: []const u8, w: *Writer, options: Options) Error!Failures {
    var work: Work = undefined;
    var opts = options;
    opts.verify_dns_length = false;
    const failures = try work.process(name, opts);
    var labels = work.labels();
    var first = true;
    while (labels.next()) |label| {
        if (!first) try w.writeByte('.');
        first = false;
        for (label.code_points) |cp| {
            var bytes: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &bytes) catch unreachable; // unreachable: every code point here is a scalar value
            try w.writeAll(bytes[0..n]);
        }
    }
    return failures;
}

const Label = struct { code_points: []const u21 };

/// A name being processed: its code points, labels separated by `.`.
const Work = struct {
    code_points: [max_code_points]u21,
    len: usize,

    const LabelIterator = struct {
        rest: ?[]const u21,

        fn next(it: *LabelIterator) ?Label {
            const rest = it.rest orelse return null;
            if (std.mem.findScalar(u21, rest, '.')) |dot| {
                it.rest = rest[dot + 1 ..];
                return .{ .code_points = rest[0..dot] };
            }
            it.rest = null;
            return .{ .code_points = rest };
        }
    };

    fn labels(work: *const Work) LabelIterator {
        return .{ .rest = work.code_points[0..work.len] };
    }

    /// UTS #46 §4: map, normalize, break into labels, convert and
    /// validate. Leaves the processed name in `code_points`.
    fn process(work: *Work, name: []const u8, options: Options) error{NameTooLong}!Failures {
        var failures: Failures = .{};
        // Map, as UTF-8.
        var mapped_bytes: [max_code_points * 4]u8 = undefined;
        var mapped: Writer = .fixed(&mapped_bytes);
        var at: usize = 0;
        while (at < name.len) {
            const d = utf8.decode(name[at..]);
            at += d.len;
            const cp = d.code_point;
            switch (record(cp).status) {
                .ignored => {},
                .mapped => for (mapping(cp)) |m| writeCodePoint(&mapped, m) catch return error.NameTooLong,
                .valid, .deviation, .disallowed => writeCodePoint(&mapped, cp) catch return error.NameTooLong,
            }
        }
        // Normalize to NFC, then to code points.
        var normal_bytes: [max_code_points * 4]u8 = undefined;
        var normal: Writer = .fixed(&normal_bytes);
        normalize.write(.nfc, mapped.buffered(), &normal) catch return error.NameTooLong;
        const text = normal.buffered();
        // Convert each label: one after "xn--" decoded in place of its
        // Punycode. A label that did not decode is kept and not validated.
        var skip: [max_code_points]bool = undefined;
        var label_count: usize = 0;
        work.len = 0;
        var labels_text = std.mem.splitScalar(u8, text, '.');
        var first = true;
        while (labels_text.next()) |label| : (label_count += 1) {
            if (!first) try work.push('.');
            first = false;
            skip[label_count] = false;
            if (!std.mem.startsWith(u8, label, "xn--")) {
                try work.pushUtf8(label);
                continue;
            }
            const start = work.len;
            var decoded: []const u21 = &.{};
            const ok = blk: {
                if (!asciiBytes(label)) break :blk false;
                decoded = punycode.decode(label[4..], work.code_points[work.len..]) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.NameTooLong,
                    error.Invalid, error.Overflow => break :blk false,
                };
                break :blk true;
            };
            if (!ok) {
                if (!options.ignore_invalid_punycode or !asciiBytes(label)) {
                    failures.punycode = true;
                    skip[label_count] = true;
                }
                work.len = start;
                try work.pushUtf8(label);
                continue;
            }
            work.len += decoded.len;
            if (decoded.len == 0 or ascii(decoded)) failures.punycode = true;
            // A label from Punycode was neither mapped nor normalized.
            if (!isNfc(decoded)) failures.not_normalized = true;
            if (std.mem.findScalar(u21, decoded, '.') != null) failures.not_normalized = true;
        }
        // The labels are split again below on the processed code points; a
        // full stop from Punycode was failed above, and the split then
        // only makes labels that are checked as any other.
        // STD3 host names have no empty label but the root's at the end.
        if (options.std3_rules) {
            var it = work.labels();
            var count: usize = 0;
            while (it.next()) |label| : (count += 1) {
                if (label.code_points.len == 0 and (it.rest != null or count == 0)) failures.std3 = true;
            }
        }
        const bidi_name = options.check_bidi and work.isBidiName();
        var labels_it = work.labels();
        var index: usize = 0;
        while (labels_it.next()) |label| : (index += 1) {
            if (index < label_count and skip[index]) continue;
            validate(label.code_points, options, bidi_name, &failures);
        }
        return failures;
    }

    fn push(work: *Work, cp: u21) error{NameTooLong}!void {
        if (work.len == work.code_points.len) return error.NameTooLong;
        work.code_points[work.len] = cp;
        work.len += 1;
    }

    fn pushUtf8(work: *Work, text: []const u8) error{NameTooLong}!void {
        var at: usize = 0;
        while (at < text.len) {
            const d = utf8.decode(text[at..]);
            at += d.len;
            try work.push(d.code_point);
        }
    }

    /// A Bidi domain name (RFC 5893 §2): a label holds a right-to-left
    /// character (R, AL) or an Arabic number (AN).
    fn isBidiName(work: *const Work) bool {
        for (work.code_points[0..work.len]) |cp| switch (record(cp).bidi) {
            .right_to_left, .arabic_letter, .arabic_number => return true,
            else => {},
        };
        return false;
    }
};

/// UTS #46 §4.1, the validity criteria, on one label.
fn validate(label: []const u21, options: Options, bidi_name: bool, failures: *Failures) void {
    if (label.len == 0) return;
    if (options.check_hyphens) {
        if (label.len >= 4 and label[2] == '-' and label[3] == '-') failures.hyphens = true;
        if (label[0] == '-' or label[label.len - 1] == '-') failures.hyphens = true;
    } else if (label.len >= 4 and label[0] == 'x' and label[1] == 'n' and label[2] == '-' and label[3] == '-') {
        failures.xn_prefix = true;
    }
    if (record(label[0]).mark) failures.leading_mark = true;
    for (label) |cp| {
        switch (record(cp).status) {
            .valid, .deviation => {},
            .mapped, .ignored, .disallowed => failures.disallowed = true,
        }
        if (options.std3_rules and cp < 0x80 and !(cp >= 'a' and cp <= 'z') and !(cp >= '0' and cp <= '9') and cp != '-')
            failures.std3 = true;
    }
    if (options.check_joiners and !joinersAllowed(label)) failures.joiners = true;
    if (bidi_name and !bidiRule(label)) failures.bidi = true;
}

/// The ContextJ rules (RFC 5892 Appendix A.1 and A.2): ZERO WIDTH JOINER
/// only after a virama; ZERO WIDTH NON-JOINER after a virama, or between a
/// left- or dual-joining and a right- or dual-joining character with only
/// transparent ones around it.
fn joinersAllowed(label: []const u21) bool {
    for (label, 0..) |cp, i| {
        if (cp != 0x200c and cp != 0x200d) continue;
        if (i > 0 and record(label[i - 1]).virama) continue;
        if (cp == 0x200d) return false;
        const left = for (0..i) |back| {
            const j = record(label[i - 1 - back]).joining;
            if (j != .transparent) break j == .left_joining or j == .dual_joining;
        } else false;
        if (!left) return false;
        const right = for (label[i + 1 ..]) |next| {
            const j = record(next).joining;
            if (j != .transparent) break j == .right_joining or j == .dual_joining;
        } else false;
        if (!right) return false;
    }
    return true;
}

/// The Bidi rule (RFC 5893 §2), its six conditions, on one label of a
/// Bidi domain name.
fn bidiRule(label: []const u21) bool {
    const first = record(label[0]).bidi;
    // 1: the first character is L, R or AL.
    const rtl = switch (first) {
        .left_to_right => false,
        .right_to_left, .arabic_letter => true,
        else => return false,
    };
    // The last character that is not NSM.
    var last_index = label.len - 1;
    while (last_index > 0 and record(label[last_index]).bidi == .nonspacing_mark) last_index -= 1;
    const last = record(label[last_index]).bidi;
    var european = false;
    var arabic = false;
    for (label) |cp| {
        const b = record(cp).bidi;
        switch (b) {
            .european_number => european = true,
            .arabic_number => arabic = true,
            else => {},
        }
        const allowed = switch (b) {
            .european_number, .european_separator, .common_separator, .european_terminator, .other_neutral, .boundary_neutral, .nonspacing_mark => true,
            // 2 and 5: right-to-left characters only in an RTL label, L
            // only in an LTR one.
            .right_to_left, .arabic_letter, .arabic_number => rtl,
            .left_to_right => !rtl,
            else => false,
        };
        if (!allowed) return false;
    }
    if (rtl) {
        // 3: it ends with R, AL, EN or AN, then NSM; 4: EN or AN, not both.
        if (last != .right_to_left and last != .arabic_letter and last != .european_number and last != .arabic_number) return false;
        if (european and arabic) return false;
    } else {
        // 6: it ends with L or EN, then NSM.
        if (last != .left_to_right and last != .european_number) return false;
    }
    return true;
}

fn record(cp: u21) classes.Idna {
    if (cp > 0x10ffff) return .{ .status = .disallowed };
    return @bitCast(data.idna.records[data.idna.table.get(cp)]);
}

/// The mapping of a code point whose status is `mapped`.
fn mapping(cp: u21) []const u21 {
    const list = &data.idna.mapped_code_points;
    var low: usize = 0;
    var high: usize = list.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (list[mid] < cp) low = mid + 1 else high = mid;
    }
    std.debug.assert(low < list.len);
    std.debug.assert(list[low] == cp);
    const m: classes.Mapping = @bitCast(data.idna.mappings[low]);
    return data.idna.pool[m.start..][0..m.len];
}

fn writeCodePoint(w: *Writer, cp: u21) Writer.Error!void {
    var bytes: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &bytes) catch unreachable; // unreachable: the table maps to scalar values, and decoding gives only them
    try w.writeAll(bytes[0..n]);
}

fn ascii(code_points: []const u21) bool {
    for (code_points) |cp| if (cp >= 0x80) return false;
    return true;
}

fn asciiBytes(bytes: []const u8) bool {
    for (bytes) |b| if (b >= 0x80) return false;
    return true;
}

fn isNfc(code_points: []const u21) bool {
    var bytes: [max_code_points * 4]u8 = undefined;
    var w: Writer = .fixed(&bytes);
    for (code_points) |cp| writeCodePoint(&w, cp) catch return false;
    return normalize.isNormalized(.nfc, w.buffered());
}

const testing = std.testing;

fn expectAscii(name: []const u8, want: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const f = try toAscii(name, &w, .{});
    try testing.expect(!f.any());
    try testing.expectEqualStrings(want, w.buffered());
}

test "a name is mapped, normalized and written in ASCII" {
    try expectAscii("Bücher.de", "xn--bcher-kva.de");
    try expectAscii("EXAMPLE.com", "example.com");
    try expectAscii("faß.de", "xn--fa-hia.de");
    try expectAscii("日本語。ＪＰ", "xn--wgv71a119e.jp");
}

test "toUnicode decodes Punycode and says what failed" {
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try testing.expect(!(try toUnicode("xn--bcher-kva.de", &w, .{})).any());
    try testing.expectEqualStrings("bücher.de", w.buffered());
    w = .fixed(&buf);
    const f = try toUnicode("xn--a-.-b.c", &w, .{});
    try testing.expect(f.punycode and f.hyphens);
}

test "toAscii writes nothing when a check fails" {
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const f = try toAscii("a\u{200d}b.com", &w, .{});
    try testing.expect(f.joiners);
    try testing.expectEqual(@as(usize, 0), w.end);
    try testing.expect((try toAscii("example.com.", &w, .{})).dns_length);
    try testing.expect(!(try toAscii("example.com.", &w, .url)).any());
}
