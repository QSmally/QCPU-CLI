
const std = @import("std");

const Self = @This();

pub const stride = 2;

pub const Bridge = struct {

    pub const Type = u96; // 24 * 4
    pub const Address = u2;
    pub const interrupts = std.math.pow(usize, 2, @bitSizeOf(Address));

    context: *Self,
    page: usize,

    pub fn interrupt(self: *@This(), flag: Address) void {
        const index = self.page * interrupts + flag;
        std.debug.assert(@bitSizeOf(Type) > index);
        self.context.vector |= @as(Type, 1) << @intCast(index);
    }
};

vector: Bridge.Type = 0,

pub fn bridge(self: *Self, page: usize) Bridge {
    return .{ .context = self, .page = page };
}
