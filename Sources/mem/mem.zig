
const std = @import("std");

pub fn Memory(
    comptime PageType: type,
    comptime AddressType: type,
    comptime Size: usize
) type {
    if (@bitSizeOf(AddressType) < 8)
        @compileError("address type must be greater than or equal to 8 bits");

    return struct {

        const Self = @This();

        pages: [Size]PageType,

        pub fn init(layout: [Size]PageType) Self {
            return .{ .pages = layout };
        }

        pub fn read(self: *Self, address: AddressType) u8 {
            return self.pages[phys(address)].read(offset(address));
        }

        pub fn write(self: *Self, address: AddressType, value: u8) void {
            self.pages[phys(address)].write(offset(address), value);
        }

        inline fn phys(address: AddressType) AddressType {
            return address >> 8;
        }

        inline fn offset(address: AddressType) u8 {
            return @truncate(address);
        }
    };
}

test {
    _ = @import("page.zig");
    _ = @import("vmpage.zig");
    _ = @import("pages/store.zig");
}

const Page = @import("page.zig").Page;
const StorePage = @import("pages/store.zig");

test "address alignment" {
    const MemoryType = Memory(Page, u16, 2);
    const store_0 = StorePage { .container = .{ 0, 1, 2, 3 } ** (256/4) };
    const store_1 = StorePage { .container = .{ 4, 5, 6, 7 } ** (256/4) };

    var physmem = MemoryType.init(.{
        @unionInit(Page, "store", store_0),
        @unionInit(Page, "store", store_1) });

    try std.testing.expectEqual(physmem.read(0), 0);
    try std.testing.expectEqual(physmem.read(2), 2);
    try std.testing.expectEqual(physmem.read(4), 0);
    try std.testing.expectEqual(physmem.read(5), 1);
    try std.testing.expectEqual(physmem.read(255), 3);
    try std.testing.expectEqual(physmem.read(256), 4);

    physmem.write(0, 24);
    try std.testing.expectEqual(physmem.read(0), 24);

    physmem.write(511, 24);
    try std.testing.expectEqual(physmem.read(511), 24);
}
