//! The generated tables, one file each in data/; tools/generate.zig writes
//! them from the UCD files in ucd/.
pub const cluster = @import("data/cluster.zig");
pub const general_category = @import("data/general_category.zig");
pub const east_asian_width = @import("data/east_asian_width.zig");
pub const word_break = @import("data/word_break.zig");
pub const sentence_break = @import("data/sentence_break.zig");
pub const line_break = @import("data/line_break.zig");
pub const emoji = @import("data/emoji.zig");
pub const core = @import("data/core.zig");
pub const script = @import("data/script.zig");
