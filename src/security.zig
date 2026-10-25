//! Unicode security mechanisms (UTS #39): confusable detection by skeleton,
//! mixed-script detection, restriction levels, the General Security Profile
//! (Identifier_Status and Identifier_Type), and the checks of ICU's spoof
//! checker: mixed numbers, unlikely runs of nonspacing marks, hidden
//! overlays.
const std = @import("std");
const aegis = @import("aegis");
const bidi = @import("bidi.zig");
const canonical = @import("canonical.zig");
const case = @import("case.zig");
const data = @import("data.zig");
const normalize = @import("normalize.zig");
const properties = @import("properties.zig");
const records = @import("records.zig");
const utf8 = @import("utf8.zig");

const tables = data.security;
const Writer = std.Io.Writer;
const Script = properties.Script;

// ---------------------------------------------------------------------------
// The identifier profile

/// Identifier_Status: whether the General Security Profile allows a code
/// point in identifiers.
pub const IdentifierStatus = enum { restricted, allowed };

/// Identifier_Type: why a code point is restricted, or why it is allowed
/// (`inclusion`, `recommended`). Several reasons may hold at once.
pub const IdentifierType = packed struct(u16) {
    not_character: bool = false,
    deprecated: bool = false,
    default_ignorable: bool = false,
    not_nfkc: bool = false,
    not_xid: bool = false,
    exclusion: bool = false,
    obsolete: bool = false,
    technical: bool = false,
    uncommon_use: bool = false,
    limited_use: bool = false,
    inclusion: bool = false,
    recommended: bool = false,
    _: u4 = 0,
};

pub fn identifierType(cp: u21) IdentifierType {
    if (cp > 0x10ffff) return .{ .not_character = true };
    return @bitCast(tables.identifier_types.get(cp));
}

/// Allowed exactly where the type is `inclusion` or `recommended`.
pub fn identifierStatus(cp: u21) IdentifierStatus {
    const t = identifierType(cp);
    return if (t.inclusion or t.recommended) .allowed else .restricted;
}

/// Whether the profile allows `text`, up to canonical equivalence (UTS #39
/// §3.1): each segment of its NFC (a starter and the marks after it) has
/// its code points allowed, or those of its NFD. So `u` with U+0308 passes
/// if both are allowed or `ü` is, and a Hangul syllable passes though its
/// conjoining jamo are restricted.
fn inProfile(text: []const u8) bool {
    var composed = true;
    var decomposed = true;
    var it: normalize.Iterator(.nfc) = .init(text);
    while (it.next()) |cp| {
        if (normalize.combiningClass(cp) == 0) {
            if (!composed and !decomposed) return false;
            composed = true;
            decomposed = true;
        }
        composed = composed and identifierStatus(cp) == .allowed;
        var buffer: [18]u21 = undefined;
        for (normalize.decompose(cp, .nfd, &buffer)) |d| decomposed = decomposed and identifierStatus(d) == .allowed;
    }
    return composed or decomposed;
}

// ---------------------------------------------------------------------------
// Scripts

/// The writing systems of several scripts that augmented script sets add
/// (UTS #39 §5.1).
pub const WritingSystem = enum {
    /// Hanb: Han with Bopomofo.
    han_with_bopomofo,
    /// Hntl: Traditional Han with Latin.
    traditional_han_with_latin,
    /// Jpan: Han, Hiragana and Katakana.
    japanese,
    /// Kore: Han and Hangul.
    korean,
};

/// A set of scripts and writing systems: an augmented script set, or what
/// intersecting them leaves.
pub const ScriptSet = struct {
    /// Private: a bit a script, in `Script`'s order, then a bit a writing system.
    bits: Bits,

    const scripts = @typeInfo(Script).@"enum".field_names.len;
    const Bits = std.bit_set.Static(scripts + @typeInfo(WritingSystem).@"enum".field_names.len);

    /// Every script and writing system: what a Common or Inherited code
    /// point gives, and the resolved set of a string of nothing else.
    pub const all: ScriptSet = .{ .bits = .full };
    pub const empty: ScriptSet = .{ .bits = .empty };

    /// A code point's augmented script set (UTS #39 §5.1): its
    /// Script_Extensions, with Hanb, Hntl, Jpan and Kore added where their
    /// scripts are, and all scripts where Common or Inherited is.
    pub fn of(cp: u21) ScriptSet {
        var s: ScriptSet = .empty;
        for (properties.scriptExtensions(cp)) |script| switch (script) {
            .common, .inherited => return .all,
            .han => {
                s.addWritingSystem(.han_with_bopomofo);
                s.addWritingSystem(.traditional_han_with_latin);
                s.addWritingSystem(.japanese);
                s.addWritingSystem(.korean);
                s.bits.set(@backingInt(script));
            },
            .hiragana, .katakana => {
                s.addWritingSystem(.japanese);
                s.bits.set(@backingInt(script));
            },
            .hangul => {
                s.addWritingSystem(.korean);
                s.bits.set(@backingInt(script));
            },
            .bopomofo => {
                s.addWritingSystem(.han_with_bopomofo);
                s.bits.set(@backingInt(script));
            },
            .latin => {
                s.addWritingSystem(.traditional_han_with_latin);
                s.bits.set(@backingInt(script));
            },
            else => s.bits.set(@backingInt(script)),
        };
        return s;
    }

    fn addWritingSystem(s: *ScriptSet, w: WritingSystem) void {
        s.bits.set(scripts + @backingInt(w));
    }

    pub fn contains(s: ScriptSet, script: Script) bool {
        return s.bits.isSet(@backingInt(script));
    }

    pub fn containsWritingSystem(s: ScriptSet, w: WritingSystem) bool {
        return s.bits.isSet(scripts + @backingInt(w));
    }

    pub fn isEmpty(s: ScriptSet) bool {
        return s.bits.count() == 0;
    }

    pub fn isAll(s: ScriptSet) bool {
        return s.bits.eql(all.bits);
    }

    pub fn intersection(a: ScriptSet, b: ScriptSet) ScriptSet {
        return .{ .bits = a.bits.intersectWith(b.bits) };
    }

    pub fn intersects(a: ScriptSet, b: ScriptSet) bool {
        return !a.intersection(b).isEmpty();
    }
};

/// A string's resolved script set (UTS #39 §5.1): the intersection of its
/// code points' augmented script sets. Empty: the string is mixed-script;
/// otherwise single-script. All: it holds only Common and Inherited code
/// points, or nothing.
pub fn resolvedScripts(text: []const u8) ScriptSet {
    var resolved: ScriptSet = .all;
    var it: utf8.Iterator = .init(text);
    while (it.next()) |cp| {
        resolved = resolved.intersection(.of(cp));
        if (resolved.isEmpty()) break;
    }
    return resolved;
}

/// Restriction levels (UTS #39 §5.2), from the strictest a string meets.
pub const RestrictionLevel = enum {
    ascii_only,
    single_script,
    /// Single-script, or covered by Latin with Han and Hiragana and
    /// Katakana, Han and Bopomofo, or Han and Hangul.
    highly_restrictive,
    /// Covered by Latin and one other Recommended script, not Cyrillic or
    /// Greek.
    moderately_restrictive,
    /// Any scripts, but every code point in the identifier profile.
    minimally_restrictive,
    /// A code point outside the identifier profile.
    unrestricted,
};

/// UAX #31's Recommended Scripts (Table 5, Unicode 18.0.0).
const recommended = [_]Script{
    .common,   .inherited, .arabic,  .armenian, .bengali, .cyrillic, .devanagari, .ethiopic, .georgian, .greek,
    .gujarati, .gurmukhi,  .hangul,  .han,      .hebrew,  .hiragana, .katakana,   .kannada,  .khmer,    .lao,
    .latin,    .malayalam, .myanmar, .oriya,    .sinhala, .tamil,    .telugu,     .thaana,   .thai,     .tibetan,
};

/// The strictest restriction level `text` meets (UTS #39 §5.2), with the
/// General Security Profile as the identifier profile.
pub fn restrictionLevel(text: []const u8) RestrictionLevel {
    if (!inProfile(text)) return .unrestricted;
    for (text) |b| {
        if (b >= 0x80) break;
    } else return .ascii_only;
    // The resolved set, and what intersecting the sets without Latin leaves.
    var resolved: ScriptSet = .all;
    var rest: ScriptSet = .all;
    var it: utf8.Iterator = .init(text);
    while (it.next()) |cp| {
        const set: ScriptSet = .of(cp);
        resolved = resolved.intersection(set);
        if (!set.contains(.latin)) rest = rest.intersection(set);
    }
    if (!resolved.isEmpty()) return .single_script;
    if (rest.containsWritingSystem(.korean) or rest.containsWritingSystem(.han_with_bopomofo) or rest.containsWritingSystem(.japanese)) return .highly_restrictive;
    for (recommended) |script| if (script != .cyrillic and script != .greek and rest.contains(script)) return .moderately_restrictive;
    return .minimally_restrictive;
}

// ---------------------------------------------------------------------------
// Confusables

/// How a skeleton reorders a string before mapping it (UTS #39 §4).
pub const Direction = enum {
    /// As shown in a left-to-right paragraph: UTS #39's `skeleton`, and
    /// ICU's `uspoof_getBidiSkeleton` with `UBIDI_LTR`.
    ltr,
    /// As shown in a right-to-left paragraph.
    rtl,
    /// As shown in a paragraph its first strong character sets the
    /// direction of (rules P2 and P3, left to right if there is none).
    first_strong,
    /// Not reordered: UTS #39's internalSkeleton, the skeleton of its
    /// versions before 15.1, and ICU's `uspoof_getSkeleton`.
    logical,
};

pub const Options = struct {
    direction: Direction = .ltr,
};

/// The memory a skeleton in display order resolves the text's paragraphs
/// in, the caller's: each slice at least as long as the text in bytes. It
/// is read only where display order differs from logical order: for
/// `.rtl`, and for `.ltr` and `.first_strong` when the text holds a
/// right-to-left letter, an Arabic number or a directional format. A
/// `.logical` skeleton never reads it.
pub const Buffers = struct {
    levels: []bidi.Level = &.{},
    scratch: []bidi.Scratch = &.{},
    runs: []bidi.Run = &.{},
};

/// The skeleton of `text` (UTS #39 §4), as UTF-8: the text as shown in
/// `options.direction` (UAX #9 up to L2, a right-to-left run's combining
/// marks after their base and its bases mirrored, L3 and L4), in NFD,
/// without default ignorables, each code point replaced by its prototype,
/// and in NFD again. Two texts are confusable when their skeletons are
/// equal. Not for display; it changes with the Unicode version.
pub fn skeleton(text: []const u8, w: *Writer, options: Options, buffers: Buffers) Writer.Error!void {
    var it: Skeleton = .init(text, options, buffers);
    try utf8.encode(&it, w);
}

/// The code points of a text's skeleton, in order, read as they are needed:
/// nothing is allocated, and comparing two skeletons stops where they
/// first differ.
pub const Skeleton = struct {
    /// Private: printable ASCII shown left to right maps byte by byte (its
    /// prototypes are starters in NFD, with nothing to order or decompose);
    /// anything else goes through the four steps.
    steps: union(enum) { ascii: Ascii, full: Second },

    pub fn init(text: []const u8, options: Options, buffers: Buffers) Skeleton {
        if (options.direction != .rtl and utf8.printableAscii(text)) return .{ .steps = .{ .ascii = .{ .text = text } } };
        var display: Display = .{ .text = text, .runs = &.{} };
        if (options.direction == .rtl or (options.direction != .logical and reorders(text))) {
            display.runs = visualRuns(text, options.direction, buffers);
            display.enter();
        }
        const decomposed: Decomposed = .{ .inner = display, .before = display.position() };
        const first: First = .{ .source = decomposed };
        return .{ .steps = .{ .full = .{ .source = .{ .inner = first, .before = first } } } };
    }

    pub fn next(s: *Skeleton) ?u21 {
        return switch (s.steps) {
            inline else => |*steps| steps.next(),
        };
    }
};

/// ASCII's prototypes, byte by byte.
const Ascii = struct {
    text: []const u8,
    at: usize = 0,
    prototype: Prototype = .{},
    index: u8 = 0,

    fn next(a: *Ascii) ?u21 {
        while (a.index == a.prototype.len) {
            if (a.at == a.text.len) return null;
            a.prototype = .of(a.text[a.at]);
            a.at += 1;
            a.index = 0;
        }
        defer a.index += 1;
        return a.prototype.at(a.index);
    }
};

/// A code point's prototype (confusables.txt): itself, another code point,
/// or a run of `prototypes`. A value, so the steps that hold one copy.
const Prototype = struct {
    one: u21 = 0,
    start: u32 = 0,
    len: u8 = 0,

    fn of(cp: u21) Prototype {
        const value = tables.confusables.get(cp);
        if (value == 0) return .{ .one = cp, .len = 1 };
        if (value & 1 != 0) return .{ .one = @intCast(value >> 1), .len = 1 };
        return .{ .start = value >> 6, .len = @intCast(value >> 1 & 0x1f) };
    }

    fn at(p: Prototype, i: u8) u21 {
        return if (p.len == 1) p.one else tables.prototypes[p.start + i];
    }
};

/// Whether a left-to-right paragraph can show `text` other than in logical
/// order: it holds a right-to-left or Arabic letter, an Arabic number (a
/// neutral between two of them goes right to left), or an explicit
/// directional format.
fn reorders(text: []const u8) bool {
    var it: utf8.Iterator = .init(text);
    while (it.next()) |cp| switch (properties.bidiClass(cp)) {
        .right_to_left, .arabic_letter, .arabic_number => return true,
        .left_to_right_embedding, .left_to_right_override, .right_to_left_embedding, .right_to_left_override => return true,
        .pop_directional_format, .left_to_right_isolate, .right_to_left_isolate, .first_strong_isolate, .pop_directional_isolate => return true,
        else => {},
    };
    return false;
}

/// The runs of `text` in visual order, each paragraph shown as one line
/// (UAX #9 up to L2), in `buffers.runs`.
fn visualRuns(text: []const u8, direction: Direction, buffers: Buffers) []const bidi.Run {
    aegis.assert.pre(buffers.levels.len >= text.len and buffers.scratch.len >= text.len and buffers.runs.len >= text.len, "a skeleton in display order has buffers as long as its text");
    const options: bidi.Options = .{ .direction = switch (direction) {
        .ltr => .ltr,
        .rtl => .rtl,
        .first_strong, .logical => .auto,
    } };
    var used: usize = 0;
    var start: usize = 0;
    while (start < text.len) {
        const p = bidi.Paragraph.resolve(text, .fromRaw(start), options, .{ .levels = buffers.levels, .scratch = buffers.scratch });
        used += p.line(p.span, buffers.runs[used..]).runs.len;
        start = p.span.end.raw();
    }
    return buffers.runs[0..used];
}

/// The first step: the text's code points as shown. In a right-to-left
/// run, from its end, each base and the combining marks after it
/// (General_Category M) in logical order, the base mirrored, as ICU's
/// `UBIDI_KEEP_BASE_COMBINING` and `UBIDI_DO_MIRRORING` write them. With no
/// runs, the text in logical order.
const Display = struct {
    const Self = @This();

    text: []const u8,
    runs: []const bidi.Run,
    run: usize = 0,
    /// Where the next code point starts; in a right-to-left run, inside the
    /// segment from `segment` to `end`.
    at: usize = 0,
    segment: usize = 0,
    end: usize = 0,

    pub const Position = struct {
        run: usize,
        at: usize,
        segment: usize,
        end: usize,

        pub fn eql(a: Position, b: Position) bool {
            return a.run == b.run and a.at == b.at and a.segment == b.segment and a.end == b.end;
        }
    };

    pub fn position(d: *const Self) Position {
        return .{ .run = d.run, .at = d.at, .segment = d.segment, .end = d.end };
    }

    pub fn seek(d: *Self, p: Position) void {
        d.run = p.run;
        d.at = p.at;
        d.segment = p.segment;
        d.end = p.end;
    }

    /// Enters run `run`: at its start, or at its end with no segment yet.
    fn enter(d: *Self) void {
        if (d.run == d.runs.len) return;
        const r = d.runs[d.run];
        const start = r.span.start.raw();
        const end = r.span.end.raw();
        d.at = if (r.level & 1 == 0) start else end;
        d.segment = d.at;
        d.end = d.at;
    }

    pub fn next(d: *Self) ?u21 {
        if (d.runs.len == 0) {
            if (d.at >= d.text.len) return null;
            const c = utf8.decode(d.text[d.at..]);
            d.at += c.len;
            return c.code_point;
        }
        while (d.run < d.runs.len) {
            const r = d.runs[d.run];
            const start = r.span.start.raw();
            const end = r.span.end.raw();
            if (r.level & 1 == 0) {
                if (d.at < end) {
                    const c = utf8.decode(d.text[d.at..end]);
                    d.at += c.len;
                    return c.code_point;
                }
            } else {
                if (d.at < d.end) {
                    const base = d.at == d.segment;
                    const c = utf8.decode(d.text[d.at..d.end]);
                    d.at += c.len;
                    return if (base) bidi.mirror(c.code_point) orelse c.code_point else c.code_point;
                }
                if (d.segment > start) {
                    d.end = d.segment;
                    d.segment = records.codePointStart(d.text, d.end);
                    while (d.segment > start and mark(utf8.decode(d.text[d.segment..d.end]).code_point)) d.segment = records.codePointStart(d.text, d.segment);
                    d.at = d.segment;
                    continue;
                }
            }
            d.run += 1;
            d.enter();
        }
        return null;
    }
};

fn mark(cp: u21) bool {
    return switch (properties.generalCategory(cp)) {
        .nonspacing_mark, .spacing_mark, .enclosing_mark => true,
        else => false,
    };
}

/// The code points of the first step, each fully decomposed: what the
/// first NFD orders.
const Decomposed = struct {
    const Self = @This();

    inner: Display,
    /// Where the first step stood before the code point being given out.
    before: Display.Position,
    expansion: [18]u21 = undefined,
    len: u8 = 0,
    index: u8 = 0,

    pub const Position = struct {
        inner: Display.Position,
        index: u8,

        pub fn eql(a: Position, b: Position) bool {
            return a.index == b.index and a.inner.eql(b.inner);
        }
    };

    pub fn position(d: *const Self) Position {
        if (d.index < d.len) return .{ .inner = d.before, .index = d.index };
        return .{ .inner = d.inner.position(), .index = 0 };
    }

    pub fn seek(d: *Self, p: Position) void {
        d.inner.seek(p.inner);
        d.len = 0;
        d.index = 0;
        if (p.index > 0 and d.load()) d.index = p.index;
    }

    pub fn next(d: *Self) ?u21 {
        if (d.index == d.len and !d.load()) return null;
        defer d.index += 1;
        return d.expansion[d.index];
    }

    fn load(d: *Self) bool {
        d.before = d.inner.position();
        const cp = d.inner.next() orelse return false;
        d.len = @intCast(normalize.decompose(cp, .nfd, &d.expansion).len);
        d.index = 0;
        return true;
    }
};

/// The first NFD.
const First = canonical.Canonical(Decomposed, false);

/// The third step: the first NFD without default ignorables, each code
/// point its prototype's. The step before keeps no positions, so a
/// position here holds a copy of it to go back to.
const Mapped = struct {
    const Self = @This();

    inner: First,
    /// The first NFD as it stood before the code point being given out.
    before: First,
    /// How many code points of the first NFD have been read.
    read: usize = 0,
    prototype: Prototype = .{},
    index: u8 = 0,

    const finished = std.math.maxInt(u8);

    pub const Position = struct {
        state: First,
        read: usize,
        /// The prototype's code point next, or `finished`: the first NFD
        /// stands after the code point `read` counts.
        index: u8,

        pub fn eql(a: Position, b: Position) bool {
            return a.read == b.read and a.index == b.index;
        }
    };

    pub fn position(m: *const Self) Position {
        if (m.index < m.prototype.len) return .{ .state = m.before, .read = m.read, .index = m.index };
        return .{ .state = m.inner, .read = m.read, .index = finished };
    }

    pub fn seek(m: *Self, p: Position) void {
        m.inner = p.state;
        m.read = p.read;
        m.prototype = .{};
        m.index = 0;
        if (p.index == finished) return;
        m.before = p.state;
        m.prototype = .of(m.inner.next() orelse aegis.assert.never("a position inside a prototype has its code point"));
        m.index = p.index;
    }

    pub fn next(m: *Self) ?u21 {
        while (m.index == m.prototype.len) {
            m.before = m.inner;
            const cp = m.inner.next() orelse return null;
            m.read += 1;
            if (properties.core(cp).default_ignorable_code_point) continue;
            m.prototype = .of(cp);
            m.index = 0;
        }
        defer m.index += 1;
        return m.prototype.at(m.index);
    }
};

/// The second NFD: prototypes are in NFD, so ordering them is all it does.
const Second = canonical.Canonical(Mapped, false);

/// The class of a confusable pair (UTS #39 §4): single-script where their
/// resolved script sets meet, mixed-script where they do not, whole-script
/// where they do not and each is single-script.
pub const Confusability = enum { single_script, mixed_script, whole_script };

/// Whether `a` and `b` are confusable (their skeletons are equal), and how;
/// `buffers` one for each, as `skeleton` takes them.
pub fn confusable(a: []const u8, b: []const u8, options: Options, buffers: [2]Buffers) ?Confusability {
    aegis.assert.pre(buffers[0].runs.len == 0 or buffers[0].runs.ptr != buffers[1].runs.ptr, "the two texts' skeletons have buffers of their own");
    var ka: Skeleton = .init(a, options, buffers[0]);
    var kb: Skeleton = .init(b, options, buffers[1]);
    while (true) {
        const x = ka.next();
        if (x != kb.next()) return null;
        if (x == null) break;
    }
    const sa = resolvedScripts(a);
    const sb = resolvedScripts(b);
    if (sa.intersects(sb)) return .single_script;
    if (!sa.isEmpty() and !sb.isEmpty()) return .whole_script;
    return .mixed_script;
}

// ---------------------------------------------------------------------------
// Checks

/// What `check` found, by name.
pub const Failures = packed struct(u8) {
    /// A code point outside the identifier profile (ICU's `CHAR_LIMIT`
    /// with the General Security Profile).
    restricted: bool = false,
    /// A restriction level past the one allowed.
    restriction_level: bool = false,
    /// Decimal digits of more than one system (§5.3).
    mixed_numbers: bool = false,
    /// A nonspacing mark twice in one run of them, in NFD (§5.4; ICU's
    /// `INVISIBLE`).
    repeated_mark: bool = false,
    /// More than four nonspacing marks in a row, in NFD (§5.4).
    long_mark_run: bool = false,
    /// U+0307 COMBINING DOT ABOVE over a letter with a dot or a stem it
    /// hides in, as `i` or `l` (ICU's `HIDDEN_OVERLAY`).
    hidden_overlay: bool = false,
    _: u2 = 0,

    /// Whether anything failed.
    pub fn any(f: Failures) bool {
        return @as(u8, @bitCast(f)) != 0;
    }
};

/// UTS #39's checks of an identifier, all of them: its code points against
/// the identifier profile, its restriction level against `allowed`, mixed
/// numbers, and the runs of nonspacing marks and hidden overlays §5.4 and
/// ICU's spoof checker look for.
pub fn check(text: []const u8, allowed: RestrictionLevel) Failures {
    var f: Failures = .{};
    f.restricted = !inProfile(text);
    f.restriction_level = @backingInt(restrictionLevel(text)) > @backingInt(allowed);
    f.mixed_numbers = mixedNumbers(text);
    marks(text, &f);
    return f;
}

fn mixedNumbers(text: []const u8) bool {
    var zero: ?u21 = null;
    var it: utf8.Iterator = .init(text);
    while (it.next()) |cp| {
        if (properties.generalCategory(cp) != .decimal_number) continue;
        const z = decimalZero(cp);
        if (zero) |seen| if (seen != z) return true;
        zero = z;
    }
    return false;
}

/// The zero of a decimal digit's system.
fn decimalZero(cp: u21) u21 {
    const zeros = &tables.decimal_zeros;
    var low: usize = 0;
    var high: usize = zeros.len;
    while (low < high) {
        const mid = (low + high) / 2;
        if (zeros[mid] <= cp) low = mid + 1 else high = mid;
    }
    return zeros[low - 1];
}

/// The longest run of nonspacing marks `repeated_mark` compares within:
/// a longer run already fails `long_mark_run`.
const max_marks = 32;

/// The mark checks, on the text's NFD: repeated marks, long runs, hidden
/// overlays.
fn marks(text: []const u8, f: *Failures) void {
    var run: [max_marks]u21 = undefined;
    var len: usize = 0;
    var lead = false;
    var it: normalize.Iterator(.nfd) = .init(text);
    while (it.next()) |cp| {
        if (lead and cp == 0x307) f.hidden_overlay = true;
        const class = normalize.combiningClass(cp);
        if (class == 0 or class == 230) lead = dotLead(cp);
        switch (properties.generalCategory(cp)) {
            .nonspacing_mark, .enclosing_mark => {
                if (std.mem.findScalar(u21, run[0..@min(len, max_marks)], cp) != null) f.repeated_mark = true;
                if (len < max_marks) run[len] = cp;
                len += 1;
                if (len > 4) f.long_mark_run = true;
            },
            else => len = 0,
        }
    }
}

/// A letter U+0307 would hide in: `i`, `j`, `l`, dotless `ı` and `ȷ`, a
/// Soft_Dotted letter, or one whose prototype ends in one of these.
fn dotLead(cp: u21) bool {
    if (dotted(cp)) return true;
    const p: Prototype = .of(cp);
    const last = p.at(p.len - 1);
    return last != cp and dotted(last);
}

fn dotted(cp: u21) bool {
    return switch (cp) {
        'i', 'j', 'l', 0x131, 0x237 => true,
        else => case.softDotted(cp),
    };
}
