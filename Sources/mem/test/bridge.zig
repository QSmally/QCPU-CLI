
const Self = @This();

pub const Result = u8;

flags: [4]bool = .{ false } ** 4,

pub fn interrupt(self: *Self, flag: u2) void {
    self.flags[flag] = true;
}
