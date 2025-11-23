
// Intermediate Representation

const std = @import("std");
const SourceLocation = @import("SourceLocation.zig");
const AsmTokeniser = @import("AsmTokeniser.zig");
const AsmAst = @import("AsmAst.zig");
const AsmSemanticAir = @import("AsmSemanticAir.zig");
const Token = @import("Token.zig");

const AsmIr = @This();

blocks: []const *Block,
link_info: []const LinkInfo,
/// Map of all the symbols created in this source location. Symbols in header
/// definitions are also included, as well as a symbol to the header definition
/// itself.
symbols: std.StringHashMapUnmanaged(Symbol),

/// Ingests the Abstract Syntax Tree and initialises IrGen which lowers the Ast
/// into statically-analysed intermediate representation.
pub fn init(
    allocator: std.mem.Allocator,
    source_location: *const SourceLocation,
    tree: *const AsmAst,
    bridge: Bridge
) !AsmIr {
    var ir_gen = IrGen.init(allocator, source_location, tree, bridge);
    defer ir_gen.deinit();
    errdefer ir_gen.destroy();

    try ir_gen.lower_tree();

    return .{
        .blocks = try ir_gen.blocks.toOwnedSlice(allocator),
        .link_info = try ir_gen.link_info.toOwnedSlice(allocator),
        .symbols = ir_gen.symbols };
}

pub fn deinit(self: *AsmIr, allocator: std.mem.Allocator) void {
    for (self.blocks) |block|
        block.deinit(allocator);
    allocator.free(self.blocks);
    for (self.link_info) |*info|
        info.deinit(allocator);
    allocator.free(self.link_info);
    self.symbols.deinit(allocator);
}

pub fn dump(self: *AsmIr, _: std.mem.Allocator, writer: anytype) !void {
    var iterator = self.symbols.iterator();

    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        const symbol = entry.value_ptr;
        try writer.print("@define{s} {s} {any}\n", .{
            if (symbol.privacy == .public) "(expose)" else "",
            name,
            symbol.ty });
    }

    for (self.blocks) |block| {
        try writer.print("{s} {s}\n", .{ block.ty_keyword(), block.name });

        for (block.content.items, 0..) |ir, index| {
            try writer.print("  {} {s} {any}\n", .{ index, @tagName(ir.ty), ir.ty });
        }
    }
}

pub const Bridge = struct {

    const AllocatorError = std.mem.Allocator.Error;

    const ImportError = error {
        SelfImport,
        SemanticsNotSupported
    } || SourceLocation.InitError;

    vtable: VTable,
    context: *anyopaque,

    pub const VTable = struct {
        emit_error: *const fn (*anyopaque, SourceLocation.Error) AllocatorError!void,
        flag: *const fn (*anyopaque, []const u8) ?i32,
        import: *const fn (*anyopaque, []const u8) ImportError!Index
    };

    fn emit_error(self: *Bridge, err: SourceLocation.Error) !void {
        return try self.vtable.emit_error(self.context, err);
    }

    fn flag(self: *Bridge, name: []const u8) ?i32 {
        return self.vtable.flag(self.context, name);
    }

    fn import(self: *Bridge, file_path: []const u8) !Index {
        return try self.vtable.import(self.context, file_path);
    }
};

/// A tiny sketch of the data architecture:
///
/// symbol table -> block (label)          for triggering lazy analysis)
/// symbol table -> block / header (label) for symbol look-up and triggering lazy analysis)
/// symbol table -> linkinfo (label)       for linkinfo
/// symbol table -> block (offset)         namespace for triggering lazy analysis)
/// symbol table -> block (header)         for header unrolling)
/// symbol table -> macro (define)         for expression evaluation)
/// symbol table -> file (import)          for file traversal
/// symbol table register, non-look-up (arguments)
///
/// headers may not have local macros, apart from its arguments
/// headers' argument bindings are managed in sema, but duplicate defines in the file are managed here
/// label/offsets can be duplicate if owned by the same block, otherwise errors (single lazy analysis)
/// sema's emit_label/offset checks for duplicates after @if evaluation when doing rel. addr. resolving
/// linker checks for undefined labels during resolution as a result of conditional evaluation
///
/// block -> ir
///
/// ir -> label name -> resolved rel. addr. for linking
/// ir -> base/offset name -> resolved rel. addr. for linking
pub const Symbol = struct {

    token: Token,
    ty: Type,
    privacy: Privacy,

    pub const Privacy = enum {
        public,
        private
    };

    pub const Macro = union(enum) {
        expression: AsmAst.Index,
        static: i32
    };

    pub const LinkInfoReference = struct {
        /// Index into link_info
        li: Index,
        ty: SymType,

        pub const SymType = enum { virt, phys, size, len };
    };

    pub const Type = union(enum) {
        /// A macro.
        /// token: the name
        macro: Macro,
        /// A header.
        /// token: the name
        /// index: block index
        /// asserts .ty == .header
        header: Index,
        /// A label defined within a @section or @header. (Only first.)
        /// token: the label
        /// index: block index
        label: Index,
        /// A base offset defined within a @section or @header. (Only first.)
        /// token: the offset (to indicate the base addr)
        /// index: block index
        base_offset: Index,
        /// A label defined within a @section or @header referencing a header.
        /// The referenced header is included, unlike an .label symbol.
        /// token: the label
        /// block: block index
        /// header: node of the @header call
        header_label: struct {
            block: Index,
            header: Index
        },
        /// A linkinfo definition (e.g. placement).
        /// token: the @linkinfo
        /// ref: index into link_info
        linkinfo: LinkInfoReference,
        /// A (successfully) imported file as namespace.
        /// token: the namespace
        /// index: file index
        import: Index,
        /// Non-traversable symbol, but must be kept to reserve a symbol name.
        reserved
    };
};

pub const LinkInfo = struct {

    token: Token,
    ty: Type,

    pub const SectionPlacement = struct {

        section: []const u8,          // .section (virtual)
        ld_phys_label: []const u8,    // .physical_section
        ld_sections_size: []const u8, // .section_size
        ld_sections_len: []const u8,  // @section_len (constant)
        expression: AsmAst.Index,

        pub fn init(
            allocator: std.mem.Allocator,
            section: []const u8,
            expression: AsmAst.Index
        ) !SectionPlacement {
            const ld_phys_label = try std.fmt.allocPrint(allocator, "physical_{s}", .{ section });
            errdefer allocator.free(ld_phys_label);

            const ld_sections_size = try std.fmt.allocPrint(allocator, "{s}_size", .{ section });
            errdefer allocator.free(ld_sections_size);

            const ld_sections_len = try std.fmt.allocPrint(allocator, "{s}_len", .{ section });
            errdefer allocator.free(ld_sections_len);

            return .{
                .section = section,
                .ld_phys_label = ld_phys_label,
                .ld_sections_size = ld_sections_size,
                .ld_sections_len = ld_sections_len,
                .expression = expression };
        }

        pub fn deinit(self: *const SectionPlacement, allocator: std.mem.Allocator) void {
            allocator.free(self.ld_phys_label);
            allocator.free(self.ld_sections_size);
            allocator.free(self.ld_sections_len);
        }
    };

    pub const Tag = enum {
        phys,
        origin,
        @"align"
    };

    pub const Type = union(Tag) {
        phys: AsmAst.Index,
        origin: SectionPlacement,
        @"align": SectionPlacement
    };

    pub fn deinit(self: *const LinkInfo, allocator: std.mem.Allocator) void {
        switch (self.ty) {
            .origin, .@"align" => |*placement| placement.deinit(allocator),
            .phys => {}
        }
    }
};

pub const Block = struct {

    /// @section or @header
    token: Token,
    name: []const u8,
    ty: Type,
    content: std.ArrayListUnmanaged(Ir) = .empty,
    is_conditional: bool = false,

    pub const Type = union(enum) {
        section: struct {
            is_entrypoint: bool = false,
            is_noelimination: bool
        },
        /// argument: the range of arguments (identifiers), which are
        /// guaranteed to be unique in this file
        header: AsmAst.IndexRange
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
        allocator.destroy(self);
    }

    pub fn ty_keyword(self: *const Block) []const u8 {
        return switch (self.ty) {
            .section => "@section",
            .header => "@header"
        };
    }

    pub fn add_len(self: *Block, begin_index: Index) void {
        const end_index: Index = @intCast(self.content.items.len);
        const len = end_index - begin_index - 1; // exclusive

        switch (self.content.items[begin_index].ty) {
            inline .@"if", .region => |*scope| scope.body_len = len,
            .@"else" => |*scope| scope.* = len,
            else => unreachable
        }
    }
};

pub const Ir = struct {

    token: Token,
    ty: Type,

    pub const Type = union(enum) {
        /// token: @align
        /// argument: constant alignment expression
        @"align": AsmAst.Index,
        /// token: @alignop
        /// argument: constant alignment expression
        alignop: AsmAst.Index,
        /// token: @err
        /// argument[0]: guaranteed to be the message node
        /// argument: the range of @err arguments
        err: AsmAst.IndexRange,
        /// token: @if
        /// expression: constant expression to be evaluated
        /// body_len: length of scoped IR instructions
        @"if": struct {
            expression: AsmAst.Index,
            body_len: AsmAst.Index,
        },
        /// token: @else
        /// argument: length of scoped IR instructions
        @"else": AsmAst.Index,
        /// token: @region
        /// expression: constant size expression
        /// body_len: length of scoped IR instructions
        region: struct {
            expression: AsmAst.Index,
            body_len: AsmAst.Index
        },
        /// token: the instruction
        /// argument: the range of arguments
        instruction: AsmAst.IndexRange,
        /// token; @header identifier
        /// argument: the range of header arguments
        header: AsmAst.IndexRange,
        /// token: the reserve instruction
        /// type_expression: type-resolving expression
        /// len_expression: constant len expression
        reserve: struct {
            type_expression: AsmAst.Index,
            len_expression: AsmAst.Index
        },
        /// token: the ascii instruction
        /// argument: the string expression
        ascii: AsmAst.Index,
        /// token: the (private) label
        label,
        /// token: the discarding label (value '_', public)
        discard_label,
        /// token: the namespace
        /// offset: offset identifier token
        base_offset: AsmAst.Index
    };
};

pub const Index = u32;

pub fn Iterator(comptime T: type) type {
    return struct {

        const IteratorType = @This();

        host: *T,
        start: AsmAst.Index,
        end: AsmAst.Index,
        cursor: AsmAst.Index = 0,

        pub fn init(host: *T, index_range: AsmAst.IndexRange) IteratorType {
            return .{
                .host = host,
                .start = index_range.lhs,
                .end = index_range.rhs };
        }

        pub fn index(self: *const IteratorType) AsmAst.Index {
            return self.start + self.cursor;
        }

        pub fn is_end(self: *const IteratorType) bool {
            return self.index() == self.end;
        }

        pub fn range(self: *const IteratorType) AsmAst.IndexRange {
            return .{ .lhs = self.index(), .rhs = self.end };
        }

        pub fn next(self: *IteratorType) AsmAst.Index {
            const idx = self.index();
            if (!self.is_end()) self.cursor += 1;
            return idx;
        }

        pub fn maybe(self: *IteratorType) ?AsmAst.Index {
            return if (!self.is_end()) self.next() else null;
        }

        pub fn expect_index(
            self: *IteratorType,
            tag: AsmAst.Node.Tag,
            context_token: Token
        ) !?AsmAst.Index {
            if (self.is_end()) {
                try self.host.add_error(error.Expected, context_token, "{s} expects {s}", .{ context_token.tag.fmt(), tag.fmt() });
                return null;
            }

            return self.expect_or_end_index(tag, context_token);
        }

        pub fn expect(
            self: *IteratorType,
            tag: AsmAst.Node.Tag,
            context_token: Token
        ) !?AsmAst.Node {
            return if (try self.expect_index(tag, context_token)) |idx|
                self.host.tree.nodes[idx] else
                null;
        }

        pub fn expect_or_end_index(
            self: *IteratorType,
            tag: AsmAst.Node.Tag,
            context_token: Token
        ) !?AsmAst.Index {
            if (self.is_end())
                return null;
            const node = self.host.tree.nodes[self.index()];

            if (node.tag != tag) {
                const token = self.host.tree.tokens[node.token];
                try self.host.add_error(error.Expected, token, "{s} expects {s}, found {s}", .{ context_token.tag.fmt(), tag.fmt(), token.tag.fmt() });
                return null;
            }

            return self.next();
        }

        pub fn expect_or_end(
            self: *IteratorType,
            tag: AsmAst.Node.Tag,
            context_token: Token
        ) !?AsmAst.Node {
            return if (try self.expect_or_end_index(tag, context_token)) |idx|
                self.host.tree.nodes[idx] else
                null;
        }

        pub fn expect_any(self: *IteratorType, context_token: Token) !?AsmAst.Index {
            return self.maybe() orelse {
                try self.host.add_error(error.Expected, context_token, "{s} expects an expression", .{ context_token.tag.fmt() });
                return null;
            };
        }

        pub fn expect_end(self: *IteratorType) !void {
            if (!self.is_end()) {
                const node = self.host.tree.nodes[self.index()];
                const token = self.host.tree.tokens[node.token];
                const s = if (self.cursor == 1) "" else "s";
                try self.host.add_error(error.Unexpected, token, "unexpectedly got {s}", .{ token.tag.fmt() });
                try self.host.add_error(error.Note, token, "expected {} argument{s}, found {}", .{ self.cursor, s, self.end - self.start });
            }
        }
    };
}

const IrGen = struct {

    allocator: std.mem.Allocator,
    source_location: *const SourceLocation,
    tree: *const AsmAst,
    bridge: Bridge,

    blocks: std.ArrayListUnmanaged(*Block) = .empty,
    link_info: std.ArrayListUnmanaged(LinkInfo) = .empty,
    link_sections: std.StringHashMapUnmanaged(Token) = .empty,
    symbols: std.StringHashMapUnmanaged(Symbol) = .empty,
    imports: std.AutoHashMapUnmanaged(AsmIr.Index, Token) = .empty,
    current_block_idx: ?Index = null,
    /// Only sections, not header blocks. It assumes header definitions cannot
    /// be nested.
    current_section_idx: ?Index = null,

    pub fn init(
        allocator: std.mem.Allocator,
        source_location: *const SourceLocation,
        tree: *const AsmAst,
        bridge: Bridge
    ) IrGen {
        return .{
            .allocator = allocator,
            .source_location = source_location,
            .tree = tree,
            .bridge = bridge };
    }

    pub fn deinit(self: *IrGen) void {
        self.blocks.deinit(self.allocator);
        self.link_info.deinit(self.allocator);
        self.link_sections.deinit(self.allocator);
        self.imports.deinit(self.allocator);
    }

    /// Like deinit, but destroys the owned memory for error events.
    pub fn destroy(self: *IrGen) void {
        for (self.blocks.items) |block|
            block.deinit(self.allocator);
        for (self.link_info.items) |*info|
            info.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
    }

    pub const Error = error {
        Expected,
        Unexpected,
        InvalidOption,
        Barrier,
        InvalidSymbol,
        DuplicateSymbol,
        MismatchedPrivacy,
        PrivateDiscardLabel,
        UselessSentinel,
        ImportFailed,
        DuplicateImport,
        SectionOnly,
        NotConditional,
        FirstEntrypoint,
        Inconsistent,
        DuplicateSectionInfo,
        NoteDefinedHere,
        NoteReason,
        Note
    };

    fn add_error(
        self: *IrGen,
        comptime err: Error,
        token: Token,
        comptime format: []const u8,
        arguments: anytype
    ) !void {
        @branchHint(.cold);

        const message = try std.fmt.allocPrint(self.allocator, format, arguments);
        errdefer self.allocator.free(message);

        const is_note = switch (err) {
            error.NoteDefinedHere,
            error.NoteReason,
            error.Note => true,
            else => false
        };

        try self.bridge.emit_error(.{
            .err = err,
            .token = token,
            .source_location = self.source_location,
            .is_note = is_note,
            .is_preview = err != error.Note,
            .message = message });
    }

    const ParseError = std.mem.Allocator.Error;

    pub fn lower_tree(self: *IrGen) ParseError!void {
        std.debug.assert(self.tree.tokens.len > 0);
        std.debug.assert(self.tree.nodes.len > 0);
        const root_node = self.tree.nodes[0];
        std.debug.assert(root_node.tag == .container);

        for (root_node.operands.lhs..root_node.operands.rhs) |node_idx| {
            const node = self.tree.nodes[node_idx];
            AsmAst.assert(node.tag == .builtin);

            const builtin = self.get_builtin(node);

            switch (builtin.token.tag) {
                .builtin_section => try self.lower_new_block(builtin),
                .builtin_barrier => try self.lower_copy_block(builtin),
                .builtin_header => try self.lower_header_block(builtin),

                .builtin_buildinfo => try self.emit_build_info(builtin),
                .builtin_define => try self.emit_define(builtin),
                .builtin_import => try self.emit_import(builtin),
                .builtin_linkinfo => try self.emit_link_info(builtin),

                // nothing to do at root
                .builtin_align,
                .builtin_alignop,
                .builtin_else,
                .builtin_entrypoint,
                .builtin_err,
                .builtin_if,
                .builtin_offset,
                .builtin_region => AsmAst.failure(),

                // transparent in the AST
                .builtin_end => AsmAst.failure(),

                // non-builtin tokens shouldn't be in node tags
                else => AsmAst.failure()
            }
        }
    }

    const Builtin = struct {
        token: Token,
        arguments: AsmAst.IndexRange,
        options: AsmAst.IndexRange,
        payload: AsmAst.IndexRange
    };

    fn get_builtin(self: *IrGen, node: AsmAst.Node) Builtin {
        AsmAst.assert(node.tag == .builtin);
        AsmAst.assert(self.tree.is_null_or(node.operands.lhs, .container));
        const arguments = self.tree.optional_range(node.operands.lhs);
        AsmAst.assert(self.tree.is_null_or(node.operands.rhs, .composite));
        const composite = self.tree.unwrap(node.operands.rhs);

        const options: AsmAst.IndexRange,
        const payload: AsmAst.IndexRange = if (composite) |the_composite| blk: {
            AsmAst.assert(self.tree.is_null_or(the_composite.operands.lhs, .container));
            AsmAst.assert(self.tree.is_null_or(the_composite.operands.rhs, .container));

            break :blk .{
                self.tree.optional_range(the_composite.operands.lhs),
                self.tree.optional_range(the_composite.operands.rhs) };
        } else .{ .none, .none };

        const token = self.tree.tokens[node.token];
        AsmAst.assert(token.tag.is_builtin_opaque() or AsmAst.is_empty(payload)); // non-opaques must not have an opaque

        return .{
            .token = token,
            .arguments = arguments,
            .options = options,
            .payload = payload };
    }

    fn identifier_list(
        self: *IrGen,
        comptime T: type,
        range: AsmAst.IndexRange,
        context_token: Token
    ) !T {
        var iterator = Iterator(IrGen).init(self, range);
        var options: T = .{};

        options: while (!iterator.is_end()) {
            const node = try iterator.expect(.identifier, context_token) orelse {
                _ = iterator.next();
                continue :options;
            };
            const token = self.tree.tokens[node.token];
            const option = self.source_location.content(token);

            inline for (@typeInfo(T).@"struct".fields) |field| {
                if (std.mem.eql(u8, field.name, option)) {
                    if (@field(options, field.name))
                        try self.add_error(error.InvalidOption, token, "duplicate option '{s}'", .{ option });
                    @field(options, field.name) = true;
                    continue :options;
                }
            }

            try self.add_error(error.InvalidOption, token, "invalid option '{s}'", .{ option });
        }

        return options;
    }

    fn add_block(
        self: *IrGen,
        token: Token,
        name: []const u8,
        ty: Block.Type
    ) !void {
        const new_block = try Block.init(self.allocator, token, name, ty);
        errdefer new_block.deinit(self.allocator);

        const index: AsmIr.Index = @intCast(self.blocks.items.len);
        try self.blocks.append(self.allocator, new_block);
        errdefer comptime unreachable;

        if (new_block.ty == .section)
            self.current_section_idx = index;
        self.current_block_idx = index;
    }

    fn current_block(self: *const IrGen) ?*Block {
        return if (self.current_block_idx) |block_index|
            self.blocks.items[block_index] else
            null;
    }

    fn current_section(self: *const IrGen) ?*Block {
        return if (self.current_section_idx) |idx|
            self.blocks.items[idx] else
            null;
    }

    fn header(self: *const IrGen) ?*Block {
        return if (self.current_block()) |block|
            if (block.ty == .header) block else null else
            null;
    }

    const SectionOptions = struct {
        noelimination: bool = false
    };

    fn lower_new_block(self: *IrGen, builtin: Builtin) !void {
        std.debug.assert(builtin.token.tag == .builtin_section);

        const options = try self.identifier_list(SectionOptions, builtin.options, builtin.token);
        var iterator = Iterator(IrGen).init(self, builtin.arguments);

        const name_node = try iterator.expect(.identifier, builtin.token) orelse return;
        try iterator.expect_end();

        const name_token = self.tree.tokens[name_node.token];
        const name = self.source_location.content(name_token);
        const ty: Block.Type = .{ .section = .{ .is_noelimination = options.noelimination } };

        try self.add_block(name_token, name, ty);
        try self.lower_opaque_tree(builtin.payload, .none);
    }

    fn lower_copy_block(self: *IrGen, builtin: Builtin) !void {
        std.debug.assert(builtin.token.tag == .builtin_barrier);

        const options = try self.identifier_list(SectionOptions, builtin.options, builtin.token);
        var iterator = Iterator(IrGen).init(self, builtin.arguments);
        try iterator.expect_end();

        const existing_block = self.current_section() orelse {
            try self.add_error(error.Barrier, builtin.token, "@barrier must be defined after at least one @section", .{});
            return;
        };
        const noelimination = options.noelimination or existing_block.ty.section.is_noelimination;
        const ty: Block.Type = .{ .section = .{ .is_noelimination = noelimination } };

        try self.add_block(builtin.token, existing_block.name, ty);
        try self.lower_opaque_tree(builtin.payload, .none);
    }

    const MacroOptions = struct {
        expose: bool = false
    };

    fn lower_header_block(self: *IrGen, builtin: Builtin) !void {
        std.debug.assert(builtin.token.tag == .builtin_header);

        const options = try self.identifier_list(MacroOptions, builtin.options, builtin.token);
        var iterator = Iterator(IrGen).init(self, builtin.arguments);

        const name_node = try iterator.expect(.identifier, builtin.token) orelse return;
        const arguments = iterator.range();

        const name_token = self.tree.tokens[name_node.token];
        const name = self.source_location.content(name_token);
        const ty: Block.Type = .{ .header = arguments };
        const block_index: AsmIr.Index = @intCast(self.blocks.items.len);

        try self.add_block(name_token, name, ty);

        while (try iterator.expect_or_end(.identifier, builtin.token)) |argument_node| {
            const argument_token = self.tree.tokens[argument_node.token];
            const argument_name = self.source_location.content(argument_token);
            try self.add_symbol(argument_name, .{
                .token = argument_token,
                .ty = .reserved,
                .privacy = .private }, .unique);
        }

        try self.add_symbol(name, .{
            .token = name_token,
            .ty = .{ .header = block_index },
            .privacy = if (options.expose) .public else .private }, .unique);
        try self.lower_opaque_tree(builtin.payload, .none);
        self.current_block_idx = self.current_section_idx; // restore last block
    }

    const LinkInfoOptions = packed struct {

        const Bits = @typeInfo(LinkInfoOptions).@"struct".backing_integer.?;

        phys: bool = false,
        origin: bool = false,
        @"align": bool = false,
        expose: bool = false,

        pub fn instructions(self: LinkInfoOptions) usize {
            var instructions_len = @popCount(@as(Bits, @bitCast(self)));
            if (self.expose) instructions_len -= 1; // expose is not a link instruction
            return instructions_len;
        }

        pub fn link_info(self: LinkInfoOptions) LinkInfo.Tag {
            if (self.phys) return .phys;
            if (self.origin) return .origin;
            if (self.@"align") return .@"align";
            unreachable;
        }
    };

    fn emit_link_info(self: *IrGen, builtin: Builtin) !void {
        std.debug.assert(builtin.token.tag == .builtin_linkinfo);

        const options = try self.identifier_list(LinkInfoOptions, builtin.options, builtin.token);
        const instructions_len = options.instructions();
        var iterator = Iterator(IrGen).init(self, builtin.arguments);

        if (instructions_len != 1)
            return try self.add_error(error.Expected, builtin.token, "expected 1 link instruction, found {}", .{ instructions_len });
        const ty = options.link_info();
        const privacy: Symbol.Privacy = if (options.expose) .public else .private;

        switch (ty) {
            .phys => {
                if (privacy == .public)
                    try self.add_error(error.InvalidOption, builtin.token, "'expose' is not valid for link instruction 'phys'", .{});
                const expr_node = try iterator.expect_any(builtin.token) orelse return;
                try iterator.expect_end();
                try self.link_info.append(self.allocator, .{
                    .token = builtin.token,
                    .ty = .{ .phys = expr_node } });
            },

            .origin => try self.emit_link_info_placement("origin", builtin.token, &iterator, privacy),
            .@"align" => try self.emit_link_info_placement("align", builtin.token, &iterator, privacy)
        }
    }

    fn emit_link_info_placement(
        self: *IrGen,
        comptime union_type: []const u8,
        token: Token,
        iterator: *Iterator(IrGen),
        privacy: Symbol.Privacy
    ) !void {
        const section_node = try iterator.expect(.identifier, token) orelse return;
        const expr_node = try iterator.expect_any(token) orelse return;
        try iterator.expect_end();

        const section_token = self.tree.tokens[section_node.token];
        const section = self.source_location.content(section_token);
        const info_index: Index = @intCast(self.link_info.items.len);

        if (self.link_sections.get(section)) |existing_token| {
            try self.add_error(error.DuplicateSectionInfo, section_token, "section '{s}' placed multiple times", .{ section });
            try self.add_error(error.NoteDefinedHere, existing_token, "previously placed here", .{});
            return; // otherwise duplicate symbol errors will also occur
        }

        try self.link_sections.put(self.allocator, section, section_token);
        try self.link_info.ensureUnusedCapacity(self.allocator, 1);

        const placement = try LinkInfo.SectionPlacement.init(self.allocator, section, expr_node);

        // this list now manages deinit for placement
        self.link_info.appendAssumeCapacity(.{
            .token = token,
            .ty = @unionInit(LinkInfo.Type, union_type, placement) });
        for (&[_]struct { []const u8, Symbol.LinkInfoReference.SymType } {
            .{ placement.section, .virt },
            .{ placement.ld_phys_label, .phys },
            .{ placement.ld_sections_size, .size },
            .{ placement.ld_sections_len, .len }
        }) |li| {
            try self.add_symbol(li[0], .{
                .token = token,
                .ty = .{ .linkinfo = .{ .li = info_index, .ty = li[1] } },
                .privacy = privacy }, .unique);
        }
    }

    fn lower_opaque_tree(self: *IrGen, range: AsmAst.IndexRange, cond_reason: CondReason) ParseError!void {
        blk: for (range.lhs..range.rhs) |node_idx| {
            const node = self.tree.nodes[node_idx];

            switch (node.tag) {
                .builtin => {
                    const builtin = self.get_builtin(node);

                    switch (builtin.token.tag) {
                        .builtin_align, .builtin_alignop => try self.emit_align(builtin),
                        .builtin_err => try self.emit_assembletime_err(builtin),
                        .builtin_offset => try self.emit_offset(builtin),

                        .builtin_region => {
                            const block, const region_index = self.create_region(builtin) catch |err| switch (err) {
                                error.AnalysisFail => continue :blk,
                                else => |the_err| return the_err
                            };
                            try self.lower_opaque_tree(builtin.payload, cond_reason);
                            block.add_len(region_index);
                        },

                        .builtin_if => {
                            const new_cond_reason: CondReason = switch (cond_reason) {
                                .none => .{ .assembletime_cond = builtin.token },
                                .assembletime_cond => cond_reason
                            };
                            const block, const if_index = self.create_if_scope(builtin) catch |err| switch (err) {
                                error.AnalysisFail => continue :blk,
                                else => |the_err| return the_err
                            };
                            try self.lower_opaque_tree(builtin.payload, new_cond_reason);
                            block.add_len(if_index);
                        },

                        .builtin_else => {
                            const new_cond_reason: CondReason = switch (cond_reason) {
                                .none => .{ .assembletime_cond = builtin.token },
                                .assembletime_cond => cond_reason
                            };
                            const block, const else_index = try self.create_else_scope(builtin);
                            try self.lower_opaque_tree(builtin.payload, new_cond_reason);
                            block.add_len(else_index);
                        },

                        // conditional builtins
                        .builtin_buildinfo => {
                            try self.maybe_emit_header_error(builtin.token);
                            try self.maybe_emit_conditional_error(cond_reason, builtin.token);
                            try self.emit_build_info(builtin);
                        },
                        .builtin_define => {
                            try self.maybe_emit_header_error(builtin.token);
                            try self.maybe_emit_conditional_error(cond_reason, builtin.token);
                            try self.emit_define(builtin);
                        },
                        .builtin_entrypoint => {
                            try self.maybe_emit_header_error(builtin.token);
                            try self.mark_entrypoint(builtin);
                        },
                        .builtin_header => {
                            try self.maybe_emit_header_error(builtin.token);
                            try self.lower_header_block(builtin);
                        },
                        .builtin_linkinfo => {
                            try self.maybe_emit_conditional_error(cond_reason, builtin.token);
                            try self.maybe_emit_header_error(builtin.token);
                            try self.emit_link_info(builtin);
                        },

                        // by convention, imports are always at root
                        .builtin_import,
                        // nothing to do at opaque level
                        .builtin_barrier,
                        .builtin_section => AsmAst.failure(),

                        // transparent in the AST
                        .builtin_end => AsmAst.failure(),

                        // non-builtin tokens shouldn't be in node tags
                        else => AsmAst.failure()
                    }
                },

                .instruction => try self.emit_instruction(node),
                .label => try self.emit_label(node),

                // other tokens are illegal
                else => AsmAst.failure()
            }
        }
    }

    const CondReason = union(enum) {
        none,
        assembletime_cond: Token
    };

    fn maybe_emit_conditional_error(self: *IrGen, cond_reason: CondReason, token: Token) !void {
        if (cond_reason == .none) return;
        try self.add_error(error.NotConditional, token, "unable to evaluate {s} at assemble-time", .{ token.tag.fmt() });

        switch (cond_reason) {
            .none => unreachable, // returned above
            .assembletime_cond => |reason| try self.add_error(error.NoteReason, reason, "{s} enters conditional context", .{ reason.tag.fmt() })
        }
    }

    fn maybe_emit_header_error(self: *IrGen, token: Token) !void {
        if (self.header() == null) return;
        try self.add_error(error.SectionOnly, token, "{s} is illegal in header opaque", .{ token.tag.fmt() });
    }

    fn maybe_emit_sentinel_error(self: *IrGen, node: AsmAst.Node) !void {
        AsmAst.assert(node.tag == .string);
        const token = self.tree.tokens[node.token];

        AsmAst.assert(token.tag == .string_literal);
        AsmAst.assert(self.tree.is_null_or(node.operands.lhs, .integer));
        AsmAst.assert(node.operands.rhs == AsmAst.Null);

        if (node.operands.lhs != AsmAst.Null) {
            const sentinel_node = self.tree.nodes[node.operands.lhs];
            const sentinel_token = self.tree.tokens[sentinel_node.token];
            try self.add_error(error.UselessSentinel, sentinel_token, "unnecessary sentinel", .{});
        }
    }

    fn emit_build_info(self: *IrGen, builtin: Builtin) !void {
        std.debug.assert(builtin.token.tag == .builtin_buildinfo);

        const options = try self.identifier_list(MacroOptions, builtin.options, builtin.token);
        var iterator = Iterator(IrGen).init(self, builtin.arguments);

        const name_node = try iterator.expect(.identifier, builtin.token) orelse return;
        const flag_node = try iterator.expect(.identifier, builtin.token) orelse return;
        const default_expr_node = iterator.maybe();
        try iterator.expect_end();

        const name_token = self.tree.tokens[name_node.token];
        const name = self.source_location.content(name_token);
        const flag_token = self.tree.tokens[flag_node.token];
        const flag = self.source_location.content(flag_token);

        const macro: Symbol.Macro = if (self.bridge.flag(flag)) |value| blk: {
            break :blk .{ .static = value };
        } else if (default_expr_node) |node| blk: {
            break :blk .{ .expression = node };
        } else blk: {
            break :blk .{ .static = 0 };
        };

        try self.add_symbol(name, .{
            .token = name_token,
            .ty = .{ .macro = macro },
            .privacy = if (options.expose) .public else .private }, .unique);
    }

    fn emit_define(self: *IrGen, builtin: Builtin) !void {
        std.debug.assert(builtin.token.tag == .builtin_define);

        const options = try self.identifier_list(MacroOptions, builtin.options, builtin.token);
        var iterator = Iterator(IrGen).init(self, builtin.arguments);

        const name_node = try iterator.expect(.identifier, builtin.token) orelse return;
        const expr_node = try iterator.expect_any(builtin.token) orelse return;
        try iterator.expect_end();

        const name_token = self.tree.tokens[name_node.token];
        const name = self.source_location.content(name_token);

        try self.add_symbol(name, .{
            .token = name_token,
            .ty = .{ .macro = .{ .expression = expr_node } },
            .privacy = if (options.expose) .public else .private }, .unique);
    }

    fn emit_import(self: *IrGen, builtin: Builtin) !void {
        std.debug.assert(builtin.token.tag == .builtin_import);

        const options = try self.identifier_list(MacroOptions, builtin.options, builtin.token);
        var iterator = Iterator(IrGen).init(self, builtin.arguments);

        const namespace_node = try iterator.expect(.identifier, builtin.token) orelse return;
        const path_node = try iterator.expect(.string, builtin.token) orelse return;
        try iterator.expect_end();

        const namespace_token = self.tree.tokens[namespace_node.token];
        const namespace = self.source_location.content(namespace_token);
        const path_token = self.tree.tokens[path_node.token];
        const path = self.source_location.content(path_token);

        try self.maybe_emit_sentinel_error(path_node);

        const file_index = self.bridge.import(path) catch |err| return switch (err) {
            error.SelfImport => try self.add_error(error.ImportFailed, path_token, "import of self", .{}),
            error.SemanticsNotSupported => try self.add_error(error.ImportFailed, path_token, "semantics not supported for this file type", .{}),
            error.FileNotFound => try self.add_error(error.ImportFailed, path_token, "file not found", .{}),
            else => try self.add_error(error.ImportFailed, path_token, "failed to import file: {s}", .{ @errorName(err) })
        };

        const result = try self.imports.getOrPut(self.allocator, file_index);

        if (result.found_existing) {
            try self.add_error(error.DuplicateImport, path_token, "duplicated import of file", .{});
            try self.add_error(error.NoteDefinedHere, result.value_ptr.*, "previously imported here", .{});
        } else {
            result.value_ptr.* = path_token;
        }

        try self.add_symbol(namespace, .{
            .token = namespace_token,
            .ty = .{ .import = file_index },
            .privacy = if (options.expose) .public else .private }, .unique);
    }

    fn add_symbol(
        self: *IrGen,
        name: []const u8,
        symbol: Symbol,
        uniqueness: enum { unique, not_unique, block_unique }
    ) !void {
        if (name.len == 0 or name[0] == '@') {
            try self.add_error(error.InvalidSymbol, symbol.token, "invalid symbol name '{s}'", .{ name });
        }

        const existing_symbol = self.symbols.get(name) orelse
            return try self.symbols.put(self.allocator, name, symbol);
        const is_error = switch (uniqueness) {
            .unique => true,
            .not_unique => false,
            .block_unique => switch (symbol.ty) {
                .label => |bi| !(existing_symbol.ty == .label and bi == existing_symbol.ty.label),
                .base_offset => |bi| !(existing_symbol.ty == .base_offset and bi == existing_symbol.ty.base_offset),
                else => true
            }
        };

        if (is_error) {
            try self.add_error(error.DuplicateSymbol, symbol.token, "duplicate symbol '{s}'", .{ name });
            try self.add_error(error.NoteDefinedHere, existing_symbol.token, "previously declared here", .{});
        }

        if (uniqueness == .block_unique) {
            const is_block_mismatch = switch (symbol.ty) {
                .label => |bi| (existing_symbol.ty == .label and bi != existing_symbol.ty.label),
                .base_offset => |bi| (existing_symbol.ty == .base_offset and bi != existing_symbol.ty.base_offset),
                else => false
            };

            if (is_error and is_block_mismatch) {
                try self.add_error(error.Note, symbol.token, "conditionally-dependent symbols must reside in the same block", .{});
            }

            if (symbol.privacy != existing_symbol.privacy) {
                try self.add_error(error.MismatchedPrivacy, symbol.token, "conditionally-dependent symbols have mismatching privacies", .{});
                try self.add_error(error.NoteDefinedHere, existing_symbol.token, "initially declared {s} here", .{ @tagName(existing_symbol.privacy) });
            }
        }
    }

    const Encoding = enum {
        reserve,
        ascii,
        __none
    };

    fn emit_instruction(self: *IrGen, node: AsmAst.Node) !void {
        std.debug.assert(node.tag == .instruction);
        AsmAst.assert(self.tree.is_null_or(node.operands.lhs, .container));
        AsmAst.assert(node.operands.rhs == AsmAst.Null);

        const token = self.tree.tokens[node.token];
        const encoding = std.meta.stringToEnum(Encoding, self.source_location.content(token)) orelse .__none;
        const block = self.current_block().?;
        const arguments = self.tree.optional_range(node.operands.lhs);
        var iterator = Iterator(IrGen).init(self, arguments);

        const instruction: Ir.Type = switch (token.tag) {
            .instruction => switch (encoding) {
                .reserve => blk: {
                    const type_expression = try iterator.expect_any(token) orelse return;
                    const len_expression = try iterator.expect_any(token) orelse return;
                    try iterator.expect_end();
                    break :blk .{ .reserve = .{
                        .type_expression = type_expression,
                        .len_expression = len_expression } };
                },
                .ascii => blk: {
                    const string = try iterator.expect_index(.string, token) orelse return;
                    try iterator.expect_end();
                    break :blk .{ .ascii = string };
                },
                .__none => .{ .instruction = arguments }
            },
            .identifier => .{ .header = arguments },
            else => AsmAst.failure()
        };

        try block.content.append(self.allocator, .{
            .token = token,
            .ty = instruction });
    }

    fn emit_label(self: *IrGen, node: AsmAst.Node) !void {
        std.debug.assert(node.tag == .label);
        AsmAst.assert(node.operands.lhs == AsmAst.Null);
        AsmAst.assert(node.operands.rhs == AsmAst.Null);

        const token = self.tree.tokens[node.token];
        const name = self.source_location.content(token);
        const block = self.current_block().?;
        const block_index = self.current_block_idx.?;

        const privacy: Symbol.Privacy = switch (token.tag) {
            .label => .public,
            .private_label => .private,
            else => AsmAst.failure()
        };

        // a so-called discarding label, to silence liveness
        // mostly only used by root sections
        const is_discarding = std.mem.eql(u8, name, "_");

        const ir: Ir.Type = if (!is_discarding)
            .label else
            .discard_label;
        if (is_discarding and privacy == .private) {
            try self.add_error(error.PrivateDiscardLabel, token, "discard label must not be private", .{});
        }

        try block.content.append(self.allocator, .{
            .token = token,
            .ty = ir });
        if (!is_discarding) {
            try self.add_symbol(name, .{
                .token = token,
                .ty = .{ .label = block_index },
                .privacy = privacy }, .block_unique);
        }
    }

    fn emit_offset(self: *IrGen, builtin: Builtin) !void {
        std.debug.assert(builtin.token.tag == .builtin_offset);

        const options = try self.identifier_list(MacroOptions, builtin.options, builtin.token);
        var iterator = Iterator(IrGen).init(self, builtin.arguments);

        const namespace_node = try iterator.expect(.identifier, builtin.token) orelse return;
        const offset_node = try iterator.expect(.identifier, builtin.token) orelse return;
        try iterator.expect_end();

        const namespace_token = self.tree.tokens[namespace_node.token];
        const namespace = self.source_location.content(namespace_token);
        const block = self.current_block().?;
        const block_index = self.current_block_idx.?;

        try block.content.append(self.allocator, .{
            .token = namespace_token,
            .ty = .{ .base_offset = offset_node.token } });
        try self.add_symbol(namespace, .{
            .token = namespace_token,
            .ty = .{ .base_offset = block_index },
            .privacy = if (options.expose) .public else .private }, .block_unique);
    }

    fn emit_align(self: *IrGen, builtin: Builtin) !void {
        _ = try self.identifier_list(struct {}, builtin.options, builtin.token);
        var iterator = Iterator(IrGen).init(self, builtin.arguments);

        const expr_node = try iterator.expect_any(builtin.token) orelse return;
        try iterator.expect_end();

        const ir: Ir.Type = switch (builtin.token.tag) {
            .builtin_align => .{ .@"align" = expr_node },
            .builtin_alignop => .{ .alignop = expr_node },
            else => AsmAst.failure()
        };
        const block = self.current_block().?;

        try block.content.append(self.allocator, .{
            .token = builtin.token,
            .ty = ir });
    }

    fn mark_entrypoint(self: *IrGen, builtin: Builtin) !void {
        std.debug.assert(builtin.token.tag == .builtin_entrypoint);

        _ = try self.identifier_list(struct {}, builtin.options, builtin.token);
        var iterator = Iterator(IrGen).init(self, builtin.arguments);
        try iterator.expect_end();

        const block = self.current_block().?;
        if (block.ty != .section) return;

        if (block.content.items.len > 0) {
            try self.add_error(error.FirstEntrypoint, builtin.token, "@entrypoint must appear as the first builtin in @section", .{});
        }

        block.ty.section.is_entrypoint = true;
    }

    fn emit_assembletime_err(self: *IrGen, builtin: Builtin) !void {
        std.debug.assert(builtin.token.tag == .builtin_err);

        _ = try self.identifier_list(struct {}, builtin.options, builtin.token);
        var iterator = Iterator(IrGen).init(self, builtin.arguments);

        const arguments = iterator.range();
        const message_node = try iterator.expect(.string, builtin.token) orelse return;

        try self.maybe_emit_sentinel_error(message_node);

        const block = self.current_block().?;

        try block.content.append(self.allocator, .{
            .token = builtin.token,
            .ty = .{ .err = arguments } });
    }

    fn create_region(self: *IrGen, builtin: Builtin) !struct { *Block, Index } {
        std.debug.assert(builtin.token.tag == .builtin_region);

        _ = try self.identifier_list(struct {}, builtin.options, builtin.token);
        var iterator = Iterator(IrGen).init(self, builtin.arguments);

        const expr_node = try iterator.expect_any(builtin.token) orelse return error.AnalysisFail;
        try iterator.expect_end();

        const block = self.current_block().?;
        const region_index: Index = @intCast(block.content.items.len);

        const ir_region: Ir.Type = .{ .region = .{
            .expression = expr_node,
            .body_len = 0 } };
        try block.content.append(self.allocator, .{
            .token = builtin.token,
            .ty = ir_region });
        return .{ block, region_index };
    }

    fn create_if_scope(self: *IrGen, builtin: Builtin) !struct { *Block, Index } {
        std.debug.assert(builtin.token.tag == .builtin_if);

        _ = try self.identifier_list(struct {}, builtin.options, builtin.token);
        var iterator = Iterator(IrGen).init(self, builtin.arguments);

        const expr_node = try iterator.expect_any(builtin.token) orelse return error.AnalysisFail;
        try iterator.expect_end();

        const block = self.current_block().?;
        const if_index: Index = @intCast(block.content.items.len);

        const ir_if: Ir.Type = .{ .@"if" = .{
            .expression = expr_node,
            .body_len = 0 } };
        try block.content.append(self.allocator, .{
            .token = builtin.token,
            .ty = ir_if });
        block.is_conditional = true;
        return .{ block, if_index };
    }

    fn create_else_scope(self: *IrGen, builtin: Builtin) !struct { *Block, Index } {
        std.debug.assert(builtin.token.tag == .builtin_else);

        _ = try self.identifier_list(struct {}, builtin.options, builtin.token);
        var iterator = Iterator(IrGen).init(self, builtin.arguments);
        try iterator.expect_end();

        const block = self.current_block().?;
        const else_index: Index = @intCast(block.content.items.len);

        try block.content.append(self.allocator, .{
            .token = builtin.token,
            .ty = .{ .@"else" = 0 } });
        return .{ block, else_index };
    }
};

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

    const astTable = AsmAst.Bridge.VTable {
        .emit_error = emit_error
    };

    const irTable = Bridge.VTable {
        .emit_error = emit_error,
        .flag = flag,
        .import = import
    };

    fn emit_error(context: *anyopaque, err: SourceLocation.Error) !void {
        const self: *TestBridge = @alignCast(@ptrCast(context));
        try self.errors.append(self.allocator, err);
    }

    fn flag(context: *anyopaque, name: []const u8) ?i32 {
        _ = context;
        _ = name;
        return 0xEA;
    }

    fn import(context: *anyopaque, file_path: []const u8) !Index {
        _ = context;
        _ = file_path;
        return error.FileNotFound;
    }

    pub fn ast(self: *TestBridge) AsmAst.Bridge {
        return .{ .vtable = astTable, .context = self };
    }

    pub fn ir(self: *TestBridge) Bridge {
        return .{ .vtable = irTable, .context = self };
    }
};

const stderr = std.io.getStdErr().writer();

fn testIrGen(input: [:0]const u8, errors: []const IrGen.Error) !void {
    const source_location = SourceLocation {
        .cwd = std.fs.cwd(),
        .file_name = "AsmIr.zig",
        .real_path = "Sources/AsmIr.zig",
        .buffer = input,
        .inode = undefined,
        .size = undefined };
    var bridge = TestBridge { .allocator = std.testing.allocator };
    defer bridge.deinit();
    var ast = try AsmAst.init(std.testing.allocator, &source_location, bridge.ast());
    defer ast.deinit(std.testing.allocator);
    std.debug.assert(bridge.errors.items.len == 0);

    var ir = try AsmIr.init(std.testing.allocator, &source_location, &ast, bridge.ir());
    defer ir.deinit(std.testing.allocator);

    if (build_options.dump and errors.len == 0)
        try ir.dump(std.testing.allocator, stderr);

    if (errors.len != bridge.errors.items.len) {
        for (bridge.errors.items) |err|
            try err.write(stderr);
    }

    try std.testing.expectEqual(errors.len, bridge.errors.items.len);
    for (errors, 0..) |err, i| try std.testing.expectEqual(err, bridge.errors.items[i].err);
}

test "sections" {
    try testIrGen("@section foo", &.{});
    try testIrGen("@section", &.{ error.Expected });
    try testIrGen("@section 5", &.{ error.Expected });
    try testIrGen("@section 5, foo", &.{ error.Expected });
    try testIrGen("@section foo, bar", &.{ error.Unexpected, error.Note });
    try testIrGen("@section foo, 5", &.{ error.Unexpected, error.Note });
    try testIrGen("@barrier", &.{ error.Barrier });
    try testIrGen("@section foo\n@barrier", &.{});
}

test "entrypoint" {
    try testIrGen(
        \\@section foo
        \\@align 2
        \\@entrypoint
    , &.{
        error.FirstEntrypoint
    });

    try testIrGen(
        \\@section foo
        \\@entrypoint
        \\@align 2
    , &.{});
}

test "symbols" {
    try testIrGen("@define foo, bar", &.{});
    try testIrGen("@define(foo) foo, bar", &.{ error.InvalidOption });
    try testIrGen("@define(5) foo, bar", &.{ error.Expected });
    try testIrGen("@define(expose) foo, bar", &.{});
    try testIrGen("@section foo\nhello: bkpt", &.{});
    try testIrGen("@define foo, 5\n@define foo, 3", &.{ error.DuplicateSymbol, error.NoteDefinedHere });

    try testIrGen(
        \\@define foo, 5
        \\@section foo
        \\.foo: bkpt
    , &.{
        error.DuplicateSymbol,
        error.NoteDefinedHere
    });
}

test "labels" {
    try testIrGen("@section foo\n.label:", &.{});
    try testIrGen("@section foo\n.label: .foo:", &.{});
    try testIrGen("@section foo\n.label: .label:", &.{});
    try testIrGen("@define label, 5\n@section foo\n.label:", &.{ error.DuplicateSymbol, error.NoteDefinedHere });

    try testIrGen(
        \\@section foo
        \\.label:
        \\@section bar
        \\.label:
    , &.{
        error.DuplicateSymbol,
        error.NoteDefinedHere,
        error.Note
    });

    try testIrGen(
        \\@section foo
        \\label:
        \\.label:
    , &.{
        error.MismatchedPrivacy,
        error.NoteDefinedHere
    });
}

test "headers" {
    try testIrGen("@header\n@end", &.{ error.Expected });
    try testIrGen("@header foo\n@end", &.{});
    try testIrGen("@header foo\n@header bar\n@end\n@end", &.{ error.SectionOnly });

    try testIrGen(
        \\@header Queue, len
        \\@end
        \\@define len, 5
    , &.{
        error.DuplicateSymbol,
        error.NoteDefinedHere
    });

    try testIrGen(
        \\@header Queue
        \\@define len, 5
        \\@end
        \\@define len, 5
    , &.{
        error.SectionOnly,
        error.DuplicateSymbol,
        error.NoteDefinedHere
    });

    try testIrGen(
        \\@header Queue
        \\@entrypoint
        \\@end
        \\@section foo
        \\@entrypoint
    , &.{
        error.SectionOnly
    });
}

test "imports" {
    try testIrGen("@import foo, \"hello-world.s\"", &.{ error.ImportFailed });
    try testIrGen("@import foo, \"hello-world.s\" 0", &.{ error.UselessSentinel, error.ImportFailed });
}

test "assembletime err" {
    try testIrGen("@section foo\n@err", &.{ error.Expected });
    try testIrGen("@section foo\n@err \"hello world\"", &.{});
    try testIrGen("@section foo\n@err \"hello world\" 0", &.{ error.UselessSentinel });
    try testIrGen("@section foo\n@err \"hello world\", arg, arg", &.{});
}

test "if/else" {
    try testIrGen("@section foo\n@if\n@end", &.{ error.Expected });
    try testIrGen("@section foo\n@if 1\n@end", &.{});

    try testIrGen(
        \\@section foo
        \\@if 1
        \\bkpt
        \\@end
    , &.{});

    try testIrGen(
        \\@section foo
        \\@if 0
        \\bkpt
        \\@else
        \\@end
    , &.{});

    try testIrGen(
        \\@section foo
        \\@if 0
        \\bkpt
        \\@else foo
        \\@end
    , &.{
        error.Unexpected,
        error.Note
    });
}

test "buildinfo" {
    try testIrGen("@buildinfo", &.{ error.Expected });
    try testIrGen("@buildinfo x, x, x, x", &.{ error.Unexpected, error.Note });
    try testIrGen("@buildinfo foo, bar, 0", &.{});

    try testIrGen(
        \\@buildinfo foo, bar, 0
        \\@define foo, 0
    , &.{
        error.DuplicateSymbol,
        error.NoteDefinedHere
    });
}

test "linkinfo" {
    try testIrGen("@linkinfo", &.{ error.Expected });
    try testIrGen("@linkinfo(expose)", &.{ error.Expected });
    try testIrGen("@linkinfo(phys)", &.{ error.Expected });
    try testIrGen("@linkinfo(phys) 0x0800", &.{});

    try testIrGen(
        \\@linkinfo(origin) foo, 0x0800
        \\@linkinfo(align) foo, 256
    , &.{
        error.DuplicateSectionInfo,
        error.NoteDefinedHere
    });

    try testIrGen(
        \\@linkinfo(origin) foo, 0x0800
        \\@define foo, @bar
        \\@define physical_foo, @bar
        \\@define foo_len, @bar
    , &.{
        error.DuplicateSymbol,
        error.NoteDefinedHere,
        error.DuplicateSymbol,
        error.NoteDefinedHere,
        error.DuplicateSymbol,
        error.NoteDefinedHere
    });
}
