
// Semantic Analysed Intermediate Representation

const std = @import("std");
const SourceLocation = @import("SourceLocation.zig");
const AsmAst = @import("AsmAst.zig");
const AsmIr = @import("AsmIr.zig");
const Token = @import("Token.zig");
const Instruction = @import("Instruction.zig");

const AsmSemanticAir = @This();

allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
source_location: *const SourceLocation,
tree: *const AsmAst,
ir: *const AsmIr,
namespace: []const u8,
bridge: Bridge,

output: union(enum) {
    owned: Section,
    parent: *AsmSemanticAir,
    suppressed
} = .suppressed,

reference_pool: std.ArrayListUnmanaged(struct {
    name: []const u8,
    token: SourceLocation.Token,
    ty: enum { discard, reference }
}) = .empty,

/// Pointing to the stack during the call to lower a header into the current
/// section of this Sema, or further propagated.
lowering_block: ?*AsmSemanticAir = null,

/// Assemble-time conditional reason, for error info.
cond_reason: CondReason = .none,

/// Tracked by headers to skip @align padding for first Air.
is_first_air: bool = true,

/// Borrows the Abstract Syntax Tree, Intermediate Representation and
/// namespace, and initialises a Semantic Analysis unit in its context. A
/// specific `analyse_block` call must be done in order to add an analysed
/// section.
pub fn init(
    allocator: std.mem.Allocator,
    source_location: *const SourceLocation,
    tree: *const AsmAst,
    ir: *const AsmIr,
    namespace: []const u8,
    bridge: Bridge
) AsmSemanticAir {
    return .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .source_location = source_location,
        .tree = tree,
        .ir = ir,
        .namespace = namespace,
        .bridge = bridge };
}

pub fn deinit(self: *AsmSemanticAir) void {
    self.arena.deinit();
}

pub fn dump(self: *AsmSemanticAir, _: std.mem.Allocator, writer: anytype) !void {
    std.debug.assert(self.output == .owned);
    const section = self.output.owned;
    try writer.print("@section {s} (align {})\n", .{ section.name, section.alignment.toByteUnits() });

    for (section.content.items) |air| switch (air.op) {
        .instr => |instr| try writer.print("  instr {s}({})\n", .{ @tagName(instr), air.size() }),
        .padding => |padding| try writer.print("  pad {}\n", .{ padding }),
        .nops => |padding| try writer.print("  reserve {}\n", .{ padding }),
        .ascii => |ascii| try writer.print("  ascii \"{s}\" {?}\n", .{ ascii.text, ascii.sentinel })
    };

    var reference_iterator = section.references.iterator();
    var address_base_iterator = section.address_base.iterator();

    while (reference_iterator.next()) |reference|
        try writer.print("  ^{s} -> {}\n", .{ reference.key_ptr.*, reference.value_ptr.index });
    while (address_base_iterator.next()) |addr_base|
        try writer.print("  ^{s} = b{}\n", .{ addr_base.key_ptr.*, addr_base.value_ptr.index });
}

pub const Bridge = struct {

    const AllocatorError = std.mem.Allocator.Error;

    pub const VTable = struct {
        emit_error: *const fn (*anyopaque, SourceLocation.Error) AllocatorError!void,
        file_context: *const fn (*anyopaque, AsmIr.Index, []const u8) AsmSemanticAir,
        ensure_block_analysed: *const fn (*anyopaque, AsmIr.Index, AsmIr.Index) AllocatorError!void
    };

    vtable: VTable,
    context: *anyopaque,

    fn emit_error(self: *Bridge, err: SourceLocation.Error) !void {
        try self.vtable.emit_error(self.context, err);
    }

    fn file_context(self: *Bridge, file_path: []const u8, namespace: []const u8) AsmSemanticAir {
        return self.vtable.file_context(self.context, file_path, namespace);
    }

    fn ensure_block_analysed(self: *Bridge, index: AsmIr.Index, block_index: AsmIr.Index) !void {
        try self.vtable.ensure_block_analysed(self.context, index, block_index);
    }
};

pub const Air = struct {

    op: Operation,
    token: SourceLocation.Token,
    is_labeled: bool,

    pub const Operation = union(enum) {
        instr: AirInstruction,
        padding: usize,
        /// Like padding, but so Liveness doesn't complain
        nops: usize,
        ascii: struct { text: []const u8, sentinel: ?u8 }
    };

    const Register = Loc(Instruction.Register);
    const Condition = Loc(Instruction.Condition);
    const Immediate = Loc(Numeric);

    pub const AirInstruction = union(Instruction.Tag) {
        add: struct { Register, Register, Register },
        addc: struct { Register, Register, Register },
        sub: struct { Register, Register, Register },
        subb: struct { Register, Register, Register },
        addi: struct { Register, Immediate },
        cmpi: struct { Register, Immediate },
        csrr: struct { Register, Immediate },
        csrw: struct { Register, Immediate },
        slt: struct { Register, Register, Register },
        sltu: struct { Register, Register, Register },
        szr: struct { Register, Register, Register },
        ior: struct { Register, Register, Register },
        @"and": struct { Register, Register, Register },
        xor: struct { Register, Register, Register },
        iori: struct { Register, Immediate },
        ioriu: struct { Register, Immediate },
        andi: struct { Register, Immediate },
        andiu: struct { Register, Immediate },
        xori: struct { Register, Immediate },
        xoriu: struct { Register, Immediate },
        bsl: struct { Register, Register, Immediate },
        bsr: struct { Register, Register, Immediate },
        bsrs: struct { Register, Register, Immediate },
        brr: struct { Register, Register, Immediate },
        bsld: struct { Register, Register, Immediate },
        bsrd: struct { Register, Register, Immediate },
        bsrsd: struct { Register, Register, Immediate },
        brrd: struct { Register, Register, Immediate },
        //
        //
        //
        //
        lli: struct { Register, Immediate },
        lui: struct { Register, Immediate },
        jmp: struct { Immediate },
        jmpl: struct { Immediate },
        jmpr: struct { Immediate },
        jmprl: struct { Immediate },
        jmpd: struct { Register },
        jmpdl: struct { Register },
        brh: struct { Condition, Immediate },
        prfi: struct { Immediate },
        mld: struct { Register, Register, Immediate },
        mldw: struct { Register, Register, Immediate },
        mst: struct { Register, Register, Immediate },
        mstw: struct { Register, Register, Immediate },
        xch: struct { Register, Register, Immediate },
        xchw: struct { Register, Register, Immediate },

        bkpt,
        mov: struct { Register, Register },
        @"test": struct { Register },
        neg: struct { Register, Register },
        cmp: struct { Register, Register },
        nop,
        inc: struct { Register },
        dec: struct { Register },
        alloc: struct { Register },
        ip: struct { Register },
        clri,
        sneg: struct { Register, Register },
        spos: struct { Register, Register },
        snez: struct { Register, Register },
        cut4: struct { Register },
        cut8: struct { Register },
        clrl: struct { Register },
        not: struct { Register },
        not8: struct { Register },
        clr: struct { Register },
        sysc: struct { Immediate },
        ret,
        fence,
        ftlb,
        rfi,
        wfi,
        scf,
        rscf,
        //
        //
        prfd: struct { Register, Immediate },
        mclr: struct { Register, Immediate },
        mclrw: struct { Register, Immediate },

        u8: struct { Immediate },
        u16: struct { Immediate },
        u24: struct { Immediate },
        u32: struct { Immediate },
        i8: struct { Immediate },
        i16: struct { Immediate },
        i24: struct { Immediate },
        i32: struct { Immediate }
    };

    pub fn size(self: *const Air) usize {
        return switch (self.op) {
            .instr => |instr| std.meta.activeTag(instr).size(),
            .padding => |padding| padding,
            .nops => |padding| padding,
            .ascii => |ascii| ascii.text.len + if (ascii.sentinel != null) @as(usize, 1) else @as(usize, 0)
        };
    }
};

pub const Section = struct {

    token: SourceLocation.Token,
    name: []const u8,
    alignment: std.mem.Alignment = .@"1",
    content: std.ArrayListUnmanaged(Air) = .empty,
    /// Public or private labels/offsets defined in this section, including
    /// lowered header labels/offsets, with a fully qualified name. A FQN
    /// looks like 'filename.symbolname', or 'filename.namespace.symbolname'
    /// for labeled header symbols. Keys are allocated by `self.allocator`.
    /// Labels are an index pointing to `content`, whilst base offsets are
    /// the offsets themselves.
    references: std.StringHashMapUnmanaged(Reference) = .empty,
    /// Offsets are offsetted from a base, which is defined here. References
    /// include the 'base.offset' namespace whilst this only defines the
    /// 'base'. Allocated with `Sema.arena`.
    address_base: std.StringHashMapUnmanaged(Reference) = .empty,

    pub const Reference = struct {
        /// If identifier, it's an offset, otherwise a (private) label.
        token: SourceLocation.Token,
        index: Index
    };

    pub fn deinit(self: *Section, allocator: std.mem.Allocator) void {
        self.content.deinit(allocator);
        var references_iterator = self.references.keyIterator();
        while (references_iterator.next()) |key| allocator.free(key);
        self.references.deinit(allocator);
    }

    pub fn size(self: *const Section) usize {
        var total_size: usize = 0;
        for (self.content.items) |air| total_size += air.size();
        return total_size;
    }
};

pub const Index = u32;

pub const Error = error {
    InvalidFormat,
    RegionExceedsSize,
    UnlinkedReference,
    DuplicateReference,
    AlignPowerTwo,
    InvalidNumeric,
    NoteCalledFromHere,
    NoteDefinedHere,
    Note
};

fn add_error(
    self: *AsmSemanticAir,
    comptime err: Error,
    token: SourceLocation.Token,
    comptime format: []const u8,
    arguments: anytype
) !void {
    @branchHint(.cold);

    const message = try std.fmt.allocPrint(self.allocator, format, arguments);
    errdefer self.allocator.free(message);

    const is_note = switch (err) {
        error.NoteCalledFromHere,
        error.NoteDefinedHere,
        error.Note => true,
        else => false
    };

    try self.bridge.emit_error(.{
        .err = err,
        .token = token.inner_token,
        .source_location = token.source_location,
        .is_note = is_note,
        .is_preview = err != error.Note,
        .message = message });
}

const ParseError = std.mem.Allocator.Error;

/// Undefined behaviour to call analyse_block twice on the same block.
pub fn analyse_block(self: *AsmSemanticAir, block_index: AsmIr.Index) ParseError!void {
    const block = self.ir.blocks[block_index];
    std.log.debug("analyse_block({s}, {s}({}))", .{ self.source_location.file_name, block.name, block_index });
    std.debug.assert(block.ty == .section);
    std.debug.assert(self.output == .suppressed); // check illegal behaviour

    const section_token = self.source_location.qualified_token(block.token);
    const new_section: Section = .{
        .token = section_token,
        .name = block.name };
    self.output = .{ .owned = new_section };

    self.analyse_body_inner(block.content.items) catch |err| switch (err) {
        error.AnalysisFail => {},
        else => |the_err| return the_err
    };
}

fn analyse_block_into(self: *AsmSemanticAir, block_index: AsmIr.Index, sema: *AsmSemanticAir) !void {
    _ = self;
    _ = block_index;
    _ = sema;
}

const AnalysisError = error {
    AnalysisFail
} || ParseError;

fn analyse_body_inner(self: *AsmSemanticAir, body: []const AsmIr.Ir) AnalysisError!void {
    std.log.debug("analyse_body_inner(body.len={})", .{ body.len });
    var cursor: Index = 0;

    while (cursor < body.len) {
        std.log.debug("analyse[{}] ty {s}", .{ cursor, @tagName(body[cursor].ty) });

        switch (body[cursor].ty) {
            .@"if" => {
                const if_body = body[(cursor + 1)..];
                const analysed_len = try self.ir_conditional_block(body[cursor], if_body);
                cursor += analysed_len;
            },
            .@"else" => unreachable, // handled by if
            .region => |region| {
                const region_body = body[(cursor + 1)..];
                try self.ir_region(body[cursor], region_body);
                cursor += region.body_len;
            },
            .err => try self.ir_err(body[cursor]),
            .@"align" => try self.ir_align(body[cursor]),
            .alignop => try self.ir_alignop(body[cursor]),
            .instruction => try self.ir_instruction(body[cursor]),
            .header => try self.ir_header(body[cursor]),
            .reserve => try self.ir_reserve_instruction(body[cursor]),
            .ascii => try self.ir_ascii_instruction(body[cursor]),
            .label => try self.ir_label(body[cursor]),
            .discard_label => try self.ir_discard_label(body[cursor]),
            .base_offset => try self.ir_base_offset(body[cursor])
        }

        cursor += 1;
    }

    for (self.reference_pool.items) |reference|
        try self.add_error(error.UnlinkedReference, reference.token, "reference '{s}' not bound to an opaque", .{ reference.name });
    self.reference_pool.clearRetainingCapacity();
}

const CondReason = union(enum) {
    none,
    assembletime_cond: SourceLocation.Token,
    assembletime_false: SourceLocation.Token
};

fn analyse_body_cond(self: *AsmSemanticAir, body: []const AsmIr.Ir, cond_reason: CondReason) AnalysisError!void {
    const old_cond_reason = self.cond_reason;
    self.cond_reason = cond_reason;
    defer self.cond_reason = old_cond_reason;

    try self.analyse_body_inner(body);
}

fn current_section(self: *AsmSemanticAir) *Section {
    return switch (self.output) {
        .owned => |*section| section,
        .parent => |sema| sema.current_section(),
        .suppressed => unreachable
    };
}

/// Flush is always called on the root Sema, which propagates reference flushes
/// upwards through the `lowering_block` property. References are made fully
/// qualified with their parent namespace before being put into the section's
/// reference block. Returns the amount of flushed references.
fn flush(self: *AsmSemanticAir, section: *Section) !u32 {
    const index: Index = @intCast(section.content.items.len);
    const references_len: u32 = @intCast(self.reference_pool.items.len);
    try section.references.ensureUnusedCapacity(self.allocator, references_len);

    for (self.reference_pool.items) |reference| if (reference.ty == .reference) {
        const qualified_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ self.namespace, reference.name });
        errdefer self.allocator.free(qualified_name);
        const result = section.references.getOrPutAssumeCapacity(qualified_name);

        if (result.found_existing) {
            defer self.allocator.free(qualified_name);
            try self.add_error(error.DuplicateReference, reference.token, "found duplicate reference '{s}' during assemble-time evaluation", .{ reference.name });
            try self.add_error(error.NoteDefinedHere, result.value_ptr.token, "first evaluated here", .{});
            break;
        }

        result.value_ptr.* = .{
            .token = reference.token,
            .index = index };
        result.key_ptr.* = qualified_name;
    };

    self.reference_pool.clearRetainingCapacity();

    // this includes the discard reference types, for Liveness
    const lowering_len = if (self.lowering_block) |block|
        try block.flush(section) else
        0;
    return references_len + lowering_len;
}

fn emit_air(
    self: *AsmSemanticAir,
    op: Air.Operation,
    token: SourceLocation.Token,
    references: enum { flush, no_flush }
) !void {
    switch (self.output) {
        .owned => |*section| {
            @branchHint(.likely);

            const references_len = switch (references) {
                .flush => try self.flush(section),
                .no_flush => 0
            };

            try section.content.append(self.allocator, .{
                .op = op,
                .token = token,
                .is_labeled = references_len > 0 });
        },
        .parent => |sema| {
            self.is_first_air = false;
            try sema.emit_air(op, token, references);
        },
        .suppressed => {}
    }
}

fn ir_conditional_block(self: *AsmSemanticAir, ir: AsmIr.Ir, body: []const AsmIr.Ir) !Index {
    std.debug.assert(ir.ty == .@"if");
    const token = self.source_location.qualified_token(ir.token);
    const expr = ir.ty.@"if".expression;
    const true_len = ir.ty.@"if".body_len;

    _ = expr;
    const condition = true;

    if (condition)
        try self.analyse_body_cond(body[0..true_len], .{ .assembletime_cond = token });
    if (true_len == body.len or body[true_len].ty != .@"else")
        return true_len;
    const false_len = body[true_len].ty.@"else";
    const else_start = true_len + 1; // skip else IR instr
    const full_body_len = else_start + false_len;

    std.debug.assert(body.len >= full_body_len);

    if (!condition)
        try self.analyse_body_cond(body[else_start..full_body_len], .{ .assembletime_false = token });
    return full_body_len;
}

fn ir_region(self: *AsmSemanticAir, ir: AsmIr.Ir, body: []const AsmIr.Ir) !void {
    std.debug.assert(ir.ty == .region);
    const token = self.source_location.qualified_token(ir.token);
    const maximum_size: usize = 0;
    const section = self.current_section();
    const current_size = section.size();

    try self.analyse_body_inner(body);

    const actual_size = section.size() - current_size;

    if (maximum_size >= actual_size) {
        const padding = maximum_size - actual_size;
        try self.emit_air(.{ .padding = padding }, token, .flush);
    } else {
        try self.add_error(error.RegionExceedsSize, token, "region exceeds size of {} bytes, found {} bytes", .{ maximum_size, actual_size });
    }
}

fn ir_err(self: *AsmSemanticAir, ir: AsmIr.Ir) !void {
    std.debug.assert(ir.ty == .err);
    const arguments_len = ir.ty.err.rhs - ir.ty.err.lhs;
    std.debug.assert(arguments_len > 0);

    const format_node = self.tree.nodes[ir.ty.err.lhs];
    const format_token = self.tree.tokens[format_node.token];
    const format = self.source_location.content(format_token);
    var buffer = try std.ArrayList(u8).initCapacity(self.allocator, format.len); // minimum of format.len
    errdefer buffer.deinit();
    const writer = buffer.writer();

    var token = format_token;
    var cursor: Index = 0;
    var argument: Index = 1; // 0 is message

    while (cursor < format.len) : (cursor += 1) switch (format[cursor]) {
        '%' => blk: {
            cursor += 1;
            token.location.start = format_token.location.start + cursor;
            token.location.end = token.location.end + 1;

            const qualified_token = self.source_location.qualified_token(token);
            const argument_node = self.tree.nodes[ir.ty.err.lhs + argument];
            const argument_token = self.tree.tokens[argument_node.token];

            if (cursor >= format.len) {
                try self.add_error(error.InvalidFormat, qualified_token, "invalid format string '%\\0'", .{});
                break :blk;
            }

            if (format[cursor] == '%') {
                try writer.writeAll("%");
                break :blk;
            }

            if (argument >= arguments_len) {
                try self.add_error(error.InvalidFormat, qualified_token, "missing argument", .{});
                break :blk;
            }

            switch (format[cursor]) {
                't' => try writer.writeAll(self.source_location.content(argument_token)),
                'y' => try writer.writeAll(@tagName(argument_token.tag)),
                'a' => try writer.writeAll("err:not-implemented"), // any (node tree)
                'd' => try writer.writeAll("err:not-implemented"), // discrete (decimal)
                'h' => try writer.writeAll("err:not-implemented"), // hexadecimal
                'b' => try writer.writeAll("err:not-implemented"), // binary
                'o' => try writer.writeAll("err:not-implemented"), // local offset of label
                else => try self.add_error(error.InvalidFormat, qualified_token, "invalid format string '%{c}'", .{ format[cursor] })
            }

            argument += 1;
        },
        else => try buffer.append(format[cursor])
    };

    if (argument != arguments_len) {
        return try self.add_error(
            error.InvalidFormat,
            self.source_location.qualified_token(token),
            "expected {} formatting arguments, found {}",
            .{ argument - 1, arguments_len - 1 });
    }

    const message = try buffer.toOwnedSlice();
    errdefer self.allocator.free(message);

    try self.bridge.emit_error(.{
        .err = error.AssembleTimeError,
        .token = ir.token,
        .source_location = self.source_location,
        .is_note = false,
        .is_preview = true,
        .message = message });
    switch (self.cond_reason) {
        .none => {},
        .assembletime_cond => |cond_prong| try self.add_error(error.NoteCalledFromHere, cond_prong, "conditionally evaluated from here", .{}),
        .assembletime_false => |false_prong| try self.add_error(error.NoteCalledFromHere, false_prong, "conditionally evaluated false from here", .{})
    }
}

fn ir_label(self: *AsmSemanticAir, ir: AsmIr.Ir) !void {
    std.debug.assert(ir.ty == .label);
    try self.reference_pool.append(self.allocator, .{
        .name = self.source_location.content(ir.token),
        .token = self.source_location.qualified_token(ir.token),
        .ty = .reference });
}

fn ir_discard_label(self: *AsmSemanticAir, ir: AsmIr.Ir) !void {
    std.debug.assert(ir.ty == .discard_label);
    try self.reference_pool.append(self.allocator, .{
        .name = "",
        .token = self.source_location.qualified_token(ir.token),
        .ty = .discard });
}

fn ir_base_offset(self: *AsmSemanticAir, ir: AsmIr.Ir) !void {
    std.debug.assert(ir.ty == .base_offset);
    const namespace = self.source_location.content(ir.token);
    const section = self.current_section();
    const current_size: Index = @intCast(section.size());
    const address_base = try section.address_base.getOrPut(self.arena.allocator(), namespace);

    if (!address_base.found_existing) {
        address_base.value_ptr.* = .{
            .token = self.source_location.qualified_token(ir.token),
            .index = current_size };
        address_base.key_ptr.* = namespace;
    }

    const offset_token = self.tree.tokens[ir.ty.base_offset];
    const offset_name = self.source_location.content(offset_token);
    const qualified_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}.{s}", .{ self.namespace, namespace, offset_name });
    errdefer self.allocator.free(qualified_name);
    const result = try section.references.getOrPut(self.allocator, qualified_name);

    if (result.found_existing) {
        defer self.allocator.free(qualified_name);
        try self.add_error(
            error.DuplicateReference,
            self.source_location.qualified_token(offset_token),
            "found duplicate base-offset '{s}.{s}' during assemble-time evaluation",
            .{ namespace, offset_name });
        try self.add_error(error.NoteDefinedHere, result.value_ptr.token, "first evaluated here", .{});
        return;
    }

    result.value_ptr.* = .{
        .token = self.source_location.qualified_token(offset_token),
        .index = current_size - address_base.value_ptr.index };
    result.key_ptr.* = qualified_name;
}

fn ir_align(self: *AsmSemanticAir, ir: AsmIr.Ir) !void {
    std.debug.assert(ir.ty == .@"align");
    const padding = try self.alignment_padding(self.tree.nodes[ir.ty.@"align"]);
    const noflush = self.output == .parent and self.is_first_air;
    try self.emit_air(
        .{ .padding = padding },
        self.source_location.qualified_token(ir.token),
        if (noflush) .no_flush else .flush);
}

fn ir_alignop(self: *AsmSemanticAir, ir: AsmIr.Ir) !void {
    std.debug.assert(ir.ty == .alignop);
    const padding = try self.alignment_padding(self.tree.nodes[ir.ty.alignop]);
    try self.emit_air(.{ .nops = padding }, self.source_location.qualified_token(ir.token), .flush);
}

fn alignment_padding(self: *AsmSemanticAir, node: AsmAst.Node) !usize {
    const token = self.source_location.qualified_token(self.tree.tokens[node.token]);
    const alignment_unit = 4;

    if (!std.math.isPowerOfTwo(alignment_unit)) {
        try self.add_error(error.AlignPowerTwo, token, "alignment of {} is not a power of two", .{ alignment_unit });
        return 0;
    }

    const alignment = std.mem.Alignment.fromByteUnits(alignment_unit);
    const section = self.current_section();
    const current_address = section.size();

    section.alignment = alignment.max(section.alignment);
    return alignment.forward(current_address);
}

fn ir_instruction(self: *AsmSemanticAir, ir: AsmIr.Ir) !void {
    std.debug.assert(ir.ty == .instruction);
    const instruction_str = self.source_location.content(ir.token);
    const tag = std.meta.stringToEnum(Instruction.Tag, instruction_str);

    _ = tag;

    try self.emit_air(
        .{ .instr = .nop },
        self.source_location.qualified_token(ir.token),
        .flush);
}

fn ir_header(self: *AsmSemanticAir, ir: AsmIr.Ir) !void {
    std.debug.assert(ir.ty == .header);
    _ = self;
}

fn ir_reserve_instruction(self: *AsmSemanticAir, ir: AsmIr.Ir) !void {
    std.debug.assert(ir.ty == .reserve);
    _ = self;
}

fn ir_ascii_instruction(self: *AsmSemanticAir, ir: AsmIr.Ir) !void {
    std.debug.assert(ir.ty == .ascii);
    const text_node = self.tree.nodes[ir.ty.ascii];
    std.debug.assert(text_node.tag == .string);
    const text_token = self.tree.tokens[text_node.token];
    std.debug.assert(text_token.tag == .string_literal);
    const text = self.source_location.content(text_token);

    const sentinel: ?u8 = if (self.tree.unwrap(text_node.operands.lhs)) |sentinel_node| blk: {
        std.debug.assert(sentinel_node.tag == .integer);
        const sentinel_token = self.tree.tokens[sentinel_node.token];
        const qualified_sentinel_token = self.source_location.qualified_token(sentinel_token);
        const sentinel_str = self.source_location.content(sentinel_token);

        break :blk std.fmt.parseInt(u8, sentinel_str, 0) catch |err| switch (err) {
            error.InvalidCharacter => return try self.add_error(
                error.InvalidNumeric,
                qualified_sentinel_token,
                "invalid numeric literal '{s}'",
                .{ sentinel_str }),
            error.Overflow => return try self.add_error(
                error.InvalidNumeric,
                qualified_sentinel_token,
                "sentinel must fit in an 8 bit unsigned interger",
                .{})
        };
    } else null;

    try self.emit_air(
        .{ .ascii = .{ .text = text, .sentinel = sentinel } },
        self.source_location.qualified_token(ir.token),
        .flush);
}

fn Loc(comptime T: type) type {
    return struct {

        const LocType = @This();

        source_token: SourceLocation.Token,
        lowered_token: SourceLocation.Token,
        expr: T
    };
}

const Numeric = struct {

    label: ?struct {
        qualified_name: []const u8,
        mask: u16
    },
    constant: i32,
    mask: u16
};

pub fn analyse_link_script(self: *AsmSemanticAir) !void {
    std.log.debug("analyse_link_script({s})", .{ self.source_location.file_name });
}

// Tests

const build_options = @import("options");

const TestBridge = struct {

    allocator: std.mem.Allocator,
    errors: std.ArrayListUnmanaged(SourceLocation.Error) = .empty,

    pub fn deinit(self: *TestBridge) void {
        for (self.errors.items) |err|
            self.allocator.free(err.message);
        self.errors.deinit(self.allocator);
    }

    const semaTable = Bridge.VTable {
        .emit_error = emit_error,
        .file_context = file_context,
        .ensure_block_analysed = ensure_block_analysed
    };

    fn emit_error(context: *anyopaque, err: SourceLocation.Error) !void {
        const self: *TestBridge = @alignCast(@ptrCast(context));
        try self.errors.append(self.allocator, err);
    }

    fn file_context(context: *anyopaque, index: AsmIr.Index, namespace: []const u8) AsmSemanticAir {
        _ = context;
        _ = index;
        _ = namespace;
        @panic("bug: not implemented");
    }

    fn ensure_block_analysed(context: *anyopaque, index: AsmIr.Index, block_index: AsmIr.Index) !void {
        _ = context;
        _ = index;
        _ = block_index;
        @panic("bug: not implemented");
    }

    pub fn bridge(self: *TestBridge) Bridge {
        return .{ .vtable = semaTable, .context = self };
    }
};
