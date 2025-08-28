
const std = @import("std");

pub fn Memory(comptime Address: type, comptime Result: type) type {
    return struct {

        const ReaderType = @This();

        // fixme: add cursor

        context: *anyopaque,
        vtable: VTable,

        pub const Error = error {
            OutOfMemory
        };

        pub const VTable = struct {
            read: *const fn (*const anyopaque, Address) ?Result,
            write: *const fn (*anyopaque, Address, Result) Error!void,
            to_byte: *const fn (?Result) u8
        };

        // Memory

        pub fn read(self: *const ReaderType, address: Address) ?Result {
            return self.vtable.read(self.context, address);
        }

        pub fn write(self: *ReaderType, address: Address, result: Result) Error!void {
            return try self.vtable.write(self.context, address, result);
        }

        pub fn to_byte(self: *const ReaderType, result: ?Result) u8 {
            return self.vtable.to_byte(result);
        }

        // Reader

        pub fn read_type(self: *const ReaderType, comptime T: type, address: Address) T {
            return switch (@typeInfo(T)) {
                .@"int" => {
                    const size = @bitSizeOf(T) / 8;
                    std.debug.assert(size != 0);

                    var output: [size]u8 = undefined;

                    for (0..size, address..) |offset, absolute_address|
                        output[offset] = self.to_byte(self.read(@intCast(absolute_address)));
                    const reference: *align(1) const T = @ptrCast(&output);
                    return reference.*;
                },

                .@"struct" => {
                    var offset: Address = 0;
                    var output: T = undefined;

                    inline for (std.meta.fields(T)) |field| {
                        std.debug.assert(@bitSizeOf(field.@"type") != 0);
                        @field(output, field.name) = self.read_type(field.@"type", address + offset);
                        offset += @bitSizeOf(field.@"type") / 8;
                    }

                    return output;
                },

                else => @compileError("memory: unsupported struct type")
            };
        }
    };
}
