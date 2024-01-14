
const std = @import("std");

// TODO: make union for more page types
/// A regfile.
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

        comptime {
            const addressable_elements = std.math.pow(usize, 2, @bitSizeOf(Address));
            if (elements > addressable_elements)
                @compileError("amount of elements must be less than or equal to total amount of elements");
        }

        container: [elements]Result,

        pub fn size(self: *Self) usize {
            _ = self;
            return size_bytes;
        }

        pub fn read(self: *Self, address: Address) Result {
            return self.container[address];
        }

        pub fn write(self: *Self, address: Address, value: Result) void {
            self.container[address] = value;
        }
    };
}

// Mark: test

test "read/write" {
    const PageTest = Page(u16, u8, 256);

    try std.testing.expectEqual(256, PageTest.size_bytes);
    try std.testing.expectEqual(256, PageTest.elements);

    var page = PageTest { .container = .{ 0 } ** PageTest.elements };

    page.write(1, 24);
    page.write(2, 64);

    try std.testing.expectEqual(@as(PageTest.Result, 0), page.read(0));
    try std.testing.expectEqual(@as(PageTest.Result, 24), page.read(1));
    try std.testing.expectEqual(@as(PageTest.Result, 64), page.read(2));
}
