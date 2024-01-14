
const Region = @import("../region.zig");

/// Memory's 'sector' type must have a comptime-known 'size_bytes' constant,
/// and it must therefore be a fixed-size layout. A sector is here known as a
/// 'page'.
pub fn LinearRegion(comptime Memory_: type) type {
    return struct {

        const Self = @This();

        pub const Memory = Memory_;
        pub const Sector = Memory.Sector;
        pub const Address = Sector.Address;
        pub const Result = Sector.Result;
        pub const page_size_bytes = Sector.size_bytes;

        source: *Memory,     // Source of truth, providing memory
        size_pages: usize,   // Size of this region in pages
        offset_pages: usize, // Offset, in pages of the source, where this region starts

        pub fn physical_offset(self: *Self, address: Address) Address {
            return address + @as(Address, @intCast(self.offset_pages * page_size_bytes));
        }

        const regionTable = Region(Sector).VTable {
            .size = size,
            .read = read,
            .write = write };
        pub fn region(self: *Self) Region(Sector) {
            return .{ .context = self, .vtable = regionTable };
        }

        pub fn size(context: *anyopaque) usize {
            const self: *Self = @alignCast(@ptrCast(context));
            return self.size_pages * page_size_bytes;
        }

        pub fn read(context: *anyopaque, address: Address) Result {
            const self: *Self = @alignCast(@ptrCast(context));
            if (self.size_pages * page_size_bytes < address)
                unreachable;
            const physical_address = self.physical_offset(address);
            return self.source.read(physical_address);
        }

        pub fn write(context: *anyopaque, address: Address, value: Result) void {
            const self: *Self = @alignCast(@ptrCast(context));
            if (self.size_pages * page_size_bytes < address)
                unreachable;
            const physical_address = self.physical_offset(address);
            self.source.write(physical_address, value);
        }
    };
}

// Mark: test

const MemoryTest = @import("test/mem.zig");
const std = @import("std");

test "address alignment" {
    const RegionTest = LinearRegion(MemoryTest);
    var memory = MemoryTest {};
    var region = RegionTest {
        .source = &memory,
        .size_pages = 4,
        .offset_pages = 2 };

    try std.testing.expectEqual(@as(MemoryTest.Result, 2), RegionTest.read(&region, 0));
    try std.testing.expectEqual(@as(MemoryTest.Result, 2), RegionTest.read(&region, 1));
    try std.testing.expectEqual(@as(MemoryTest.Result, 2), RegionTest.read(&region, 255));
    try std.testing.expectEqual(@as(MemoryTest.Result, 3), RegionTest.read(&region, 256));
}
