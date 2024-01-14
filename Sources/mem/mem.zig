
/// A generic memory interface to route pages based on their layout address.
/// Sector must implement 'read', 'write' and 'pages'. Address is an integer
/// type, of which @sizeOf(Address) equals the total memory size in bytes.
pub fn Memory(comptime Sector_: type) type {
    return struct {

        const Self = @This();

        pub const Sector = Sector_;
        pub const Address = Sector.Address;
        pub const Result = Sector.Result;

        layout: []Sector,

        pub fn init(layout: []Sector) Self {
            return .{ .layout = layout };
        }

        pub fn section(self: *Self, address: Address) *Sector {
            var size_bytes: usize = 0;

            for (self.layout) |*section_| {
                size_bytes += section_.size();
                if (address < size_bytes)
                    return section_;
            }

            // TODO: verify in init
            unreachable;
        }

        pub fn size(self: *Self) usize {
            var size_bytes: usize = 0;
            for (self.layout) |*section_|
                size_bytes += section_.size();
            return size_bytes;
        }

        pub fn read(self: *Self, address: Address) Result {
            const section_ = self.section(address);
            const size_ = section_.size();
            return section_.read(@intCast(@mod(address, size_)));
        }

        pub fn write(self: *Self, address: Address, value: Result) void {
            const section_ = self.section(address);
            const size_ = section_.size();
            section_.write(@intCast(@mod(address, size_)), value);
        }
    };
}

// Mark: test

const PageTest = @import("test/page.zig");
const std = @import("std");

test "address alignment" {
    var storage = [_]PageTest {
        .{ .value = 0 },
        .{ .value = 10 } };
    const MemoryTest = Memory(PageTest);
    var memory = MemoryTest.init(&storage);

    try std.testing.expectEqual(@as(usize, 512), memory.size());
    try std.testing.expectEqual(@as(MemoryTest.Result, 0), memory.read(0));
    try std.testing.expectEqual(@as(MemoryTest.Result, 1), memory.read(1));
    try std.testing.expectEqual(@as(MemoryTest.Result, 255), memory.read(255));
    try std.testing.expectEqual(@as(MemoryTest.Result, 10), memory.read(256));
    try std.testing.expectEqual(@as(MemoryTest.Result, 11), memory.read(257));
}
