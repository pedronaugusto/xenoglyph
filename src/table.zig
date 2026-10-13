//! The lookups the generated tables share. Each is a trie over every code
//! point in which equal blocks are stored once, so a table costs its
//! distinct blocks; the generator picks, for each table, the shape and
//! block sizes that make it smallest, or two stages for a table read on
//! every code point of the segmentation hot path.

/// Two stages: the code point's high bits pick a block in `blocks`, and its
/// low `shift` bits the entry in that block.
pub fn Stages(comptime Block: type, comptime Entry: type, comptime shift: u5) type {
    return struct {
        blocks: *const [0x110000 >> shift]Block,
        entries: []const Entry,

        const mask = (1 << shift) - 1;

        /// The entry of `cp`, which must be at most U+10FFFF.
        pub inline fn get(t: *const @This(), cp: u21) Entry {
            const block: usize = t.blocks[cp >> shift];
            return t.entries[(block << shift) | (cp & mask)];
        }
    };
}

/// Three stages: the top bits pick a run of blocks in `middle`, the middle
/// `middle_shift` bits a block from that run, and the low `leaf_shift` bits
/// the entry in it.
pub fn Trie(comptime Top: type, comptime Middle: type, comptime Entry: type, comptime middle_shift: u5, comptime leaf_shift: u5) type {
    return struct {
        top: *const [0x110000 >> (middle_shift + leaf_shift)]Top,
        middle: []const Middle,
        entries: []const Entry,

        const leaf_mask = (1 << leaf_shift) - 1;
        const middle_mask = (1 << middle_shift) - 1;

        /// The entry of `cp`, which must be at most U+10FFFF.
        pub inline fn get(t: *const @This(), cp: u21) Entry {
            const run: usize = t.top[cp >> (middle_shift + leaf_shift)];
            const block: usize = t.middle[(run << middle_shift) | ((cp >> leaf_shift) & middle_mask)];
            return t.entries[(block << leaf_shift) | (cp & leaf_mask)];
        }
    };
}
