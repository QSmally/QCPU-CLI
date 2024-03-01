
/// A persistent memory page.
pub fn StorePage(comptime Page_: type) type {
    return struct {

        const Self = @This();

        pub const Page = Page_;
        pub const Address = Page.Address;
        pub const Result = Page.Result;
        pub const size_bytes = Page.size_bytes;
        pub const elements = Page.elements;

        container: [elements]Result,

        pub fn init(value: Result) Self {
            return .{ .container = .{ value } ** elements };
        }

        // Page

        const pageTable = Page.VTable {
            .read = read,
            .write = write };
        pub fn page(self: *Self) Page {
            return .{ .context = self, .vtable = pageTable };
        }

        pub fn read(context: *anyopaque, address: Address) Result {
            const self: *Self = @alignCast(@ptrCast(context));
            if (size_bytes < address) unreachable;
            return self.container[address];
        }

        pub fn write(context: *anyopaque, address: Address, value: Result) void {
            const self: *Self = @alignCast(@ptrCast(context));
            if (size_bytes < address) unreachable;
            self.container[address] = value;
        }
    };
}

// Mark: test

const PageInterfaceTest = @import("page.zig").Page;
const std = @import("std");

test "read/write" {
    const PageInterface = PageInterfaceTest(u16, u8, 256);
    const PageTest = StorePage(PageInterface);

    try std.testing.expectEqual(256, PageTest.size_bytes);
    try std.testing.expectEqual(256, PageTest.elements);

    var page = PageTest { .container = .{ 0 } ** PageTest.elements };

    PageTest.write(&page, 1, 24);
    PageTest.write(&page, 2, 64);

    try std.testing.expectEqual(@as(PageTest.Result, 0), PageTest.read(&page, 0));
    try std.testing.expectEqual(@as(PageTest.Result, 24), PageTest.read(&page, 1));
    try std.testing.expectEqual(@as(PageTest.Result, 64), PageTest.read(&page, 2));
}
