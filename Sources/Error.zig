
const std = @import("std");
const Token = @import("Token.zig");

const Error = @This();

const pointer = "^\n";

id: anyerror,
token: Token,
message: []const u8,
line: usize,
line_cursor: usize,
end_cursor: usize,

pub fn write(self: *const Error, file: []const u8, buffer: [:0]const u8, writer: anytype) !void {
    try writer.print("{s}:{}:{}: error: {s}\n{s}\n", .{
        file,
        self.line,
        self.token.location.start_byte - self.line_cursor + 1,
        self.message,
        buffer[self.line_cursor..self.end_cursor] });
    try std.fmt.formatText(pointer, "s", .{
        .width = @intCast(self.token.location.start_byte - self.line_cursor + pointer.len)
    }, writer);
}
