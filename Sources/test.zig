
test {
    _ = @import("mem/mem.zig");

    _ = @import("mem/pages/page.zig");
    _ = @import("mem/pages/store.zig");

    _ = @import("mem/regions/region.zig");
    _ = @import("mem/regions/linear.zig");
    _ = @import("mem/regions/map.zig");
}
