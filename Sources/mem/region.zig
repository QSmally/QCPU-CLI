
pub fn Region(
    comptime AddressType: type
) type {
    return struct {

        const Self = @This();
        const Address = AddressType;

        context: *anyopaque,
        vtable: VTable,

        pub const VTable = struct {
            pages: *const fn (*anyopaque) usize,
            read: *const fn (*anyopaque, Address, u8) u8,
            write: *const fn (*anyopaque, Address, u8, u8) void
        };

        pub fn pages(self: *Self) usize {
            return self.vtable.pages(self.context);
        }

        pub fn read(self: *Self, address: Address, offset: u8) u8 {
            return self.vtable.read(address, offset);
        }

        pub fn write(self: *Self, address: Address, offset: u8, value: u8) void {
            return self.vtable.write(address, offset, value);
        }
    };
}
