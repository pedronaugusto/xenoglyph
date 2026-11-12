//! Internationalized domain names as UTS #46 processes them, with
//! Nontransitional Processing: `toAscii` gives the name DNS looks up
//! (`Bücher.de` is `xn--bcher-kva.de`), `toUnicode` the name to show. Each
//! maps the name through the IDNA Mapping Table, normalizes it to NFC,
//! decodes its Punycode labels and checks every label (hyphens, combining
//! marks, the Bidi rule of RFC 5893, the ContextJ rules of RFC 5892), and
//! says what failed. Nothing allocates: a name is worked on in buffers on
//! the stack, up to `max_code_points`.
//!
//! `check2008` is IDNA2008 itself (RFC 5890 to 5893) with no mapping: a
//! name valid as it is written, which is what JSON Schema's `idn-hostname`
//! asks.
const std = @import("std");
const aegis = @import("aegis");
const Writer = std.Io.Writer;
const classes = @import("classes.zig");
const data = @import("data.zig");
const normalize = @import("normalize.zig");
const utf8 = @import("utf8.zig");
const properties = @import("properties.zig");
pub const punycode = @import("punycode.zig");

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
    /// rules, no hyphen checks and no DNS lengths. Its host parser then
    /// refuses a result holding a forbidden domain code point (a C0
    /// control, space, `#` `%` `/` `:` `<` `>` `?` `@` `[` `\` `]` `^` `|`
    /// or DEL); that check is the host parser's, after this, and not made
    /// here.
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
    var work: Work = .{};
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
    var work: Work = .{};
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
            const n = std.unicode.utf8Encode(cp, &bytes) catch aegis.assert.never("every code point here is a scalar value");
            try w.writeAll(bytes[0..n]);
        }
    }
    return failures;
}

const Label = struct { code_points: []const u21 };

/// A name being processed: its code points, labels separated by `.`.
const Work = struct {
    code_points: aegis.bounded.Array(u21, max_code_points) = .init,

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
        return .{ .rest = work.code_points.constItems() };
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
        // Whether each label, in order, is one not to validate. Each label
        // but the first pushed a full stop, so there is at most one more
        // label than there are code points.
        var skip: aegis.bounded.Array(bool, max_code_points + 1) = .init;
        work.code_points = .init;
        var labels_text = std.mem.splitScalar(u8, text, '.');
        var first = true;
        while (labels_text.next()) |label| {
            if (!first) try work.push('.');
            first = false;
            var skipped = false;
            defer skip.append(&skipped) catch aegis.assert.never("there is at most one more label than code points");
            if (!std.mem.startsWith(u8, label, "xn--")) {
                try work.pushUtf8(label);
                continue;
            }
            var decoded_buffer: [max_code_points]u21 = undefined;
            var decoded: []const u21 = &.{};
            const ok = blk: {
                if (!asciiBytes(label)) break :blk false;
                const room = work.code_points.capacity() - work.code_points.len();
                decoded = punycode.decode(label[4..], decoded_buffer[0..room]) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.NameTooLong,
                    error.Invalid, error.Overflow => break :blk false,
                };
                break :blk true;
            };
            if (!ok) {
                if (!options.ignore_invalid_punycode or !asciiBytes(label)) {
                    failures.punycode = true;
                    skipped = true;
                }
                try work.pushUtf8(label);
                continue;
            }
            work.code_points.appendSlice(decoded) catch aegis.assert.never("a label decodes into the room left");
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
            if (index < skip.len() and skip.constItems()[index]) continue;
            validate(label.code_points, options, bidi_name, &failures);
        }
        return failures;
    }

    fn push(work: *Work, cp: u21) error{NameTooLong}!void {
        var pushed = cp;
        work.code_points.append(&pushed) catch return error.NameTooLong;
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
        for (work.code_points.constItems()) |cp| switch (record(cp).bidi) {
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
    aegis.assert.invariant(low < list.len, "a mapped code point is in the list");
    aegis.assert.invariant(list[low] == cp, "a mapped code point is in the list");
    const m: classes.Mapping = @bitCast(data.idna.mappings[low]);
    return data.idna.pool[m.start..][0..m.len];
}

fn writeCodePoint(w: *Writer, cp: u21) Writer.Error!void {
    var bytes: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &bytes) catch aegis.assert.never("the table maps to scalar values, and decoding gives only them");
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

/// A code point's IDNA2008 derived property (RFC 5892), from this
/// version of Unicode by the RFC's algorithm.
pub fn status2008(cp: u21) classes.Idna2008 {
    return record(cp).idna2008;
}

/// What failed in a name under IDNA2008.
pub const Failures2008 = packed struct(u16) {
    /// A code point DISALLOWED or UNASSIGNED (ill-formed UTF-8 among them).
    disallowed: bool = false,
    /// A CONTEXTJ or CONTEXTO code point whose rule (RFC 5892 Appendix A)
    /// does not hold.
    context: bool = false,
    /// `-` at either end of a label, or `--` in its third and fourth
    /// positions (RFC 5891 §4.2.3.1).
    hyphens: bool = false,
    /// A label that begins with a combining mark (§4.2.3.2).
    leading_mark: bool = false,
    /// A label that is not in NFC (§5.4): IDNA2008 normalizes nothing.
    not_normalized: bool = false,
    /// A label after `xn--` that does not decode, decodes to nothing or
    /// to ASCII alone, or does not encode back to itself.
    punycode: bool = false,
    /// In a name with right-to-left text, a label breaks the Bidi rule
    /// (RFC 5893).
    bidi: bool = false,
    /// An empty label, a label past 63 bytes or the name past 253 in
    /// their ASCII (A-label) form.
    length: bool = false,
    _: u8 = 0,

    /// Whether anything failed.
    pub fn any(f: Failures2008) bool {
        return @as(u16, @bitCast(f)) != 0;
    }
};

/// IDNA2008's validity of a name as written (RFC 5891 §5.3 to 5.5, the
/// derived properties of RFC 5892 with its ContextJ and ContextO rules,
/// the Bidi rule of RFC 5893): nothing is mapped, folded or normalized
/// first. Labels are split at U+002E FULL STOP alone, and one trailing
/// full stop (the root) is taken. A label beginning `xn--` in any case is
/// an A-label, read lowercased (DNS compares labels without regard to
/// ASCII case), valid when it decodes to a valid U-label that encodes back
/// to it. Nothing allocates.
pub fn check2008(name: []const u8) error{NameTooLong}!Failures2008 {
    var f: Failures2008 = .{};
    var text = name;
    if (text.len > 1 and text[text.len - 1] == '.') text = text[0 .. text.len - 1];
    if (text.len == 0) return .{ .length = true };
    // Every label's code points (A-labels decoded), to see first whether
    // the name is a Bidi domain name.
    var work: Work = .{};
    var bounds: aegis.bounded.Array(Bound, max_code_points + 1) = .init;
    var ace_total: usize = 0;
    var labels = std.mem.splitScalar(u8, text, '.');
    var first = true;
    while (labels.next()) |label| {
        if (!first) ace_total += 1;
        first = false;
        var bound: Bound = .{ .start = work.code_points.len(), .end = 0 };
        if (label.len == 0) f.length = true;
        if (isAceLabel(label)) {
            ace_total += label.len;
            if (label.len > 63) f.length = true;
            // DNS compares labels without regard to ASCII case: the A-label
            // is read lowercased, as the same label.
            var lower_buffer: [max_code_points]u8 = undefined;
            if (label.len > lower_buffer.len) return error.NameTooLong;
            const lower = std.ascii.lowerString(&lower_buffer, label);
            var decoded_buffer: [max_code_points]u21 = undefined;
            const room = work.code_points.capacity() - work.code_points.len();
            const decoded = punycode.decode(lower[4..], decoded_buffer[0..@min(room, decoded_buffer.len)]) catch |err| switch (err) {
                error.NoSpaceLeft => return error.NameTooLong,
                error.Invalid, error.Overflow => blk: {
                    f.punycode = true;
                    break :blk decoded_buffer[0..0];
                },
            };
            if (!f.punycode) {
                if (decoded.len == 0 or ascii(decoded)) f.punycode = true;
                if (!encodesTo(decoded, lower[4..])) f.punycode = true;
            }
            work.code_points.appendSlice(decoded) catch return error.NameTooLong;
        } else {
            try work.pushUtf8(label);
            const cps = work.code_points.constItems()[bound.start..];
            const len = aceLength(cps) orelse return error.NameTooLong;
            ace_total += len;
            if (len > 63) f.length = true;
        }
        bound.end = work.code_points.len();
        bounds.append(&bound) catch return error.NameTooLong;
    }
    if (ace_total > 253) f.length = true;
    const bidi_name = work.isBidiName();
    const all = work.code_points.constItems();
    for (bounds.constItems()) |b| {
        const label = all[b.start..b.end];
        if (label.len == 0) continue;
        validate2008(label, bidi_name, &f);
    }
    return f;
}

const Bound = struct { start: usize, end: usize };

/// A label that begins `xn--`, in any case: an A-label, or a label that
/// fails as one.
fn isAceLabel(label: []const u8) bool {
    return label.len >= 4 and std.ascii.eqlIgnoreCase(label[0..4], "xn--");
}

/// Whether `decoded` encodes to `ace` as Punycode, ignoring ASCII case.
fn encodesTo(decoded: []const u21, ace: []const u8) bool {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    punycode.encode(decoded, &w) catch return false;
    return std.ascii.eqlIgnoreCase(w.buffered(), ace);
}

/// The length of a label's ASCII form: itself when ASCII, else `xn--` and
/// its Punycode. Null past what fits a buffer far past any DNS label.
fn aceLength(label: []const u21) ?usize {
    if (ascii(label)) return label.len;
    var buf: [max_code_points * 2]u8 = undefined;
    var w: Writer = .fixed(&buf);
    punycode.encode(label, &w) catch return null;
    return 4 + w.buffered().len;
}

/// RFC 5891 §5.4's checks of one U-label (or LDH label), and the Bidi
/// rule in a Bidi domain name.
fn validate2008(label: []const u21, bidi_name: bool, f: *Failures2008) void {
    if (!isNfc(label)) f.not_normalized = true;
    if (label.len >= 4 and label[2] == '-' and label[3] == '-') f.hyphens = true;
    if (label[0] == '-' or label[label.len - 1] == '-') f.hyphens = true;
    if (record(label[0]).mark) f.leading_mark = true;
    var joiners = false;
    for (label, 0..) |cp, i| switch (status2008(cp)) {
        .pvalid => {},
        .contextj => joiners = true,
        .contexto => if (!contextO(label, i)) {
            f.context = true;
        },
        .disallowed, .unassigned => f.disallowed = true,
    };
    if (joiners and !joinersAllowed(label)) f.context = true;
    if (bidi_name and !bidiRule(label)) f.bidi = true;
}

/// The ContextO rules (RFC 5892 Appendix A.3 to A.9) for the code point at
/// `i` of `label`.
fn contextO(label: []const u21, i: usize) bool {
    const cp = label[i];
    const before: ?u21 = if (i > 0) label[i - 1] else null;
    const after: ?u21 = if (i + 1 < label.len) label[i + 1] else null;
    return switch (cp) {
        // A.3 MIDDLE DOT: between two 'l'.
        0x00b7 => before == 'l' and after == 'l',
        // A.4 GREEK LOWER NUMERAL SIGN (KERAIA): before Greek.
        0x0375 => if (after) |a| properties.script(a) == .greek else false,
        // A.5 HEBREW PUNCTUATION GERESH and A.6 GERSHAYIM: after Hebrew.
        0x05f3, 0x05f4 => if (before) |b| properties.script(b) == .hebrew else false,
        // A.7 KATAKANA MIDDLE DOT: the label holds Hiragana, Katakana or Han.
        0x30fb => for (label) |other| {
            switch (properties.script(other)) {
                .hiragana, .katakana, .han => break true,
                else => {},
            }
        } else false,
        // A.8 ARABIC-INDIC DIGITS: no Extended Arabic-Indic digit in the label.
        0x0660...0x0669 => for (label) |other| {
            if (other >= 0x06f0 and other <= 0x06f9) break false;
        } else true,
        // A.9 EXTENDED ARABIC-INDIC DIGITS: no Arabic-Indic digit in the label.
        0x06f0...0x06f9 => for (label) |other| {
            if (other >= 0x0660 and other <= 0x0669) break false;
        } else true,
        else => false,
    };
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
