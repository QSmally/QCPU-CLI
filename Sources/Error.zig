
const std = @import("std");
const Source = @import("Source.zig");
const Token = @import("Token.zig");

const Error = @This();

const pointer = "^\n";

id: anyerror,
token: ?Token,
is_note: bool,
message: []const u8,
location: ?Source.FileLocation,

pub fn write(self: *const Error, file: []const u8, buffer: [:0]const u8, writer: anytype) !void {
    const tag = if (self.is_note)
        "note" else
        "error";
    if (self.token) |token| {
        const location = self.location orelse unreachable;
        try writer.print("{s}:{}:{}: {s}: {s}\n", .{
            file,
            location.line,
            token.location.start_byte - location.line_cursor + 1,
            tag,
            self.message });
        try writer.print("{s}\n", .{ buffer[location.line_cursor..location.end_cursor] });
        try std.fmt.formatText(pointer, "s", .{
            .width = @intCast(token.location.start_byte - location.line_cursor + pointer.len)
        }, writer);
    } else {
        try writer.print("{s}: {s}\n", .{
            tag,
            self.message });
    }
}
