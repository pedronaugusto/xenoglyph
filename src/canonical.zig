//! Canonical ordering and canonical composition (UAX #15) over any stream
//! of fully decomposed code points, and the combining classes and primary
//! composites they read, internal to xenoglyph: `normalize` runs it over a
//! text's decomposition, and `case` over the stages of the caseless
//! matches. Nothing allocates.
const data = @import("data.zig");

const tables = data.normalization;

/// Canonical_Combining_Class.
pub fn combiningClass(cp: u21) u8 {
    if (cp > 0x10ffff) return 0;
    return tables.ccc.get(cp);
}

pub const hangul = struct {
    pub const s_base = 0xac00;
    pub const l_base = 0x1100;
    pub const v_base = 0x1161;
    pub const t_base = 0x11a7;
    pub const l_count = 19;
    pub const v_count = 21;
    pub const t_count = 28;
    pub const n_count = v_count * t_count;
    pub const s_count = l_count * n_count;

    pub fn syllable(cp: u21) bool {
        return cp >= s_base and cp < s_base + s_count;
    }
};

/// The primary composite of `first` and `second`, if there is one: the
/// composition canonical composition makes when nothing blocks it.
pub fn compose(first: u21, second: u21) ?u21 {
    // Hangul: L V to LV, LV T to LVT.
    if (first >= hangul.l_base and first < hangul.l_base + hangul.l_count and second >= hangul.v_base and second < hangul.v_base + hangul.v_count)
        return hangul.s_base + ((first - hangul.l_base) * hangul.v_count + second - hangul.v_base) * hangul.t_count;
    if (hangul.syllable(first) and (first - hangul.s_base) % hangul.t_count == 0 and second > hangul.t_base and second < hangul.t_base + hangul.t_count)
        return first + (second - hangul.t_base);
    const key = (@as(u64, first) << 21) | second;
    const keys = &tables.pair_keys;
    var low: usize = 0;
    var high: usize = keys.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (keys[mid] < key) low = mid + 1 else high = mid;
    }
    if (low < keys.len and keys[low] == key) return tables.pair_composites[low];
    return null;
}

/// Canonical ordering, and for `composes` canonical composition, of the
/// fully decomposed code points `Source` gives: anything with `next() ?u21`,
/// `position() Source.Position`, `seek(Source.Position)` and
/// `Position.eql`. A run is ordered in a buffer of 32 code points; a longer
/// run is read again from its positions once for each combining class in it.
pub fn Canonical(comptime Source: type, comptime composes: bool) type {
    return struct {
        const Self = @This();
        const capacity = 32;
        const Position = Source.Position;

        /// Private: the decomposed input.
        source: Source,
        /// Private: the run being given out, in canonical order and, for
        /// the composed forms, composed.
        buffer: [capacity]u21 = undefined,
        len: u8 = 0,
        out: u8 = 0,
        /// Private: a starter read past the end of the run; the source
        /// stands after it.
        pending: ?u21 = null,
        /// Private: the non-starters of a run too long for the buffer,
        /// given out a combining class at a time.
        long: ?Long = null,

        const Long = struct {
            /// Where the run's non-starters start and where they end.
            marks: Position,
            end: Position,
            /// The combining class being given out, and where its reading
            /// stands.
            class: u8 = 0,
            cursor: Position,
            /// For the composed forms: the run's starter as the compositions
            /// so far make it, and whether a non-starter of `class` was kept.
            starter: ?u21,
            kept: bool = false,
        };

        /// Over the decomposition of `bytes`, for a `Source` that reads
        /// bytes.
        pub fn init(bytes: []const u8) Self {
            return .{ .source = .{ .bytes = bytes } };
        }

        /// The next code point of the normal form, or null at the end.
        pub fn next(it: *Self) ?u21 {
            while (true) {
                if (it.out < it.len) {
                    defer it.out += 1;
                    return it.buffer[it.out];
                }
                if (it.long != null) {
                    if (it.nextLong()) |cp| return cp;
                    continue;
                }
                if (!it.fill()) return null;
            }
        }

        /// Gathers the next run into the buffer: a starter (or, at the
        /// start of the text, none) and the non-starters after it.
        fn fill(it: *Self) bool {
            it.len = 0;
            it.out = 0;
            if (it.pending) |starter| {
                it.pending = null;
                it.buffer[0] = starter;
                it.len = 1;
                it.gather(starter);
                return true;
            }
            // Only at the start of the text, or after a long run, which ends
            // where a starter is next.
            const before = it.source.position();
            const first = it.source.next() orelse return false;
            if (combiningClass(first) != 0) {
                // At the start of the text: the run has no starter, and its
                // non-starters begin with this one.
                it.source.seek(before);
                it.gather(null);
            } else {
                it.buffer[0] = first;
                it.len = 1;
                it.gather(first);
            }
            return true;
        }

        /// Reads non-starters onto the buffer until a starter, which it
        /// keeps pending or, composed with a lone starter, absorbs. `starter`
        /// is the run's starter; its non-starters begin where the source
        /// stands.
        fn gather(it: *Self, starter: ?u21) void {
            var s = starter;
            var from = it.source.position();
            while (true) {
                const cp = it.source.next() orelse break;
                if (combiningClass(cp) == 0) {
                    it.finish();
                    if (composes and it.len == 1 and s != null) {
                        if (compose(it.buffer[0], cp)) |composite| {
                            it.buffer[0] = composite;
                            s = composite;
                            from = it.source.position();
                            continue;
                        }
                    }
                    it.pending = cp;
                    return;
                }
                if (it.len == capacity) return it.startLong(s, from);
                it.buffer[it.len] = cp;
                it.len += 1;
            }
            it.finish();
        }

        /// Puts the buffered run in canonical order and composes it.
        fn finish(it: *Self) void {
            const run = it.buffer[0..it.len];
            const marks_from: usize = if (combiningClass(run[0]) == 0) 1 else 0;
            // A stable insertion sort by combining class.
            var i: usize = marks_from + 1;
            while (i < run.len) : (i += 1) {
                const cp = run[i];
                const class = combiningClass(cp);
                var j: usize = i;
                while (j > marks_from and combiningClass(run[j - 1]) > class) : (j -= 1) run[j] = run[j - 1];
                run[j] = cp;
            }
            if (!composes or marks_from == 0) return;
            // Canonical composition: a non-starter composes with the starter
            // unless a kept non-starter of its class stands between.
            var kept: u8 = 1;
            var last: u8 = 0;
            for (run[1..]) |cp| {
                const class = combiningClass(cp);
                if (last != class) if (compose(run[0], cp)) |composite| {
                    run[0] = composite;
                    continue;
                };
                run[kept] = cp;
                kept += 1;
                last = class;
            }
            it.len = kept;
        }

        /// A run longer than the buffer: finds where its non-starters end,
        /// then gives out its starter and the non-starters a class at a time.
        fn startLong(it: *Self, starter: ?u21, marks: Position) void {
            var scan = it.source;
            scan.seek(marks);
            var end = scan.position();
            while (scan.next()) |cp| {
                if (combiningClass(cp) == 0) break;
                end = scan.position();
            }
            const long: Long = .{ .marks = marks, .end = end, .cursor = end, .starter = starter };
            it.source.seek(end);
            it.out = 0;
            it.len = 0;
            if (starter) |s| {
                it.buffer[0] = s;
                it.len = 1;
                if (composes) {
                    const result = it.composeLong(long);
                    it.buffer[0] = result.starter;
                    // Every non-starter composed: the starter stays open to
                    // the starter after the run, as in a short run.
                    if (!result.kept) return it.gather(result.starter);
                }
            }
            it.long = long;
        }

        /// Every composition of a long run, in canonical order: the final
        /// starter, and whether any non-starter is kept.
        fn composeLong(it: *const Self, long: Long) struct { starter: u21, kept: bool } {
            var starter = long.starter.?;
            var any_kept = false;
            var class: u8 = 0;
            while (it.classAbove(long, class)) |c| : (class = c) {
                var scan = it.source;
                scan.seek(long.marks);
                var kept = false;
                while (!scan.position().eql(long.end)) {
                    const cp = scan.next().?;
                    if (combiningClass(cp) != c) continue;
                    if (!kept) if (compose(starter, cp)) |composite| {
                        starter = composite;
                        continue;
                    };
                    kept = true;
                    any_kept = true;
                }
            }
            return .{ .starter = starter, .kept = any_kept };
        }

        /// The smallest combining class above `class` among a long run's
        /// non-starters.
        fn classAbove(it: *const Self, long: Long, class: u8) ?u8 {
            var scan = it.source;
            scan.seek(long.marks);
            var best: ?u8 = null;
            while (!scan.position().eql(long.end)) {
                const c = combiningClass(scan.next().?);
                if (c > class and (best == null or c < best.?)) best = c;
            }
            return best;
        }

        /// The next non-starter of a long run, or null when it is done.
        fn nextLong(it: *Self) ?u21 {
            const long = &it.long.?;
            while (true) {
                if (long.cursor.eql(long.end)) {
                    long.class = it.classAbove(long.*, long.class) orelse {
                        it.long = null;
                        return null;
                    };
                    long.cursor = long.marks;
                    long.kept = false;
                }
                var scan = it.source;
                scan.seek(long.cursor);
                const cp = scan.next().?;
                long.cursor = scan.position();
                if (combiningClass(cp) != long.class) continue;
                if (composes) if (long.starter) |s| if (!long.kept) if (compose(s, cp)) |composite| {
                    long.starter = composite;
                    continue;
                };
                long.kept = true;
                return cp;
            }
        }
    };
}
