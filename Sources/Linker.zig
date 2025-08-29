
// Linker

const builtin = @import("builtin");
const std = @import("std");
const AsmSemanticAir = @import("AsmSemanticAir.zig");
const Error = @import("Error.zig");
const Qcu = @import("Qcu.zig");
const Token = @import("Token.zig");

const Linker = @This();

allocator: std.mem.Allocator,
options: Qcu.Options,
link_list: SectionLinkList,
blocks: BlockMap, 
current_block: *Block,
unified_references: ReferenceMap,
last_emitted_section: ?*Section,
dump_section_name: ?[]const u8,

pub fn init(allocator: std.mem.Allocator, options: Qcu.Options) Linker {
    return .{
        .allocator = allocator,
        .options = options,
        .link_list = .empty,
        .blocks = .empty,
        .current_block = undefined,
        .unified_references = .empty,
        .last_emitted_section = null,
        .dump_section_name = null };
}

pub fn deinit(self: *Linker) void {
    for (self.link_list.items) |*link_node|
        link_node.deinit(self.allocator);
    self.link_list.deinit(self.allocator);
    for (self.blocks.values()) |block|
        block.deinit(self.allocator);
    self.blocks.deinit(self.allocator);
    self.current_block = undefined;
    self.unified_references.deinit(self.allocator);
}

pub fn dump(self: *Linker, writer: anytype) !void {
    for (self.blocks.keys()) |section_name|
        try self.dump_block_trace(section_name, writer);
}

const Section = struct {

    identifier: []const u8,
    file: *Qcu.File,
    inner: *AsmSemanticAir.Section,
    is_poked: bool,
    is_emitted: bool = false,
    depth_sequence: i32 = std.math.maxInt(i32),
    // fixme: multiple labels per instruction. currently semantics rejects them
    reference_map: std.AutoArrayHashMapUnmanaged(u32, []const u8) = .empty, // address : unified_label

    pub fn deinit(self: *Section, allocator: std.mem.Allocator) void {
        for (self.reference_map.values()) |str|
            allocator.free(str);
        self.reference_map.deinit(allocator);
    }

    pub fn contains_relativity(self: *Section) bool {
        for (self.inner.content.items(.instruction)) |instruction|
            if (std.meta.activeTag(instruction).is_relative())
                return true;
        return false;
    }
};

const Block = struct {

    token: Token,
    origin: u32,
    content: ByteList = .empty,

    pub fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        self.content.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn absolute_size(self: *Block) usize {
        return self.origin + self.content.len;
    }

    /// If true, it's possible to map this block as just a length to be
    /// allocated later by a kernel.
    pub fn is_empty_content(self: *Block) bool {
        for (self.content.items(.instruction)) |instr|
            if (instr.raw_value != 0)
                return false;
        return true;
    }
};

pub const Byte = struct {

    pub const Tag = union(enum) {

        cli,
        ast: AsmSemanticAir.GpRegister,
        rst: AsmSemanticAir.GpRegister,
        jmp,
        jmpr,
        jmpd,
        mst: AsmSemanticAir.SpRegister,
        mstx: AsmSemanticAir.SpRegister,
        mstw: AsmSemanticAir.SpRegister,
        mstwx: AsmSemanticAir.SpRegister,
        mld: AsmSemanticAir.SpRegister,
        mldx: AsmSemanticAir.SpRegister,
        mldw: AsmSemanticAir.SpRegister,
        mldwx: AsmSemanticAir.SpRegister,

        pub fn size(self: Tag) usize {
            @setEvalBranchQuota(999_999);
            inline for (@typeInfo(AsmSemanticAir.Instruction.Tag).@"enum".fields) |tag|
                if (std.mem.eql(u8, @tagName(self), tag.name))
                    return (comptime std.meta.stringToEnum(AsmSemanticAir.Instruction.Tag, tag.name).?).basic_size();
            unreachable;
        }
    };

    pub const pad = Byte {
        .raw_value = 0,
        .is_padding = true };

    raw_value: u8,

    compiled: ?Tag = null,
    address_hint: ?i32 = null,
    label: ?[]const u8 = null,
    long: ?*const AsmSemanticAir.Instruction = null,
    is_padding: bool = false
};

const SectionLinkList = std.ArrayListUnmanaged(Section);
const BlockMap = std.StringArrayHashMapUnmanaged(*Block);
const ByteList = std.MultiArrayList(Byte);
const ReferenceMap = std.StringArrayHashMapUnmanaged(u32);

/// To calculate alignment.
fn find_available_mask(from_address: usize, mask: usize) usize {
    std.debug.assert(std.math.isPowerOfTwo(mask));
    return (from_address + mask -% 1) & ~(mask -% 1);
}

pub fn append(self: *Linker, file: *Qcu.File) !void {
    const sema = file.sema orelse unreachable;

    for (sema.sections.keys()) |section_name| {
        var section: ?*AsmSemanticAir.Section = sema.sections.get(section_name) orelse unreachable;

        while (section) |section_| {
            try self.link_list.append(self.allocator, .{
                .identifier = section_name,
                .file = file,
                .inner = section_,
                .is_poked = !section_.is_removable });
            section = section_.next;
        }
    }
}

const LinkError = error {
    DuplicateSymbolId,
    DuplicateGlobalSection,
    MissingGlobalSection,
    DuplicateLinkingInfo,
    UnknownLinkInfo,
    InvalidLinkInfo,
    DuplicateSectionMapping,
    DescendingSectionMapping,
    AlignPowerTwo,
    EmptyLinkSections,
    MaximumMemoryExceeded,
    MaximumSizeExceeded,
    MaximumAddressExceeded,
    NoteDefinedHere,
    NotePreviouslyDefinedHere,
    NoteAddressDefinedHere,
    NoteSizeDefinedHere
};

fn add_error(self: *Linker, comptime err: LinkError, target: *Qcu.File, argument: anytype) !void {
    @branchHint(.cold);

    const message = switch (err) {
        error.DuplicateSymbolId => "duplicate global symbol '{s}'",
        error.DuplicateGlobalSection => "duplicate global section '{s}' (no stable memory layout)",
        error.MissingGlobalSection => "missing global section '{s}'",
        error.DuplicateLinkingInfo => "multiply defined linking info",
        error.UnknownLinkInfo => "unknown link info key '{s}'",
        error.InvalidLinkInfo => "invalid link info subject format",
        error.DuplicateSectionMapping => "duplicate mapping of section '{s}'",
        error.DescendingSectionMapping => "section '{s}' mapping with origin {} is less than cumulative size {}",
        error.AlignPowerTwo => "alignment of {} is not a power of two",
        error.EmptyLinkSections => "nothing to link; are you missing @linkinfo definitions?",
        error.MaximumMemoryExceeded => "memory exceeds maximum total size of {} bytes",
        error.MaximumSizeExceeded => "memory of section '{s}' exceeds set size of {} bytes",
        error.MaximumAddressExceeded => "memory of section '{s}' exceeds set address {}",
        error.NoteDefinedHere => "{s} defined here",
        error.NotePreviouslyDefinedHere => "previously defined here",
        error.NoteAddressDefinedHere => "address range {}..{} mapped here",
        error.NoteSizeDefinedHere => "address {} -> {} mapped here"
    };

    const is_note = switch (err) {
        error.NoteDefinedHere,
        error.NotePreviouslyDefinedHere,
        error.NoteAddressDefinedHere,
        error.NoteSizeDefinedHere => true,
        else => false
    };

    const token: ?Token = switch (err) {
        error.DuplicateGlobalSection,
        error.UnknownLinkInfo,
        error.DuplicateSectionMapping,
        error.AlignPowerTwo,
        error.NoteDefinedHere => argument[1],
        error.DuplicateSymbolId,
        error.MissingGlobalSection,
        error.MaximumMemoryExceeded,
        error.EmptyLinkSections => null,
        error.DuplicateLinkingInfo,
        error.InvalidLinkInfo,
        error.NotePreviouslyDefinedHere => argument,
        error.DescendingSectionMapping => argument[3],
        error.MaximumSizeExceeded,
        error.MaximumAddressExceeded,
        error.NoteAddressDefinedHere,
        error.NoteSizeDefinedHere => argument[2]
    };
    const token_location = if (token) |token_|
        target.source.?.location_of(token_.location) else
        null;
    const arguments = switch (err) {
        error.DuplicateGlobalSection,
        error.DuplicateSectionMapping,
        error.AlignPowerTwo,
        error.UnknownLinkInfo => .{ argument[0] },
        error.DuplicateSymbolId,
        error.MissingGlobalSection,
        error.MaximumMemoryExceeded => .{ argument },
        error.DuplicateLinkingInfo,
        error.InvalidLinkInfo,
        error.EmptyLinkSections,
        error.NotePreviouslyDefinedHere => .{},
        error.NoteDefinedHere => .{ argument[0].fmt() },
        error.DescendingSectionMapping => .{ argument[0], argument[1], argument[2] },
        error.MaximumSizeExceeded,
        error.MaximumAddressExceeded,
        error.NoteAddressDefinedHere,
        error.NoteSizeDefinedHere => .{ argument[0], argument[1] }
    };

    const format = try std.fmt.allocPrint(self.allocator, message, arguments);
    errdefer self.allocator.free(format);

    const err_data = Error {
        .id = err,
        .token = token,
        .is_note = is_note,
        .message = format,
        .location = token_location };
    try target.add_error(err_data);
}

pub fn generate(self: *Linker) !void {
    const root_section = try self.get_root_section() orelse return;
    try self.poke_section_tree(root_section, 0); // generates address map

    if (!self.options.noelimination)
        self.remove_unpoked_inplace();
    if (!self.options.noautoalign)
        self.inject_optimised_alignment();
    const link = try self.find_single_linkinfo() orelse return;

    for (link.info) |link_node| {
        const action = link_node.action() orelse {
            if (!self.options.nolinkwarnings)
                try self.add_error(error.UnknownLinkInfo, link.file, .{ link_node.key, link_node.token });
            continue;
        };

        if (!link_node.is_valid()) {
            try self.add_error(error.InvalidLinkInfo, link.file, link_node.token);
            continue;
        }

        switch (action) {
            .origin => try self.emit_link_origin(link.file, link_node),
            .@"align" => try self.emit_link_align(link.file, link_node),
            .maxlen => try self.emit_link_maxlen(link.file, link_node),
            .maxaddr => try self.emit_link_maxaddr(link.file, link_node)
        }
    }

    if (!self.options.nolinkwarnings and self.blocks.count() == 0) {
        try self.add_error(error.EmptyLinkSections, link.file, {});
        return;
    }

    for (self.blocks.values()) |block|
        try self.address_resolution(block);
}

fn get_root_section(self: *Linker) !?*Section {
    return try self.find_single_section(self.options.rootsection) orelse {
        try self.add_error(error.MissingGlobalSection, self.link_list.items[0].file, self.options.rootsection);
        return null;
    };
}

fn find_single_section(self: *Linker, name: []const u8) !?*Section {
    var result: ?*Section = null;

    for (self.link_list.items) |*section| {
        if (!std.mem.eql(u8, section.identifier, name))
            continue;
        if (result) |existing_result| {
            try self.add_error(error.DuplicateGlobalSection, section.file, .{ name, section.inner.token });
            try self.add_error(error.NoteDefinedHere, existing_result.file, .{ existing_result.inner.token.tag, existing_result.inner.token });
            continue;
        }

        result = section;
    }

    return result;
}

fn poke_section_tree(self: *Linker, section: *Section, depth_sequence: i32) !void {
    if (section.is_poked)
        return;
    section.is_poked = true;
    section.depth_sequence = depth_sequence;

    loop: for (section.inner.content.items(.instruction)) |instruction| {
        switch (instruction) {
            .ld_padding => {},

            inline else => |operands| {
                if (@typeInfo(@TypeOf(operands)) != .@"struct")
                    continue :loop;
                @setEvalBranchQuota(9999);

                oper: inline for (operands) |operand| {
                    if (!@hasField(@TypeOf(operand), "result") or !@hasField(@TypeOf(operand.result), "linktime_label"))
                        continue :oper;
                    if (operand.result.linktime_label) |linktime_label| {
                        // semantic analysis verifies that the imported reference exists
                        const foreign_reference = linktime_label.sema.references.get(linktime_label.name) orelse unreachable;
                        const linker_section = self.find_linker_section(foreign_reference.section) orelse unreachable;

                        // map local indexes to universal labels to link later
                        if (!linker_section.reference_map.contains(foreign_reference.instruction_index)) {
                            const unified_label = try linktime_label.sema.unified_label(self.allocator, linktime_label.name);
                            errdefer self.allocator.free(unified_label);
                            try linker_section.reference_map.put(self.allocator, foreign_reference.instruction_index, unified_label);
                        }

                        // poke outgoing reference to section
                        try self.poke_section_tree(linker_section, depth_sequence + 1);
                    }
                }
            }
        }
    }
}

fn find_linker_section(self: *Linker, sema_section: *AsmSemanticAir.Section) ?*Section {
    for (self.link_list.items) |*section| {
        if (section.inner == sema_section)
            return section;
    }

    return null;
}

fn remove_unpoked_inplace(self: *Linker) void {
    var index: usize = 0;

    while (index < self.link_list.items.len) {
        if (!self.link_list.items[index].is_poked) {
            var pruned = self.link_list.swapRemove(index);
            pruned.deinit(self.allocator);
            // new element possibly at this index, so no increment
        } else {
            index += 1;
        }
    }

    for (self.link_list.items) |referenced_section|
        std.debug.assert(referenced_section.is_poked);
}

fn inject_optimised_alignment(self: *Linker) void {
    for (self.link_list.items) |*link_node| {
        if (link_node.inner.alignment != 0)
            continue; // don't want to do anything with custom alignment
        link_node.inner.alignment = if (link_node.inner.size() >= self.options.l1)
            self.options.l1 else // the best we can do is align it on an L1 cache line
            power_two_ceil(link_node.inner.size()); // for smaller sequences, make sure it's not overstepping L1 boundaries
    }
}

fn power_two_ceil(size: usize) usize {
    var power: usize = 1;
    while (power < size) power *= 2;
    return power;
}

fn find_single_linkinfo(self: *Linker) !?struct {
    info: []const AsmSemanticAir.LinkInfo,
    file: *Qcu.File
} {
    var result: ?*const AsmSemanticAir = null;
    var file: *Qcu.File = undefined;

    for (self.link_list.items) |section| {
        const sema = &section.file.sema.?;

        if (result == sema or sema.link_info.items.len == 0)
            continue;
        if (result) |existing_result| {
            const first_info_token = sema.link_info.items[0].token;
            const existing_info_token = existing_result.link_info.items[0].token;
            try self.add_error(error.DuplicateLinkingInfo, section.file, first_info_token);
            try self.add_error(error.NoteDefinedHere, existing_result.qcu.?, .{ existing_info_token.tag, existing_info_token });
            continue;
        }

        result = sema;
        file = section.file;
    }

    return if (result) |result_|
        .{ .info = result_.link_info.items, .file = file } else
        null;
}

fn emit_link_origin(self: *Linker, file: *Qcu.File, link_node: AsmSemanticAir.LinkInfo) !void {
    const section_name = link_node.subject.?;
    try self.new_block(file, section_name, .{ .token = link_node.token, .origin = link_node.value });
    try self.emit_section_blocks(section_name);
}

fn emit_link_align(self: *Linker, file: *Qcu.File, link_node: AsmSemanticAir.LinkInfo) !void {
    if (!std.math.isPowerOfTwo(link_node.value))
        return try self.add_error(error.AlignPowerTwo, file, .{ link_node.value, link_node.token });
    const section_name = link_node.subject.?;
    const aligned_origin = if (self.blocks.count() > 0)
        find_available_mask(self.current_block.absolute_size(), link_node.value) else
        0;
    try self.new_block(file, section_name, .{ .token = link_node.token, .origin = @intCast(aligned_origin) });
    try self.emit_section_blocks(section_name);
}

fn emit_link_maxlen(self: *Linker, file: *Qcu.File, link_node: AsmSemanticAir.LinkInfo) !void {
    const section_name = link_node.subject.?;
    const block = self.blocks.get(section_name) orelse return;

    if (block.content.len > link_node.value) {
        try self.add_error(error.MaximumSizeExceeded, file, .{ section_name, link_node.value, link_node.token });
        try self.add_error(error.NoteSizeDefinedHere, file, .{ block.origin, block.content.len, block.token });
        if (!self.options.dnotrace) self.dump_section_name = section_name;
    }
}

fn emit_link_maxaddr(self: *Linker, file: *Qcu.File, link_node: AsmSemanticAir.LinkInfo) !void {
    const section_name = link_node.subject.?;
    const block = self.blocks.get(section_name) orelse return;

    if (block.absolute_size() > link_node.value) {
        try self.add_error(error.MaximumAddressExceeded, file, .{ section_name, link_node.value, link_node.token });
        try self.add_error(error.NoteAddressDefinedHere, file, .{ block.origin, block.absolute_size(), block.token });
        if (!self.options.dnotrace) self.dump_section_name = section_name;
    }
}

fn new_block(self: *Linker, file: *Qcu.File, name: []const u8, block: Block) !void {
    if (self.blocks.get(name)) |existing_block| {
        try self.add_error(error.DuplicateSectionMapping, file, .{ name, block.token });
        try self.add_error(error.NotePreviouslyDefinedHere, file, existing_block.token);
        return;
    }

    if (self.blocks.count() > 0) blk: {
        const last_address = self.current_block.absolute_size();
        if (block.origin >= last_address)
            break :blk;
        try self.add_error(error.DescendingSectionMapping, file, .{ name, block.origin, last_address, block.token });
        try self.add_error(error.NoteAddressDefinedHere, file, .{ self.current_block.origin, last_address, self.current_block.token });
        return;
    }

    const alloc_block = try self.allocator.create(Block);
    errdefer self.allocator.destroy(alloc_block);
    alloc_block.* = block;

    try self.blocks.put(self.allocator, name, alloc_block);
    self.current_block = alloc_block;
}

fn emit_section_blocks(self: *Linker, section_name: []const u8) !void {
    while (true) {
        // fixme: add most optimal size for further padding optimisation?
        var least_padding_section: ?*Section = null;
        var least_padding: usize = undefined;

        search: for (self.link_list.items) |*section| {
            if (section.is_emitted or !std.mem.eql(u8, section.identifier, section_name))
                continue :search;
            if (section.inner.alignment <= 1) {
                least_padding_section = section;
                least_padding = 0;
                break :search;
            }

            const current_address = self.current_block.absolute_size();
            const section_padding = find_available_mask(current_address, section.inner.alignment) - current_address;

            if (least_padding_section == null or section_padding < least_padding) {
                if (self.last_emitted_section) |last_section| blk: {
                    if (!last_section.contains_relativity() or self.options.nodepthoptimisation)
                        break :blk;
                    const selected_section = least_padding_section orelse break :blk;

                    // if this section depends on relative addressing,
                    // prioritise depth sequences as close to current one
                    const selected_depth = selected_section.depth_sequence - last_section.depth_sequence;
                    const new_depth = section.depth_sequence - last_section.depth_sequence;
                    if (@abs(new_depth) > @abs(selected_depth)) continue :search;
                }

                least_padding_section = section;
                least_padding = section_padding;
            }
        }

        self.last_emitted_section = least_padding_section orelse break;
        self.last_emitted_section.?.is_emitted = true;
        try self.emit_section_padding(least_padding);
        try self.emit_section_block(self.last_emitted_section.?);

        const next_address = self.current_block.absolute_size();
        const max_memory = self.options.page * self.options.pagelen;

        if (next_address >= max_memory) {
            try self.add_error(error.MaximumMemoryExceeded, self.link_list.items[0].file, max_memory);
            if (!self.options.dnotrace) self.dump_section_name = self.last_emitted_section.?.identifier;
            break;
        }
    }
}

fn emit_section_padding(self: *Linker, padding: usize) !void {
    try self.current_block.content.ensureUnusedCapacity(self.allocator, padding);
    for (0..padding) |_| self.current_block.content.appendAssumeCapacity(.pad);
}

fn emit_section_block(self: *Linker, section: *const Section) !void {
    for (section.inner.content.items(.instruction), 0..) |*instr, i| {
        const initial_address = self.current_block.absolute_size();
        const instr_size = instr.size();

        if (instr_size == 0)
            continue;
        const maybe_unified_reference = section.reference_map.get(@intCast(i));
        try self.emit_instruction_bytes(instr, maybe_unified_reference);
        std.debug.assert(self.current_block.absolute_size() - initial_address == instr_size);

        // there's a reference at this index, now its real address is known
        if (maybe_unified_reference) |unified_reference| {
            if (self.unified_references.contains(unified_reference)) {
                try self.add_error(error.DuplicateSymbolId, section.file, unified_reference);
                continue;
            }

            try self.unified_references.put(self.allocator, unified_reference, @intCast(initial_address));
        }
    }
}

fn emit_instruction_bytes(
    self: *Linker,
    instruction: *const AsmSemanticAir.Instruction,
    label: ?[]const u8
) !void {
    const size = instruction.size();
    if (size == 0) return;

    switch (instruction.*) {
        .reserve, // fixme: force constant for reserve expression
        .u8, .u16, .u24,
        .i8, .i16, .i24 => {
            try self.current_block.content.append(self.allocator, .{
                .raw_value = 0,
                .label = label,
                .long = instruction });
            for (0..(size - 1)) |_|
                try self.current_block.content.append(self.allocator, .pad);
        },

        .ascii => |ascii| {
            const string = ascii[0].result;

            if (string.memory.len > 0) {
                try self.current_block.content.append(self.allocator, .{
                    .raw_value = string.memory[0],
                    .label = label,
                    .long = instruction });
                for (string.memory[1..]) |byte|
                    try self.current_block.content.append(self.allocator, .{ .raw_value = byte });
            }

            if (string.sentinel) |sentinel| {
                if (string.memory.len > 0)
                    try self.current_block.content.append(self.allocator, .{
                        .raw_value = sentinel.result }) else
                    try self.current_block.content.append(self.allocator, .{
                        .raw_value = sentinel.result,
                        .label = label,
                        .long = instruction });
            }
        },

        .ld_padding => {
            for (0..size) |_| try self.current_block.content.append(self.allocator, .pad);
        },

        else => {
            const class_1: struct {
                raw_value: u8,
                compiled: Byte.Tag
            } = map: switch (instruction.*) {
                .u8, .u16, .u24,
                .i8, .i16, .i24,
                .ascii,
                .reserve,
                .ld_padding => unreachable,

                inline else => |operands, tag| {
                    inline for (@typeInfo(Byte.Tag).@"union".fields) |mapping| {
                        // Zig should eagerly evaluate this at comptime! but still cool
                        if (comptime std.mem.eql(u8, mapping.name, @tagName(tag))) {
                            const opcode: u8 = switch (tag) {
                                .cli => 0b0_0000_000,
                                .ast => 0b0_0001_000,
                                .rst => 0b0_0100_000,
                                .jmp => 0b1_1010_0_00,
                                .jmpr => 0b1_1010_0_01,
                                .jmpd => 0b1_1010_0_10,
                                .mst => 0b1_1100_0_00,
                                .mstx => 0b1_1100_1_00,
                                .mstw => 0b1_1101_0_00,
                                .mstwx => 0b1_1101_1_00,
                                .mld => 0b1_1110_0_00,
                                .mldx => 0b1_1110_1_00,
                                .mldw => 0b1_1111_0_00,
                                .mldwx => 0b1_1111_1_00,
                                else => @compileError("bug: unmapped binary representation in linker")
                            };

                            const is_operand = mapping.@"type" != void;

                            const binary = opcode | if (is_operand)
                                @as(u8, @intCast(@intFromEnum(operands[0].result))) else
                                0;
                            const compiled = if (is_operand)
                                @unionInit(Byte.Tag, mapping.name, operands[0].result) else
                                @unionInit(Byte.Tag, mapping.name, {});

                            break :map .{
                                .raw_value = binary,
                                .compiled = compiled };
                        }
                    }

                    comptime unreachable;
                }
            };

            try self.current_block.content.append(self.allocator, .{
                .raw_value = class_1.raw_value,
                .compiled = class_1.compiled,
                .label = label,
                .long = instruction });

            // they're zero bytes for now, because all the addresses are not known yet
            for (0..(size - 1)) |_| try self.current_block.content.append(self.allocator, .pad);
        }
    }
}

fn address_resolution(self: *Linker, block: *Block) !void {
    const instructions = block.content.items(.long);
    const labels = block.content.items(.label);

    for (instructions, 0..) |instruction, i| {
        switch ((instruction orelse continue).*) {
            // only constant
            .ascii,
            .reserve,
            .ld_padding => {},

            // free game
            inline else => |operands, tag| blk: {
                if (@TypeOf(operands) == void)
                    break :blk;
                const operand = operands[operands.len - 1];

                if (!@hasField(@TypeOf(operand), "result") or !@hasField(@TypeOf(operand.result), "linktime_label"))
                    break :blk;
                const label_address = if (operand.result.linktime_label) |lbl|
                    self.unified_references.get(lbl.unified_name) orelse unreachable else
                    0;
                const resolved_address = try operand.result.resolve(
                    operand.token,
                    operand.executed_token,
                    @as(i32, @intCast(block.origin)) + @as(i32, @intCast(i)),
                    @intCast(label_address)) orelse break :blk;
                // https://ziglang.org/documentation/master/#byteSwap for u24
                const little_endian: @TypeOf(resolved_address.result) = switch (builtin.cpu.arch.endian()) {
                    .big => @byteSwap(resolved_address.result),
                    .little => resolved_address.result
                };
                const bytes = std.mem.asBytes(&little_endian);

                // instructions skip one byte for address insertion,
                // pseudoinstructions are completely overwritten
                @setEvalBranchQuota(9999);
                const ByteTag = @typeInfo(Byte.Tag).@"union".tag_type.?;
                const offset = if (comptime std.meta.stringToEnum(ByteTag, @tagName(tag)) != null) 1 else 0;

                for (bytes, 0..) |byte, idx| {
                    const byte_address = i + offset + idx; // block addr + instr. byte offset + byte index
                    std.debug.assert(block.content.get(byte_address).compiled == null);

                    block.content.set(byte_address, .{
                        .raw_value = byte,
                        .label = labels[byte_address],
                        .address_hint = if (idx == 0) resolved_address.real_address else null,
                        .long = instructions[byte_address] });
                }
            }
        }
    }
}

pub fn dump_last_block_trace(self: *const Linker, writer: anytype) !void {
    const section_name = self.dump_section_name orelse return;
    try self.dump_block_trace(section_name, writer);
}

pub fn dump_block_trace(self: *const Linker, section_name: []const u8, writer: anytype) !void {
    const block = self.blocks.get(section_name) orelse unreachable;
    try self.dump_block_trace_range(section_name, block, .{ .min = 0, .max = null }, null, writer);
}

pub fn dump_block_trace_near(self: *const Linker, note: Note, writer: anytype) !void {
    var section_name: ?[]const u8 = null;
    var block: *const Block = undefined;

    for (self.blocks.keys(), self.blocks.values()) |name, section| {
        if (note.address < section.origin or note.address > section.origin + section.content.len)
            continue;
        section_name = name;
        block = section;
    }

    if (section_name) |the_section_name| {
        const offset: isize = @intCast(note.address - block.origin);
        const range = Range {
            .min = @intCast(@max(0, offset - 10)),
            .max = @intCast(@min(@as(isize, @intCast(block.content.len)), offset + 10)) };
        try self.dump_block_trace_range(the_section_name, block, range, note, writer);
    } else {
        try writer.print(
            \\@section unknown
            \\"... unknown section mapped near address {}
            \\"... {s}
            \\
        , .{ note.address, note.message });
    }
}

const Range = struct {
    min: usize,
    max: ?usize
};

const Note = struct {
    address: usize,
    message: []const u8
};

pub fn dump_block_trace_range(
    self: *const Linker,
    section_name: []const u8,
    block: *const Block,
    range: Range,
    note: ?Note,
    writer: anytype
) !void {
    try writer.print("@section {s} (size {})\n", .{
        section_name,
        block.content.len });
    if (range.min != 0)
        try writer.writeAll("... (omitted)\n");
    const content = block.content.slice();
    const len = if (range.max) |m| m else block.content.len;

    for (
        content.items(.raw_value)[range.min..len],
        content.items(.compiled)[range.min..len],
        content.items(.address_hint)[range.min..len],
        content.items(.label)[range.min..len],
        content.items(.is_padding)[range.min..len],
        range.min..
    ) |raw_value, compiled, address_hint, label, is_padding, i| {
        const absolute_address = block.origin + i;

        if (i != 0 and absolute_address % self.options.page == 0)
            try writer.print("Page ({})\n", .{ self.options.page })
        else if (i != 0 and absolute_address % self.options.l1 == 0)
            try writer.print("L1 ({})\n", .{ self.options.l1 });

        try writer.print("{s: <23} {x:0>4}:{s}0b{b:0>8}   ", .{
            label orelse "",
            absolute_address,
            if (is_padding) " * " else " ",
            raw_value });
        defer writer.writeAll("\n") catch {};

        if (compiled) |instruction| switch (instruction) {
            inline else => |operand, tag| if (@TypeOf(operand) != void)
                try writer.print(" {s} {s}", .{ @tagName(tag), @tagName(operand) }) else
                try writer.print(" {s}", .{ @tagName(tag) })
        };

        if (address_hint) |hint|
            try writer.print(" ({})", .{ hint });

        // this dump can only be shown if it was generated by this fault anyway
        if (absolute_address == self.options.page * self.options.pagelen)
            try writer.print("    <-- address exceeds limit here", .{});

        if (note) |the_note| if (the_note.address == absolute_address)
            try writer.print("    <-- {s}", .{ the_note.message });
    }

    if (len != block.content.len)
        try writer.writeAll("... (omitted)\n");
}

// Tests

const options_ = @import("options");

const stderr = std.io
    .getStdErr()
    .writer();

fn testLinkerQueue(files: []const []const u8) !*Qcu {
    return try Qcu.init(
        std.testing.allocator,
        std.fs.cwd(),
        files,
        .{ .noliveness = true, .nolinkwarnings = true });
}

fn testQueue(qcu: *Qcu, errors: []const anyerror) !void {
    while (qcu.work_queue.removeOrNull()) |job| {
        job.execute() catch |err| {
            if (errors.len == 0) {
                std.debug.print("failed on job {s} with {}\n", .{ @tagName(std.meta.activeTag(job)), err });
                for (qcu.errors.items) |the_err|
                    try the_err.write(stderr);
                return err;
            }

            var qcu_errors = std.ArrayList(anyerror).init(std.testing.allocator);
            defer qcu_errors.deinit();
            for (qcu.errors.items) |the_err|
                try qcu_errors.append(the_err.err.id);
            if (!std.mem.eql(anyerror, errors, qcu_errors.items)) {
                for (qcu.errors.items) |the_err|
                    try the_err.write(stderr);
                try std.testing.expectEqualSlices(anyerror, errors, qcu_errors.items);
            }
            return;
        };
    }
}

test "root section duplicate" {
    var qcu = try testLinkerQueue(&.{ "Tests/bad_root.1.s" });
    defer qcu.deinit();

    try testQueue(qcu, &.{
        error.DuplicateGlobalSection,
        error.NoteDefinedHere });
}

test "root section missing" {
    var qcu = try testLinkerQueue(&.{ "Tests/sample.s" });
    defer qcu.deinit();

    try testQueue(qcu, &.{ error.MissingGlobalSection });
}
