
const Region = @import("../region.zig").Region;

pub fn LinearRegion(
    comptime MemoryType: type
) type {
    return struct {

        const Self = @This();
        const Address = MemoryType.Address;
        const Interface = Region(Address);

        truth: *MemoryType, // Source of truth, providing memory
        pages: usize,       // Size of this region in pages
        offset: usize,      // Offset, in pages in the truth, where this region starts

        const regionTable = Interface.VTable {
            .pages = get_pages,
            .read = read,
            .write = write };
        pub fn region(self: *Self) Interface {
            return .{ .context = self, .vtable = regionTable };
        }

        pub fn get_pages(context: *anyopaque) usize {
            const self: *Self = @alignCast(@ptrCast(context));
            return self.pages;
        }

        pub fn read(context: *anyopaque, address: Address, offset: u8) u8 {
            const self: *Self = @alignCast(@ptrCast(context));
            _ = self;
            _ = address;
            _ = offset;
            return 0;
        }

        pub fn write(context: *anyopaque, address: Address, offset: u8, value: u8) void {
            const self: *Self = @alignCast(@ptrCast(context));
            _ = self;
            _ = address;
            _ = offset;
            _ = value;
        }
    };
}
