
const std = @import("std");
const AsmTokeniser = @import("AsmTokeniser.zig");
const Token = @import("Token.zig");

const Source = @This();

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
