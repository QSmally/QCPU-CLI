
pub const Token = @import("Token.zig");
pub const AsmTokeniser = @import("AsmTokeniser.zig");
pub const AsmAst = @import("AsmAst.zig");

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
    // _ = @import("AsmSemanticAir.zig");

    // _ = @import("mem/mem.zig");

    // _ = @import("mem/pages/page.zig");
    // _ = @import("mem/pages/store.zig");

    // _ = @import("mem/regions/region.zig");
    // _ = @import("mem/regions/linear.zig");
    // _ = @import("mem/regions/map.zig");
}
