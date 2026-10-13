//! Source layers, lowest first. Every production source has one place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "values and lookups", .patterns = &.{
        "src/classes.zig",
        "src/table.zig",
    } },
    .{ .name = "generated tables", .patterns = &.{ "src/data/**", "src/data.zig" } },
    .{ .name = "properties and decoding", .patterns = &.{
        "src/properties.zig",
        "src/utf8.zig",
    } },
    .{ .name = "grapheme clusters", .patterns = &.{"src/grapheme.zig"} },
    .{ .name = "words, sentences and widths", .patterns = &.{
        "src/word.zig",
        "src/sentence.zig",
        "src/width.zig",
    } },
    .{ .name = "public", .patterns = &.{"src/xenoglyph.zig"} },
};

pub const entries: []const []const u8 = &.{};

/// src/data.zig publishes the generated tables of its directory.
pub const reexports = [_]struct { from: []const u8, to: []const u8 }{
    .{ .from = "src/data.zig", .to = "src/data/cluster.zig" },
    .{ .from = "src/data.zig", .to = "src/data/general_category.zig" },
    .{ .from = "src/data.zig", .to = "src/data/east_asian_width.zig" },
    .{ .from = "src/data.zig", .to = "src/data/word_break.zig" },
    .{ .from = "src/data.zig", .to = "src/data/sentence_break.zig" },
    .{ .from = "src/data.zig", .to = "src/data/line_break.zig" },
    .{ .from = "src/data.zig", .to = "src/data/emoji.zig" },
    .{ .from = "src/data.zig", .to = "src/data/core.zig" },
    .{ .from = "src/data.zig", .to = "src/data/script.zig" },
};

pub const modules: []const gantry.NamedModule = &.{};

const package_references = [_]gantry.rules.ReferenceRule{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "std",
        "shakedown",
        "ucd",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const references: []const gantry.rules.ReferenceRule = &package_references;

pub const required = [_][]const u8{
    "src/classes.zig",
    "src/table.zig",
    "src/properties.zig",
    "src/utf8.zig",
    "src/grapheme.zig",
    "src/word.zig",
    "src/sentence.zig",
    "src/width.zig",
    "src/xenoglyph.zig",
    "src/tests.zig",
};
