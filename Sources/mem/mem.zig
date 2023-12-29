
const std = @import("std");

pub fn Memory(
    comptime SectorType: type,
    comptime AddressType: type
) type {
    return struct {

        const Self = @This();

        pub const Address = AddressType;

        layout: []SectorType,

        pub fn init(layout: []SectorType) Self {
            const address_size = @bitSizeOf(Address);
            var page_total: usize = 0;

            for (layout) |*section_|
                page_total += section_.pages();

            // TODO: make comptime
            if (page_total != std.math.pow(usize, 2, address_size))
                @panic("address size and page amount don't match");
            return .{ .layout = layout };
        }

        pub fn section(self: *Self, address: Address) *SectorType {
            var page_total: usize = 0;

            for (self.layout) |*section_| {
                page_total += section_.pages();
                if (address < page_total)
                    return section_;
            }

            @panic("is verified by init");
        }

        pub fn read(self: *Self, address: Address, offset: u8) u8 {
            const section_ = self.section(address);
            return section_.read(offset);
        }

        pub fn write(self: *Self, address: Address, offset: u8, value: u8) void {
            const section_ = self.section(address);
            section_.write(offset, value);
        }
    };
}

// Mark: test

const Page = @import("page.zig").Page;
const StorePage = @import("pages/store.zig");

test "address alignment" {
    const MemoryType = Memory(Page, u8);
    var store = [_]Page {
        @unionInit(Page, "store", .{ .container = .{ 0, 1, 2, 3 } ** (256/4) }),
        @unionInit(Page, "store", .{ .container = .{ 4, 5, 6, 7 } ** (256/4) }) } ** (256/2);
    var physmem = MemoryType.init(&store);

    try std.testing.expectEqual(physmem.read(0, 0), 0);
    try std.testing.expectEqual(physmem.read(0, 1), 1);
    try std.testing.expectEqual(physmem.read(0, 2), 2);
    try std.testing.expectEqual(physmem.read(0, 3), 3);
    try std.testing.expectEqual(physmem.read(0, 4), 0);
    try std.testing.expectEqual(physmem.read(1, 0), 4);

    physmem.write(0, 0, 24);
    try std.testing.expectEqual(physmem.read(0, 0), 24);
}

const Region = @import("region.zig").Region;
const LinearRegion = @import("regions/linear.zig").LinearRegion;
const MappedRegion = @import("regions/mmap.zig").MappedRegion;

test "region chain" {
    const PhysicalMemoryType = Memory(Page, u8);
    var physmem = blk: {
        var store = [_]Page {
            @unionInit(Page, "store", .{ .container = .{ 0, 1, 2, 3 } ** (256/4) }),
            @unionInit(Page, "store", .{ .container = .{ 4, 5, 6, 7 } ** (256/4) }) } ** (256/2);
        break :blk PhysicalMemoryType.init(&store);
    };

    var kfixed = LinearRegion(PhysicalMemoryType) {
        .truth = &physmem,
        .pages = 192,
        .offset = 0 };
    var kvariable = MappedRegion(PhysicalMemoryType) {
        .truth = &physmem,
        .pages = 48,
        .offset = 0,
        .mmap = kfixed.region() };
    var userland = MappedRegion(PhysicalMemoryType) {
        .truth = &physmem,
        .pages = 16,
        .offset = 0,
        .mmap = kvariable.region() };

    const RegionType = Region(u8);
    const VirtualMemoryType = Memory(RegionType, u8);
    var virtmem = blk: {
        var store = [_]RegionType {
            userland.region(),
            kfixed.region(),
            kvariable.region() };
        break :blk VirtualMemoryType.init(&store);
    };

    // TODO: Offset type declaration
    _ = virtmem;
    try std.testing.expectEqual(physmem.read(2, 1), 1);
    // try std.testing.expectEqual(virtmem.read(2, 1), 1);
    try std.testing.expectEqual(physmem.read(3, 1), 5);
    // try std.testing.expectEqual(physmem.read(3, 1), 5);

//     physmem.write(2, 1, 24);
//     try std.testing.expectEqual(physmem.read(2, 1), 1);
//     try std.testing.expectEqual(virtmem.read(2, 1), 24);
//     try std.testing.expectEqual(physmem.read(3, 1), 5);
//     try std.testing.expectEqual(physmem.read(3, 1), 24);

//     virtmem.write(3, 1, 64);
//     try std.testing.expectEqual(physmem.read(2, 1), 64);
//     try std.testing.expectEqual(virtmem.read(2, 1), 24);
//     try std.testing.expectEqual(physmem.read(3, 1), 64);
//     try std.testing.expectEqual(physmem.read(3, 1), 24);
}
