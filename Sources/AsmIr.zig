
// Intermediate Representation

const std = @import("std");
const indexable_list = @import("indexable_list.zig");
const Qcu = @import("Qcu.zig");
const SourceFile = @import("SourceFile.zig");
const Error = @import("Error.zig");
const Token = @import("Token.zig");
const AsmAst = @import("AsmAst.zig");

const AsmIr = @This();

blocks: Block.List.Slice,
symbols: std.StringHashMapUnmanaged(Symbol),

/// Ingests the Abstract Syntax Tree and initialises IrGen which lowers the Ast
/// into statically-analysed intermediate representation.
pub fn init(
    allocator: std.mem.Allocator,
    source_file: *const SourceFile,
    tree: *const AsmAst,
    bridge: Bridge
) !AsmIr {
    var ir_gen = IrGen.init(allocator, source_file, tree, bridge);
    defer ir_gen.deinit();
    errdefer ir_gen.destroy();

    try ir_gen.lowerTree();

    return .{
        .blocks = try ir_gen.blocks.toOwnedSlice(allocator),
        // .link_info = try ir_gen.link_info.toOwnedSlice(allocator),
        .symbols = ir_gen.symbols };
}

pub fn deinit(self: *AsmIr, allocator: std.mem.Allocator) void {
    for (self.blocks.items) |block|
        block.deinit(allocator);
    self.blocks.deinit(allocator);
    self.symbols.deinit(allocator);
}

pub fn dump(self: *const AsmIr, _: std.mem.Allocator, writer: *std.Io.Writer) !void {
    var iterator = self.symbols.iterator();

    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        const symbol = entry.value_ptr;
        try writer.print("@{s}({s}) {s} {any}\n", .{
            @tagName(symbol.ty),
            @tagName(symbol.privacy),
            name,
            symbol.ty });
    }

    for (self.blocks.items) |block| {
        try writer.print("@{s} {s}\n", .{
            @tagName(block.ty),
            block.name });

        for (block.content.list.items, 0..) |ir, index| {
            try writer.print("  {} {any}\n", .{ index, ir.ty });
        }
    }
}

pub const Bridge = struct {

    const AllocatorError = std.mem.Allocator.Error;

    const ImportError = error {
        CircularImport,
        FileTypeNotSupported
    } || SourceFile.InitError;

    vtable: VTable,
    context: *anyopaque,

    pub const VTable = struct {
        emitError: *const fn (*anyopaque, Error) AllocatorError!void,
        import: *const fn (*anyopaque, []const u8) ImportError!Qcu.File.List.Index
    };

    fn emitError(self: *const Bridge, err: Error) !void {
        return try self.vtable.emitError(self.context, err);
    }

    fn import(self: *const Bridge, file_path: []const u8) !Qcu.File.List.Index {
        return try self.vtable.import(self.context, file_path);
    }
};

pub const Block = struct {

    token: Token,
    name: []const u8,
    ty: Type,

    content: Ir.List = .empty,
    symbols: std.StringHashMapUnmanaged(Symbol) = .empty,

    pub const List = indexable_list.IndexableList(*Block);

    pub const Type = union(enum) {
        section: struct {
            is_entrypoint: bool,
            is_noelimination: bool
        },
        /// the range of arguments (identifiers) of the header
        header: AsmAst.Node.Operands
    };

    pub fn init(
        allocator: std.mem.Allocator,
        token: Token,
        name: []const u8,
        ty: Type
    ) !*Block {
        const block = try allocator.create(Block);
        errdefer block.deinit(allocator);

        block.* = .{
            .token = token,
            .name = name,
            .ty = ty };

        return block;
    }

    pub fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        self.content.deinit(allocator);
        self.symbols.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setOpaqueLen(self: *Block, index: Ir.List.Index) void {
        const len = self.content.len() - index.raw() - 1;

        switch (self.content.list.items[index.raw()].ty) {
            inline .region, .@"if", .@"else" => |*scope| scope.opaque_len = len,
            else => unreachable
        }
    }
};

pub const Ir = struct {

    token: Token,
    ty: Type,

    pub const List = indexable_list.IndexableList(Ir);

    pub const Type = union(enum) {
        /// token: @align
        /// node index: alignment expression
        @"align": AsmAst.Node.List.Index,
        /// token: @err
        /// range: argument container
        /// guaranteed to have >=1 elements, with arguments[0] being an expression node
        err: AsmAst.Node.Operands,
        /// token: @region
        /// expression: region size expression
        /// opaque_len: len of opaque body
        region: struct {
            expression: AsmAst.Node.List.Index,
            opaque_len: AsmAst.UntypedIndex
        },
        /// token: @if
        /// expression: conditional expression
        /// opaque_len: len of opaque body
        @"if": struct {
            expression: AsmAst.Node.List.Index,
            opaque_len: AsmAst.UntypedIndex
        },
        /// token: @else
        /// opaque_len: len of opaque body
        @"else": struct {
            opaque_len: AsmAst.UntypedIndex
        },
        /// token: the header call
        /// node_index: the header call
        /// arguments: argument container
        header: struct {
            node_index: AsmAst.Node.List.Index,
            arguments: AsmAst.Node.Operands,
        },
        /// token: the instruction
        /// range: argument container
        instruction: AsmAst.Node.Operands,
        /// token: reserve
        /// type_expression: expression which must resolve a size
        /// len_expression: len expression
        reserve: struct {
            type_expression: AsmAst.Node.List.Index,
            len_expression: AsmAst.Node.List.Index
        },
        /// token: ascii
        /// node index: string expression
        ascii: AsmAst.Node.List.Index,
        /// token: the public or private label
        label,
        /// token: the discard label (guaranteed to be public)
        discard_label
    };
};

pub const Symbol = struct {

    token: Token,
    ty: Type,
    privacy: Privacy,

    pub const Type = union(enum) {

        /// token: the define name
        define: AsmAst.Node.List.Index,
        /// token: the header name
        header: Block.List.Index,
        /// token: the label
        label: Block.List.Index,
        /// token: the namespace
        import: Qcu.File.List.Index,

        deferred,

        pub fn fmt(self: Type) []const u8 {
            return switch (self) {
                .define => "@define",
                .header => "@header",
                .label => "a label",
                .import => "an import",
                .deferred => "a @header argument"
            };
        }
    };

    pub const Privacy = enum {
        public,
        private
    };
};

const IrGen = struct {

    allocator: std.mem.Allocator,
    source_file: *const SourceFile,
    tree: *const AsmAst,
    bridge: Bridge,

    blocks: Block.List = .empty,
    symbols: std.StringHashMapUnmanaged(Symbol) = .empty,
    imports: std.AutoHashMapUnmanaged(Qcu.File.List.Index, Token) = .empty,
    block_index: ?Block.List.Index = null,

    const log = std.log.scoped(.AsmIr);

    pub fn init(
        allocator: std.mem.Allocator,
        source_file: *const SourceFile,
        tree: *const AsmAst,
        bridge: Bridge
    ) IrGen {
        return .{
            .allocator = allocator,
            .source_file = source_file,
            .tree = tree,
            .bridge = bridge };
    }

    pub fn deinit(self: *IrGen) void {
        self.blocks.deinit(self.allocator);
        self.imports.deinit(self.allocator);
    }

    /// Like deinit, but destroys the owned memory for error events.
    pub fn destroy(self: *IrGen) void {
        for (self.blocks.list.items) |block|
            block.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
    }

    pub const IrError = error {
        Expected,
        Unexpected,
        DuplicateOption,
        InvalidOption,
        Barrier,
        InvalidSymbol,
        DuplicateSymbol,
        MismatchedSymbolLocality,
        MismatchedSymbolPrivacy,
        UselessSentinel,
        FailedImport,
        DuplicateImport,
        InvalidConditional,
        Illegal,
        InvalidLabelType,
        NoteDefinedHere,
        NoteReason,
        Note
    };

    fn addError(
        self: *IrGen,
        comptime err: IrError,
        token: Token,
        comptime format: []const u8,
        arguments: anytype
    ) !void {
        @branchHint(.cold);

        const message = try self.allocator.print(format, arguments);
        errdefer self.allocator.free(message);

        try self.bridge.emitError(.{
            .err = err,
            .token = token,
            .source_file = self.source_file,
            .is_note = switch (err) {
                error.NoteDefinedHere,
                error.NoteReason,
                error.Note => true,
                else => false
            },
            .is_preview = err != error.Note,
            .message = message });
    }

    const ParseError = std.mem.Allocator.Error;

    pub fn lowerTree(self: *IrGen) ParseError!void {
        std.debug.assert(self.tree.tokens.items.len > 0);
        std.debug.assert(self.tree.nodes.items.len > 0);
        const root_node = self.tree.nodes.get(.root);
        std.debug.assert(root_node.tag == .container);

        for (root_node.operands.lhs..root_node.operands.rhs) |node_index| {
            const node = self.tree.nodes.get(.fromIndex(node_index));
            std.debug.assert(node.tag == .builtin);

            const builtin = self.getBuiltin(node);

            switch (builtin.token.tag) {
                .builtin_section => try self.lowerSectionBlock(builtin),
                .builtin_barrier => try self.lowerBarrierBlock(builtin),
                .builtin_header => try self.lowerHeaderBlock(builtin),

                .builtin_define => try self.emitDefine(builtin),
                .builtin_import => try self.emitImport(builtin),
                .builtin_linkinfo => {},

                // nothing to do at root
                .builtin_align,
                .builtin_else,
                .builtin_err,
                .builtin_if,
                .builtin_region => unreachable,

                // transparent in the AST
                .builtin_end => unreachable,

                // non-builtin tokens shouldn't be in node tags
                else => unreachable
            }
        }
    }

    fn treeTagOrNull(self: *const IrGen, index: AsmAst.UntypedIndex, tag: AsmAst.Node.Tag) bool {
        return index == AsmAst.untypedNull or self.tree.nodes.get(.at(index)).tag == tag;
    }

    fn treeUnwrap(self: *const IrGen, index: AsmAst.UntypedIndex) ?AsmAst.Node {
        return if (index != AsmAst.untypedNull) self.tree.nodes.get(.at(index)) else null;
    }

    fn treeUnwrapRange(self: *const IrGen, index: AsmAst.UntypedIndex) AsmAst.Node.Operands {
        return if (self.treeUnwrap(index)) |node| node.operands else .{};
    }

    const Builtin = struct {
        token: Token,
        arguments: AsmAst.Node.Operands,
        options: AsmAst.Node.Operands,
        payload: AsmAst.Node.Operands
    };

    fn getBuiltin(self: *const IrGen, node: AsmAst.Node) Builtin {
        std.debug.assert(node.tag == .builtin);
        std.debug.assert(self.treeTagOrNull(node.operands.lhs, .container));
        std.debug.assert(self.treeTagOrNull(node.operands.rhs, .composite));

        const arguments = self.treeUnwrapRange(node.operands.lhs);
        const composite = self.treeUnwrap(node.operands.rhs);

        const options: AsmAst.Node.Operands,
        const payload: AsmAst.Node.Operands = if (composite) |the_composite| blk: {
            std.debug.assert(self.treeTagOrNull(the_composite.operands.lhs, .container));
            std.debug.assert(self.treeTagOrNull(the_composite.operands.rhs, .container));

            break :blk .{
                self.treeUnwrapRange(the_composite.operands.lhs),
                self.treeUnwrapRange(the_composite.operands.rhs) };
        } else .{ .{}, .{} };

        const token = self.tree.tokens.get(node.token);
        std.debug.assert(token.tag.isBuiltinOpaque() or payload.lhs == payload.rhs);

        return .{
            .token = token,
            .arguments = arguments,
            .options = options,
            .payload = payload };
    }

    const ContainerIterator = struct {

        context: *IrGen,
        range: AsmAst.Node.Operands,

        cursor: AsmAst.UntypedIndex = 0,

        pub fn currentIndex(self: *const ContainerIterator) AsmAst.UntypedIndex {
            return self.range.lhs + self.cursor;
        }

        pub fn unprocessedRange(self: *const ContainerIterator) AsmAst.Node.Operands {
            return .{ .lhs = self.currentIndex(), .rhs = self.range.rhs };
        }

        pub fn nextIndex(self: *ContainerIterator) AsmAst.Node.List.Index {
            const index = self.currentIndex();
            if (!self.isEnd()) self.cursor += 1;
            return .at(index);
        }

        pub fn isEnd(self: *const ContainerIterator) bool {
            return self.currentIndex() >= self.range.rhs;
        }

        pub fn expectTagOrEnd(
            self: *ContainerIterator,
            tag: AsmAst.Node.Tag,
            token: Token
        ) !?AsmAst.Node.List.Index {
            if (self.isEnd())
                return null;
            const node = self.context.tree.nodes.get(.at(self.currentIndex()));

            if (node.tag != tag) {
                const actual_token = self.context.tree.tokens.get(node.token);
                try self.context.addError(error.Expected, actual_token, "{s} expects {s}, found {s}", .{
                    token.tag.fmt(),
                    tag.fmt(),
                    actual_token.tag.fmt() });
                return null;
            }

            return self.nextIndex();
        }

        pub fn expectTag(
            self: *ContainerIterator,
            tag: AsmAst.Node.Tag,
            token: Token
        ) !?AsmAst.Node.List.Index {
            if (self.isEnd()) {
                try self.context.addError(error.Expected, token, "{s} expects {s}", .{ token.tag.fmt(), tag.fmt() });
                return null;
            }

            return self.expectTagOrEnd(tag, token);
        }

        pub fn expectAny(
            self: *ContainerIterator,
            token: Token,
            expected_str: []const u8
        ) !?AsmAst.Node.List.Index {
            if (self.isEnd()) {
                try self.context.addError(error.Expected, token, "{s} expects {s}", .{ token.tag.fmt(), expected_str });
                return null;
            }

            return self.nextIndex();
        }

        pub fn expectEnd(self: *const ContainerIterator) !void {
            if (self.isEnd())
                return;
            const node = self.context.tree.nodes.get(.at(self.currentIndex()));
            const token = self.context.tree.tokens.get(node.token);
            const s = if (self.cursor == 1) "" else "s";
            const len = self.range.rhs - self.range.lhs;

            try self.context.addError(error.Unexpected, token, "unexpectedly got {s}", .{ token.tag.fmt() });
            try self.context.addError(error.Note, token, "expected {} argument{s}, found {}", .{ self.cursor, s, len });
        }
    };

    fn containerIterator(self: *IrGen, range: AsmAst.Node.Operands) ContainerIterator {
        return .{ .context = self, .range = range };
    }

    fn resolveOptionList(
        self: *IrGen,
        comptime T: type,
        range: AsmAst.Node.Operands,
        context_token: Token
    ) !T {
        var iterator = self.containerIterator(range);
        var options: T = .{};

        options: while (!iterator.isEnd()) {
            const node_index = try iterator.expectTag(.identifier, context_token) orelse {
                _ = iterator.nextIndex();
                continue :options;
            };
            const node = self.tree.nodes.get(node_index);
            const token = self.tree.tokens.get(node.token);
            const option = self.source_file.slice(token);

            inline for (@typeInfo(T).@"struct".field_names) |field_name| {
                if (std.mem.eql(u8, field_name, option)) {
                    if (@field(options, field_name))
                        try self.addError(error.DuplicateOption, token, "duplicate option '{s}'", .{ option });
                    @field(options, field_name) = true;
                    continue :options;
                }
            }

            try self.addError(error.InvalidOption, token, "invalid option '{s}'", .{ option });
        }

        return options;
    }

    fn addBlock(self: *IrGen, token: Token, name: []const u8, ty: Block.Type) !Block.List.Index {
        const new_block = try Block.init(self.allocator, token, name, ty);
        errdefer new_block.deinit(self.allocator);

        const new_block_index: Block.List.Index = .at(self.blocks.len());
        try self.blocks.append(self.allocator, new_block);
        return new_block_index;
    }

    fn getCurrentBlock(self: *const IrGen) ?*Block {
        const index = self.block_index orelse return null;
        return self.blocks.get(index);
    }

    fn getCurrentSection(self: *const IrGen) ?*Block {
        const block = self.getCurrentBlock() orelse return null;
        return if (block.ty == .section) block else null;
    }

    fn getCurrentHeader(self: *const IrGen) ?*Block {
        const block = self.getCurrentBlock() orelse return null;
        return if (block.ty == .header) block else null;
    }

    fn maybeEmitSentinelError(self: *IrGen, node: AsmAst.Node) !void {
        std.debug.assert(node.tag == .string);

        const token = self.tree.tokens.get(node.token);

        std.debug.assert(token.tag == .string_literal);
        std.debug.assert(self.treeTagOrNull(node.operands.lhs, .integer));
        std.debug.assert(node.operands.rhs == AsmAst.untypedNull);

        if (node.operands.lhs != AsmAst.untypedNull) {
            const sentinel_node = self.tree.nodes.get(.at(node.operands.lhs));
            const sentinel_token = self.tree.tokens.get(sentinel_node.token);
            try self.addError(error.UselessSentinel, sentinel_token, "unnecessary sentinel", .{});
        }
    }

    fn maybeEmitConditionalError(self: *IrGen, cond_reason: CondReason, token: Token) !void {
        switch (cond_reason) {
            .none => {},
            .scoped => |reason_token| {
                try self.addError(error.InvalidConditional, token, "unable to evaluate {s} at assemble-time", .{ token.tag.fmt() });
                try self.addError(error.NoteReason, reason_token, "{s} enters conditional context", .{ reason_token.tag.fmt() });
            }
        }
    }

    fn maybeEmitNestedHeaderError(self: *IrGen, token: Token) !void {
        if (self.getCurrentHeader()) |header_block| {
            try self.addError(error.Illegal, token, "{s} is illegal in header", .{ token.tag.fmt() });
            try self.addError(error.NoteDefinedHere, header_block.token, "{s} defined here", .{ header_block.token.tag.fmt() });
        }
    }

    const SectionOptions = struct {
        noelimination: bool = false,
        entrypoint: bool = false
    };

    fn lowerSectionBlock(self: *IrGen, builtin: Builtin) !void {
        std.debug.assert(builtin.token.tag == .builtin_section);

        const options = try self.resolveOptionList(SectionOptions, builtin.options, builtin.token);
        var iterator = self.containerIterator(builtin.arguments);

        const name_node_index = try iterator.expectTag(.identifier, builtin.token) orelse return;
        try iterator.expectEnd();

        const name_node = self.tree.nodes.get(name_node_index);
        const name_token = self.tree.tokens.get(name_node.token);
        const name = self.source_file.slice(name_token);

        const ty: Block.Type = .{ .section = .{
            .is_noelimination = options.noelimination,
            .is_entrypoint = options.entrypoint } };
        const block_index = try self.addBlock(builtin.token, name, ty);

        log.debug("lowerSectionBlock {s} (block_index={})", .{ name, block_index });

        try self.lowerBlock(block_index, builtin.payload);
    }

    fn lowerBarrierBlock(self: *IrGen, builtin: Builtin) !void {
        std.debug.assert(builtin.token.tag == .builtin_barrier);

        const options = try self.resolveOptionList(SectionOptions, builtin.options, builtin.token);
        var iterator = self.containerIterator(builtin.arguments);

        try iterator.expectEnd();

        const existing_block = self.getCurrentSection() orelse {
            try self.addError(error.Barrier, builtin.token, "@barrier must be defined after a section", .{});
            return;
        };
        const noelimination = options.noelimination or existing_block.ty.section.is_noelimination;

        const ty: Block.Type = .{ .section = .{
            .is_noelimination = noelimination,
            .is_entrypoint = options.entrypoint } };
        const block_index = try self.addBlock(builtin.token, existing_block.name, ty);

        log.debug("lowerBarrierBlock {s} (block_index={?} -> {})", .{ existing_block.name, self.block_index, block_index });

        try self.lowerBlock(block_index, builtin.payload);
    }

    const MacroOptions = struct {
        expose: bool = false
    };

    fn lowerHeaderBlock(self: *IrGen, builtin: Builtin) !void {
        std.debug.assert(builtin.token.tag == .builtin_header);

        const options = try self.resolveOptionList(MacroOptions, builtin.options, builtin.token);
        var iterator = self.containerIterator(builtin.arguments);

        const name_node_index = try iterator.expectTag(.identifier, builtin.token) orelse return;
        const arguments = iterator.unprocessedRange();

        const name_node = self.tree.nodes.get(name_node_index);
        const name_token = self.tree.tokens.get(name_node.token);
        const name = self.source_file.slice(name_token);

        const ty: Block.Type = .{ .header = arguments };
        const block_index = try self.addBlock(builtin.token, name, ty);

        log.debug("lowerHeaderBlock {s} (block_index={})", .{ name, block_index });

        const symbol = Symbol {
            .token = name_token,
            .ty = .{ .header = block_index },
            .privacy = if (options.expose) .public else .private };
        try self.addSymbol(name, .unique, .global, block_index, symbol);

        while (try iterator.expectTagOrEnd(.identifier, builtin.token)) |argument_node_index| {
            const parameter_node = self.tree.nodes.get(argument_node_index);
            const parameter_token = self.tree.tokens.get(parameter_node.token);
            const parameter = self.source_file.slice(parameter_token);

            const parameter_symbol = Symbol {
                .token = parameter_token,
                .ty = .deferred,
                .privacy = .private };
            try self.addSymbol(parameter, .unique, .local, block_index, parameter_symbol);
        }

        try self.lowerBlock(block_index, builtin.payload);
    }

    fn lowerBlock(
        self: *IrGen,
        index: Block.List.Index,
        range: AsmAst.Node.Operands
    ) !void {
        const previous_block_index = self.block_index;
        self.block_index = index;

        defer {
            if (self.blocks.get(index).ty == .header)
                self.block_index = previous_block_index;
        }

        try self.lowerOpaqueTree(range, .none);
    }

    const CondReason = union(enum) {
        none,
        scoped: Token
    };

    fn lowerOpaqueTree(self: *IrGen, range: AsmAst.Node.Operands, cond_reason: CondReason) ParseError!void {
        loop: for (range.lhs..range.rhs) |node_index| {
            const node = self.tree.nodes.get(.fromIndex(node_index));

            switch (node.tag) {
                .builtin => {
                    const builtin = self.getBuiltin(node);

                    switch (builtin.token.tag) {
                        .builtin_align => try self.emitAlign(builtin),
                        .builtin_err => try self.emitErr(builtin),
                        .builtin_region => {
                            const block, const index = self.createRegionScope(builtin) catch |err| switch (err) {
                                error.Break => continue :loop,
                                else => |the_err| return the_err
                            };
                            try self.lowerOpaqueTree(builtin.payload, cond_reason);
                            block.setOpaqueLen(index);
                        },
                        .builtin_if => {
                            const new_cond_reason: CondReason = switch (cond_reason) {
                                .none => .{ .scoped = builtin.token },
                                .scoped => cond_reason
                            };
                            const block, const index = self.createIfScope(builtin) catch |err| switch (err) {
                                error.Break => continue :loop,
                                else => |the_err| return the_err
                            };
                            try self.lowerOpaqueTree(builtin.payload, new_cond_reason);
                            block.setOpaqueLen(index);
                        },
                        .builtin_else => {
                            const new_cond_reason: CondReason = switch (cond_reason) {
                                .none => .{ .scoped = builtin.token },
                                .scoped => cond_reason
                            };
                            const block, const index = try self.createElseScope(builtin);
                            try self.lowerOpaqueTree(builtin.payload, new_cond_reason);
                            block.setOpaqueLen(index);
                        },
                        .builtin_define => {
                            try self.maybeEmitConditionalError(cond_reason, builtin.token);
                            try self.emitDefine(builtin);
                        },
                        .builtin_header => {
                            try self.maybeEmitNestedHeaderError(builtin.token);
                            try self.lowerHeaderBlock(builtin);
                        },
                        .builtin_linkinfo => {},

                        // nothing to do at opaque level
                        .builtin_import,
                        .builtin_barrier,
                        .builtin_section => unreachable,

                        // transparent in AST
                        .builtin_end => unreachable,

                        // non-builtin tokens shouldn't be present here
                        else => unreachable
                    }
                },

                .instruction => try self.emitInstruction(.fromIndex(node_index)),
                .label => try self.emitLabel(node),

                // other nodes are illegal
                else => unreachable
            }
        }
    }

    const Uniqueness = enum {
        unique,
        conditionally_unique
    };

    const Scope = enum {
        global,
        local
    };

    fn addSymbol(
        self: *IrGen,
        identifier: []const u8,
        uniqueness: Uniqueness,
        scope: Scope,
        block_index: ?Block.List.Index,
        symbol: Symbol
    ) !void {
        std.debug.assert(identifier.len > 0);
        std.debug.assert(scope != .local or block_index != null);

        const block = if (block_index) |the_block_index|
            self.blocks.get(the_block_index) else
            null;

        var namespaces = std.mem.splitScalar(u8, identifier, '.');
        const namespace = namespaces.first();

        switch (symbol.ty) {
            .define, .header, .import => if (namespaces.rest().len != 0) {
                try self.addError(error.InvalidSymbol, symbol.token, "{s} may not have namespaces", .{ symbol.ty.fmt() });
                return;
            },
            .label, .deferred => {}
        }

        const result = self.fetchSymbol(namespace, scope, block_index) orelse {
            return switch (scope) {
                .global => try self.symbols.put(self.allocator, namespace, symbol),
                .local => try block.?.symbols.put(self.allocator, namespace, symbol)
            };
        };

        const is_duplicate = switch (uniqueness) {
            .unique => true,
            .conditionally_unique => switch (symbol.ty) {
                .label => |label| !(result.symbol.ty == .label and label == result.symbol.ty.label),
                else => true
            }
        };

        if (is_duplicate) {
            try self.addError(error.DuplicateSymbol, symbol.token, "duplicate symbol '{s}'", .{ namespace });
            try self.addError(error.NoteDefinedHere, result.symbol.token, "initially declared here", .{});
        }

        if (symbol.ty == .label and result.symbol.ty == .label and result.scope != scope) {
            try self.addError(error.MismatchedSymbolLocality, symbol.token, "{s} label with a local namespace has mismatching locality", .{ @tagName(scope) });
            try self.addError(error.NoteDefinedHere, result.symbol.token, "initially declared {s} here", .{ @tagName(result.scope) });
            return;
        }

        if (uniqueness == .conditionally_unique) {
            const is_foreign_block = switch (symbol.ty) {
                .label => |label| (result.symbol.ty == .label and label != result.symbol.ty.label),
                else => false
            };

            if (is_duplicate and is_foreign_block) {
                try self.addError(error.Note, symbol.token, "labels with a local namespace must reside in the same block", .{});
            }

            const symbol_tag = std.meta.activeTag(symbol.ty);
            const existing_symbol_tag = std.meta.activeTag(result.symbol.ty);

            if (symbol_tag == existing_symbol_tag and symbol.privacy != result.symbol.privacy) {
                try self.addError(error.MismatchedSymbolPrivacy, symbol.token, "{s} label with a local namespace has mismatching privacy", .{ @tagName(symbol.privacy) });
                try self.addError(error.NoteDefinedHere, result.symbol.token, "initially declared {s} here", .{ @tagName(result.symbol.privacy) });
            }
        }
    }

    fn fetchSymbol(
        self: *IrGen,
        identifier: []const u8,
        scope: Scope,
        block_index: ?Block.List.Index
    ) ?struct {
        symbol: Symbol,
        scope: Scope
    } {
        if (self.symbols.get(identifier)) |global_symbol| {
            return .{ .symbol = global_symbol, .scope = .global };
        }

        const block = if (block_index) |the_block_index|
            self.blocks.get(the_block_index) else
            null;

        if (block) |the_block| {
            if (the_block.symbols.get(identifier)) |local_symbol|
                return .{ .symbol = local_symbol, .scope = .local };
        }

        if (scope == .global) for (self.blocks.list.items) |local_block| {
            if (local_block.symbols.get(identifier)) |local_symbol|
                return .{ .symbol = local_symbol, .scope = .local };
        };

        return null;
    }

    fn emitDefine(self: *IrGen, builtin: Builtin) !void {
        std.debug.assert(builtin.token.tag == .builtin_define);

        const options = try self.resolveOptionList(MacroOptions, builtin.options, builtin.token);
        var iterator = self.containerIterator(builtin.arguments);

        const name_node_index = try iterator.expectTag(.identifier, builtin.token) orelse return;
        const expr_node_index = try iterator.expectAny(builtin.token, "an expression") orelse return;
        try iterator.expectEnd();

        const name_node = self.tree.nodes.get(name_node_index);
        const name_token = self.tree.tokens.get(name_node.token);
        const name = self.source_file.slice(name_token);

        const symbol = Symbol {
            .token = name_token,
            .ty = .{ .define = expr_node_index },
            .privacy = if (options.expose) .public else .private };
        const scope: Scope = if (self.getCurrentHeader() != null) .local else .global;
        try self.addSymbol(name, .unique, scope, self.block_index, symbol);
    }

    fn emitImport(self: *IrGen, builtin: Builtin) !void {
        std.debug.assert(builtin.token.tag == .builtin_import);
        std.debug.assert(self.block_index == null);

        const options = try self.resolveOptionList(MacroOptions, builtin.options, builtin.token);
        var iterator = self.containerIterator(builtin.arguments);

        const namespace_node_index = try iterator.expectTag(.identifier, builtin.token) orelse return;
        const path_node_index = try iterator.expectTag(.string, builtin.token) orelse return;
        try iterator.expectEnd();

        const namespace_node = self.tree.nodes.get(namespace_node_index);
        const namespace_token = self.tree.tokens.get(namespace_node.token);
        const namespace = self.source_file.slice(namespace_token);
        const path_node = self.tree.nodes.get(path_node_index);
        const path_token = self.tree.tokens.get(path_node.token);
        const path = self.source_file.slice(path_token);

        try self.maybeEmitSentinelError(path_node);

        const file_index = self.bridge.import(path) catch |err| return switch (err) {
            error.CircularImport => try self.addError(error.FailedImport, path_token, "circular import", .{}),
            error.FileTypeNotSupported => try self.addError(error.FailedImport, path_token, "file type not supported", .{}),
            error.FileNotFound => try self.addError(error.FailedImport, path_token, "file not found", .{}),
            else => try self.addError(error.FailedImport, path_token, "import failure: {s}", .{ @errorName(err) })
        };

        const result = try self.imports.getOrPut(self.allocator, file_index);

        if (result.found_existing) {
            try self.addError(error.DuplicateImport, path_token, "duplicated import of file", .{});
            try self.addError(error.NoteDefinedHere, result.value_ptr.*, "previously imported here", .{});
        } else {
            result.value_ptr.* = path_token;
        }

        const symbol = Symbol {
            .token = namespace_token,
            .ty = .{ .import = file_index },
            .privacy = if (options.expose) .public else .private };
        try self.addSymbol(namespace, .unique, .global, null, symbol);
    }

    fn emitAlign(self: *IrGen, builtin: Builtin) !void {
        std.debug.assert(builtin.token.tag == .builtin_align);
        std.debug.assert(self.block_index != null);

        _ = try self.resolveOptionList(struct {}, builtin.options, builtin.token);
        var iterator = self.containerIterator(builtin.arguments);

        const expr_node_index = try iterator.expectAny(builtin.token, "an expression") orelse return;
        try iterator.expectEnd();

        const block = self.getCurrentBlock().?;
        try block.content.append(self.allocator, .{
            .token = builtin.token,
            .ty = .{ .@"align" = expr_node_index } });
    }

    fn emitErr(self: *IrGen, builtin: Builtin) !void {
        std.debug.assert(builtin.token.tag == .builtin_err);
        std.debug.assert(self.block_index != null);

        _ = try self.resolveOptionList(struct {}, builtin.options, builtin.token);
        var iterator = self.containerIterator(builtin.arguments);

        const arguments = iterator.unprocessedRange();
        const message_node_index = try iterator.expectAny(builtin.token, "a string expression") orelse return;

        const message_node = self.tree.nodes.get(message_node_index);

        // string arguments will be checked for unnecessary sentinels, but
        // expressions (those from @define) won't be, because those may also be
        // used for ascii instructions
        if (message_node.tag == .string)
            try self.maybeEmitSentinelError(message_node);

        const block = self.getCurrentBlock().?;
        try block.content.append(self.allocator, .{
            .token = builtin.token,
            .ty = .{ .err = arguments } });
    }

    fn createRegionScope(self: *IrGen, builtin: Builtin) !struct { *Block, Ir.List.Index } {
        std.debug.assert(builtin.token.tag == .builtin_region);
        std.debug.assert(self.block_index != null);

        _ = try self.resolveOptionList(struct {}, builtin.options, builtin.token);
        var iterator = self.containerIterator(builtin.arguments);

        const expr_node_index = try iterator.expectAny(builtin.token, "an expression") orelse return error.Break;
        try iterator.expectEnd();

        const block = self.getCurrentBlock().?;
        const index: Ir.List.Index = .at(block.content.len());
        const ty: Ir.Type = .{ .region = .{
            .expression = expr_node_index,
            .opaque_len = 0 } };
        try block.content.append(self.allocator, .{ .token = builtin.token, .ty = ty });

        return .{ block, index };
    }

    fn createIfScope(self: *IrGen, builtin: Builtin) !struct { *Block, Ir.List.Index } {
        std.debug.assert(builtin.token.tag == .builtin_if);
        std.debug.assert(self.block_index != null);

        _ = try self.resolveOptionList(struct {}, builtin.options, builtin.token);
        var iterator = self.containerIterator(builtin.arguments);

        const expr_node_index = try iterator.expectAny(builtin.token, "an expression") orelse return error.Break;
        try iterator.expectEnd();

        const block = self.getCurrentBlock().?;
        const index: Ir.List.Index = .at(block.content.len());
        const ty: Ir.Type = .{ .@"if" = .{
            .expression = expr_node_index,
            .opaque_len = 0 } };
        try block.content.append(self.allocator, .{ .token = builtin.token, .ty = ty });

        return .{ block, index };
    }

    fn createElseScope(self: *IrGen, builtin: Builtin) !struct { *Block, Ir.List.Index } {
        std.debug.assert(builtin.token.tag == .builtin_else);
        std.debug.assert(self.block_index != null);

        _ = try self.resolveOptionList(struct {}, builtin.options, builtin.token);
        var iterator = self.containerIterator(builtin.arguments);

        try iterator.expectEnd();

        const block = self.getCurrentBlock().?;
        const index: Ir.List.Index = .at(block.content.len());
        const ty: Ir.Type = .{ .@"else" = .{ .opaque_len = 0 } };
        try block.content.append(self.allocator, .{ .token = builtin.token, .ty = ty });

        return .{ block, index };
    }

    const Encoding = enum {
        reserve,
        ascii,
        instruction
    };

    fn emitInstruction(self: *IrGen, node_index: AsmAst.Node.List.Index) !void {
        const node = self.tree.nodes.get(node_index);

        std.debug.assert(node.tag == .instruction);
        std.debug.assert(self.treeTagOrNull(node.operands.lhs, .container));
        std.debug.assert(node.operands.rhs == AsmAst.untypedNull);
        std.debug.assert(self.block_index != null);

        const token = self.tree.tokens.get(node.token);
        const instruction = self.source_file.slice(token);
        const encoding = std.meta.stringToEnum(Encoding, instruction) orelse .instruction;

        const arguments = self.treeUnwrapRange(node.operands.lhs);
        var iterator = self.containerIterator(arguments);

        const ty: Ir.Type = switch (token.tag) {
            .instruction => switch (encoding) {
                .reserve => blk: {
                    const type_expression = try iterator.expectAny(token, "a type expression") orelse return;
                    const len_expression = try iterator.expectAny(token, "an expression") orelse return;
                    try iterator.expectEnd();
                    break :blk .{ .reserve = .{
                        .type_expression = type_expression,
                        .len_expression = len_expression } };
                },
                .ascii => blk: {
                    const str_expression = try iterator.expectAny(token, "a string expression") orelse return;
                    try iterator.expectEnd();
                    break :blk .{ .ascii = str_expression };
                },
                .instruction => .{ .instruction = arguments }
            },
            .identifier => .{ .header = .{
                .node_index = node_index,
                .arguments = arguments } },
            else => unreachable
        };

        const block = self.getCurrentBlock().?;
        try block.content.append(self.allocator, .{ .token = token, .ty = ty });
    }

    fn emitLabel(self: *IrGen, node: AsmAst.Node) !void {
        std.debug.assert(node.tag == .label);
        std.debug.assert(node.operands.lhs == AsmAst.untypedNull);
        std.debug.assert(node.operands.rhs == AsmAst.untypedNull);
        std.debug.assert(self.block_index != null);

        const block = self.getCurrentBlock().?;
        const token = self.tree.tokens.get(node.token);
        const identifier = self.source_file.slice(token);

        if (block.ty == .header and token.tag == .local_label) {
            try self.addError(error.InvalidLabelType, token, "local labels are illegal in @header definitions", .{});
            try self.addError(error.Note, token, "labels in @header are implicitly local; use private labels instead", .{});
        }

        if (token.tag == .private_label and std.mem.eql(u8, identifier, "_")) {
            try self.addError(error.InvalidLabelType, token, "discard label may not have a privacy accessory", .{});
        }

        // a so-called discarding label, to silence liveness
        // mostly only used by root sections
        const ty: Ir.Type = if (token.tag == .local_label and identifier.len == 0)
            .discard_label else
            .label;

        const scope: Scope = if (token.tag == .local_label or block.ty == .header)
            .local else
            .global;

        const privacy: Symbol.Privacy = switch (token.tag) {
            .label => .public,
            .local_label => .private,
            .private_label => .private,
            else => unreachable
        };

        try block.content.append(self.allocator, .{ .token = token, .ty = ty });

        if (ty != .discard_label) {
            const symbol = Symbol {
                .token = token,
                .ty = .{ .label = self.block_index.? },
                .privacy = privacy };
            try self.addSymbol(identifier, .conditionally_unique, scope, self.block_index, symbol);
        }
    }
};

// Tests

const TestBridge = struct {

    allocator: std.mem.Allocator,
    errors: std.ArrayList(Error) = .empty,

    pub fn deinit(self: *TestBridge) void {
        for (self.errors.items) |*err|
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

    fn emitError(context: *anyopaque, err: Error) !void {
        const self: *TestBridge = @alignCast(@ptrCast(context));
        try self.errors.append(self.allocator, err);
    }

    fn import(_: *anyopaque, _: []const u8) !Qcu.File.List.Index {
        return .root;
    }

    pub fn ast(self: *TestBridge) AsmAst.Bridge {
        return .{ .vtable = astTable, .context = self };
    }

    pub fn ir(self: *TestBridge) Bridge {
        return .{ .vtable = irTable, .context = self };
    }
};

fn testIrGen(input: [:0]const u8, errors: []const IrGen.IrError) !void {
    const stderr_file = std.Io.File.stderr();
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = stderr_file.writer(std.testing.io, &stderr_buffer);
    defer stderr.flush() catch {};

    const source_file = SourceFile {
        .pwd = std.Io.Dir.cwd(),
        .real_path = "Sources/AsmIr.zig",
        .buffer = input,
        .inode = undefined,
        .size = undefined };
    var bridge = TestBridge { .allocator = std.testing.allocator };
    defer bridge.deinit();
    var ast = try AsmAst.init(std.testing.allocator, &source_file, bridge.ast());
    defer ast.deinit(std.testing.allocator);
    std.debug.assert(bridge.errors.items.len == 0);

    var ir = try AsmIr.init(std.testing.allocator, &source_file, &ast, bridge.ir());
    defer ir.deinit(std.testing.allocator);

    if (errors.len != bridge.errors.items.len) {
        for (bridge.errors.items) |err|
            try err.write(&stderr.interface);
    }

    try std.testing.expectEqual(errors.len, bridge.errors.items.len);
    for (errors, 0..) |err, i| try std.testing.expectEqual(err, bridge.errors.items[i].err);
}

test "@section" {
    try testIrGen("@section foo", &.{});
    try testIrGen("@section", &.{ error.Expected });
    try testIrGen("@section 5", &.{ error.Expected });
    try testIrGen("@section 5, foo", &.{ error.Expected });
    try testIrGen("@section foo, bar", &.{ error.Unexpected, error.Note });
    try testIrGen("@section foo, 5", &.{ error.Unexpected, error.Note });
    try testIrGen("@barrier", &.{ error.Barrier });
    try testIrGen("@section(noelimination) foo", &.{});
    try testIrGen("@section(entrypoint) foo", &.{});
    try testIrGen("@section(noelimination, entrypoint) foo", &.{});
    try testIrGen("@section(bar) foo", &.{ error.InvalidOption });
    try testIrGen("@section(entrypoint, entrypoint) foo", &.{ error.DuplicateOption });
}

test "@barrier" {
    try testIrGen("@section foo\n@barrier", &.{});
    try testIrGen("@section foo\n@barrier xd", &.{ error.Unexpected, error.Note });
    try testIrGen("@section foo\n@barrier(noelimination)", &.{});
    try testIrGen("@section foo\n@header foo\n@end\n@barrier", &.{});
}

test "@header" {
    try testIrGen("@header foo\n@end", &.{});
    try testIrGen("@header\n@end", &.{ error.Expected });
    try testIrGen("@header 5\n@end", &.{ error.Expected });
    try testIrGen("@header foo, xd\n@end", &.{});
    try testIrGen("@header foo, foo\n@end", &.{ error.DuplicateSymbol, error.NoteDefinedHere });
    try testIrGen("@header foo, xd, xd\n@end", &.{ error.DuplicateSymbol, error.NoteDefinedHere });
    try testIrGen("@header(expose) foo\n@end", &.{});
    try testIrGen("@header foo\n@header bar\n@end\n@end", &.{ error.Illegal, error.NoteDefinedHere });
}

test "@import" {
    try testIrGen("@import foo, \"bar\"", &.{});
    try testIrGen("@import foo", &.{ error.Expected });
    try testIrGen("@import", &.{ error.Expected });
    try testIrGen("@import foo, \"bar\" 0", &.{ error.UselessSentinel });
    try testIrGen("@import foo, \"bar\", xd", &.{ error.Unexpected, error.Note });
    try testIrGen("@import(expose) foo, \"bar\"", &.{});
}

test "@define" {
    try testIrGen("@define foo, bar", &.{});
    try testIrGen("@define", &.{ error.Expected });
    try testIrGen("@define foo", &.{ error.Expected });
    try testIrGen("@define(expose) foo, bar", &.{});
    try testIrGen("@define foo, 5 + 3", &.{});
    try testIrGen("@define(noelimination) foo, bar", &.{ error.InvalidOption });
    try testIrGen("@define foo, bar, roo", &.{ error.Unexpected, error.Note });
}

test "@err" {
    try testIrGen("@section root\n@err foo", &.{});
    try testIrGen("@section root\n@err \"foo\"", &.{});
    try testIrGen("@section root\n@err \"foo\" 0", &.{ error.UselessSentinel });
    try testIrGen("@section root\n@err bar", &.{});
    try testIrGen("@section root\n@err bar, roo", &.{});
    try testIrGen("@section root\n@err bar, roo, 5 + 3", &.{});
}

test "@if" {
    try testIrGen("@section root\n@if xd\n@end", &.{});
    try testIrGen("@section root\n@if\n@end", &.{ error.Expected });
    try testIrGen("@section root\n@if xd, xd\n@end", &.{ error.Unexpected, error.Note });
    try testIrGen("@section root\n@if xd\n@else\n@end", &.{});
    try testIrGen("@section root\n@if xd\n@else foo\n@end", &.{ error.Unexpected, error.Note });
}

test "labels" {
    try testIrGen("@section root\npublic:", &.{});
    try testIrGen("@section root\n_local:", &.{});
    try testIrGen("@section root\n.private:", &.{});
    try testIrGen("@section root\n_:", &.{});
    try testIrGen("@section root\n._:", &.{ error.InvalidLabelType });
    try testIrGen("@section root\n_local:", &.{});
    try testIrGen("@section root\n._internal_private:", &.{}); // disallow this?

    try testIrGen(
        \\@section root
        \\.bar:
    , &.{});

    try testIrGen(
        \\@header foo
        \\bar:
        \\.roo:
        \\@end
    , &.{});

    try testIrGen(
        \\@header foo
        \\_bar:
        \\@end
    , &.{ error.InvalidLabelType, error.Note });
}

test "duplication" {
    try testIrGen(
        \\@define foo, 5 + 3
        \\@define(expose) foo, xd
    , &.{ error.DuplicateSymbol, error.NoteDefinedHere });

    try testIrGen(
        \\@define foo, 5 + 3
        \\@section root
        \\foo:
    , &.{ error.DuplicateSymbol, error.NoteDefinedHere });

    try testIrGen(
        \\@section root
        \\foo:
        \\foo:
    , &.{});

    try testIrGen(
        \\@section root
        \\foo:
        \\_foo:
    , &.{ error.MismatchedSymbolLocality, error.NoteDefinedHere });

    try testIrGen(
        \\@section root
        \\.foo:
        \\_foo:
    , &.{ error.MismatchedSymbolLocality, error.NoteDefinedHere });

    try testIrGen(
        \\@section root
        \\.foo:
        \\@section root
        \\_foo:
    , &.{ error.DuplicateSymbol, error.NoteDefinedHere, error.MismatchedSymbolLocality, error.NoteDefinedHere });

    try testIrGen(
        \\@section root
        \\_:
        \\_:
        \\_:
    , &.{});

    try testIrGen(
        \\@section root
        \\foo:
        \\@section root
        \\foo:
    , &.{ error.DuplicateSymbol, error.NoteDefinedHere, error.Note });

    try testIrGen(
        \\@section root
        \\foo.roo:
        \\@section root
        \\foo.bar:
    , &.{ error.DuplicateSymbol, error.NoteDefinedHere, error.Note });

    try testIrGen(
        \\@section root
        \\foo.roo:
        \\foo.bar:
    , &.{});

    try testIrGen(
        \\@section root
        \\_foo:
        \\@section root
        \\_foo:
    , &.{});

    try testIrGen(
        \\@header foo, xd
        \\@define roo, 5 + 3
        \\@end
        \\@header bar, xd
        \\@define roo, 5 + 3
        \\@end
    , &.{});

    try testIrGen(
        \\@define xd, 5 + 3
        \\@header bar, xd
        \\@end
    , &.{ error.DuplicateSymbol, error.NoteDefinedHere });

    try testIrGen(
        \\@header bar
        \\@define roo, 5 + 3
        \\@end
        \\@section text
        \\@define roo, 5 + 3
    , &.{ error.DuplicateSymbol, error.NoteDefinedHere });

    try testIrGen(
        \\@header bar, doo
        \\@define roo, 5 + 3
        \\@end
        \\@section text
        \\roo:
        \\doo:
    , &.{ error.DuplicateSymbol, error.NoteDefinedHere, error.DuplicateSymbol, error.NoteDefinedHere });
}
