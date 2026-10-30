
const std = @import("std");
const Token = @import("Token.zig");
const SourceFile = @import("SourceFile.zig");

const Error = @This();

err: anyerror,
token: ?Token,
source_file: *const SourceFile,
is_note: bool,
is_preview: bool,
message: []const u8,

pub fn deinit(self: *const Error, allocator: std.mem.Allocator) void {
    allocator.free(self.message);
}

pub fn write(self: *const Error, writer: *std.Io.Writer) !void {
    const tag = if (self.is_note) "note" else "error";

    if (self.token) |the_token| {
        const location = self.source_file.location(the_token);

        try writer.print("{s}:{}:{}: {s}: {s}\n", .{
            self.source_file.real_path,
            location.line,
            the_token.location.start - location.cursor + 1,
            tag,
            self.message });

        if (self.is_preview) {
            const line = self.source_file.buffer[location.cursor..location.cursor_end];
            try writer.print("{s}\n", .{ line });
            try writer.splatByteAll(' ', the_token.location.start - location.cursor);
            try writer.writeAll("^");

            if (the_token.location.end - the_token.location.start > 1)
                try writer.splatByteAll('~', the_token.location.end - the_token.location.start - 1);
            try writer.writeAll("\n");
        }
    } else {
        try writer.print("{s}:0:0: {s}: {s}\n", .{
            self.source_file.real_path,
            tag,
            self.message });
    }
}

// Tests

const test_buffer = "@section text\nlui x1, .label\n";

const test_source_file = SourceFile {
    .pwd = std.Io.Dir.cwd(),
    .real_path = "Tests/foo.s",
    .buffer = test_buffer,
    .inode = undefined,
    .size = undefined };

const test_token = Token {
    .tag = .argument,
    .location = .{ .start = 18, .end = 20 } };

test "errors full" {
    const err = Error {
        .err = error.Test,
        .token = test_token,
        .source_file = &test_source_file,
        .is_note = false,
        .is_preview = true,
        .message = "test error" };
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();

    try err.write(&list.writer);

    try std.testing.expectEqualSlices(u8,
        \\Tests/foo.s:2:5: error: test error
        \\lui x1, .label
        \\    ^~
        \\
    , list.written());
}

test "errors note" {
    const err = Error {
        .err = error.Test,
        .token = test_token,
        .source_file = &test_source_file,
        .is_note = true,
        .is_preview = false,
        .message = "test error" };
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();

    try err.write(&list.writer);

    try std.testing.expectEqualSlices(u8,
        \\Tests/foo.s:2:5: note: test error
        \\
    , list.written());
}

test "errors empty" {
    const err = Error {
        .err = error.Test,
        .token = null,
        .source_file = &test_source_file,
        .is_note = false,
        .is_preview = false,
        .message = "test error" };
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();

    try err.write(&list.writer);

    try std.testing.expectEqualSlices(u8,
        \\Tests/foo.s:0:0: error: test error
        \\
    , list.written());
}
