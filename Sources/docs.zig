
const std = @import("std");

const pages = std.StaticStringMap([]const u8).initComptime(.{
    .{ "align", @embedFile("Builtins/align.txt") },
    .{ "barrier", @embedFile("Builtins/barrier.txt") },
    .{ "define", @embedFile("Builtins/define.txt") },
    .{ "else", @embedFile("Builtins/else.txt") },
    .{ "end", @embedFile("Builtins/end.txt") },
    .{ "err", @embedFile("Builtins/err.txt") },
    .{ "header", @embedFile("Builtins/header.txt") },
    .{ "if", @embedFile("Builtins/if.txt") },
    .{ "import", @embedFile("Builtins/import.txt") },
    .{ "linkinfo", @embedFile("Builtins/linkinfo.txt") },
    .{ "region", @embedFile("Builtins/region.txt") },
    .{ "section", @embedFile("Builtins/section.txt") }
});

pub fn output(keyword: []const u8, writer: *std.Io.Writer) !void {
    const page = pages.get(keyword) orelse return error.DocsNotFound;
    try writer.writeAll(page);
}
