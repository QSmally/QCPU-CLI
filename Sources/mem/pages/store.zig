
const Self = @This();

container: [256]u8,

pub fn read(self: *Self, address: u8) u8 {
    return self.container[address];
}

pub fn write(self: *Self, address: u8, value: u8) void {
    self.container[address] = value;
}
