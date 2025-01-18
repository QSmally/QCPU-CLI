
const std = @import("std");
const AsmTokeniser = @import("AsmTokeniser.zig");
const Token = @import("Token.zig");

const Source = @This();

pub const FileLocation = struct {
    line: usize,
    line_cursor: usize,
    end_cursor: usize
};

allocator: std.mem.Allocator,
buffer: [:0]const u8,
tokens: []const Token,

pub fn init(allocator: std.mem.Allocator, tokeniser: *AsmTokeniser) !Source {
    var tokens = std.ArrayList(Token).init(allocator);

    while (true) {
        const token = tokeniser.next();
        try tokens.append(token);
        if (token.tag == .eof)
            break;
    }

    return .{
        .allocator = allocator,
        .buffer = tokeniser.buffer,
        .tokens = try tokens.toOwnedSlice() };
}

pub fn deinit(self: Source) void {
    self.allocator.free(self.tokens);
}

pub fn location_of(self: Source, token: Token) FileLocation {
    var line: usize = 1;
    var line_cursor: usize = 0;

    while (std.mem.indexOfScalarPos(u8, self.buffer, line_cursor, '\n')) |index| {
        if (index >= token.start_byte)
            break;
        line += 1;
        line_cursor = index + 1;
    }

    const end_cursor = std.mem.indexOfScalarPos(u8, self.buffer, line_cursor, '\n') orelse self.buffer.len;
    std.debug.assert(end_cursor >= line_cursor);
    std.debug.assert(end_cursor <= self.buffer.len);

    return .{
        .line = line,
        .line_cursor = line_cursor,
        .end_cursor = end_cursor };
}
