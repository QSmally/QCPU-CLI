
const std = @import("std");
const indexable_list = @import("indexable_list.zig");
const AsmSemanticAir = @import("AsmSemanticAir.zig");

const Linker = @This();

allocator: std.mem.Allocator,
link_list: SectionList = .empty,

pub fn init(allocator: std.mem.Allocator) Linker {
    return .{ .allocator = allocator };
}

pub const SectionList = indexable_list.IndexableList(AsmSemanticAir.Section);

pub fn provisionSection(self: *Linker, section: AsmSemanticAir.Section) !SectionList.Index {
    const index = self.link_list.len();
    try self.link_list.append(self.allocator, section);
    return .at(index);
}

pub fn performLink(self: *Linker) !void {
    _ = self;
}
