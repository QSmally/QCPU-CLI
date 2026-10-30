
// Semantic Analysed Intermediate Representation

const std = @import("std");
const indexable_list = @import("indexable_list.zig");
const instruction = @import("instruction.zig");
const Qcu = @import("Qcu.zig");
const SourceFile = @import("SourceFile.zig");
const Token = @import("Token.zig");
const Error = @import("Error.zig");
const AsmAst = @import("AsmAst.zig");
const AsmIr = @import("AsmIr.zig");
const AsmCompute = @import("AsmCompute.zig");

const AsmSemanticAir = @This();

allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
file_index: Qcu.File.List.Index,
source_file: *const SourceFile,
tree: *const AsmAst,
ir: *const AsmIr,
namespace: []const u8,
bridge: Bridge,

// Section memory is allocated by `allocator` and owned by the constructor of
// this AsmSemanticAir.
output: union(enum) {
    owned: Section,
    parent: *AsmSemanticAir,
    suppressed
} = .suppressed,
/// Reference to the Intermediate Representation block currently being
/// analysed.
block: *const AsmIr.Block = undefined,
/// References to be flushed to the section's symbol mapping when `emitAir` is
/// called with `.flush`. Allocated with `arena`.
reference_pool: std.ArrayList(struct {
    name: []const u8,
    token: SourceFile.Token,
    ty: enum { discard, address }
}) = .empty,
/// Pointing to the stack during the call to lower headers into the current
/// section. Flushes are called from `emitAir` on the owned section, and this
/// property is used to propagate flushes upwards.
lowering_block: ?*AsmSemanticAir = null,
// Allocated with `arena`.
deferred_symbols: std.StringHashMapUnmanaged(struct {
    scope: *const AsmSemanticAir,
    token: Token,
    file_index: Qcu.File.List.Index,
    node_index: AsmAst.Node.List.Index
}) = .empty,

const log = std.log.scoped(.AsmSemanticAir);

// Borrows the Abstract Syntax Tree, Intermediate Representation and the
// lowering namespace, and initialises a Semantic Analysis unit. After
// initialisation, `analyseBlock` must be called exactly once for an owned
// section.
pub fn init(
    allocator: std.mem.Allocator,
    file_index: Qcu.File.List.Index,
    source_file: *const SourceFile,
    tree: *const AsmAst,
    ir: *const AsmIr,
    namespace: []const u8,
    bridge: Bridge
) AsmSemanticAir {
    return .{
        .allocator = allocator,
        .arena = .init(allocator),
        .file_index = file_index,
        .source_file = source_file,
        .tree = tree,
        .ir = ir,
        .namespace = namespace,
        .bridge = bridge };
}

pub fn deinit(self: *const AsmSemanticAir) void {
    self.arena.deinit();
}

pub fn dump(self: *const AsmSemanticAir, _: std.mem.Allocator, writer: *std.Io.Writer) !void {
    std.debug.assert(self.output == .owned);
    const section = self.output.owned;

    try writer.print("@section {s} (align {})\n", .{
        section.name,
        section.alignment.toByteUnits() });

    for (section.content.list.items, 0..) |air, index| switch (air.op) {
        .instruction => |instr| try writer.print("  {} {any}\n", .{ index, instr }),
        .padding => try writer.print("  {} padding({})\n", .{ index, air.bytes() }),
        .data => |data| try writer.print("  {} data({}) = {any}\n", .{ index, air.bytes(), data.value }),
        .ascii => |ascii| try writer.print("  {} data({}) = {s}\n", .{ index, air.bytes(), ascii.text })
    };

    var reference_iterator = section.references.iterator();

    while (reference_iterator.next()) |reference|
        try writer.print("  ^{s} -> {}\n", .{ reference.key_ptr.*, reference.value_ptr.index });
}

pub const Bridge = struct {

    const AllocatorError = std.mem.Allocator.Error;

    vtable: VTable,
    context: *anyopaque,

    pub const VTable = struct {
        emitError: *const fn (*anyopaque, Error) AllocatorError!void,
        createScope: *const fn (*anyopaque, Qcu.File.List.Index, []const u8) AsmSemanticAir,
        ensureBlockAnalysed: *const fn (*anyopaque, Qcu.File.List.Index, AsmIr.Block.List.Index) AllocatorError!void
    };

    fn emitError(self: *const Bridge, err: Error) !void {
        return try self.vtable.emitError(self.context, err);
    }

    fn createScope(self: *const Bridge, file_index: Qcu.File.List.Index, namespace: []const u8) AsmSemanticAir {
        return self.vtable.createScope(self.context, file_index, namespace);
    }

    fn ensureBlockAnalysed(
        self: *const Bridge,
        file_index: Qcu.File.List.Index,
        block_index: AsmIr.Block.List.Index
    ) !void {
        try self.vtable.ensureBlockAnalysed(self.context, file_index, block_index);
    }
};

pub const Section = struct {

    token: SourceFile.Token,
    name: []const u8,

    alignment: std.mem.Alignment = .@"1",
    content: Air.List = .empty,
    references: std.StringHashMapUnmanaged(Reference) = .empty,

    pub const Reference = struct {
        token: SourceFile.Token,
        /// An index into the current section.
        index: Air.List.Index
    };

    pub fn init(token: SourceFile.Token, name: []const u8) Section {
        return .{ .token = token, .name = name };
    }

    // pub fn deinit(self: *Section, allocator: std.mem.Allocator) void {
    //     _ = self;
    //     _ = allocator;
    // }

    pub fn bytes(self: *const Section) usize {
        var total_bytes: usize = 0;
        for (self.content.list.items) |air| total_bytes += air.bytes();
        return total_bytes;
    }
};

pub const Air = struct {

    token: SourceFile.Token,
    op: Operation,
    is_labeled: bool,

    pub const List = indexable_list.IndexableList(Air);

    pub const Operation = union(enum) {
        instruction: instruction.MachineInstr,
        padding: Index,
        data: struct { bytes: Index, value: instruction.LinkerAddress },
        ascii: struct { text: []const u8, sentinel: ?u8 }
    };

    pub fn isJump(self: *const Air) bool {
        return switch (self.op) {
            .instruction => |instr| switch (instr) {
                // these can reference the instruction ptr, but are conditional
                .movec_caa,
                .movez_aaa => false,

                // we know these can't jump unconditionally
                .brh_ci,
                .brhl_ci => false,

                // these implicitly reference the instruction ptr
                .jmpl_i,
                .jmprl_i => true,

                // it's a jump if the `rd` operand is the instruction ptr
                inline else => |operands| blk: {
                    const Ty = @TypeOf(operands);

                    if (Ty == void) {
                        break :blk false;
                    }

                    if (@hasField(Ty, "rd") and @TypeOf(operands.rd) == instruction.Register.AddressRegister) {
                        break :blk operands.rd == .ip;
                    }

                    break :blk false;
                }
            },
            .padding,
            .data,
            .ascii => false
        };
    }

    pub fn bytes(self: *const Air) usize {
        return switch (self.op) {
            .instruction => 2,
            .padding => |padding| padding,
            .data => |data| data.bytes,
            .ascii => |ascii| blk: {
                const sentinel_len: usize = if (ascii.sentinel != null) 1 else 0;
                break :blk ascii.text.len + sentinel_len;
            }
        };
    }
};

const Index = indexable_list.UnderlyingType;

pub const SemanticError = error {
    DuplicateReference,
    VoidedReference,
    AlignNegative,
    AlignPowerTwo,
    InvalidFormat,
    AssembleTimeError,
    RegionNegative,
    RegionExceedsSize,
    SingleHeaderNamespace,
    HeaderArguments,
    InstrSelection,
    NoteCalledFromHere,
    NoteDefinedHere,
    Note
};

fn addError(
    self: *AsmSemanticAir,
    comptime err: SemanticError,
    token: SourceFile.Token,
    comptime format: []const u8,
    arguments: anytype
) !void {
    @branchHint(.cold);

    const message = try self.allocator.print(format, arguments);
    errdefer self.allocator.free(message);

    try self.bridge.emitError(.{
        .err = err,
        .token = token.inner_token,
        .source_file = token.source_file,
        .is_note = switch (err) {
            error.NoteCalledFromHere,
            error.NoteDefinedHere,
            error.Note => true,
            else => false
        },
        .is_preview = err != error.Note,
        .message = message });
}

const ParseError = std.mem.Allocator.Error || std.Io.Writer.Error;

// Illegal behaviour to call `analyseBlock` twice in the same Semantic Analysis
// unit, and undefined behaviour to analyse the same block twice.
pub fn analyseBlock(self: *AsmSemanticAir, block_index: AsmIr.Block.List.Index) ParseError!void {
    const block = self.ir.blocks.get(block_index);
    log.debug("analyseBlock {s} {s}({})", .{ self.source_file.fileName(), block.name, block_index.raw() });
    std.debug.assert(block.ty == .section);
    std.debug.assert(self.output == .suppressed); // check illegal behaviour

    const block_token = self.source_file.qualifiedToken(block.token);
    const new_section = Section.init(block_token, block.name);

    self.output = .{ .owned = new_section };
    self.block = block;

    self.analyseBodyInner(block.content.list.items) catch |err| switch (err) {
        error.Break => {},
        else => |the_err| return the_err
    };
}

fn analyseBlockInto(
    self: *AsmSemanticAir,
    block_index: AsmIr.Block.List.Index,
    owner: *AsmSemanticAir
) AnalysisError!void {
    const block = self.ir.blocks.get(block_index);
    log.debug("analyseBlockInto {s} {s}({})", .{ self.source_file.fileName(), block.name, block_index.raw() });
    std.debug.assert(block.ty == .header);
    std.debug.assert(self.output == .suppressed); // check illegal behaviour

    self.output = .{ .parent = owner };
    self.block = block;

    try self.analyseBodyInner(block.content.list.items);
}

const CondReason = union(enum) {
    none,
    truth: SourceFile.Token,
    falsth: SourceFile.Token
};

fn analyseConditionalBody(
    self: *AsmSemanticAir,
    body: []const AsmIr.Ir,
    cond_reason: CondReason
) AnalysisError!void {
    self.analyseBodyInner(body) catch |err| switch (err) {
        error.Break => {
            switch (cond_reason) {
                .none => {},
                .truth => |prong| try self.addError(error.NoteCalledFromHere, prong, "conditionally evaluated from here", .{}),
                .falsth => |prong| try self.addError(error.NoteCalledFromHere, prong, "conditionally evaluated @else prong from here", .{})
            }

            return error.Break;
        },
        else => |the_err| return the_err
    };
}

const AnalysisError = error {
    Break
} || ParseError;

fn analyseBodyInner(self: *AsmSemanticAir, body: []const AsmIr.Ir) AnalysisError!void {
    log.debug("analyseBodyInner(body.len={})", .{ body.len });
    var cursor: usize = 0;

    while (cursor < body.len) {
        const ir = body[cursor];
        log.debug("analyse[{}] ty {any}", .{ cursor, ir.ty });

        switch (ir.ty) {
            .@"align" => try self.irAlign(ir),
            .err => try self.irErr(ir),
            .region => {
                const body_cursor = cursor + 1;
                const scope = body[body_cursor..(body_cursor + ir.ty.region.opaque_len)];
                try self.createRegionalScope(ir, scope);
                cursor += ir.ty.region.opaque_len;
            },
            .@"if" => {
                const scope = body[(cursor + 1)..];
                const analysed_len = try self.createConditionalScope(ir, scope);
                cursor += analysed_len;
            },
            .@"else" => unreachable,
            .header => try self.irHeader(ir),
            .instruction => try self.irInstruction(ir),
            .reserve => try self.irReserve(ir),
            .ascii => try self.irAscii(ir),
            .label => try self.irLabel(ir),
            .discard_label => try self.irDiscardLabel(ir)
        }

        cursor += 1;
    }

    for (self.reference_pool.items) |reference| blk: {
        if (reference.ty == .discard) {
            try self.addError(error.VoidedReference, reference.token, "pointless discard label", .{});
            break :blk;
        }

        try self.addError(error.VoidedReference, reference.token, "reference '{s}' points to nothing", .{ reference.name });

        const section = self.getCurrentSection();

        const last_air_index = if (section.content.len() > 0)
            section.content.len() - 1 else
            break :blk;
        const air = section.content.get(.at(last_air_index));

        switch (air.op) {
            .padding, .data, .ascii => {
                try self.addError(error.Note, reference.token, "use 'reserve u8, 0' to silence this error", .{});
            },
            .instruction => {}
        }
    }

    self.reference_pool.clearRetainingCapacity();
}

fn flush(self: *AsmSemanticAir, section: *Section) !usize {
    const instruction_index: Air.List.Index = .at(section.content.len());
    const references_len = self.reference_pool.items.len;

    try section.references.ensureUnusedCapacity(self.allocator, @intCast(references_len));

    for (self.reference_pool.items) |reference| {
        if (reference.ty != .address)
            continue;

        self.addReference(
            section,
            reference.name,
            reference.token,
            instruction_index,
            .unique
        ) catch |err| switch (err) {
            error.Break => {},
            else => |the_err| return the_err
        };

        var namespaces = std.mem.splitBackwardsScalar(u8, reference.name, '.');
        var len_accumulator = namespaces.first().len;

        while (len_accumulator < reference.name.len) {
            const namespace = reference.name[0..len_accumulator];

            self.addReference(
                section,
                namespace,
                reference.token,
                instruction_index,
                .not_unique
            ) catch |err| switch (err) {
                error.Break => {},
                else => |the_err| return the_err
            };

            const cut_namespace = namespaces.next() orelse break;
            len_accumulator += cut_namespace.len + 1;
        }
    }

    self.reference_pool.clearRetainingCapacity();

    const lowering_len = if (self.lowering_block) |block|
        try block.flush(section) else
        0;
    return references_len + lowering_len;
}

fn addReference(
    self: *AsmSemanticAir,
    section: *Section,
    name: []const u8,
    token: SourceFile.Token,
    instruction_index: Air.List.Index,
    mode: enum { unique, not_unique }
) !void {
    const is_local = switch (self.block.ty) {
        .section => token.inner_token.tag == .local_label,
        .header => self.block.ty == .header and token.inner_token.tag != .label
    };

    const locality: Locality = if (is_local)
        .local else
        .global;
    const qualified_name = try self.resolveQualifiedNamespaceOwned(locality, self.namespace, name);
    errdefer self.allocator.free(qualified_name);

    if (section.references.get(qualified_name)) |result| {
        if (mode == .unique) {
            try self.addError(error.DuplicateReference, token, "found duplicate label '{s}'", .{ name });

            if (std.mem.eql(u8, result.token.slice(), name)) {
                try self.addError(error.NoteDefinedHere, result.token, "first evaluated here", .{});
            } else {
                try self.addError(error.NoteDefinedHere, result.token, "namespace '{s}' first registered here", .{ name });
            }
        }
        return error.Break;
    }

    try section.references.put(
        self.allocator,
        qualified_name,
        .{ .token = token, .index = instruction_index });
}

fn emitAir(
    self: *AsmSemanticAir,
    token: SourceFile.Token,
    op: Air.Operation,
    mode: enum { flush, no_flush }
) !void {
    switch (self.output) {
        .owned => |*section| {
            @branchHint(.likely);

            const references_len = switch (mode) {
                .flush => try self.flush(section),
                .no_flush => 0
            };

            try section.content.append(self.allocator, .{
                .token = token,
                .op = op,
                .is_labeled = references_len > 0 });
        },
        .parent => |sema| try sema.emitAir(token, op, mode),
        .suppressed => unreachable
    }
}

fn getCurrentSection(self: *AsmSemanticAir) *Section {
    return switch (self.output) {
        .owned => |*section| section,
        .parent => |sema| sema.getCurrentSection(),
        .suppressed => unreachable
    };
}

fn getCompute(self: *AsmSemanticAir) AsmCompute {
    const bridge = AsmCompute.Bridge {
        .vtable = computeTable,
        .context = self };
    return AsmCompute.init(
        self.allocator,
        self.file_index,
        self.source_file,
        self.tree,
        self.ir,
        self,
        bridge);
}

const computeTable = AsmCompute.Bridge.VTable {
    .emitError = computeEmitError,
    .createScope = computeCreateScope
};

fn computeEmitError(context: *anyopaque, err: Error) !void {
    const self: *AsmSemanticAir = @alignCast(@ptrCast(context));
    try self.bridge.emitError(err);
}

fn computeCreateScope(
    context: *anyopaque,
    file_index: Qcu.File.List.Index,
    scope: ?*const AsmSemanticAir
) AsmCompute {
    const self: *AsmSemanticAir = @alignCast(@ptrCast(context));
    const dummy_scope = self.bridge.createScope(file_index, "");
    const bridge = AsmCompute.Bridge {
        .vtable = computeTable,
        .context = self };
    return AsmCompute.init(
        self.allocator,
        file_index,
        dummy_scope.source_file,
        dummy_scope.tree,
        dummy_scope.ir,
        scope,
        bridge);
}

fn explainTokenOrigin(
    self: *AsmSemanticAir,
    source_token: SourceFile.Token,
    folded_token: SourceFile.Token,
    message: []const u8
) !void {
    if (!source_token.eql(folded_token)) {
        try self.addError(error.NoteDefinedHere, folded_token, "{s} defined here", .{ message });
    }
}

const Crc32 = std.hash.crc.@"CRC-32/ISO-HDLC";

fn createReferenceNamespaceOwned(
    self: *AsmSemanticAir,
    unique_node_index: AsmAst.Node.List.Index,
    unique_file_index: Qcu.File.List.Index,
    unique_block_index: AsmIr.Block.List.Index
) ![]const u8 {
    if (self.reference_pool.items.len > 0) {
        return try self.allocator.print("{s}.{s}", .{
            self.namespace,
            self.reference_pool.items[0].token.slice() });
    }

    var unique_value = Crc32.init();
    unique_value.update(self.namespace);                       // location called from
    unique_value.update(&std.mem.toBytes(unique_node_index));  // location called from
    unique_value.update(&std.mem.toBytes(unique_block_index)); // location of header
    unique_value.update(&std.mem.toBytes(unique_file_index));  // location of header

    const hash = std.mem.toBytes(unique_value.final());
    return try self.allocator.print("{s}:anon_{x}", .{ self.namespace, hash });
}

pub const Locality = enum { global, local };

fn resolveQualifiedNamespaceOwned(
    self: *AsmSemanticAir,
    locality: Locality,
    namespace: []const u8,
    label: []const u8
) ![]const u8 {
    const local_namespace = if (locality == .local)
        ":local" else
        "";
    return try self.allocator.print("{s}{s}.{s}", .{ namespace, local_namespace, label });
}

fn resolveSymbolsInto(
    self: *AsmSemanticAir,
    child: *AsmSemanticAir,
    block_index: AsmIr.Block.List.Index,
    token: SourceFile.Token,
    arguments: AsmAst.Node.Operands
) !void {
    const block = child.ir.blocks.get(block_index);
    std.debug.assert(block.ty == .header);

    const first_argument_index: AsmAst.Node.List.Index = .at(arguments.lhs);
    const arguments_len = arguments.rhs - arguments.lhs;
    const parameters_len = block.ty.header.rhs - block.ty.header.lhs;

    if (arguments_len != parameters_len) {
        try self.addError(error.HeaderArguments, token, "expected {} header arguments, found {}", .{
            parameters_len,
            arguments_len });
        const qualified_token = child.source_file.qualifiedToken(block.token);
        try child.addError(error.NoteDefinedHere, qualified_token, "@header defined here", .{});
        return error.Break;
    }

    for (block.ty.header.lhs..block.ty.header.rhs, 0..) |node_index, argument_index| {
        const parameter_node = child.tree.nodes.get(.fromIndex(node_index));
        const parameter_token = child.tree.tokens.get(parameter_node.token);
        const parameter_name = parameter_token.slice(child.source_file.buffer);

        const argument_node_index = first_argument_index.addIndex(argument_index);

        try child.deferred_symbols.put(child.arena.allocator(), parameter_name, .{
            .scope = self,
            .token = parameter_token,
            .file_index = self.file_index,
            .node_index = argument_node_index });
    }
}

fn irAlign(self: *AsmSemanticAir, ir: AsmIr.Ir) !void {
    std.debug.assert(ir.ty == .@"align");

    const compute = self.getCompute();
    const alignment_node_index = ir.ty.@"align";
    const alignment_node = self.tree.nodes.get(alignment_node_index);
    const alignment_token = self.tree.tokens.get(alignment_node.token);
    const alignment_qualified_token = self.source_file.qualifiedToken(alignment_token);
    const result = try compute.evaluateConstantResult(.scalar, alignment_node_index);

    if (result.value < 1) {
        try self.addError(error.AlignNegative, alignment_qualified_token, "alignment of {} is illegal", .{ result.value });
        try self.explainTokenOrigin(alignment_qualified_token, result.folded_token, "alignment");
        return error.Break;
    }

    if (!std.math.isPowerOfTwo(result.value)) {
        try self.addError(error.AlignPowerTwo, alignment_qualified_token, "alignment of {} is not a power of two", .{ result.value });
        try self.explainTokenOrigin(alignment_qualified_token, result.folded_token, "alignment");
        return error.Break;
    }

    const section = self.getCurrentSection();
    const current_address = section.bytes();
    const alignment: std.mem.Alignment = .fromByteUnits(@intCast(result.value));
    const padding: Index = @intCast(alignment.forward(current_address) - current_address);

    section.alignment = alignment.max(section.alignment);

    try self.emitAir(
        self.source_file.qualifiedToken(ir.token),
        .{ .padding = padding },
        .no_flush);
}

fn irErr(self: *AsmSemanticAir, ir: AsmIr.Ir) !void {
    std.debug.assert(ir.ty == .err);

    const arguments_len = ir.ty.err.rhs - ir.ty.err.lhs;
    std.debug.assert(arguments_len > 0);

    const compute = self.getCompute();
    const format_node_index: AsmAst.Node.List.Index = .at(ir.ty.err.lhs);
    const format = try compute.evaluateConstantResult(.string, format_node_index);

    var buffer: std.Io.Writer.Allocating = try .initCapacity(self.allocator, format.text.len);
    errdefer buffer.deinit();

    var qualified_token = format.folded_token;
    var cursor: AsmAst.UntypedIndex = 0;
    var argument_index: AsmAst.UntypedIndex = 1;

    while (cursor < format.text.len) : (cursor += 1) switch (format.text[cursor]) {
        '%' => blk: {
            cursor += 1;
            qualified_token.inner_token.location.start = format.folded_token.inner_token.location.start + cursor;
            qualified_token.inner_token.location.end = format.folded_token.inner_token.location.start + 1;

            const argument_node_index: AsmAst.Node.List.Index = .at(ir.ty.err.lhs + argument_index);

            if (cursor >= format.text.len) {
                try self.addError(error.InvalidFormat, format.folded_token, "invalid format string '%\\0'", .{});
                break :blk;
            }

            if (format.text[cursor] == '%') {
                try buffer.writer.writeByte('%');
                break :blk;
            }

            if (argument_index >= arguments_len) {
                try self.addError(error.InvalidFormat, format.folded_token, "missing argument", .{});
                break :blk;
            }

            switch (format.text[cursor]) {
                'd' => {
                    const result = try compute.evaluateConstantResult(.scalar, argument_node_index);
                    try buffer.writer.print("{}", .{ result.value });
                },
                'b' => {
                    const result = try compute.evaluateConstantResult(.scalar, argument_node_index);
                    try buffer.writer.print("0b{b}", .{ result.value });
                },
                'h' => {
                    const result = try compute.evaluateConstantResult(.scalar, argument_node_index);
                    try buffer.writer.print("0x{x}", .{ result.value });
                },
                's' => {
                    const result = try compute.evaluateConstantResult(.string, argument_node_index);
                    try buffer.writer.print("{s}", .{ result.text });
                },
                'a' => {
                    const result = try compute.evaluateResult(argument_node_index);
                    try buffer.writer.print("{any}", .{ result });
                },
                else => try self.addError(error.InvalidFormat, format.folded_token, "invalid format string '%{c}'", .{ format.text[cursor] })
            }

            argument_index += 1;
        },
        else => try buffer.writer.writeByte(format.text[cursor])
    };

    if (argument_index != arguments_len) {
        try self.addError(error.InvalidFormat, format.folded_token, "expected {} formatting arguments, found {}", .{
            argument_index - 1,
            arguments_len - 1 });
    }

    {
        const message = try buffer.toOwnedSlice();
        errdefer self.allocator.free(message);

        try self.bridge.emitError(.{
            .err = error.AssembleTimeError,
            .token = ir.token,
            .source_file = self.source_file,
            .is_note = false,
            .is_preview = true,
            .message = message });
    }

    return error.Break;
}

fn irHeader(self: *AsmSemanticAir, ir: AsmIr.Ir) !void {
    std.debug.assert(ir.ty == .header);

    const qualified_token = self.source_file.qualifiedToken(ir.token);

    if (self.reference_pool.items.len > 1) {
        try self.addError(error.SingleHeaderNamespace, qualified_token, "header can only have a single namespace, found {}", .{ self.reference_pool.items.len });
        try self.addError(error.NoteDefinedHere, self.reference_pool.items[0].token, "{s} defined here", .{ self.reference_pool.items[0].token.inner_token.tag.fmt() });

        for (self.reference_pool.items[1..]) |reference| {
            try self.addError(error.NoteDefinedHere, reference.token, "and {s} defined here", .{ reference.token.inner_token.tag.fmt() });
        }

        return error.Break;
    }

    const compute = self.getCompute();
    const header = try compute.evaluateConstantResult(.header, ir.ty.header.node_index);

    const namespace = try self.createReferenceNamespaceOwned(
        ir.ty.header.node_index,
        header.file_index,
        header.block_index);
    defer self.allocator.free(namespace);

    var scope = self.bridge.createScope(header.file_index, namespace);
    defer scope.deinit();

    self.lowering_block = &scope;
    defer self.lowering_block = null;

    try self.resolveSymbolsInto(&scope, header.block_index, qualified_token, ir.ty.header.arguments);

    scope.analyseBlockInto(header.block_index, self) catch |err| switch (err) {
        error.Break => try self.addError(error.NoteCalledFromHere, qualified_token, "{s} unrolled from here", .{ header.folded_token.slice() }),
        else => |the_err| return the_err
    };
}

fn irInstruction(self: *AsmSemanticAir, ir: AsmIr.Ir) !void {
    std.debug.assert(ir.ty == .instruction);

    const instr_token = self.source_file.qualifiedToken(ir.token);
    const air_op = self.instrSelection(instr_token, ir.ty.instruction) catch |err| switch (err) {
        error.Break => return,
        else => |the_err| return the_err
    };
    try self.emitAir(instr_token, air_op, .flush);

    switch (air_op) {
        .instruction => |instr| try self.lazilyAnalyseReference(instr),
        else => {}
    }
}

fn irReserve(self: *AsmSemanticAir, ir: AsmIr.Ir) !void {
    std.debug.assert(ir.ty == .reserve);

    const compute = self.getCompute();
    const type_size = try compute.evaluateConstantResult(.size, ir.ty.reserve.type_expression);

    const len_expression_node = self.tree.nodes.get(ir.ty.reserve.len_expression);
    const len_expression_token = self.tree.tokens.get(len_expression_node.token);
    const len_expression_qualified_token = self.source_file.qualifiedToken(len_expression_token);
    const len = try compute.evaluateConstantResult(.scalar, ir.ty.reserve.len_expression);

    if (len.value < 0) {
        try self.addError(error.RegionNegative, len_expression_qualified_token, "reserve size of {} is illegal", .{ len.value });
        try self.explainTokenOrigin(len_expression_qualified_token, len.folded_token, "reserve size");
        return error.Break;
    }

    const positive_len: Index = @intCast(len.value);
    const padding = type_size.bytes * positive_len;

    try self.emitAir(
        self.source_file.qualifiedToken(ir.token),
        .{ .padding = padding },
        .flush);
}

fn irAscii(self: *AsmSemanticAir, ir: AsmIr.Ir) !void {
    std.debug.assert(ir.ty == .ascii);

    const compute = self.getCompute();
    const ascii = try compute.evaluateConstantResult(.string, ir.ty.ascii);

    try self.emitAir(
        self.source_file.qualifiedToken(ir.token),
        .{ .ascii = .{ .text = ascii.text, .sentinel = ascii.sentinel } },
        .flush);
}

fn irLabel(self: *AsmSemanticAir, ir: AsmIr.Ir) !void {
    std.debug.assert(ir.ty == .label);
    try self.reference_pool.append(self.arena.allocator(), .{
        .token = self.source_file.qualifiedToken(ir.token),
        .name = self.source_file.slice(ir.token),
        .ty = .address });
}

fn irDiscardLabel(self: *AsmSemanticAir, ir: AsmIr.Ir) !void {
    std.debug.assert(ir.ty == .discard_label);
    try self.reference_pool.append(self.arena.allocator(), .{
        .token = self.source_file.qualifiedToken(ir.token),
        .name = self.source_file.slice(ir.token),
        .ty = .discard });
}

fn createRegionalScope(self: *AsmSemanticAir, ir: AsmIr.Ir, body: []const AsmIr.Ir) !void {
    std.debug.assert(ir.ty == .region);

    const compute = self.getCompute();
    const expression_node = self.tree.nodes.get(ir.ty.region.expression);
    const expression_token = self.tree.tokens.get(expression_node.token);
    const expression_qualified_token = self.source_file.qualifiedToken(expression_token);
    const region_size = try compute.evaluateConstantResult(.scalar, ir.ty.region.expression);

    if (region_size.value < 1) {
        try self.addError(error.RegionNegative, expression_qualified_token, "region size of {} is illegal", .{ region_size.value });
        try self.explainTokenOrigin(expression_qualified_token, region_size.folded_token, "region size");
        return error.Break;
    }

    const section = self.getCurrentSection();
    const current_size = section.bytes();

    try self.analyseBodyInner(body);

    const actual_size: Index = @intCast(section.bytes() - current_size);

    if (actual_size <= region_size.value) {
        const padding = @as(Index, @intCast(region_size.value)) - actual_size;
        try self.emitAir(self.source_file.qualifiedToken(ir.token), .{ .padding = padding }, .flush);
    } else {
        try self.addError(error.RegionExceedsSize, expression_qualified_token, "region exceeds size of {} bytes, emitted {} bytes", .{
            region_size.value,
            actual_size });
        try self.explainTokenOrigin(expression_qualified_token, region_size.folded_token, "region size");
    }
}

fn createConditionalScope(self: *AsmSemanticAir, ir: AsmIr.Ir, body: []const AsmIr.Ir) !usize {
    std.debug.assert(ir.ty == .@"if");
    std.debug.assert(body.len >= ir.ty.@"if".opaque_len);

    const compute = self.getCompute();
    const expression_node = self.tree.nodes.get(ir.ty.@"if".expression);
    const expression_token = self.tree.tokens.get(expression_node.token);
    const expression_qualified_token = self.source_file.qualifiedToken(expression_token);
    const result = try compute.evaluateConstantResult(.scalar, ir.ty.@"if".expression);

    const truth = result.value != 0;

    if (truth) {
        const cond_reason = CondReason { .truth = expression_qualified_token };
        try self.analyseConditionalBody(body[0..ir.ty.@"if".opaque_len], cond_reason);
    }

    if (ir.ty.@"if".opaque_len == body.len or body[ir.ty.@"if".opaque_len].ty != .@"else") {
        return ir.ty.@"if".opaque_len;
    }

    const else_prong = body[ir.ty.@"if".opaque_len];
    const else_prong_start = ir.ty.@"if".opaque_len + 1;
    const else_prong_end = else_prong_start + else_prong.ty.@"else".opaque_len;

    std.debug.assert(body.len >= else_prong_end);

    if (!truth) {
        const else_prong_qualified_token = self.source_file.qualifiedToken(else_prong.token);
        const cond_reason = CondReason { .falsth = else_prong_qualified_token };
        try self.analyseConditionalBody(body[else_prong_start..else_prong_end], cond_reason);
    }

    return else_prong_end;
}

const InstrSelection = struct {

    compute: AsmCompute,
    token: SourceFile.Token,
    operands: AsmAst.Node.Operands,

    pub fn init(
        compute: AsmCompute,
        token: SourceFile.Token,
        operands: AsmAst.Node.Operands
    ) InstrSelection {
        return .{
            .compute = compute,
            .token = token,
            .operands = operands };
    }

    pub fn matches(self: *const InstrSelection, comptime T: type) !switch (T) {
        void => bool,
        i8, i16, i24, i32,
        u8, u16, u24, u32 => ?instruction.LinkerAddress,
        else => ?T
    } {
        if (T == void) {
            return self.operands.lhs == self.operands.rhs;
        }

        const operands_len = self.operands.rhs - self.operands.lhs;

        if (@typeInfo(T) == .@"int") {
            return if (operands_len == 1)
                try self.operandCast(T, .linker_address, .at(self.operands.lhs)) else
                null;
        }

        const type_info = @typeInfo(T).@"struct";

        if (type_info.field_types.len != operands_len) {
            return null;
        }

        var body: T = undefined;

        inline for (type_info.field_names, type_info.field_types, 0..) |name, ty, index| {
            const ResultType = comptime AsmCompute.mapTy(ty);
            const operand_index: AsmAst.Node.List.Index = .fromIndex(self.operands.lhs + index);
            const casted_result = try self.operandCast(ty, ResultType, operand_index);
            @field(body, name) = casted_result orelse return null;
        }

        return body;
    }

    fn operandCast(
        self: *const InstrSelection,
        comptime T: type,
        comptime ResultType: AsmCompute.Result.Type,
        operand_index: AsmAst.Node.List.Index
    ) !switch (T) {
        i8, i16, i24, i32,
        u8, u16, u24, u32 => ?instruction.LinkerAddress,
        else => ?T
    } {
        // TODO: don't evaluate this on every `matches` call
        const result = try self.compute.evaluateResult(operand_index);

        if (!AsmCompute.isTypeCastSafe(ResultType, result))
            return null;

        const casted_result = self.compute.typeCast(ResultType, result, self.token.inner_token) catch |err| switch (err) {
            error.Break => unreachable,
            else => |the_err| return the_err
        };

        return switch (T) {
            instruction.Register.DataRegister => if (casted_result.register.isDataRegister())
                .fromGeneral(casted_result.register) else
                null,
            instruction.Register.AddressRegister => if (casted_result.register.isAddressRegister())
                .fromGeneral(casted_result.register) else
                null,
            instruction.LinkerAddress => casted_result.linker_address,
            instruction.Flag => casted_result.flag,
            instruction.LinkerIndex => switch (casted_result.mode) {
                .linker_address => |linker_address| .{
                    .address = linker_address,
                    .register = casted_result.register },
                else => null
            },
            i8, i16, i24, i32,
            u8, u16, u24, u32 => casted_result.linker_address,
            else => @compileError("ty not supported: " ++ @typeName(T))
        };
    }
};

fn instrSelection(
    self: *AsmSemanticAir,
    instr_token: SourceFile.Token,
    operands: AsmAst.Node.Operands
) !Air.Operation {
    const compute = self.getCompute();
    const selection = InstrSelection.init(compute, instr_token, operands);

    const instr_tag = std.meta.stringToEnum(instruction.MachineInstr.Tag, instr_token.slice()).?;

    switch (instr_tag) {
        .add => {
            if (try selection.matches(instruction.MachineInstr.DDD)) |op| {
                if (op.rd == .zr and op.rs1 == .zr and op.rs2 == .zr)
                    return .{ .instruction = .bkpt };
                return .{ .instruction = .{ .add_ddd = op } };
            }
            if (try selection.matches(instruction.MachineInstr.AAA)) |op|
                return .{ .instruction = .{ .add_aaa = op } };
            if (try selection.matches(instruction.MachineInstr.DAD)) |op|
                return .{ .instruction = .{ .add_dad = op } };
            if (try selection.matches(instruction.MachineInstr.AAD)) |op|
                return .{ .instruction = .{ .add_aad = op } };
        },
        .addi => {
            if (try selection.matches(instruction.MachineInstr.DI)) |op|
                return .{ .instruction = .{ .addi_di = op } };
            if (try selection.matches(instruction.MachineInstr.AI)) |op|
                return .{ .instruction = .{ .addi_ai = op } };
        },
        .cmpi => {
            if (try selection.matches(instruction.MachineInstr.DI)) |op|
                return .{ .instruction = .{ .cmpi_di = op } };
        },
        .movec => {
            if (try selection.matches(instruction.MachineInstr.CDD)) |op|
                return .{ .instruction = .{ .movec_cdd = op } };
            if (try selection.matches(instruction.MachineInstr.CAA)) |op|
                return .{ .instruction = .{ .movec_caa = op } };
        },
        .movez => {
            if (try selection.matches(instruction.MachineInstr.DDD)) |op|
                return .{ .instruction = .{ .movez_ddd = op } };
            if (try selection.matches(instruction.MachineInstr.AAA)) |op|
                return .{ .instruction = .{ .movez_aaa = op } };
        },
        .sub => {
            if (try selection.matches(instruction.MachineInstr.DDD)) |op|
                return .{ .instruction = .{ .sub_ddd = op } };
            if (try selection.matches(instruction.MachineInstr.AAA)) |op|
                return .{ .instruction = .{ .sub_aaa = op } };
        },
        .slt => {
            if (try selection.matches(instruction.MachineInstr.DDD)) |op|
                return .{ .instruction = .{ .slt_ddd = op } };
        },
        .sltu => {
            if (try selection.matches(instruction.MachineInstr.DDD)) |op|
                return .{ .instruction = .{ .sltu_ddd = op } };
        },
        .ior => {
            if (try selection.matches(instruction.MachineInstr.DDD)) |op|
                return .{ .instruction = .{ .ior_ddd = op } };
        },
        .@"and" => {
            if (try selection.matches(instruction.MachineInstr.DDD)) |op|
                return .{ .instruction = .{ .and_ddd = op } };
        },
        .xor => {
            if (try selection.matches(instruction.MachineInstr.DDD)) |op|
                return .{ .instruction = .{ .xor_ddd = op } };
        },
        .iori => {
            if (try selection.matches(instruction.MachineInstr.DI)) |op|
                return .{ .instruction = .{ .iori_di = op } };
        },
        .ioriu => {
            if (try selection.matches(instruction.MachineInstr.DI)) |op|
                return .{ .instruction = .{ .ioriu_di = op } };
        },
        .andi => {
            if (try selection.matches(instruction.MachineInstr.DI)) |op|
                return .{ .instruction = .{ .andi_di = op } };
        },
        .andiu => {
            if (try selection.matches(instruction.MachineInstr.DI)) |op|
                return .{ .instruction = .{ .andiu_di = op } };
        },
        .mask => {
            if (try selection.matches(instruction.MachineInstr.DI)) |op|
                return .{ .instruction = .{ .mask_di = op } };
        },
        .xori => {
            if (try selection.matches(instruction.MachineInstr.DI)) |op|
                return .{ .instruction = .{ .xori_di = op } };
        },
        .xoriu => {
            if (try selection.matches(instruction.MachineInstr.DI)) |op|
                return .{ .instruction = .{ .xoriu_di = op } };
        },
        .bsl => {
            if (try selection.matches(instruction.MachineInstr.DDI)) |op|
                return .{ .instruction = .{ .bsl_ddi = op } };
        },
        .bsr => {
            if (try selection.matches(instruction.MachineInstr.DDI)) |op|
                return .{ .instruction = .{ .bsr_ddi = op } };
        },
        .bsrs => {
            if (try selection.matches(instruction.MachineInstr.DDI)) |op|
                return .{ .instruction = .{ .bsrs_ddi = op } };
        },
        .brr => {
            if (try selection.matches(instruction.MachineInstr.DDI)) |op|
                return .{ .instruction = .{ .brr_ddi = op } };
        },
        .lli => {
            if (try selection.matches(instruction.MachineInstr.DI)) |op|
                return .{ .instruction = .{ .lli_di = op } };
        },
        .lui => {
            if (try selection.matches(instruction.MachineInstr.DI)) |op|
                return .{ .instruction = .{ .lui_di = op } };
        },
        .lua => {
            if (try selection.matches(instruction.MachineInstr.AI)) |op|
                return .{ .instruction = .{ .lua_ai = op } };
        },
        .jmpl => {
            if (try selection.matches(instruction.MachineInstr.I)) |op|
                return .{ .instruction = .{ .jmpl_i = op } };
        },
        .jmprl => {
            if (try selection.matches(instruction.MachineInstr.I)) |op|
                return .{ .instruction = .{ .jmprl_i = op } };
        },
        .brh => {
            if (try selection.matches(instruction.MachineInstr.CI)) |op|
                return .{ .instruction = .{ .brh_ci = op } };
        },
        .brhl => {
            if (try selection.matches(instruction.MachineInstr.CI)) |op|
                return .{ .instruction = .{ .brhl_ci = op } };
        },
        .xch => {
            if (try selection.matches(instruction.MachineInstr.DX)) |op|
                return .{ .instruction = .{ .xch_dx = op } };
        },
        .xchw => {
            if (try selection.matches(instruction.MachineInstr.DX)) |op|
                return .{ .instruction = .{ .xchw_dx = op } };
        },
        .move => {
            if (try selection.matches(instruction.MachineInstr.DX)) |op|
                return .{ .instruction = .{ .move_dx = op } };
            if (try selection.matches(instruction.MachineInstr.XD)) |op|
                return .{ .instruction = .{ .move_xd = op } };
            if (try selection.matches(instruction.MachineInstr.DM)) |op|
                return .{ .instruction = .{ .move_dm = op } };
            if (try selection.matches(instruction.MachineInstr.DP)) |op|
                return .{ .instruction = .{ .move_dp = op } };
            if (try selection.matches(instruction.MachineInstr.MD)) |op|
                return .{ .instruction = .{ .move_md = op } };
            if (try selection.matches(instruction.MachineInstr.PD)) |op|
                return .{ .instruction = .{ .move_pd = op } };

            if (try selection.matches(instruction.MachineInstr.DD)) |op|
                return .{ .instruction = .{ .add_ddd = .{ .rd = op.rd, .rs1 = .zr, .rs2 = op.rs1 } } };
            if (try selection.matches(instruction.MachineInstr.AA)) |op|
                return .{ .instruction = .{ .add_aaa = .{ .rd = op.rd, .rs1 = .zr, .rs2 = op.rs1 } } };
            if (try selection.matches(instruction.MachineInstr.DA)) |op|
                return .{ .instruction = .{ .add_dad = .{ .rd = op.rd, .rs1 = op.rs1, .rs2 = .zr } } };
            if (try selection.matches(instruction.MachineInstr.AD)) |op|
                return .{ .instruction = .{ .add_aad = .{ .rd = op.rd, .rs1 = .zr, .rs2 = op.rs1 } } };
        },
        .movew => {
            if (try selection.matches(instruction.MachineInstr.DX)) |op|
                return .{ .instruction = .{ .movew_dx = op } };
            if (try selection.matches(instruction.MachineInstr.XD)) |op|
                return .{ .instruction = .{ .movew_xd = op } };
            if (try selection.matches(instruction.MachineInstr.DM)) |op|
                return .{ .instruction = .{ .movew_dm = op } };
            if (try selection.matches(instruction.MachineInstr.DP)) |op|
                return .{ .instruction = .{ .movew_dp = op } };
            if (try selection.matches(instruction.MachineInstr.MD)) |op|
                return .{ .instruction = .{ .movew_md = op } };
            if (try selection.matches(instruction.MachineInstr.PD)) |op|
                return .{ .instruction = .{ .movew_pd = op } };
        },
        .sysc => {
            if (try selection.matches(instruction.MachineInstr.I)) |op|
                return .{ .instruction = .{ .sysc_i = op } };
        },
        .csrr => {
            if (try selection.matches(instruction.MachineInstr.DI)) |op|
                return .{ .instruction = .{ .csrr_di = op } };
        },
        .csrw => {
            if (try selection.matches(instruction.MachineInstr.DI)) |op|
                return .{ .instruction = .{ .csrw_di = op } };
        },
        .reti => {
            if (try selection.matches(void))
                return .{ .instruction = .reti };
        },
        .waiti => {
            if (try selection.matches(void))
                return .{ .instruction = .waiti };
        },
        .ftlb => {
            if (try selection.matches(void))
                return .{ .instruction = .ftlb };
        },
        .fence => {
            if (try selection.matches(void))
                return .{ .instruction = .fence };
        },
        .nop => {
            if (try selection.matches(void))
                return .{ .instruction = .nop };
        },
        .ssf => {
            if (try selection.matches(void))
                return .{ .instruction = .ssf };
        },
        .rsf => {
            if (try selection.matches(void))
                return .{ .instruction = .rsf };
        },

        .bkpt => {
            if (try selection.matches(void))
                return .{ .instruction = .bkpt };
        },
        .jmpr => {
            if (try selection.matches(instruction.MachineInstr.I)) |op|
                return .{ .instruction = .{ .addi_ai = .{ .rd = .ip, .i = op.i } } };
        },

        .i8 => {
            if (try selection.matches(i8)) |op|
                return .{ .data = .{ .bytes = 1, .value = op } };
        },
        .i16 => {
            if (try selection.matches(i16)) |op|
                return .{ .data = .{ .bytes = 2, .value = op } };
        },
        .i24 => {
            if (try selection.matches(i24)) |op|
                return .{ .data = .{ .bytes = 3, .value = op } };
        },
        .i32 => {
            if (try selection.matches(i32)) |op|
                return .{ .data = .{ .bytes = 4, .value = op } };
        },
        .u8 => {
            if (try selection.matches(u8)) |op|
                return .{ .data = .{ .bytes = 1, .value = op } };
        },
        .u16 => {
            if (try selection.matches(u16)) |op|
                return .{ .data = .{ .bytes = 2, .value = op } };
        },
        .u24 => {
            if (try selection.matches(u24)) |op|
                return .{ .data = .{ .bytes = 3, .value = op } };
        },
        .u32 => {
            if (try selection.matches(u32)) |op|
                return .{ .data = .{ .bytes = 4, .value = op } };
        }
    }

    try self.addError(error.InstrSelection, instr_token, "instruction '{s}' doesn't match any candidates", .{ @tagName(instr_tag) });
    return error.Break;
}

fn lazilyAnalyseReference(self: *AsmSemanticAir, instr: instruction.MachineInstr) !void {
    const label: instruction.LinkerAddress = switch (instr) {
        inline else => |ty| blk: {
            const Ty = @TypeOf(ty);

            if (Ty == void) {
                return;
            }

            const type_info = @typeInfo(Ty).@"struct";

            inline for (type_info.field_names, type_info.field_types) |field_name, field_ty| {
                const address = switch (field_ty) {
                    instruction.LinkerAddress => @field(ty, field_name),
                    instruction.LinkerIndex => @field(ty, field_name).address,
                    else => continue
                };
                break :blk address;
            }

            return;
        }
    };

    if (label.dynamic) |dynamic| {
        try self.bridge.ensureBlockAnalysed(dynamic.file_index, dynamic.block_index);
    }
}

// Tests

const TestBridge = struct {

    allocator: std.mem.Allocator,
    errors: std.ArrayList(Error) = .empty,

    pub fn deinit(self: *TestBridge) void {
        for (self.errors.items) |err|
            err.deinit(self.allocator);
        self.errors.deinit(self.allocator);
    }

    const astTable = AsmAst.Bridge.VTable {
        .emitError = emitError
    };

    const irTable = Bridge.VTable {
        .emitError = emitError,
        .import = import
    };

    const semaTable = Bridge.VTable {
        .emitError = emitError,
        .createScope = createScope,
        .ensureBlockAnalysed = ensureBlockAnalysed
    };

    fn emitError(context: *anyopaque, err: Error) !void {
        const self: *TestBridge = @alignCast(@ptrCast(context));
        try self.errors.append(self.allocator, err);
    }

    fn import(_: *anyopaque, _: []const u8) !Qcu.File.List.Index {
        return .root;
    }

    fn createScope(_: *anyopaque, _: Qcu.File.List.Index, _: []const u8) AsmSemanticAir {
        @panic("bug: not implemented");
    }

    fn ensureBlockAnalysed(_: *anyopaque, _: Qcu.File.List.Index, _: AsmIr.Block.List.Index) !void {
        @panic("bug: not implemented");
    }

    pub fn ast(self: *TestBridge) AsmAst.Bridge {
        return .{ .vtable = astTable, .context = self };
    }

    pub fn ir(self: *TestBridge) Bridge {
        return .{ .vtable = irTable, .context = self };
    }

    pub fn sema(self: *TestBridge) Bridge {
        return .{ .vtable = semaTable, .context = self };
    }
};

// fn testSemantics(input: [:0]const u8, errors: []const AnalysisError) !void {
//     const stderr_file = std.Io.File.stderr();
//     var stderr_buffer: [4096]u8 = undefined;
//     var stderr = stderr_file.writer(std.testing.io, &stderr_buffer);
//     defer stderr.flush() catch {};

//     const source_file = SourceFile {
//         .pwd = std.Io.Dir.cwd(),
//         .real_path = "Sources/AsmIr.zig",
//         .buffer = input,
//         .inode = undefined,
//         .size = undefined };
//     var bridge = TestBridge { .allocator = std.testing.allocator };
//     defer bridge.deinit();
//     var ast = try AsmAst.init(std.testing.allocator, &source_file, bridge.ast());
//     defer ast.deinit(std.testing.allocator);
//     std.debug.assert(bridge.errors.items.len == 0);

//     var ir = try AsmIr.init(std.testing.allocator, &source_file, &ast, bridge.ir());
//     defer ir.deinit(std.testing.allocator);

//     if (errors.len != bridge.errors.items.len) {
//         for (bridge.errors.items) |err|
//             try err.write(&stderr.interface);
//     }

//     try std.testing.expectEqual(errors.len, bridge.errors.items.len);
//     for (errors, 0..) |err, i| try std.testing.expectEqual(err, bridge.errors.items[i].err);
// }
