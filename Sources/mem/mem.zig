
const std = @import("std");
const Reader = @import("./reader.zig").Reader;

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

        pub fn single(self: *Self, comptime T: type, address: Address, mode: std.builtin.Endian) T {
            var reader_ = self.reader(address, mode);
            return reader_.read(T);
        }

        pub fn reader(self: *Self, offset: Address, mode: std.builtin.Endian) Reader(*Self) {
            return Reader(*Self).init(self, mode, offset);
        }
    };
}

// Mark: test

const PageTest = @import("test/page.zig");

const MemoryTest = Memory(PageTest);

test "address alignment" {
    var storage = [_]PageTest {
        .{ .value = 0 },
        .{ .value = 10 } };
    var memory = MemoryTest.init(&storage);

    try std.testing.expectEqual(@as(usize, 512), memory.size());
    try std.testing.expectEqual(@as(MemoryTest.Result, 0), memory.read(0));
    try std.testing.expectEqual(@as(MemoryTest.Result, 1), memory.read(1));
    try std.testing.expectEqual(@as(MemoryTest.Result, 255), memory.read(255));
    try std.testing.expectEqual(@as(MemoryTest.Result, 10), memory.read(256));
    try std.testing.expectEqual(@as(MemoryTest.Result, 11), memory.read(257));
}

test "word" {
    var storage = [_]PageTest { .{ .value = 0 } };
    var memory = MemoryTest.init(&storage);

    try std.testing.expectEqual(@as(MemoryTest.Address, 513), memory.single(MemoryTest.Address, 1, .Little)); // (1 << 0) + (2 << 8)
    try std.testing.expectEqual(@as(MemoryTest.Address, 770), memory.single(MemoryTest.Address, 2, .Little)); // (2 << 0) + (3 << 8)
    try std.testing.expectEqual(@as(MemoryTest.Address, 258), memory.single(MemoryTest.Address, 1, .Big)); // (1 << 8) + (2 << 0)
}
