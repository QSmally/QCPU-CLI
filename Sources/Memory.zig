
const std = @import("std");
const Linker = @import("Linker.zig");
const Reader = @import("mem.zig").Memory;

const Memory = @This();

allocator: std.mem.Allocator,
inner: InnerMap,

const InnerMap = std.AutoHashMapUnmanaged(u32, Linker.Byte);

pub fn init(allocator: std.mem.Allocator) Memory {
    return .{
        .allocator = allocator,
        .inner = .empty };
}

pub fn deinit(self: *Memory) void {
    self.inner.deinit(self.allocator);
}

pub fn from_blocks(allocator: std.mem.Allocator, blocks: anytype) !Memory {
    var memory = Memory.init(allocator);
    errdefer memory.deinit();

    for (blocks.values()) |block| {
        const content = block.content.slice();
        for (0..content.len) |i|
            try memory.write(@intCast(block.origin + i), content.get(i));
    }

    return memory;
}

const reader_table = Reader(u32, Linker.Byte).VTable {
    .read = reader_read,
    .write = reader_write,
    .to_byte = reader_to_byte };
pub fn reader(self: *Memory) Reader(u32, Linker.Byte) {
    return .{ .context = self, .vtable = reader_table };
}

fn reader_read(context: *const anyopaque, address: u32) ?Linker.Byte {
    const self: *const Memory = @alignCast(@ptrCast(context));
    return self.read(address);
}

fn reader_write(context: *anyopaque, address: u32, result: Linker.Byte) !void {
    const self: *Memory = @alignCast(@ptrCast(context));
    return try self.write(address, result);
}

fn reader_to_byte(result: ?Linker.Byte) u8 {
    return if (result) |the_result| the_result.raw_value else 0;
}

pub fn read(self: *const Memory, address: u32) ?Linker.Byte {
    return self.inner.get(address);
}

pub fn write(self: *Memory, address: u32, value: Linker.Byte) !void {
    return try self.inner.put(self.allocator, address, value);
}
