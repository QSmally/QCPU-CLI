
// Linker

const std = @import("std");
const indexable_list = @import("indexable_list.zig");
const Section = @import("Section.zig");
const Qcu = @import("Qcu.zig");
const SourceFile = @import("SourceFile.zig");
const AsmSemanticAir = @import("AsmSemanticAir.zig");
const AsmCompute = @import("AsmCompute.zig");

const Linker = @This();

qcu: *Qcu,

link_list: BlockList = .empty,
pending_list: std.DynamicBitSetUnmanaged = .{},
link_info: ?[]const LinkInfo = null,
linked_sections: Section.List = .empty,
unified_references: std.StringHashMapUnmanaged(u32) = .empty,
virt: LinkInfo.VirtDevice = .none,

const log = std.log.scoped(.Linker);

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
        try section.dumpTrace(writer);
    }

    var iterator = self.unified_references.iterator();

    while (iterator.next()) |reference| {
        try writer.print("{s} -> 0x{X:0>4}\n", .{ reference.key_ptr.*, reference.value_ptr.* });
    }
}

pub const LinkInfo = struct {

    token: SourceFile.Token,
    ty: Type,

    pub const Type = union(enum) {
        virt: struct {
            device: VirtDevice
        },
        origin: struct {
            section_name: []const u8,
            address: u32
        },
        aligned: struct {
            section_name: []const u8,
            alignment: std.mem.Alignment
        }
    };

    pub const VirtDevice = union(enum) {
        none,
        boot,
        memory: u32
    };
};

pub const BlockList = indexable_list.IndexableList(AsmSemanticAir.Block);

pub const LinkerError = error {
    DuplicateLinkInfo,
    EmptyLinkSections,
    InvalidLinkSections,
    DuplicateSection,
    DescendingSection,
    UnlinkedSection,
    InstructionAlignTwo,
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

    log.debug("performLink link_info.len={} link_list.len={}", .{ info.len, self.link_list.len() });

    try self.pending_list.resize(self.qcu.allocator, self.link_list.len(), true);

    for (info) |li| switch (li.ty) {
        .virt => |virt| try self.emitLinkVirt(li.token, virt.device),
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
        for (section.content.list.items, 0..) |*mir, index| {
            const ip = section.origin + section.localAddressOf(.fromIndex(index));
            try self.resolveBinaryInstr(mir, ip);
        }
    }
}

fn emitLinkVirt(self: *Linker, token: SourceFile.Token, virt: LinkInfo.VirtDevice) !void {
    if (self.virt == .none) {
        self.virt = virt;
        return;
    }

    try self.addError(error.InvalidLinkSections, token, "@linkinfo(virt) is multiply defined", .{});
    for (self.link_info.?) |li| if (li.ty == .virt) {
        try self.addError(error.NoteDefinedHere, li.token, "first defined here", .{});
        break;
    };
    return error.Break;
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
    if (self.linked_sections.len() == 0) {
        try self.addError(error.InvalidLinkSections, token, "first @linkinfo must be an origin type", .{});
        return error.Break;
    }

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
) !Section.List.Index {
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

fn processSectionBlocks(self: *Linker, section_index: Section.List.Index) !void {
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

    const base_address: u32 = @intCast(block.alignment.forward(section.nextAddress()));
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

        const placement_address = base_address + section.bytes();

        if (air.op == .instruction and placement_address & 1 > 0) {
            try self.addError(error.InstructionAlignTwo, air.token, "address of instruction must be aligned by 2", .{});
            return error.Break;
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

        const global_address = base_address + block.localAddressOf(reference.value_ptr.index);

        try self.unified_references.put(
            self.qcu.allocator,
            reference.key_ptr.*,
            global_address);
    }
}

fn resolveBinaryInstr(self: *Linker, mir: *Section.Mir, ip: usize) !void {
    switch (mir.op) {
        .instruction => |instr| switch (instr) {
            inline else => |operands| blk: {
                const T = @TypeOf(operands);

                mir.binary = @intCast(instr.opcode());

                if (T == void) {
                    break :blk;
                }

                const type_info = @typeInfo(T).@"struct";

                inline for (type_info.field_names, type_info.field_types) |id, Type| {
                    const operand = @field(operands, id);
                    const mask = @field(T, id ++ "_mask");

                    const result = switch (Type) {
                        Section.Register.DataRegister,
                        Section.Register.AddressRegister,
                        Section.Flag => @backingInt(operand),
                        Section.LinkerAddress => addr: {
                            const bits = @popCount(@as(u16, mask));
                            const relative_ip: ?i32 = if (mir.op.instruction.isRelativeIp()) @intCast(ip) else null;
                            const address = try self.resolveAddressConstraint(operand, relative_ip, instr.immAlignment(), bits, mir.token);
                            break :addr address;
                        },
                        Section.LinkerIndex => addr: {
                            const bits = @popCount(@as(u16, mask));
                            const relative_ip: ?i32 = if (mir.op.instruction.isRelativeIp()) @intCast(ip) else null;
                            const address = try self.resolveAddressConstraint(operand.address, relative_ip, instr.immAlignment(), bits, mir.token);
                            break :addr address;
                        },
                        else => comptime unreachable
                    };
                    mir.binary |= @intCast(maskedShift(@intCast(result), mask));

                    if (Type == Section.LinkerIndex) {
                        const reg_mask = @field(T, id ++ "_mask_src");
                        const register = @backingInt(operand.register);
                        mir.binary |= @intCast(maskedShift(register, reg_mask));
                    }
                }
            }
        },
        .data => |data| {
            mir.binary = try self.resolveAddressConstraint(data.value, null, .@"1", data.bytes * 8, mir.token);
        },
        .padding,
        .ascii => {}
    }
}

fn resolveAddressConstraint(
    self: *Linker,
    value: Section.LinkerAddress,
    relative_address: ?i32,
    alignment: std.mem.Alignment,
    bits: usize,
    token: SourceFile.Token
) !u32 {
    const mask: i32 = @intCast(std.math.pow(usize, 2, bits) - 1);

    const dynamic_address: AsmCompute.ComputeTimeInt = if (value.dynamic) |dynamic| blk: {
        const unified_label = try resolveQualifiedNamespaceOwned(
            self.qcu.allocator,
            dynamic.locality,
            dynamic.namespace,
            dynamic.label);
        defer self.qcu.allocator.free(unified_label);

        log.debug("resolve namespace:{s} label:{s}", .{ dynamic.namespace, dynamic.label });

        const address = self.unified_references.get(unified_label) orelse {
            try self.addError(error.UnknownReference, token, "unknown reference '{s}'", .{ unified_label });
            return error.Break;
        };

        break :blk switch (dynamic.mode) {
            .normal => @intCast(address),
            .difference => blk1: {
                const last_namespace_index = std.mem.findScalarLast(u8, dynamic.label, '.') orelse dynamic.label.len;
                const base_label = dynamic.label[0..last_namespace_index];
                const base_unified_label = try resolveQualifiedNamespaceOwned(
                    self.qcu.allocator,
                    dynamic.locality,
                    dynamic.namespace,
                    base_label);
                defer self.qcu.allocator.free(base_unified_label);

                const base_address = self.unified_references.get(base_unified_label) orelse {
                    try self.addError(error.UnknownReference, token, "unknown reference '{s}'", .{ unified_label });
                    return error.Break;
                };
                break :blk1 @intCast(address - base_address);
            }
        };
    } else 0;

    const masked_dynamic_address: AsmCompute.ComputeTimeInt = @intCast(dynamic_address & value.bit_mask);
    var global_address = masked_dynamic_address + value.offset;

    if (relative_address) |the_ip| {
        global_address -= the_ip;
    }

    check: switch (alignment) {
        .@"1" => if (global_address >= 0) {
            if (global_address & ~mask > 0) {
                try self.addError(error.AddressOverflow, token, "integer of 0x{X:0>4} overflows {} bit mask", .{
                    @as(u32, @intCast(global_address)),
                    @popCount(mask) });
                return error.Break;
            }
        } else {
            if (global_address + 1 < -(mask >> 1)) {
                try self.addError(error.AddressOverflow, token, "signed integer of {} underflows {} bit mask", .{
                    global_address,
                    @popCount(mask) });
                return error.Break;
            }
        },
        .@"2" => {
            if (global_address & 1 > 0) {
                try self.addError(error.AddressOverflow, token, "address must have an alignment of 2", .{});
                return error.Break;
            }
            global_address >>= 1;
            continue :check .@"1";
        },
        else => {
            const shift = @ctz(alignment.toByteUnits());
            const shifted_mask = mask << @intCast(shift);
            const overflow = global_address & ~shifted_mask;

            if (overflow > 0) {
                try self.addError(error.AddressOverflow, token, "address of 0x{X:0>4} overflows {} bit mask with alignment of {}", .{
                    global_address,
                    @popCount(mask),
                    alignment.toByteUnits() });
                try self.addError(error.Note, token, "address:  0b{b:0>16}", .{ @as(u32, @bitCast(global_address)) });
                try self.addError(error.Note, token, "mask:     0b{b:0>16} ~&", .{ @as(u32, @bitCast(shifted_mask)) });
                try self.addError(error.Note, token, "overflow: 0b{b:0>16} =", .{ @as(u32, @bitCast(overflow)) });
                return error.Break;
            }

            global_address >>= @intCast(shift);
        }
    }

    if (global_address < 0 and relative_address == null) {
        if (value.dynamic) |dynamic| {
            try self.addError(error.AddressOverflow, token, "address with reference '{s}.{s}' is negative", .{
                dynamic.namespace,
                dynamic.label });
            if (value.bit_mask > 0) {
                try self.addError(error.Note, token, "reference is masked with 0x{X:0>4}, resulting in 0x{X:0>4}", .{
                    @as(u32, @intCast(value.bit_mask)),
                    @as(u32, @intCast(dynamic_address)) });
            }
            try self.addError(error.Note, token, "offset of {} causes an underflow", .{ value.offset });
            return error.Break;
        }
    }

    const result: u32 = @bitCast(global_address);
    return result & @as(u32, @bitCast(mask));
}

pub fn resolveTotalBytes(self: *const Linker) u32 {
    std.debug.assert(self.linked_sections.len() > 0);
    const root_section = self.linked_sections.get(.root);
    const last_section = self.linked_sections.last().?;

    return
        last_section.origin -
        root_section.origin +
        last_section.bytes();
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

fn maskedShift(int: u16, mask: usize) u16 {
    var result: u16 = 0;
    var emitting_bit: u4 = 0;

    for (0..16) |mask_index| {
        if (mask & (@as(usize, 1) << @intCast(mask_index)) > 0) {
            const bit = (int >> emitting_bit) & 1;
            result |= bit << @intCast(mask_index);
            emitting_bit +%= 1;
        }
    }

    return result;
}

// Tests

test maskedShift {
    try std.testing.expectEqual(maskedShift(0b0000_0000, 0b0000_0000), 0b0000_0000);
    try std.testing.expectEqual(maskedShift(0b0000_0001, 0b0000_1000), 0b0000_1000);
    try std.testing.expectEqual(maskedShift(0b0000_1111, 0b1100_1100), 0b1100_1100);
    try std.testing.expectEqual(maskedShift(0b0000_1010, 0b1100_1100), 0b1000_1000);
}
