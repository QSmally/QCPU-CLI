
const std = @import("std");

/// A regfile with a fixed size across all pages.
pub fn Page(
    comptime Address_: type,
    comptime Result_: type,
    comptime size_bytes_: usize
) type {
    return struct {

        const Self = @This();

        pub const Address = Address_;
        pub const Result = Result_;
        pub const size_bytes = size_bytes_;
        pub const elements = size_bytes / @sizeOf(Result);

        pub const VTable = struct {
            read: *const fn (*anyopaque, Address) Result,
            write: *const fn (*anyopaque, Address, Result) void
        };

        comptime {
            const addressable_elements = std.math.pow(usize, 2, @bitSizeOf(Address));
            if (elements > addressable_elements)
                @compileError("amount of elements must be less than or equal to total amount of elements");
        }

        context: *anyopaque,
        vtable: VTable,

        // Memory(anytype)

        pub fn size(self: *Self) usize {
            _ = self;
            return size_bytes;
        }

        pub fn read(self: *Self, address: Address) Result {
            return self.vtable.read(self.context, address);
        }

        pub fn write(self: *Self, address: Address, value: Result) void {
            return self.vtable.write(self.context, address, value);
        }
    };
}
