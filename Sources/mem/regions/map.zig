
const Region = @import("region.zig").Region;

/// Memory's 'sector' type must have a comptime-known 'size_bytes' constant,
/// and it must therefore be a fixed-size layout. A sector is here known as a
/// 'page'.
pub fn MapRegion(comptime Memory_: type, comptime Controller_: type) type {
    return struct {

        const Self = @This();
        const permissionsOffset = 1;
        const physicalPageOffset = 0;

        pub const Memory = Memory_;
        pub const Sector = Memory.Sector;
        pub const Address = Sector.Address;
        pub const Result = Sector.Result;
        pub const page_size_bytes = Sector.size_bytes;
        pub const Controller = Controller_;

        pub const stride = 2;

        comptime {
            if (@bitSizeOf(Address) != @bitSizeOf(u16))
                @compileError("map region only supports u16 address size calculation");
            if (@bitSizeOf(Result) != @bitSizeOf(u8))
                @compileError("map region only supports u8 data size calculation");
        }

        pub const Permissions = packed struct(Result) {
            readonly: bool,
            cacheable: bool,
            copy_on_write: bool,
            executable: bool,
            dirty: bool,
            _: u3
        };

        pub const Interrupts = enum(Result) {
            SegmentationFault = 0
        };

        source: *Memory,            // Source of truth, providing memory
        size_pages: usize,          // Size of this region in pages
        map_region: Region(Sector), // Region containing the map protocol
        map_offset: usize,          // Offset from the start of the region for the mappings
        bridge: *Controller,        // Reference to push interrupts to

        pub fn virtual_page(address: Address) Address {
            return @divFloor(address, @as(Address, @truncate(page_size_bytes)));
        }

        pub fn physical_address(page: Address, address: Address) Address {
            return ((page & 0xFF) << 8) | (address & 0xFF);
        }

        pub fn physical_page(self: *Self, page: Address) Address {
            const map_location = page * stride;
            const map_byte_offset: Address = @intCast(self.map_offset * page_size_bytes + physicalPageOffset);
            const data = self.map_region.read(map_location + map_byte_offset);
            return @as(Address, @intCast(data));
        }

        pub fn permissions(self: *Self, page: Address) Permissions {
            const map_location = page * stride;
            const map_byte_offset: Address = @intCast(self.map_offset * page_size_bytes + permissionsOffset);
            const data = self.map_region.read(map_location + map_byte_offset);
            return @as(Permissions, @bitCast(data));
        }

        // Region(Sector)

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
            const virtual_page_ = Self.virtual_page(address);
            const permissions_ = self.permissions(virtual_page_);

            _ = permissions_;
            return Self.read_unprivileged(context, address);
        }

        pub fn write(context: *anyopaque, address: Address, value: Result) void {
            const self: *Self = @alignCast(@ptrCast(context));
            if (self.size_pages * page_size_bytes < address)
                unreachable;
            const virtual_page_ = Self.virtual_page(address);
            const permissions_ = self.permissions(virtual_page_);

            if (permissions_.readonly)
                return self.bridge.interrupt(@intFromEnum(Interrupts.SegmentationFault));
            Self.write_unprivileged(context, address, value);
        }

        // Region(Sector)

        const regionUnprivilegedTable = Region(Sector).VTable {
            .size = size,
            .read = read_unprivileged,
            .write = write_unprivileged };
        pub fn region_unprivileged(self: *Self) Region(Sector) {
            return .{ .context = self, .vtable = regionUnprivilegedTable };
        }

        pub fn read_unprivileged(context: *anyopaque, address: Address) Result {
            const self: *Self = @alignCast(@ptrCast(context));
            if (self.size_pages * page_size_bytes < address)
                unreachable;
            const virtual_page_ = Self.virtual_page(address);
            const physical_page_ = self.physical_page(virtual_page_);
            const physical_address_ = Self.physical_address(physical_page_, address);
            return self.source.read(physical_address_);
        }

        pub fn write_unprivileged(context: *anyopaque, address: Address, value: Result) void {
            const self: *Self = @alignCast(@ptrCast(context));
            if (self.size_pages * page_size_bytes < address)
                unreachable;
            const virtual_page_ = Self.virtual_page(address);
            const physical_page_ = self.physical_page(virtual_page_);
            const physical_address_ = Self.physical_address(physical_page_, address);
            self.source.write(physical_address_, value);
        }
    };
}

// Mark: test

const MemoryTest = @import("test/mem.zig");
const BridgeTest = @import("test/bridge.zig");
const RegionTest = @import("test/linregion.zig");
const std = @import("std");

const MapRegion_ = MapRegion(MemoryTest, BridgeTest);
var memory = MemoryTest {};
var map_region = RegionTest {};
var bridge = BridgeTest {};
var region = MapRegion_ {
    .source = &memory,
    .size_pages = 4,
    .map_region = map_region.region(Region(MemoryTest.Sector)),
    .map_offset = 0,
    .bridge = &bridge };

test "permission mapping" {
    const permissions_0 = MapRegion_.permissions(&region, 0); // [0] * 2 + 1 = 0b00000001
    try std.testing.expectEqual(@as(bool, true), permissions_0.readonly);
    try std.testing.expectEqual(@as(bool, false), permissions_0.cacheable);
    try std.testing.expectEqual(@as(bool, false), permissions_0.copy_on_write);
    try std.testing.expectEqual(@as(bool, false), permissions_0.executable);
    try std.testing.expectEqual(@as(bool, false), permissions_0.dirty);

    const permissions_1 = MapRegion_.permissions(&region, 1); // [1] * 2 + 1 = 0b00000011
    try std.testing.expectEqual(@as(bool, true), permissions_1.readonly);
    try std.testing.expectEqual(@as(bool, true), permissions_1.cacheable);
    try std.testing.expectEqual(@as(bool, false), permissions_1.copy_on_write);
    try std.testing.expectEqual(@as(bool, false), permissions_1.executable);
    try std.testing.expectEqual(@as(bool, false), permissions_1.dirty);

    const permissions_2 = MapRegion_.permissions(&region, 2); // [2] * 2 + 1 = 0b00000101
    try std.testing.expectEqual(@as(bool, true), permissions_2.readonly);
    try std.testing.expectEqual(@as(bool, false), permissions_2.cacheable);
    try std.testing.expectEqual(@as(bool, true), permissions_2.copy_on_write);
    try std.testing.expectEqual(@as(bool, false), permissions_2.executable);
    try std.testing.expectEqual(@as(bool, false), permissions_2.dirty);
}

test "physical page mapping" {
    try std.testing.expectEqual(@as(MemoryTest.Result, 0), MapRegion_.read(&region, 0));   // [0] * 2 + 0 = 0
    try std.testing.expectEqual(@as(MemoryTest.Result, 0), MapRegion_.read(&region, 1));   // [0] * 2 + 0 = 0
    try std.testing.expectEqual(@as(MemoryTest.Result, 0), MapRegion_.read(&region, 255)); // [0] * 2 + 0 = 0
    try std.testing.expectEqual(@as(MemoryTest.Result, 2), MapRegion_.read(&region, 256)); // [1] * 2 + 0 = 2
    try std.testing.expectEqual(@as(MemoryTest.Result, 4), MapRegion_.read(&region, 512)); // [2] * 2 + 0 = 4
}

test "interrupt mapping" {
    try std.testing.expectEqualSlices(bool, &.{ false, false, false, false }, &bridge.flags);

    MapRegion_.write_unprivileged(&region, 2, 255);
    try std.testing.expectEqualSlices(bool, &.{ false, false, false, false }, &bridge.flags);

    MapRegion_.write(&region, 2, 255);
    try std.testing.expectEqualSlices(bool, &.{ true, false, false, false }, &bridge.flags);
}
