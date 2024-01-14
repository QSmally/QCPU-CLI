
/// An upper-level virtual table of the memory region types, which define
/// unique behaviour and propagation of data.
pub fn Region(comptime Sector_: type) type {
    return struct {

        const Self = @This();

        pub const Sector = Sector_;
        pub const Address = Sector.Address;
        pub const Result = Sector.Result;

        pub const VTable = struct {
            size: *const fn (*anyopaque) usize,
            read: *const fn (*anyopaque, Address) Result,
            write: *const fn (*anyopaque, Address, Result) void
        };

        context: *anyopaque,
        vtable: VTable,

        pub fn size(self: *Self) usize {
            return self.vtable.size(self.context);
        }

        pub fn read(self: *Self, address: Address) Result {
            return self.vtable.read(self.context, address);
        }

        pub fn write(self: *Self, address: Address, value: Result) void {
            return self.vtable.write(self.context, address, value);
        }
    };
}
