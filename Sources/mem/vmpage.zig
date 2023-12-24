
const Page = @import("page.zig").Page;

const Self = @This();

container: *Page,
flags: Flags,

const Flags = packed struct {
    cachable: bool = 0,
    readonly: bool = 0,
    copy_on_write: bool = 0,
    executable: bool = 0
};

pub fn read(self: *Self, address: u8) u8 {
    return self.container.read(address);
}

pub fn write(self: *Self, address: u8, value: u8) void {
    if (self.flags.readonly)
        @panic("attempted to write to readonly page");
    self.container.write(address, value);
}
