
pub const Page = union(enum) {

    const Self = @This();

    store: @import("pages/store.zig"),

    pub fn read(self: *Self, address: u8) u8 {
        switch (self.*) {
            inline else => |*case| return case.read(address)
        }
    }

    pub fn write(self: *Self, address: u8, value: u8) void {
        switch (self.*) {
            inline else => |*case| case.write(address, value)
        }
    }
};
