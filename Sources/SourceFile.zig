
const std = @import("std");
const InnerToken = @import("Token.zig");

const SourceFile = @This();

pwd: std.Io.Dir,
real_path: []const u8,
buffer: [:0]const u8,
inode: std.Io.File.INode,
size: u64,

pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    pwd: std.Io.Dir,
    host_path: []const u8,
    file_path: []const u8
) InitError!SourceFile {
    const real_path = try std.fs.path.resolve(allocator, &.{ host_path, file_path });
    errdefer allocator.free(real_path);

    const source = try getSource(io, allocator, pwd, real_path);
    errdefer source.deinit(allocator);

    return .{
        .pwd = pwd,
        .real_path = real_path,
        .buffer = source.buffer,
        .inode = source.inode,
        .size = source.size };
}

pub fn initFrom(
    self: *const SourceFile,
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8
) !SourceFile {
    const host_path = std.fs.path.dirname(self.real_path) orelse ".";
    return try SourceFile.init(io, allocator, self.pwd, host_path, path);
}

pub fn deinit(self: *const SourceFile, allocator: std.mem.Allocator) void {
    allocator.free(self.real_path);
    allocator.free(self.buffer);
}

pub fn fileName(self: *const SourceFile) []const u8 {
    return std.fs.path.basename(self.real_path);
}

pub fn qualifiedNamespace(self: *const SourceFile) []const u8 {
    return std.fs.path.stem(self.fileName());
}

pub fn eql(self: *const SourceFile, other: *const SourceFile) bool {
    return self.inode == other.inode and self.size == other.size;
}

pub const Type = enum {
    assembly,
    unknown
};

pub fn fileType(self: *const SourceFile) Type {
    const extension = std.fs.path.extension(self.real_path);

    if (std.mem.eql(u8, extension, ".s"))
        return .assembly;

    return .unknown;
}

pub fn slice(self: *const SourceFile, token: InnerToken) []const u8 {
    return token.slice(self.buffer);
}

const Source = struct {

    buffer: [:0]const u8,
    inode: std.Io.File.INode,
    size: u64,

    pub fn deinit(self: Source, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
    }
};

pub const InitError = error {
    FileTooBig,
    UnexpectedEndOfFile
} ||
    std.Io.File.OpenError ||
    std.Io.File.StatError ||
    std.Io.File.ReadPositionalError ||
    std.mem.Allocator.Error;

fn getSource(
    io: std.Io,
    allocator: std.mem.Allocator,
    pwd: std.Io.Dir,
    file_path: []const u8
) InitError!Source {
    var file = try pwd.openFile(io, file_path, .{});
    defer file.close(io);
    const stat = try file.stat(io);

    if (stat.size > std.math.maxInt(u32))
        return error.FileTooBig;
    const buffer = try allocator.allocSentinel(u8, stat.size, 0);
    errdefer allocator.free(buffer);

    if (try file.readPositionalAll(io, buffer, 0) != stat.size)
        return error.UnexpectedEndOfFile;

    return .{
        .buffer = buffer,
        .inode = stat.inode,
        .size = stat.size };
}

pub const Location = struct {
    line: usize,
    cursor: usize,
    cursor_end: usize
};

pub fn location(self: *const SourceFile, token: InnerToken) Location {
    var line: usize = 1;
    var cursor: usize = 0;

    while (std.mem.indexOfScalarPos(u8, self.buffer, cursor, '\n')) |index| {
        if (index >= token.location.start)
            break;
        line += 1;
        cursor = index + 1;
    }

    const cursor_end = std.mem.indexOfScalarPos(u8, self.buffer, cursor, '\n') orelse self.buffer.len;
    std.debug.assert(cursor_end >= cursor);
    std.debug.assert(cursor_end <= self.buffer.len);

    return .{
        .line = line,
        .cursor = cursor,
        .cursor_end = cursor_end };
}

pub const Token = struct {

    source_file: *const SourceFile,
    inner_token: InnerToken,

    pub fn eql(self: *const Token, other: Token) bool {
        const source_file_eql = self.source_file.eql(other.source_file);
        const token_eql = self.inner_token.location.eql(other.inner_token.location);
        return source_file_eql and token_eql;
    }

    pub fn slice(self: *const Token) []const u8 {
        return self.inner_token.slice(self.source_file.buffer);
    }
};

pub fn qualifiedToken(self: *const SourceFile, token: InnerToken) Token {
    return .{ .source_file = self, .inner_token = token };
}

// Tests

test "load file" {
    const source_file = try SourceFile.init(
        std.testing.io,
        std.testing.allocator,
        std.Io.Dir.cwd(),
        "./Tests",
        "./root.s");
    defer source_file.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, "Tests/root.s", source_file.real_path);
    try std.testing.expectEqualSlices(u8, @embedFile("Tests/root.s"), source_file.buffer);
}

const test_buffer = "@section text\nlui x1, .label\n";

const test_source_file = SourceFile {
    .pwd = std.Io.Dir.cwd(),
    .real_path = "Tests/foo.s",
    .buffer = test_buffer,
    .inode = 1,
    .size = 0 };

const test_token = InnerToken {
    .tag = .argument,
    .location = .{ .start = 18, .end = 20 } };
const test_token_a = Token {
    .inner_token = test_token,
    .source_file = &test_source_file };

test "location" {
    const loc = test_source_file.location(test_token);
    const expected_cursor = Location {
        .line = 2,
        .cursor = 14,
        .cursor_end = 28 };
    try std.testing.expectEqual(expected_cursor, loc);
    try std.testing.expectEqualSlices(u8, "x1", test_token_a.slice());
}

test "equality" {
    const other_source_file = SourceFile {
        .pwd = std.Io.Dir.cwd(),
        .real_path = "Tests/foo.s",
        .buffer = test_buffer,
        .inode = 2,
        .size = 0 };
    const token_b = Token {
        .inner_token = test_token,
        .source_file = &other_source_file };

    try std.testing.expect(test_token_a.eql(test_token_a));
    try std.testing.expect(!test_token_a.eql(token_b));
}
