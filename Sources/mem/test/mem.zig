
const PageTest = @import("page.zig");

const Self = @This();

pub const Sector = PageTest;
pub const Address = Sector.Address;
pub const Result = Sector.Result;

pub fn read(self: *Self, address: Address) Result {
    _ = self;
    // hack to return the current physical page
    return @as(Result, @intCast(@divFloor(address, 256)));
}
