
const Region = @import("../region.zig");

/// ...
pub fn LinearRegion(comptime Memory_: type) type {
    return struct {

        const Self = @This();

        pub const Memory = Memory_;
        pub const Sector = Memory.Sector;
        pub const Address = Sector.Address;
        pub const Result = Sector.Result;
        pub const Interface = Region(Sector);

        source: *Memory,

        const regionTable = Interface.VTable {
            .size = size,
            .read = read,
            .write = write };
        pub fn region(self: *Self) Interface {
            return .{ .context = self, .vtable = regionTable };
        }

        pub fn size(context: *anyopaque) usize {
            const self: *Self = @alignCast(@ptrCast(context));
            _ = self;
            return 256;
        }

        pub fn read(context: *anyopaque, address: Address) Result {
            const self: *Self = @alignCast(@ptrCast(context));
            _ = self;
            _ = address;
            return 0;
        }

        pub fn write(context: *anyopaque, address: Address, value: Result) void {
            const self: *Self = @alignCast(@ptrCast(context));
            _ = self;
            _ = address;
            _ = value;
        }
    };
}
