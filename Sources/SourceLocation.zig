
const std = @import("std");
const InnerToken = @import("Token.zig");

const SourceLocation = @This();

cwd: std.fs.Dir,
file_name: []const u8,
real_path: []const u8,
buffer: [:0]const u8,
inode: std.fs.File.INode,
size: u64,

pub fn init(
    allocator: std.mem.Allocator,
    cwd: std.fs.Dir,
    host_path: []const u8,
    path: []const u8
) InitError!SourceLocation {
    const real_path = try std.fs.path.resolve(allocator, &.{ host_path, path });
    errdefer allocator.free(real_path);

    const source = try get_source(allocator, cwd, real_path);
    errdefer allocator.free(source.buffer);

    return .{
        .cwd = cwd,
        .file_name = std.fs.path.basename(path),
        .real_path = real_path,
        .buffer = source.buffer,
        .inode = source.inode,
        .size = source.size };
}

pub fn init_from(
    self: *const SourceLocation,
    allocator: std.mem.Allocator,
    path: []const u8
) !SourceLocation {
    const host_path = std.fs.path.dirname(self.real_path) orelse ".";
    return try SourceLocation.init(allocator, self.cwd, host_path, path);
}

pub fn deinit(self: *const SourceLocation, allocator: std.mem.Allocator) void {
    allocator.free(self.real_path);
    allocator.free(self.buffer);
}

pub const Token = struct {

    inner_token: InnerToken,
    source_location: *const SourceLocation,

    pub fn eql(self: *const Token, other: Token) bool {
        return self.source_location == other.source_location and self.inner_token.location.eql(other.inner_token.location);
    }

    pub fn content(self: *const Token) []const u8 {
        return self.inner_token.location.slice(self.source_location.buffer);
    }
};

// TODO: use this
pub fn default_token(self: *const SourceLocation) Token {
    const zero_token: Token = .{
        .tag = .identifier,
        .location = .{ .start = 0, .end = 0 } };
    return .{
        .inner_token = zero_token,
        .source_location = self };
}

pub fn content(self: *const SourceLocation, token: InnerToken) []const u8 {
    return token.content_slice(self.buffer);
}

pub const Error = struct {

    const pointer = "^\n";

    err: anyerror,
    token: ?InnerToken,
    source_location: *const SourceLocation,
    is_note: bool,
    is_preview: bool,
    message: []const u8,

    pub fn deinit(self: *const Error, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }

    pub fn write(self: *const Error, writer: anytype) !void {
        var buffer = std.io.bufferedWriter(writer);
        defer buffer.flush() catch {};
        const inner_writer = buffer.writer();

        const tag = if (self.is_note) "note" else "error";

        if (self.token) |the_token| {
            const cursor = self.source_location.location(the_token);

            try inner_writer.print("{s}:{}:{}: {s}: {s}\n", .{
                self.source_location.real_path,
                cursor.line,
                the_token.location.start - cursor.line_cursor + 1,
                tag,
                self.message });
            if (self.is_preview) {
                try inner_writer.print("{s}\n", .{ self.source_location.buffer[cursor.line_cursor..cursor.line_end_cursor] });
                try std.fmt.formatText(pointer, "s", .{
                    .width = @intCast(the_token.location.start - cursor.line_cursor + pointer.len)
                }, inner_writer);
            }
        } else {
            try inner_writer.print("{s}:0:0: {s}: {s}\n", .{
                self.source_location.real_path,
                tag,
                self.message });
        }
    }
};

pub const Cursor = struct {
    line: usize,
    line_cursor: usize,
    line_end_cursor: usize
};

pub const InitError = error {
    FileTooBig,
    UnexpectedEndOfFile
} ||
    std.fs.File.OpenError ||
    std.fs.File.StatError ||
    std.fs.File.ReadError ||
    std.mem.Allocator.Error;

const Source = struct {
    buffer: [:0]const u8,
    inode: std.fs.File.INode,
    size: u64
};

/// Memory (`buffer`) returned is owned by caller.
fn get_source(
    allocator: std.mem.Allocator,
    cwd: std.fs.Dir,
    path: []const u8
) InitError!Source {
    var file = try cwd.openFile(path, .{});
    defer file.close();
    const stat = try file.stat();

    if (stat.size > std.math.maxInt(u32))
        return error.FileTooBig;
    const buffer = try allocator.allocSentinel(u8, stat.size, 0);
    errdefer allocator.free(buffer);

    if (try file.readAll(buffer) != stat.size)
        return error.UnexpectedEndOfFile;

    return .{
        .buffer = buffer,
        .inode = stat.inode,
        .size = stat.size };
}

pub fn eql(self: *const SourceLocation, other: *const SourceLocation) bool {
    return self.inode == other.inode and self.size == other.size;
}

pub fn location(self: *const SourceLocation, token: InnerToken) Cursor {
    var line: usize = 1;
    var line_cursor: usize = 0;

    while (std.mem.indexOfScalarPos(u8, self.buffer, line_cursor, '\n')) |index| {
        if (index >= token.location.start)
            break;
        line += 1;
        line_cursor = index + 1;
    }

    const line_end_cursor = std.mem.indexOfScalarPos(u8, self.buffer, line_cursor, '\n') orelse self.buffer.len;
    std.debug.assert(line_end_cursor >= line_cursor);
    std.debug.assert(line_end_cursor <= self.buffer.len);

    return .{
        .line = line,
        .line_cursor = line_cursor,
        .line_end_cursor = line_end_cursor };
}

// Tests

test "load file" {
    const test_source_location = try SourceLocation.init(
        std.testing.allocator,
        std.fs.cwd(),
        "./Tests",
        "./root.s");
    defer test_source_location.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, "Tests/root.s", test_source_location.real_path);
    try std.testing.expectEqualSlices(u8, @embedFile("Tests/root.s"), test_source_location.buffer);
}

const test_buffer = "@section text\nlui x1, .label\n";

const source_location = SourceLocation {
    .cwd = std.fs.cwd(),
    .file_name = "foo.s",
    .real_path = "Tests/foo.s",
    .buffer = test_buffer,
    .inode = undefined,
    .size = undefined };

const test_token = InnerToken {
    .tag = .argument,
    .location = .{ .start = 18, .end = 20 } };
const token_a = Token {
    .inner_token = test_token,
    .source_location = &source_location };

test "location" {
    const cursor = source_location.location(test_token);
    const expected_cursor = Cursor {
        .line = 2,
        .line_cursor = 14,
        .line_end_cursor = 28 };
    try std.testing.expectEqual(expected_cursor, cursor);
    try std.testing.expectEqualSlices(u8, "x1", token_a.content());
}

test "equality" {
    const other_source_location = SourceLocation {
        .cwd = std.fs.cwd(),
        .file_name = "foo.s",
        .real_path = "Tests/foo.s",
        .buffer = test_buffer,
        .inode = undefined,
        .size = undefined };
    const token_b = Token {
        .inner_token = test_token,
        .source_location = &other_source_location };

    try std.testing.expect(token_a.eql(token_a));
    try std.testing.expect(!token_a.eql(token_b));
}

test "errors full" {
    const err = Error {
        .err = error.Test,
        .token = test_token,
        .source_location = &source_location,
        .is_note = false,
        .is_preview = true,
        .message = "test error" };
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();

    try err.write(list.writer());

    try std.testing.expectEqualSlices(u8,
        \\Tests/foo.s:2:5: error: test error
        \\lui x1, .label
        \\    ^
        \\
    , list.items);
}

test "errors note" {
    const err = Error {
        .err = error.Test,
        .token = test_token,
        .source_location = &source_location,
        .is_note = true,
        .is_preview = false,
        .message = "test error" };
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();

    try err.write(list.writer());

    try std.testing.expectEqualSlices(u8,
        \\Tests/foo.s:2:5: note: test error
        \\
    , list.items);
}

test "errors empty" {
    const err = Error {
        .err = error.Test,
        .token = null,
        .source_location = &source_location,
        .is_note = false,
        .is_preview = false,
        .message = "test error" };
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();

    try err.write(list.writer());

    try std.testing.expectEqualSlices(u8,
        \\Tests/foo.s:0:0: error: test error
        \\
    , list.items);
}
