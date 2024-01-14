
const Self = @This();

pub const Address = u16;
pub const Result = u8;
pub const size_bytes = 256;

value: Result,

pub fn size(self: *Self) usize {
    _ = self;
    return size_bytes;
}

pub fn read(self: *Self, address: Address) Result {
    // hack to verify page division and address modulation
    return @as(Result, @intCast(address)) + self.value;
}
