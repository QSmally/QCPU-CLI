
const std = @import("std");
const indexable_list = @import("indexable_list.zig");
const instruction = @import("instruction.zig");
const Qcu = @import("Qcu.zig");
const SourceFile = @import("SourceFile.zig");
const AsmSemanticAir = @import("AsmSemanticAir.zig");
const AsmCompute = @import("AsmCompute.zig");

const Linker = @This();

qcu: *Qcu,

link_list: BlockList = .empty,
pending_list: std.DynamicBitSetUnmanaged = .{},
link_info: ?[]const LinkInfo = null,
linked_sections: SectionList = .empty,
unified_references: std.StringHashMapUnmanaged(u32) = .empty,

pub fn init(qcu: *Qcu) Linker {
    return .{ .qcu = qcu };
}

pub fn deinit(self: *Linker) void {
    for (self.link_list.list.items) |*section|
        section.deinit(self.qcu.allocator);
    self.link_list.deinit(self.qcu.allocator);
    self.pending_list.deinit(self.qcu.allocator);
    if (self.link_info) |the_link_info|
        self.qcu.allocator.free(the_link_info);
}

pub fn destroy(self: *Linker) void {
    for (self.linked_sections) |the_linked_section|
        the_linked_section.deinit(self.qcu.allocator);
    self.linked_sections.deinit(self.qcu.allocator);
    self.unified_references.deinit(self.qcu.allocator);
}

pub fn dump(self: *Linker, writer: *std.Io.Writer) !void {
    for (self.linked_sections.list.items) |*section| {
        try self.dumpSectionTrace(section, writer);
    }

    var iterator = self.unified_references.iterator();

    while (iterator.next()) |reference| {
        try writer.print("{s} -> {}\n", .{ reference.key_ptr.*, reference.value_ptr.* });
    }
}

pub const LinkInfo = struct {

    token: SourceFile.Token,
    ty: Type,

    pub const Type = union(enum) {
        origin: struct {
            section_name: []const u8,
            address: u32
        },
        aligned: struct {
            section_name: []const u8,
            alignment: std.mem.Alignment
        }
    };
};

const Section = struct {

    identifier: []const u8,
    origin: u32,
    linkinfo_token: SourceFile.Token,

    content: Mir.List = .empty,

    pub fn init(identifier: []const u8, origin: u32, linkinfo_token: SourceFile.Token) Section {
        return .{
            .identifier = identifier,
            .origin = origin,
            .linkinfo_token = linkinfo_token };
    }

    pub fn deinit(self: *Section, allocator: std.mem.Allocator) void {
        self.content.deinit(allocator);
    }

    pub fn nextAddress(self: *const Section) usize {
        return self.origin + self.bytes();
    }

    pub fn localAddressOf(self: *const Section, index: Mir.List.Index) usize {
        var total_bytes: usize = 0;
        for (self.content.list.items[0..index.raw()]) |air| total_bytes += air.op.bytes();
        return total_bytes;
    }

    pub fn bytes(self: *const Section) usize {
        return self.localAddressOf(.at(self.content.len()));
    }
};

const Mir = struct {

    token: SourceFile.Token,
    op: AsmSemanticAir.Air.Operation,

    binary: u32 = 0,
    address: u32 = 0,

    pub const List = indexable_list.IndexableList(Mir);
};

const SectionList = indexable_list.IndexableList(Section);

pub const BlockList = indexable_list.IndexableList(AsmSemanticAir.Block);

pub const LinkerError = error {
    DuplicateLinkInfo,
    EmptyLinkSections,
    InvalidLinkSections,
    DuplicateSection,
    DescendingSection,
    UnlinkedSection,
    DuplicateReference,
    UnknownReference,
    AddressOverflow,
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

pub fn provisionBlockTransferOwnership(self: *Linker, section: AsmSemanticAir.Block) !BlockList.Index {
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
    const info = self.link_info orelse {
        try self.addError(error.EmptyLinkSections, dummy_token, "nothing to link", .{});
        try self.addError(error.Note, dummy_token, "missing @linkinfo definitions", .{});
        return error.Break;
    };
    if (info[0].ty != .origin) {
        try self.addError(error.InvalidLinkSections, info[0].token, "first @linkinfo must be an origin type", .{});
        return error.Break;
    }

    std.log.debug("performLink link_info.len={} link_list.len={}", .{ info.len, self.link_list.len() });

    try self.pending_list.resize(self.qcu.allocator, self.link_list.len(), true);

    for (info) |li| switch (li.ty) {
        .origin => |origin| try self.emitLinkOrigin(li.token, origin.section_name, origin.address),
        .aligned => |aligned| try self.emitLinkAligned(li.token, aligned.section_name, aligned.alignment)
    };

    if (self.pending_list.findFirstSet()) |block_index| {
        const block = self.link_list.get(.fromIndex(block_index));
        switch (block.eval_reason) {
            .reference => |reference| {
                try self.addError(error.UnlinkedSection, block.token, "section '{s}' was referenced but not linked", .{ block.name });
                try self.addError(error.NoteDefinedHere, reference.token, "first referenced in section '{s}' here", .{ reference.section_name });
                if (self.findSection(reference.section_name)) |section|
                    try self.addError(error.NoteDefinedHere, section.linkinfo_token, "which is linked here", .{});
            },
            .root_section => {
                try self.addError(error.UnlinkedSection, block.token, "root section is not linked", .{});
            },
            .no_elimination => {
                try self.addError(error.UnlinkedSection, block.token, "non-eliminated section '{s}' is not linked", .{ block.name });
            }
        }
        try self.addError(error.Note, block.token, "use '@linkinfo(...) {s}, ...' to link this section", .{ block.name });
        return error.Break;
    }

    for (self.linked_sections.list.items) |*section| {
        for (section.content.list.items) |*mir| {
            try self.resolveBinaryInstr(mir);
        }
    }
}

fn emitLinkOrigin(
    self: *Linker,
    token: SourceFile.Token,
    section_name: []const u8,
    address: u32
) !void {
    const section_index = try self.createSection(section_name, address, token);
    try self.processSectionBlocks(section_index);
}

fn emitLinkAligned(
    self: *Linker,
    token: SourceFile.Token,
    section_name: []const u8,
    alignment: std.mem.Alignment
) !void {
    std.debug.assert(self.linked_sections.len() > 0);
    const last_section = self.linked_sections.last().?;
    const last_address = last_section.nextAddress();
    const address: u32 = @intCast(alignment.forward(last_address));
    const section_index = try self.createSection(section_name, address, token);
    try self.processSectionBlocks(section_index);
}

fn createSection(
    self: *Linker,
    identifier: []const u8,
    address: u32,
    linkinfo_token: SourceFile.Token
) !SectionList.Index {
    if (self.findSection(identifier)) |existing_section| {
        try self.addError(error.DuplicateSection, linkinfo_token, "duplicate mapping for section '{s}'", .{ identifier });
        try self.addError(error.NoteDefinedHere, existing_section.linkinfo_token, "previously mapped here", .{});
        return error.Break;
    }

    if (self.linked_sections.last()) |last_section| {
        const minimum_address = last_section.nextAddress();
        if (address < minimum_address) {
            try self.addError(error.DescendingSection, linkinfo_token, "section '{s}' with origin {} overlaps with section '{s}'", .{ identifier, address, last_section.identifier });
            try self.addError(error.NoteDefinedHere, last_section.linkinfo_token, "address range {}..{} mapped here", .{ last_section.origin, minimum_address });
            return error.Break;
        }
    }

    const section = Section.init(identifier, address, linkinfo_token);
    const index = self.linked_sections.len();
    try self.linked_sections.append(self.qcu.allocator, section);
    return .at(index);
}

fn findSection(self: *const Linker, identifier: []const u8) ?*const Section {
    for (self.linked_sections.list.items) |*section| {
        if (std.mem.eql(u8, section.identifier, identifier))
            return section;
    }

    return null;
}

fn processSectionBlocks(self: *Linker, section_index: SectionList.Index) !void {
    const section = self.linked_sections.getReference(section_index);
    for (self.link_list.list.items, 0..) |block, index| {
        if (!std.mem.eql(u8, block.name, section.identifier))
            continue;
        if (!self.pending_list.isSet(index))
            continue;
        self.pending_list.unset(index);
        try self.emitSectionBlock(section, block);
    }
}

fn emitSectionBlock(self: *Linker, section: *Section, block: AsmSemanticAir.Block) !void {
    if (block.bytes() < 1) {
        return;
    }

    const base_address = block.alignment.forward(section.nextAddress());
    const pad: u32 = @intCast(base_address - section.nextAddress());

    if (pad > 0) {
        try section.content.append(self.qcu.allocator, .{
            .token = block.token,
            .op = .{ .padding = pad } });
    }

    try section.content.ensureUnusedCapacity(self.qcu.allocator, block.content.len());

    for (block.content.list.items) |air| {
        if (air.op.bytes() < 1) {
            continue;
        }

        section.content.appendAssumeCapacity(.{
            .token = air.token,
            .op = air.op });
    }

    var iterator = block.references.iterator();

    while (iterator.next()) |reference| {
        if (self.unified_references.contains(reference.key_ptr.*)) {
            try self.addError(error.DuplicateReference, block.token, "duplicate reference '{s}'", .{ reference.key_ptr.* });
            return error.Break;
        }

        const global_address: u32 = @intCast(base_address + block.localAddressOf(reference.value_ptr.index));

        try self.unified_references.put(
            self.qcu.allocator,
            reference.key_ptr.*,
            global_address);
    }
}

fn resolveBinaryInstr(self: *Linker, mir: *Mir) !void {
    switch (mir.op) {
        .instruction => |instr| {
            _ = instr;
        },
        .data => |data| {
            const mask: i32 = @intCast(std.math.pow(usize, 2, data.bytes * 8) - 1);
            const result = try self.resolveAddressConstraint(data.value, mask, mir.token);
            mir.address = result;
            mir.binary = mir.address;
        },
        .padding,
        .ascii => {}
    }
}

fn resolveAddressConstraint(
    self: *Linker,
    value: instruction.LinkerAddress,
    mask: i32,
    token: SourceFile.Token
) !u32 {
    const full_dynamic_address: AsmCompute.ComputeTimeInt = if (value.dynamic) |dynamic| blk: {
        const unified_label = try resolveQualifiedNamespaceOwned(
            self.qcu.allocator,
            dynamic.locality,
            dynamic.namespace,
            dynamic.label);
        defer self.qcu.allocator.free(unified_label);

        const address = self.unified_references.get(unified_label) orelse {
            try self.addError(error.UnknownReference, token, "unknown reference '{s}'", .{ unified_label });
            return error.Break;
        };
        break :blk @intCast(address);
    } else 0;

    const dynamic_address: AsmCompute.ComputeTimeInt = @intCast(full_dynamic_address & value.bit_mask);
    const global_address = dynamic_address + value.offset;

    if (global_address < 0 and global_address < -(mask >> 1)) {
        try self.addError(error.AddressOverflow, token, "signed integer of {} underflows {} bit mask", .{
            global_address,
            @popCount(mask) });
        return error.Break;
    }

    if (global_address > 0 and global_address & ~mask > 0) {
        try self.addError(error.AddressOverflow, token, "address of 0x{X:0>4} overflows {} bit mask", .{
            @as(u32, @intCast(global_address)),
            @popCount(mask) });
        return error.Break;
    }

    return @bitCast(global_address);
}

pub fn dumpSectionTrace(
    self: *const Linker,
    section: *const Section,
    writer: *std.Io.Writer
) !void {
    try self.dumpSectionTraceRange(section, .{ .min = 0, .max = null }, null, writer);
}

pub fn dumpSectionTraceNear(
    self: *const Linker,
    note: Note,
    writer: *std.Io.Writer
) !void {
    var nearest_section: ?*const Section = null;

    for (self.linked_sections.list.items) |*section| {
        if (note.address < section.origin or note.address > section.origin + section.bytes())
            continue;
        nearest_section = section;
    }

    if (nearest_section) |the_nearest_section| {
        const address_near: i32 = @intCast(note.address);
        const range = Range {
            .min = @max(0, address_near - 10),
            .max = @min(the_nearest_section.bytes(), address_near + 10) };
        try self.dumpSectionTraceRange(the_nearest_section, range, note, writer);
    } else {
        try writer.print(
            \\@section unknown
            \\... unknown section mapped near address {}
            \\... {s}
            \\
        , .{ note.address, note.message });
    }
}

const Range = struct {
    min: u32,
    max: ?u32
};

const Note = struct {
    address: u32,
    message: []const u8
};

pub fn dumpSectionTraceRange(
    _: *const Linker,
    section: *const Section,
    range: Range,
    note: ?Note,
    writer: *std.Io.Writer
) !void {
    try writer.print("@section {s} (size {})\n", .{
        section.identifier,
        section.bytes() });
    if (range.min > 0) {
        try writer.writeAll("... (omitted)\n");
    }

    const len: usize = if (range.max) |max| max else section.origin + section.bytes();

    for (section.content.list.items, 0..) |mir, index| {
        const global_address = section.origin + section.localAddressOf(.fromIndex(index));

        if (global_address < range.min)
            continue;
        if (global_address + mir.op.bytes() > len)
            continue;

        try writer.print("    0x{X:0>4}:{s} {}", .{
            global_address,
            if (mir.op == .padding) " * " else " ",
            mir.binary });
        defer writer.writeAll("\n") catch {};

        if (note) |the_note| {
            if (global_address >= the_note.address and global_address + mir.op.bytes() < the_note.address)
                try writer.print("  <-- {s}", .{ the_note.message });
        }
    }

    if (len != section.origin + section.bytes()) {
        try writer.writeAll("... (omitted)\n");
    }
}

pub const Locality = enum { global, local };

pub fn resolveQualifiedNamespaceOwned(
    allocator: std.mem.Allocator,
    locality: Locality,
    namespace: []const u8,
    label: []const u8
) ![]const u8 {
    const local_namespace = if (locality == .local)
        ":local" else
        "";
    return try allocator.print("{s}{s}.{s}", .{ namespace, local_namespace, label });
}
