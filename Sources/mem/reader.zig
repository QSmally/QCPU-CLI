
const std = @import("std");

pub fn Reader(comptime Source: type) type {
    return struct {

        const Self = @This();

        source: Source,
        endianness: std.builtin.Endian,
        index: usize,

        pub fn init(source: Source, endianness: std.builtin.Endian, offset: usize) Self {
            return .{
                .source = source,
                .endianness = endianness,
                .index = offset };
        }

        pub fn read(self: *Self, comptime T: type) T {
            return switch (@typeInfo(T)) {
                .Int => self.read_int(T),
                .Struct => self.read_struct(T),
                else => @compileError("unsupported type")
            };
        }

        fn read_int(self: *Self, comptime T: type) T {
            const size = @bitSizeOf(T) / 8;
            std.debug.assert(size != 0);

            var output: [size]u8 = undefined;

            for (0..size) |byte| {
                const byte_index = if (self.endianness == .Little) byte else size - byte - 1;
                const element = self.source.read(@intCast(self.index + byte_index));
                output[byte] = element;
            }

            self.index += size;
            const reference: *align(1) const T = @ptrCast(&output);
            return reference.*;
        }

        fn read_struct(self: *Self, comptime T: type) T {
            var output: T = undefined;

            inline for (std.meta.fields(T)) |field|
                @field(output, field.name) = self.read(field.type);
            return output;
        }
    };
}

// Mark: test

const TestSource = struct {

    pub fn read(_: *@This(), address: u8) u8 {
        return address;
    }
};

test "read int little endian" {
    const TestReader = Reader(TestSource);
    var test_source: TestSource = .{};
    var reader = TestReader.init(test_source, .Little, 0);

    try std.testing.expectEqual(reader.read(u16), 256); // (0 << 0) + (1 << 8)
    try std.testing.expectEqual(reader.read(u24), 262_914); // (2 << 0) + (3 << 8) + (4 << 16)
}

test "read int big endian" {
    const TestReader = Reader(TestSource);
    var test_source: TestSource = .{};
    var reader = TestReader.init(test_source, .Big, 0);

    try std.testing.expectEqual(reader.read(u16), 1); // (0 << 8) + (1 << 0)
    try std.testing.expectEqual(reader.read(u24), 131_844); // (2 << 16) + (3 << 8) + (4 << 0)
}

test "read into struct" {
    const TestStruct = struct {
        foo: u16,
        bar: u24
    };

    const TestReader = Reader(TestSource);
    var test_source: TestSource = .{};
    var reader = TestReader.init(test_source, .Little, 0);

    const output = reader.read(TestStruct);
    try std.testing.expectEqual(output.foo, 256);
    try std.testing.expectEqual(output.bar, 262_914);
}
