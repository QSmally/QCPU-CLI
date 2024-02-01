
const PageTest = @import("page.zig");

const Self = @This();

pub const Sector = PageTest;
pub const Address = Sector.Address;
pub const Result = Sector.Result;
pub const page_size_bytes = 256;

pub fn region(self: *Self, comptime T: type) T {
    const regionTable = T.VTable {
        .size = size,
        .read = read,
        .write = write };
    return .{ .context = self, .vtable = regionTable };
}

pub fn size(context: *anyopaque) usize {
    _ = context;
    return 0;
}

pub fn read(context: *anyopaque, address: Address) Result {
    _ = context;
    return @as(Result, @intCast(address));
}

pub fn write(context: *anyopaque, address: Address, value: Result) void {
    _ = context;
    _ = address;
    _ = value;
}
