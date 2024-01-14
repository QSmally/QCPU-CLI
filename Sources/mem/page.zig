
// TODO: make union for more page types
/// A regfile.
pub fn Page(comptime Address_: type, comptime Result_: type) type {
    return struct {

        const Self = @This();

        pub const Address = Address_;
        pub const Result = Result_;

        container: []Result,

        pub fn size(self: *Self) usize {
            return @sizeOf(self.container);
        }

        pub fn read(self: *Self, address: Address) Result {
            return self.container[address];
        }

        pub fn write(self: *Self, address: Address, value: Result) void {
            self.container[address] = value;
        }
    };
}
