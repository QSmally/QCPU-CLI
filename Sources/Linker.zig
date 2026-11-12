
const std = @import("std");
const indexable_list = @import("indexable_list.zig");
const Qcu = @import("Qcu.zig");
const SourceFile = @import("SourceFile.zig");
const AsmSemanticAir = @import("AsmSemanticAir.zig");
const AsmCompute = @import("AsmCompute.zig");

const Linker = @This();

qcu: *Qcu,
link_list: SectionList = .empty,
link_info: ?[]const LinkInfo = null,

pub fn init(qcu: *Qcu) Linker {
    return .{ .qcu = qcu };
}

pub fn deinit(self: *Linker) void {
    for (self.link_list.list.items) |*section|
        section.deinit(self.qcu.allocator);
    self.link_list.deinit(self.qcu.allocator);
    if (self.link_info) |the_link_info|
        self.qcu.allocator.free(the_link_info);
}

pub const LinkInfo = struct {

    token: SourceFile.Token,
    ty: Type,

    pub const Type = union(enum) {
        origin: struct {
            section_name: []const u8,
            address: AsmCompute.ComputeTimeInt
        },
        aligned: struct {
            section_name: []const u8,
            alignment: AsmCompute.ComputeTimeInt
        }
    };
};

pub const SectionList = indexable_list.IndexableList(AsmSemanticAir.Section);

pub const LinkerError = error {
    DuplicateLinkInfo,
    EmptyLinkSections,
    NoteDefinedHere,
    Note
};

fn addError(
    self: *Linker,
    comptime err: LinkerError,
    token: SourceFile.Token,
    comptime format: []const u8,
    arguments: anytype
) !void {
    @branchHint(.cold);

    const message = try self.qcu.allocator.print(format, arguments);
    errdefer self.qcu.allocator.free(message);

    try self.qcu.errors.append(self.qcu.allocator, .{
        .err = err,
        .token = token.inner_token,
        .source_file = token.source_file,
        .is_note = switch (err) {
            error.NoteDefinedHere,
            error.Note => true,
            else => false
        },
        .is_preview = err != error.Note,
        .message = message });
}

pub fn provisionSectionTransferOwnership(self: *Linker, section: AsmSemanticAir.Section) !SectionList.Index {
    const index = self.link_list.len();
    try self.link_list.append(self.qcu.allocator, section);
    return .at(index);
}

pub fn linkSectionsTransferOwnership(self: *Linker, link_info: []const LinkInfo) !void {
    std.debug.assert(link_info.len > 0);

    if (self.link_info) |existing_link_info| {
        try self.addError(error.DuplicateLinkInfo, link_info[0].token, "duplicate @linkinfo definition", .{});
        try self.addError(error.NoteDefinedHere, existing_link_info[0].token, "previously defined here", .{});
        try self.addError(error.Note, link_info[0].token, "cannot determine order of separate @linkinfo groups", .{});
        return;
    }

    self.link_info = link_info;
}

const LinkError = error {
    Break
} || std.mem.Allocator.Error;

pub fn performLink(self: *Linker) LinkError!void {
    const dummy_token: SourceFile.Token = .{
        .source_file = &self.qcu.files.get(.root).source_file,
        .inner_token = .{ .tag = .invalid, .location = .{ .start = 0, .end = 0 } } };
    if (self.link_list.len() < 1) {
        try self.addError(error.EmptyLinkSections, dummy_token, "nothing to link", .{});
        try self.addError(error.Note, dummy_token, "missing root section", .{});
        return error.Break;
    }
    if (self.link_info == null) {
        try self.addError(error.EmptyLinkSections, dummy_token, "nothing to link", .{});
        try self.addError(error.Note, dummy_token, "missing @linkinfo definitions", .{});
        return error.Break;
    }
}
