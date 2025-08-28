
// Semantic Analysed Intermediate Representation

const std = @import("std");
const AsmAst = @import("AsmAst.zig");
const Error = @import("Error.zig");
const Qcu = @import("Qcu.zig");
const Source = @import("Source.zig");
const Token = @import("Token.zig");

const AsmSemanticAir = @This();

/// A semantic analyser can be initialised in 'freestanding' mode, which
/// removes any file context and coupling for testing by not depending on the
/// QCPU compilation unit.
qcu: ?*Qcu.File,
allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
source: Source,
nodes: []const AsmAst.Node,
/// Any symbol in the current unit, which includes namespaces for symbol
/// imports. May not be modified during semantic analysis.
symbols: SymbolMap,
sections: SectionMap,
/// Reference locations defined in the section's opaque. Their index refers to
/// the instruction location inside `content`, and not the final byte offset of
/// the section. Other semas can refence this. External references (from other
/// sections) are counted to perform dead code elimination.
references: ReferenceMap,
current_section: ?*Section,
emit_reference: ?*EmitReference,
link_info: LinkInfoList,
/// Only populated in freestanding.
errors: ErrorList,

/// Borrows a list of tokens and nodes, and guarantees its output not to have
/// any dependencies on these tokens and nodes. Tokens are copied when
/// necessary. The token/node lists may be freed after both semantic analysis
/// passes.
pub fn init(qcu: *Qcu.File, source: Source, nodes: []const AsmAst.Node) !AsmSemanticAir {
    var self = AsmSemanticAir {
        .qcu = qcu,
        .allocator = qcu.allocator,
        .arena = std.heap.ArenaAllocator.init(qcu.allocator),
        .source = source,
        .nodes = nodes,
        .symbols = .empty,
        .sections = .empty,
        .references = .empty,
        .current_section = null,
        .emit_reference = null,
        .link_info = .empty,
        .errors = .empty };
    errdefer self.deinit();
    try self.prepare_root();
    return self;
}

pub fn init_freestanding(allocator: std.mem.Allocator, source: Source, nodes: []const AsmAst.Node) !AsmSemanticAir {
    var self = AsmSemanticAir {
        .qcu = null,
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .source = source,
        .nodes = nodes,
        .symbols = .empty,
        .sections = .empty,
        .references = .empty,
        .current_section = null,
        .emit_reference = null,
        .link_info = .empty,
        .errors = .empty };
    errdefer self.deinit();
    try self.prepare_root();
    return self;
}

pub fn deinit(self: *AsmSemanticAir) void {
    self.symbols.deinit(self.allocator);
    for (self.sections.values()) |section|
        section.destroy_tree(self.allocator);
    self.sections.deinit(self.allocator);
    self.references.deinit(self.allocator);
    self.current_section = null;
    self.link_info.deinit(self.allocator);
    for (self.errors.items) |err|
        self.allocator.free(err.message);
    self.errors.deinit(self.allocator);
    self.arena.deinit();
}

pub fn dump(self: *AsmSemanticAir, writer: anytype) !void {
    for (self.sections.keys()) |section_name| {
        const section = self.sections.get(section_name) orelse unreachable;
        var dumping_section: ?*Section = section;
        try writer.print("@section {s} (align {})\n", .{ section_name, section.alignment });

        while (dumping_section) |dumping_section_| {
            for (dumping_section_.content.items(.instruction)) |instr| {
                switch (instr) {
                    inline else => |instr_| try writer.print("    {s}({}) : {}\n", .{
                        @tagName(instr),
                        instr.size(),
                        instr_ })
                }
            }

            if (dumping_section_.next) |next_dumping_section|
                try writer.print("@barrier (align {})\n", .{ next_dumping_section.alignment });
            dumping_section = dumping_section_.next;
        }
    }
}

pub const Symbol = union(enum) {

    pub const Locatable = struct {
        token: Token,
        symbol: Symbol,
        is_used: bool = false // to optimise liveness
    };

    label: Label,
    define: Define,
    header: Header,
    file: File,

    pub const Label = struct {
        instr_node: AsmAst.Index,
        is_public: bool
    };

    pub const Define = struct {
        value_node: AsmAst.Index,
        is_public: bool
    };

    pub const Header = struct {
        arguments: AsmAst.IndexRange,
        content: AsmAst.IndexRange,
        is_public: bool
    };

    pub const File = struct {
        path: []const u8,
        /// optional (1): unavailable (freestanding)
        /// pointer:      Qcu's sema field
        /// optional (2): whether file exists
        sema: ?*?AsmSemanticAir
    };

    pub fn is_public(self: Symbol) bool {
        return switch (self) {
            .file => false,
            inline else => |symbol| symbol.is_public
        };
    }
};

pub const Section = struct {

    token: Token,
    /// Grows with the use of @align to ensure the correct padding is calculated
    /// ahead-of-time.
    alignment: usize = 0,
    /// A boolean to indicate whether this section is allowed to be removed by
    /// unreachable-code-elimination.
    is_removable: bool = true,
    /// Opaque list of (pseudo)instructions.
    content: InstructionList = .empty,
    /// A section is allowed to be split by @barrier or duplicate @section
    /// tags, which links to a new, unnamed section.
    next: ?*Section = null,

    pub fn destroy_tree(self: *Section, allocator: std.mem.Allocator) void {
        if (self.next) |next|
            next.destroy_tree(allocator);
        self.content.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn append(self: *Section, new_section: *Section) void {
        if (self.next) |next_section|
            return next_section.append(new_section);
        self.next = new_section;
    }

    pub fn size(self: *Section) usize {
        var address: usize = 0;
        for (self.content.items(.instruction)) |instruction|
            address += instruction.size();
        return address;
    }
};

pub const Reference = struct {

    /// Index of section opaque's instruction this reference references. If
    /// undefined, it hasn't been indexed yet by the sema.
    instruction_index: u32 = undefined,
    section: *Section = undefined
};

pub const EmitReference = struct {

    const Scope = struct {
        symbols: SymbolMap,
        previous: ?*Scope
    };

    calling_token: ForeignToken,
    section: *Section,
    scope: ?*Scope,

    pub fn init(allocator: std.mem.Allocator, calling_token: ForeignToken, section: *Section) !*EmitReference {
        const emit_reference = try allocator.create(EmitReference);
        emit_reference.* = .{
            .calling_token = calling_token,
            .section = section,
            .scope = null };
        return emit_reference;
    }

    pub fn deinit(self: *EmitReference, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    pub fn push_scope(self: *EmitReference, allocator: std.mem.Allocator, symbols: SymbolMap) !void {
        const scope = try allocator.create(Scope);
        scope.* = .{
            .symbols = symbols,
            .previous = self.scope };
        self.scope = scope;
    }

    pub fn pop_scope(self: *EmitReference, allocator: std.mem.Allocator) void {
        const popped_scope = self.scope;
        self.scope = popped_scope.?.previous;
        allocator.destroy(popped_scope.?);
    }
};

/// @linkinfo(key) subject, value
/// @linkinfo key, value
pub const LinkInfo = struct {

    const Action = enum {
        origin,
        @"align"
    };

    const action_map = std.StaticStringMap(Action).initComptime(.{
        .{ "origin", .origin },
        .{ "align", .@"align" }
    });

    token: Token,
    key: []const u8,
    subject: ?[]const u8 = null,
    value: u32,

    pub fn action(self: *const LinkInfo) ?Action {
        return action_map.get(self.key);
    }

    pub fn is_valid(self: *const LinkInfo) bool {
        return switch (self.action().?) {
            .origin,
            .@"align" => self.subject != null
        };
    }
};

const SymbolMap = std.StringArrayHashMapUnmanaged(Symbol.Locatable);
const SectionMap = std.StringArrayHashMapUnmanaged(*Section);
const InstructionList = std.MultiArrayList(Instruction.Locatable);
const ReferenceMap = std.StringArrayHashMapUnmanaged(Reference);
const ReferenceTrackList = std.ArrayListUnmanaged(Reference.ReferenceTrack);
const ErrorList = std.ArrayListUnmanaged(Error);
const LinkInfoList = std.ArrayListUnmanaged(LinkInfo);
const SemanticAirMap = std.StringArrayHashMapUnmanaged(*AsmSemanticAir);

/// SemanticAir will assume certain state generated by AstGen, and asserts them
/// for debugging purposes. If an assumption is not met, SemanticAir will
/// panic.
fn astgen_assert(ok: bool) void {
    if (!ok) unreachable;
}

fn astgen_failure() noreturn {
    unreachable;
}

/// To calculate alignment.
fn find_available_mask(from_address: usize, mask: usize) usize {
    std.debug.assert(std.math.isPowerOfTwo(mask));
    return (from_address + mask -% 1) & ~(mask -% 1);
}

fn node_is_null_or(self: *AsmSemanticAir, index: AsmAst.Index, tag: AsmAst.Node.Tag) bool {
    return index == AsmAst.Null or self.nodes[index].tag == tag;
}

fn node_is(self: *AsmSemanticAir, index: AsmAst.Index, tag: AsmAst.Node.Tag) bool {
    return index != AsmAst.Null and self.nodes[index].tag == tag;
}

fn node_len(self: *AsmSemanticAir, index: AsmAst.Index) ?u32 {
    if (!node_is(index, .container))
        return null;
    const node = self.nodes[index];
    return node.operands.rhs - node.operands.lhs;
}

fn not_null(index: AsmAst.Index) bool {
    return index != AsmAst.Null;
}

fn is_null(index: AsmAst.Index) bool {
    return index == AsmAst.Null;
}

fn node_unwrap(self: *AsmSemanticAir, index: AsmAst.Index) ?AsmAst.Node {
    return if (not_null(index)) self.nodes[index] else null;
}

fn is_valid_symbol(self: *AsmSemanticAir, string: []const u8) bool {
    _ = self;
    const is_define_or_header = std.mem.startsWith(u8, string, "@");
    const is_label = std.mem.startsWith(u8, string, ".");
    return (is_define_or_header or is_label) and string.len > 1;
}

const ContainerIterator = struct {

    sema: *AsmSemanticAir,
    cursor: AsmAst.Index,
    start: AsmAst.Index,
    end: AsmAst.Index,
    context_token: ?Token = null,

    pub fn init(sema: *AsmSemanticAir, node: AsmAst.Node) ContainerIterator {
        return .{
            .sema = sema,
            .cursor = 0,
            .start = node.operands.lhs,
            .end = node.operands.rhs };
    }

    pub fn init_range(sema: *AsmSemanticAir, range: AsmAst.IndexRange) ContainerIterator {
        return .{
            .sema = sema,
            .cursor = 0,
            .start = range.lhs,
            .end = range.rhs };
    }

    pub fn init_index(sema: *AsmSemanticAir, index: AsmAst.Index) ContainerIterator {
        if (index == AsmAst.Null)
            return .{ .sema = sema, .cursor = 0, .start = 0, .end = 0 };
        const node = sema.nodes[index];
        return ContainerIterator.init(sema, node);
    }

    pub fn init_index_context(sema: *AsmSemanticAir, index: AsmAst.Index, context_token: Token) ContainerIterator {
        var iterator = ContainerIterator.init_index(sema, index);
        iterator.context_token = context_token;
        return iterator;
    }

    pub fn expect_empty(sema: *AsmSemanticAir, index: AsmAst.Index, context_token: Token) !void {
        var iterator = ContainerIterator.init_index_context(sema, index, context_token);
        try iterator.expect_end();
    }

    fn is_the_end(self: *ContainerIterator) bool {
        return self.current() == self.end or self.start == self.end;
    }

    fn current(self: *ContainerIterator) AsmAst.Index {
        return self.start + self.cursor;
    }

    fn current_token(self: *ContainerIterator) Token {
        const node = self.sema.nodes[self.current()];
        return self.sema.source.tokens[node.token];
    }

    pub fn left(self: *ContainerIterator) AsmAst.Index {
        return self.end - self.current();
    }

    pub fn next_index(self: *ContainerIterator) AsmAst.Index {
        const index = self.current();
        self.cursor += 1;
        return index;
    }

    pub fn next(self: *ContainerIterator) ?AsmAst.Node {
        if (self.is_the_end())
            return null;
        return self.sema.nodes[self.next_index()];
    }

    pub fn expect(self: *ContainerIterator, tag: AsmAst.Node.Tag) !?AsmAst.Node {
        if (self.is_the_end()) {
            if (self.context_token) |context_token_|
                try self.sema.add_error(error.ExpectedContext, .{ tag, context_token_ }) else
                try self.sema.add_error(error.ExpectedEmpty, tag);
            return null;
        } else if (self.sema.nodes[self.current()].tag != tag) {
            try self.sema.add_error(error.Expected, .{ tag, self.current_token() });
            return null;
        }
        return self.next();
    }

    pub fn gracefully_expect(self: *ContainerIterator, tag: AsmAst.Node.Tag) !?AsmAst.Node {
        if (self.is_the_end())
            return null;
        if (self.sema.nodes[self.current()].tag != tag) {
            try self.sema.add_error(error.Expected, .{ tag, self.current_token() });
            return null;
        }
        return self.next();
    }

    pub fn expect_any(self: *ContainerIterator) !?AsmAst.Index {
        if (self.is_the_end()) {
            const str = Token.string("an argument");
            if (self.context_token) |context_token_|
                try self.sema.add_error(error.ExpectedContext, .{ str, context_token_ }) else
                try self.sema.add_error(error.ExpectedEmpty, str);
            return null;
        }

        _ =  self.next();
        return self.current() - 1;
    }

    pub fn expect_end(self: *ContainerIterator) !void {
        if (!self.is_the_end())
            try self.sema.add_error(error.Unexpected, self.current_token());
    }
};

const SemanticError = error {
    Expected,
    ExpectedContext,
    ExpectedEmpty,
    ExpectedElsewhere,
    Unexpected,
    UnsupportedOption,
    UselessSentinel,
    DuplicateSymbol,
    AlignPowerTwo,
    RegionExceedsSize,
    MissingBarrierContext,
    NonEmptyModifier,
    UnknownModifiedInstruction,
    UnknownInstruction,
    ExpectedArgumentsLen,
    AmbiguousIdentifier,
    UnknownSymbol,
    Namespace,
    NamespacePrivateSymbol,
    NonConformingSymbol,
    ImportNotFound,
    IllegalUnaryOp,
    UnlinkableToken,
    UnlinkableExpression,
    ResultType,
    HeaderResultType,
    HeaderContextIllegal,
    HeaderDuplicateParameter,
    AddressResolutionUnsigned,
    AddressResolutionOverflow,
    NoteDefinedHere,
    NoteCalledFromHere,
    NoteDidYouMean,
    Generic,
    GenericToken
};

fn add_error(self: *AsmSemanticAir, comptime err: SemanticError, argument: anytype) !void {
    @branchHint(.cold);

    const message = switch (err) {
        error.Expected,
        error.ExpectedElsewhere => "expected {s}, found {s}",
        error.ExpectedContext => "expected {s} in {s}",
        error.ExpectedEmpty => "expected {s}",
        error.Unexpected => "unexpectedly got {s}",
        error.UnsupportedOption => "unsupported option: {s}",
        error.UselessSentinel => "useless sentinel",
        error.DuplicateSymbol => "duplicate symbol '{s}'",
        error.AlignPowerTwo => "alignment of {} is not a power of two",
        error.RegionExceedsSize => "region of opaque size {} exceeds fixed region of {} bytes",
        error.MissingBarrierContext => "@barrier must be defined in a @section context",
        error.NonEmptyModifier => "an empty modifier value is required, but {s} was used",
        error.UnknownModifiedInstruction => "instruction {s} doesn't support a modifier",
        error.UnknownInstruction => "unknown instruction in the QCPU instruction set",
        error.ExpectedArgumentsLen => "expected {} {s} for instruction {s}, found {}",
        error.AmbiguousIdentifier => "ambiguous identifier; did you mean @{s}?",
        error.UnknownSymbol => "unknown symbol '{s}'",
        error.Namespace => "namespace '{s}' cannot be expanded",
        error.NamespacePrivateSymbol => "symbol is marked private in its namespace",
        error.NonConformingSymbol => "{s} is not of type similar to {s}",
        error.ImportNotFound => "file to import not found",
        error.IllegalUnaryOp => "illegal {s} operation with {s}",
        error.UnlinkableToken => "{s} is not supported in a linkable result type",
        error.UnlinkableExpression => "expression is unlinkable",
        error.ResultType => "numeric literal doesn't fit in result type {s}",
        error.HeaderResultType => "a @header call isn't supported in result type",
        error.HeaderContextIllegal => "{s} in a header context is considered illegal",
        error.HeaderDuplicateParameter => "duplicate header argument '{s}'",
        error.AddressResolutionUnsigned => "address resolved to {} but instruction doens't permit signed addresses",
        error.AddressResolutionOverflow => "resolved address of {} doesn't fit in {s} type",
        error.NoteDefinedHere => "{s} defined here",
        error.NoteCalledFromHere => "called from here",
        error.NoteDidYouMean => "did you mean to {s}{s}?",
        error.Generic,
        error.GenericToken => "{s}{s}"
    };

    const is_note = switch (err) {
        error.NoteDefinedHere,
        error.NoteCalledFromHere,
        error.NoteDidYouMean => true,
        else => false
    };

    const token: ?Token = switch (err) {
        error.ExpectedArgumentsLen,
        error.NonConformingSymbol => argument[0],
        error.Expected,
        error.ExpectedContext,
        error.DuplicateSymbol,
        error.AlignPowerTwo,
        error.NonEmptyModifier,
        error.ResultType,
        error.IllegalUnaryOp,
        error.AddressResolutionUnsigned,
        error.NoteDefinedHere => argument[1],
        error.ExpectedElsewhere,
        error.RegionExceedsSize,
        error.AddressResolutionOverflow,
        error.NoteDidYouMean,
        error.GenericToken => argument[2],
        error.Unexpected,
        error.UnsupportedOption,
        error.UselessSentinel,
        error.UnknownModifiedInstruction,
        error.UnknownInstruction,
        error.AmbiguousIdentifier,
        error.UnknownSymbol,
        error.Namespace,
        error.NamespacePrivateSymbol,
        error.ImportNotFound,
        error.MissingBarrierContext,
        error.UnlinkableToken,
        error.UnlinkableExpression,
        error.HeaderResultType,
        error.HeaderContextIllegal,
        error.HeaderDuplicateParameter,
        error.NoteCalledFromHere => argument,
        else => null
    };
    const token_location = if (token) |token_|
        self.source.location_of(token_.location) else
        null;
    const token_slice = if (token) |token_|
        token_.location.slice(self.source.buffer) else
        null;
    const arguments = switch (err) {
        error.Expected,
        error.ExpectedContext => .{ argument[0].fmt(), argument[1].tag.fmt() },
        error.ExpectedElsewhere => .{ argument[0].fmt(), argument[1].fmt() },
        error.ExpectedEmpty => .{ argument.fmt() },
        error.Unexpected,
        error.HeaderContextIllegal,
        error.UnlinkableToken => .{ argument.tag.fmt() },
        error.UnsupportedOption,
        error.UnknownModifiedInstruction,
        error.AmbiguousIdentifier,
        error.UnknownSymbol,
        error.HeaderDuplicateParameter,
        error.Namespace => .{ token_slice.? },
        error.UselessSentinel,
        error.UnknownInstruction,
        error.NamespacePrivateSymbol,
        error.ImportNotFound,
        error.MissingBarrierContext,
        error.UnlinkableExpression,
        error.HeaderResultType,
        error.NoteCalledFromHere => .{},
        error.NonConformingSymbol => .{ argument[0].tag.fmt(), argument[1].tag.fmt() },
        error.DuplicateSymbol,
        error.AlignPowerTwo,
        error.NonEmptyModifier,
        error.ResultType,
        error.AddressResolutionUnsigned => .{ argument[0] },
        error.RegionExceedsSize,
        error.NoteDidYouMean,
        error.GenericToken,
        error.AddressResolutionOverflow => .{ argument[0], argument[1] },
        error.ExpectedArgumentsLen => blk: {
            const plural = if (argument[1] != 1) "arguments" else "argument";
            break :blk .{ argument[1], plural, token_slice.?, argument[2] };
        },
        error.IllegalUnaryOp => .{ argument[0], argument[1].tag.fmt() },
        error.NoteDefinedHere => .{ argument[0].fmt() },
        else => argument
    };

    const format = try std.fmt.allocPrint(self.allocator, message, arguments);
    errdefer self.allocator.free(format);

    const err_data = Error {
        .id = err,
        .token = token,
        .is_note = is_note,
        .message = format,
        .location = token_location };
    if (self.qcu) |qcu|
        try qcu.add_error(err_data) else
        try self.errors.append(self.allocator, err_data);
}

fn prepare_root(self: *AsmSemanticAir) !void {
    astgen_assert(self.nodes.len > 0);
    astgen_assert(self.nodes[0].tag == .container);
    try self.prepare_opaque_container(self.nodes[0], &self.symbols);
}

fn prepare_opaque_container(self: *AsmSemanticAir, parent_node: AsmAst.Node, symbol_map: *SymbolMap) !void {
    for (parent_node.operands.lhs..parent_node.operands.rhs) |node_idx| {
        const node = self.nodes[node_idx];
        const token = self.source.tokens[node.token];

        switch (node.tag) {
            .builtin => {
                astgen_assert(self.node_is_null_or(node.operands.lhs, .container));
                astgen_assert(self.node_is(node.operands.rhs, .composite));
                const composite = self.nodes[node.operands.rhs];
                astgen_assert(self.node_is_null_or(composite.operands.lhs, .container));
                astgen_assert(self.node_is_null_or(composite.operands.rhs, .container));

                switch (token.tag) {
                    .builtin_define,
                    .builtin_header,
                    .builtin_import => {
                        const symbol = switch (token.tag) {
                            .builtin_define => try self.prepare_define(node),
                            // header content not prepared yet
                            .builtin_header => try self.prepare_header(node),
                            .builtin_import => try self.prepare_import(node),
                            else => unreachable
                        } orelse continue;

                        try self.maybe_emit_duplicate_error(symbol);
                        try symbol_map.put(self.allocator, symbol.name, .{
                            .token = symbol.token,
                            .symbol = symbol.symbol });
                    },

                    .builtin_region,
                    .builtin_section,
                    .builtin_barrier => {
                        if (self.node_unwrap(composite.operands.rhs)) |opaque_|
                            try self.prepare_opaque_container(opaque_, symbol_map);
                    },

                    .builtin_linkinfo => try self.emit_prepare_linkinfo(node),

                    // nothing to do here
                    .builtin_align => {},

                    // transparent in the AST
                    .builtin_end => astgen_failure(),

                    // non-builtin tokens shouldn't be in node tags
                    else => astgen_failure()
                }
            },

            .instruction => {
                astgen_assert(self.node_is_null_or(node.operands.lhs, .container));
                astgen_assert(self.node_is_null_or(node.operands.rhs, .composite));

                if (is_null(node.operands.rhs))
                    continue;
                const composite = self.nodes[node.operands.rhs];
                astgen_assert(self.node_is_null_or(composite.operands.lhs, .container));
                astgen_assert(self.node_is_null_or(composite.operands.rhs, .modifier));

                if (is_null(composite.operands.lhs))
                    continue;
                var labels = ContainerIterator.init_index(self, composite.operands.lhs);

                // fixme: labels in headers are not supported
                while (try labels.gracefully_expect(.label)) |label_node| {
                    astgen_assert(is_null(label_node.operands.lhs));
                    astgen_assert(is_null(label_node.operands.rhs));

                    const label = try self.prepare_label(label_node, @intCast(node_idx)) orelse continue;
                    try self.maybe_emit_duplicate_error(label);
                    try symbol_map.put(self.allocator, label.name, .{
                        .token = label.token,
                        .symbol = label.symbol });
                }
            },

            else => astgen_failure()
        }
    }
}

const NamedSymbol = struct {
    name: []const u8,
    token: Token,
    symbol: Symbol
};

fn maybe_emit_duplicate_error(self: *AsmSemanticAir, symbol: NamedSymbol) !void {
    if (self.symbols.get(symbol.name)) |existing_symbol| {
        try self.add_error(error.DuplicateSymbol, .{ symbol.name, symbol.token });
        try self.add_error(error.NoteDefinedHere, .{ Token.string("previously"), existing_symbol.token });
    }
}

fn maybe_emit_sentinel_error(self: *AsmSemanticAir, sentinel_index: AsmAst.Index) !void {
    astgen_assert(self.node_is_null_or(sentinel_index, .integer));
    if (sentinel_index != AsmAst.Null) {
        const sentinel_node = self.nodes[sentinel_index];
        const sentinel_token = self.source.tokens[sentinel_node.token];
        try self.add_error(error.UselessSentinel, sentinel_token);
    }
}

fn maybe_emit_nonempty_modifier_error(self: *AsmSemanticAir, token: Token) !void {
    astgen_assert(token.tag == .modifier);
    const string = token.location.slice(self.source.buffer);
    if (string.len > 1)
        try self.add_error(error.NonEmptyModifier, .{ string, token });
}

fn emit_resolved_expected_error(
    self: *AsmSemanticAir,
    expected_token: anytype,
    origin_token: ForeignToken,
    resolved_token: Token
) !void {
    try self.add_error(error.ExpectedElsewhere, .{ expected_token, resolved_token.tag, origin_token.token });
    if (!origin_token.token.location.eql(resolved_token.location))
        try self.add_error(error.NoteDefinedHere, .{ resolved_token.tag, resolved_token });
}

fn emit_resolved_error(
    self: *AsmSemanticAir,
    comptime err: SemanticError,
    origin_token: ForeignToken,
    resolved_token: Token,
    argument: anytype
) !void {
    try self.add_error(err, argument);
    if (!origin_token.token.location.eql(resolved_token.location))
        try origin_token.sema.add_error(error.NoteCalledFromHere, origin_token.token);
}

fn emit_header_error(
    self: *AsmSemanticAir,
    emit_reference: *const EmitReference,
    token: Token
) !void {
    // kind of an unnecessary error as the AST handles section/barriers, but in
    // case something ever changes in that regard
    try self.add_error(error.HeaderContextIllegal, token);
    try emit_reference.calling_token.sema.add_error(error.NoteCalledFromHere, emit_reference.calling_token.token);
}

// fixme: remove
fn emit_resolved_generic_error(
    self: *AsmSemanticAir,
    message: anytype,
    topic: anytype,
    origin_token: ForeignToken,
    resolved_token: Token
) !void {
    try origin_token.sema.add_error(error.GenericToken, .{ message, topic, origin_token.token });
    if (!origin_token.token.location.eql(resolved_token.location))
        try self.add_error(error.NoteDefinedHere, .{ resolved_token.tag, resolved_token });
}

fn prepare_define(self: *AsmSemanticAir, node: AsmAst.Node) !?NamedSymbol {
    const composite = self.nodes[node.operands.rhs];
    const options_ = if (self.node_unwrap(composite.operands.lhs)) |options_|
        try self.parse_options(options_, &.{ .expose }) else
        null;
    defer self.free_options(options_);
    const define_token = self.source.tokens[node.token];
    var arguments = ContainerIterator.init_index_context(self, node.operands.lhs, define_token);

    const name_node = try arguments.expect(.identifier) orelse return null;
    const name_token = self.source.tokens[name_node.token];
    const name = name_token.location.slice(self.source.buffer);

    const value_node = try arguments.expect_any() orelse return null;

    try arguments.expect_end();
    astgen_assert(is_null(composite.operands.rhs));

    const define = Symbol.Define {
        .value_node = value_node,
        .is_public = self.contains_option(options_, .expose) };
    return .{
        .name = name,
        .token = define_token,
        .symbol = .{ .define = define } };
}

fn prepare_header(self: *AsmSemanticAir, node: AsmAst.Node) !?NamedSymbol {
    const composite = self.nodes[node.operands.rhs];
    const options_ = if (self.node_unwrap(composite.operands.lhs)) |options_|
        try self.parse_options(options_, &.{ .expose }) else
        null;
    defer self.free_options(options_);
    const header_token = self.source.tokens[node.token];
    var arguments = ContainerIterator.init_index_context(self, node.operands.lhs, header_token);

    const name_node = try arguments.expect(.identifier) orelse return null;
    const name_token = self.source.tokens[name_node.token];
    const name = name_token.location.slice(self.source.buffer);

    while (try arguments.gracefully_expect(.identifier) != null) {}
    astgen_assert(self.node_is_null_or(composite.operands.rhs, .container));

    const header = Symbol.Header {
        .arguments = .{
            .lhs = arguments.start + 1, // skip name
            .rhs = arguments.end },
        .content = if (not_null(composite.operands.rhs))
            self.nodes[composite.operands.rhs].operands else
            .{},
        .is_public = self.contains_option(options_, .expose) };
    return .{
        .name = name,
        .token = header_token,
        .symbol = .{ .header = header } };
}

fn prepare_import(self: *AsmSemanticAir, node: AsmAst.Node) !?NamedSymbol {
    const composite = self.nodes[node.operands.rhs];
    if (self.node_unwrap(composite.operands.lhs)) |options_|
        _ = try self.parse_options(options_, &.{});
    const import_token = self.source.tokens[node.token];
    var arguments = ContainerIterator.init_index_context(self, node.operands.lhs, import_token);

    const namespace_node = try arguments.expect(.identifier) orelse return null;
    const namespace = self.source.tokens[namespace_node.token].location.slice(self.source.buffer);

    const path_string_node = try arguments.expect(.string) orelse return null;
    const path_string_token = self.source.tokens[path_string_node.token];
    const path_string = path_string_token.content_slice(self.source.buffer);
    astgen_assert(path_string_token.tag == .string_literal);
    try self.maybe_emit_sentinel_error(path_string_node.operands.lhs);

    astgen_assert(is_null(composite.operands.rhs));
    try arguments.expect_end();

    const sema = if (self.qcu) |qcu| qcu.resolve(path_string) catch |err| switch (err) {
        error.FileNotFound => blk: {
            try self.add_error(error.ImportNotFound, path_string_token);
            break :blk null;
        },
        else => |err_| return err_
    } else null;

    const file = Symbol.File {
        .path = path_string,
        .sema = sema };
    return .{
        .name = namespace,
        .token = import_token,
        .symbol = .{ .file = file } };
}

const linkinfo_subject_options = [_]Option { .origin, .@"align" };

fn emit_prepare_linkinfo(self: *AsmSemanticAir, node: AsmAst.Node) !void {
    const composite = self.nodes[node.operands.rhs];
    const options_ = if (self.node_unwrap(composite.operands.lhs)) |options_|
        try self.parse_options(options_, &linkinfo_subject_options) else
        null;
    defer self.free_options(options_);
    const linkinfo_token = self.source.tokens[node.token];
    var arguments = ContainerIterator.init_index_context(self, node.operands.lhs, linkinfo_token);

    const name_node = try arguments.expect(.identifier) orelse return;
    const name_token = self.source.tokens[name_node.token];
    const name = name_token.location.slice(self.source.buffer);

    const value_node = try arguments.expect(.integer) orelse return;
    const value = try self.cast_numeric_literal(u32, value_node) orelse return;

    try arguments.expect_end();
    astgen_assert(is_null(composite.operands.rhs));

    if (options_) |the_options| {
        try self.link_info.ensureUnusedCapacity(self.allocator, the_options.len);

        for (the_options) |the_option|
            self.link_info.appendAssumeCapacity(.{
                .token = linkinfo_token,
                .key = @tagName(the_option),
                .subject = name,
                .value = value });
    } else {
        try self.link_info.append(self.allocator, .{
            .token = linkinfo_token,
            .key = name,
            .value = value });
    }

    // fixme: return section symbol to allow .text and .globals references.
    // allow them to be published with @define(expose) _text, .text
}

const Option = enum {
    expose,
    noelimination,
    origin,
    @"align"
};

const options_map = std.StaticStringMap(Option).initComptime(.{
    .{ "expose", .expose },
    .{ "noelimination", .noelimination },
    .{ "origin", .origin },
    .{ "align", .@"align" }
});

/// If the allow list is empty, it's guaranteed that there's no need to call
/// free on the returned slice.
fn parse_options(self: *AsmSemanticAir, node: AsmAst.Node, allow_list: []const Option) ![]const Option {
    astgen_assert(node.tag == .container);
    const len = node.operands.rhs - node.operands.lhs;

    var options_ = try std
        .ArrayList(Option)
        .initCapacity(self.allocator, @min(len, allow_list.len));
    errdefer options_.deinit();

    for (node.operands.lhs..node.operands.rhs) |index| {
        astgen_assert(self.node_is(@intCast(index), .option));
        const option_node = self.nodes[index];
        astgen_assert(not_null(option_node.token));
        const option_token = self.source.tokens[option_node.token];
        astgen_assert(option_token.tag == .option);

        const option_string = option_token.location.slice(self.source.buffer);
        const option = options_map.get(option_string) orelse astgen_failure();

        if (std.mem.indexOfScalar(Option, allow_list, option) == null)
            try self.add_error(error.UnsupportedOption, option_token) else
            try options_.append(option);
    }

    if (allow_list.len == 0) {
        std.debug.assert(options_.items.len == 0);
        options_.deinit();
        return &.{};
    }

    return try options_.toOwnedSlice();
}

fn contains_option(self: *AsmSemanticAir, options_: ?[]const Option, option: Option) bool {
    _ = self;
    return if (options_) |options__|
        std.mem.indexOfScalar(Option, options__, option) != null else
        false;
}

fn free_options(self: *AsmSemanticAir, options_: ?[]const Option) void {
    if (options_) |options__|
        self.allocator.free(options__);
}

fn prepare_label(self: *AsmSemanticAir, node: AsmAst.Node, instr_index: AsmAst.Index) !?NamedSymbol {
    const label_token = self.source.tokens[node.token];
    astgen_assert(label_token.tag == .label or label_token.tag == .private_label);

    const is_public = label_token.tag == .label;
    const label_name = label_token.content_slice(self.source.buffer);
    astgen_assert(is_null(node.operands.rhs));

    const label = Symbol.Label {
        .instr_node = instr_index,
        .is_public = is_public };
    return .{
        .name = label_name,
        .token = label_token,
        .symbol = .{ .label = label } };
}

/// May only be called once, and subsequent calls are considered undefined
/// behaviour.
pub fn semantic_analyse(self: *AsmSemanticAir) !void {
    const operands = self.nodes[0].operands;
    try self.analyse_container(operands.lhs, operands.rhs);
}

const AnalysisError = SemanticError || std.mem.Allocator.Error;

fn analyse_container(self: *AsmSemanticAir, lhs: AsmAst.Index, rhs: AsmAst.Index) AnalysisError!void {
    for (lhs..rhs) |node_idx| {
        const node = self.nodes[node_idx];
        const token = self.source.tokens[node.token];

        switch (node.tag) {
            .builtin => switch (token.tag) {
                .builtin_align => try self.emit_align(node),

                .builtin_barrier => {
                    if (self.emit_reference) |emit_reference| {
                        try self.emit_header_error(emit_reference, token);
                        continue;
                    }

                    try self.emit_barrier(node);
                    const composite = self.nodes[node.operands.rhs];
                    if (self.node_unwrap(composite.operands.rhs)) |opaque_|
                        try self.analyse_container(opaque_.operands.lhs, opaque_.operands.rhs);
                },

                .builtin_region => {
                    const section = self.current_section orelse astgen_failure();
                    const begin_address = section.size();
                    const composite = self.nodes[node.operands.rhs];
                    if (self.node_unwrap(composite.operands.rhs)) |opaque_|
                        try self.analyse_container(opaque_.operands.lhs, opaque_.operands.rhs);

                    const len = section.size() - begin_address;
                    try self.emit_region(node, len);
                },

                .builtin_section => {
                    if (self.emit_reference) |emit_reference| {
                        try self.emit_header_error(emit_reference, token);
                        continue;
                    }

                    self.emit_section(node) catch |err| switch (err) {
                        // abort if there's no section already on error
                        error.SectionCreateFailed => if (self.current_section != null) continue else return,
                        else => |err_| return err_
                    };

                    const composite = self.nodes[node.operands.rhs];
                    if (self.node_unwrap(composite.operands.rhs)) |opaque_|
                        try self.analyse_container(opaque_.operands.lhs, opaque_.operands.rhs);
                },

                // nothing to do here
                .builtin_define,
                .builtin_header,
                .builtin_import,
                .builtin_linkinfo => {},

                // transparent in the AST
                .builtin_end => astgen_failure(),

                // non-builtin tokens shouldn't be in the node tags
                else => astgen_failure()
            },

            .instruction => try self.emit_addressable(@intCast(node_idx)),

            else => astgen_failure()
        }
    }
}

fn current_emitting_section(self: *AsmSemanticAir) *Section {
    return if (self.emit_reference) |emit_reference|
        emit_reference.section else
        self.current_section orelse return astgen_failure();
}

fn emit_align(self: *AsmSemanticAir, node: AsmAst.Node) !void {
    const composite = self.nodes[node.operands.rhs];
    if (self.node_unwrap(composite.operands.lhs)) |options_|
        _ = try self.parse_options(options_, &.{});
    const align_token = self.source.tokens[node.token];
    var arguments = ContainerIterator.init_index_context(self, node.operands.lhs, align_token);

    const alignment_node = try arguments.expect(.integer) orelse return;
    const alignment_token = self.source.tokens[alignment_node.token];
    const alignment = alignment_token.location.slice(self.source.buffer);
    try arguments.expect_end();

    const alignment_ = std.fmt.parseInt(usize, alignment, 0) catch astgen_failure();
    if (!std.math.isPowerOfTwo(alignment_))
        return try self.add_error(error.AlignPowerTwo, .{ alignment_, align_token });
    const section = self.current_section orelse astgen_failure();
    const current_address = section.size();
    const padding = find_available_mask(current_address, alignment_) - current_address;

    try section.content.append(self.allocator, .{
        .token = align_token,
        .is_labeled = false,
        .instruction = .{ .ld_padding = .{ padding } } });
    section.alignment = @max(section.alignment, alignment_);
}

fn emit_barrier(self: *AsmSemanticAir, node: AsmAst.Node) !void {
    const composite = self.nodes[node.operands.rhs];
    if (self.node_unwrap(composite.operands.lhs)) |options_|
        _ = try self.parse_options(options_, &.{});
    const barrier_token = self.source.tokens[node.token];
    try ContainerIterator.expect_empty(self, node.operands.lhs, barrier_token);

    const existing_section = self.current_section orelse
        return try self.add_error(error.MissingBarrierContext, barrier_token);
    const section = try self.allocator.create(Section);
    section.* = .{
        .token = barrier_token,
        .is_removable = existing_section.is_removable };

    existing_section.append(section);
    self.current_section = section;
}

fn emit_region(self: *AsmSemanticAir, node: AsmAst.Node, opaque_len: usize) !void {
    const composite = self.nodes[node.operands.rhs];
    if (self.node_unwrap(composite.operands.lhs)) |options_|
        _ = try self.parse_options(options_, &.{});
    const region_token = self.source.tokens[node.token];
    var arguments = ContainerIterator.init_index_context(self, node.operands.lhs, region_token);

    const size_node = try arguments.expect(.integer) orelse return;
    const size_token = self.source.tokens[size_node.token];
    const size = size_token.location.slice(self.source.buffer);
    try arguments.expect_end();

    const size_ = std.fmt.parseInt(usize, size, 0) catch astgen_failure();
    if (opaque_len > size_)
        return try self.add_error(error.RegionExceedsSize, .{ opaque_len, size_, region_token });
    const section = self.current_emitting_section();
    const padding = size_ - opaque_len;
    try section.content.append(self.allocator, .{
        .token = region_token,
        .is_labeled = false,
        .instruction = .{ .ld_padding = .{ padding } } });
}

fn emit_section(self: *AsmSemanticAir, node: AsmAst.Node) !void {
    const composite = self.nodes[node.operands.rhs];
    const options_ = if (self.node_unwrap(composite.operands.lhs)) |options_|
        try self.parse_options(options_, &.{ .noelimination }) else
        null;
    defer self.free_options(options_);
    const section_token = self.source.tokens[node.token];
    var arguments = ContainerIterator.init_index_context(self, node.operands.lhs, section_token);

    const name_node = try arguments.expect(.identifier) orelse return error.SectionCreateFailed;
    const name_token = self.source.tokens[name_node.token];
    const name = name_token.location.slice(self.source.buffer);
    try arguments.expect_end();

    const section = try self.allocator.create(Section);
    section.* = .{
        .token = section_token,
        .is_removable = !self.contains_option(options_, .noelimination) };

    if (self.sections.get(name)) |existing_section|
        existing_section.append(section) else
        try self.sections.put(self.allocator, name, section);
    self.current_section = section;
}

pub const Instruction = union(Tag) {

    pub const Locatable = struct {
        token: Token,
        is_labeled: bool, // to optimise liveness
        instruction: Instruction
    };

    cli,
    ast: struct { Expression(GpRegister) },
    rst: struct { Expression(GpRegister) },
    jmp: struct { Expression(Numeric(.{ .literal = u16 })) },
    jmpr: struct { Expression(Numeric(.relative)) },
    jmpd,
    mst: struct { Expression(SpRegister), Expression(Numeric(.{ .literal = u16 })) },
    mstx: struct { Expression(SpRegister), Expression(Numeric(.{ .literal = u16 })) },
    mstw: struct { Expression(SpRegister), Expression(Numeric(.{ .literal = u16 })) },
    mstwx: struct { Expression(SpRegister), Expression(Numeric(.{ .literal = u16 })) },
    mld: struct { Expression(SpRegister), Expression(Numeric(.{ .literal = u16 })) },
    mldx: struct { Expression(SpRegister), Expression(Numeric(.{ .literal = u16 })) },
    mldw: struct { Expression(SpRegister), Expression(Numeric(.{ .literal = u16 })) },
    mldwx: struct { Expression(SpRegister), Expression(Numeric(.{ .literal = u16 })) },

    // pseudoinstructions
    u8: struct { Expression(Numeric(.{ .literal = u8 })) },
    u16: struct { Expression(Numeric(.{ .literal = u16 })) },
    u24: struct { Expression(Numeric(.{ .literal = u24 })) },
    i8: struct { Expression(Numeric(.{ .literal = i8 })) },
    i16: struct { Expression(Numeric(.{ .literal = i16 })) },
    i24: struct { Expression(Numeric(.{ .literal = i24 })) },
    ascii: struct { Expression(StringContent) },
    reserve: struct { Expression(TypeSize), Expression(Numeric(.constant)) },

    // adds fixed zero bytes
    ld_padding: struct { usize },

    pub const Tag = enum {

        cli,
        ast,
        rst,
        jmp,
        jmpr,
        jmpd,
        mst,
        mstx,
        mstw,
        mstwx,
        mld,
        mldx,
        mldw,
        mldwx,
        u8,
        u16,
        u24,
        i8,
        i16,
        i24,
        ascii,
        reserve,
        ld_padding,

        /// Any unconditional jump which guarantees to divert control flow,
        /// used by Liveness to check unreachable instructions.
        pub fn is_jump(self: Tag) bool {
            return switch (self) {
                .jmp,
                .jmpr,
                .jmpd => true,

                else => false
            };
        }

        /// These instructions have multiple, 'unknown' contents to make label
        /// calculation more difficult. Liveness picks up on unlabeled
        /// instructions defined after these instructions.
        pub fn is_confusing_size(self: Tag) bool {
            return switch (self) {
                .ascii,
                .reserve,
                .ld_padding => true,

                else => false
            };
        }

        pub fn is_fixed_data(self: Tag) bool {
            return switch (self) {
                .u8, .u16, .u24,
                .i8, .i16, .i24 => true,

                else => false
            };
        }

        /// Any executable instruction, which is not a data value or internal
        /// instruction. Liveness checks on padding whether non-jump executable
        /// instructions spill into zeros.
        pub fn is_executable(self: Tag) bool {
            return switch (self) {
                .u8, .u16, .u24,
                .i8, .i16, .i24,
                .ascii,
                .reserve,
                .ld_padding => false,

                else => true
            };
        }

        pub fn basic_size(self: Tag) usize {
            return switch (self) {
                .cli,
                .ast,
                .rst,
                .jmpd => 1,

                .jmpr => 2,

                .jmp,
                .mst,
                .mstx,
                .mstw,
                .mstwx,
                .mld,
                .mldx,
                .mldw,
                .mldwx => 3,

                .u8, .i8 => 1,
                .u16, .i16 => 2,
                .u24, .i24 => 3,

                .ascii,
                .reserve,
                .ld_padding => 0
            };
        }
    };

    pub const instruction_map = std.StaticStringMap(Tag).initComptime(.{
        .{ "cli", .cli },
        .{ "ast", .ast },
        .{ "rst", .rst },
        .{ "jmp", .jmp },
        .{ "jmpr", .jmpr },
        .{ "jmpd", .jmpd },
        .{ "mst", .mst },
        .{ "mstw", .mstw },
        .{ "mld", .mld },
        .{ "mldw", .mldw },
        .{ "u8", .u8 },
        .{ "u16", .u16 },
        .{ "u24", .u24 },
        .{ "i8", .i8 },
        .{ "i16", .i16 },
        .{ "i24", .i24 },
        .{ "ascii", .ascii },
        .{ "reserve", .reserve }
    });

    pub const modifier_map = std.StaticStringMap(Tag).initComptime(.{
        .{ "mst", .mstx },
        .{ "mstw", .mstwx },
        .{ "mld", .mstx },
        .{ "mldw", .mldwx }
    });

    comptime {
        // Zig comptime validation, hell yeah!
        for (@typeInfo(Tag).@"enum".fields) |instruction_tag| {
            if (std.mem.startsWith(u8, instruction_tag.name, "ld_"))
                continue;
            const real_instruction = std.mem.trimRight(u8, instruction_tag.name, "x");
            const mapping: ?Instruction.Tag = instruction_map.get(real_instruction) orelse
                modifier_map.get(real_instruction);
            if (mapping) |the_mapping| {
                if (!std.mem.eql(u8, real_instruction, @tagName(the_mapping)))
                    @compileError("bug: mismatching mapping/instruction: " ++ @tagName(the_mapping) ++ " / " ++ real_instruction);
            } else @compileError("bug: unmapped instruction: " ++ real_instruction);
        }
    }

    pub fn size(self: Instruction) usize {
        return switch (self) {
            .ascii => |args| args[0].result.size(),
            .reserve => |args| args[0].result.size * @as(usize, @intCast(args[1].result.assembletime_offset orelse 0)), // fixme: ensure result positive
            .ld_padding => |args| args[0],
            else => std.meta.activeTag(self).basic_size()
        };
    }
};

fn emit_addressable(self: *AsmSemanticAir, index: AsmAst.Index) !void {
    const node = self.nodes[index];
    astgen_assert(self.node_is(index, .instruction));
    astgen_assert(self.node_is_null_or(node.operands.lhs, .container));
    astgen_assert(self.node_is_null_or(node.operands.rhs, .composite));

    const token = self.source.tokens[node.token];
    astgen_assert(token.tag == .instruction or
        token.tag == .pseudo_instruction or
        token.tag == .identifier);

    const labels: AsmAst.IndexRange,
    const is_modified: bool = if (self.node_unwrap(node.operands.rhs)) |composite| blk: {
        astgen_assert(self.node_is_null_or(composite.operands.lhs, .container));
        astgen_assert(self.node_is_null_or(composite.operands.rhs, .modifier));

        const label_range: AsmAst.IndexRange = if (self.node_unwrap(composite.operands.lhs)) |container_node|
            container_node.operands else
            .{};
        const modifier_token = if (self.node_unwrap(composite.operands.rhs)) |modifier_node|
            self.source.tokens[modifier_node.token] else
            null;
        if (modifier_token) |modifier_token_|
            try self.maybe_emit_nonempty_modifier_error(modifier_token_);
        break :blk .{ label_range, modifier_token != null };
    } else .{ .{}, false };

    const is_labeled = (labels.rhs - labels.lhs) > 0;
    if ((labels.rhs - labels.lhs) > 1) // fixme: allow more than one label to be defined per instruction
        try self.add_error(error.GenericToken, .{ "only one label is allowed to be defined per instruction;", " this is a bug in the QCPU linker", token });
    try self.emit_labels(labels);

    const arguments = if (self.node_unwrap(node.operands.lhs)) |arguments_node|
        arguments_node.operands else
        null;
    try self.emit_instructions(node, is_modified, is_labeled, arguments);
}

fn emit_labels(self: *AsmSemanticAir, labels: AsmAst.IndexRange) !void {
    const section = self.current_emitting_section();
    try self.references.ensureUnusedCapacity(self.allocator, labels.rhs - labels.lhs);
    for (labels.lhs..labels.rhs) |label_idx| self.emit_label(self.nodes[label_idx], section);
}

fn emit_label(
    self: *AsmSemanticAir,
    label: AsmAst.Node,
    section: *Section
) void {
    astgen_assert(label.tag == .label);
    const current_index: u32 = @intCast(section.content.len);
    const token = self.source.tokens[label.token];
    const name = token.content_slice(self.source.buffer);

    std.debug.assert(!self.references.contains(name));

    const new_reference = Reference {
        .instruction_index = current_index,
        .section = section };
    self.references.putAssumeCapacity(name, new_reference);
}

fn emit_instructions(
    self: *AsmSemanticAir,
    node: AsmAst.Node,
    is_modified: bool,
    is_labeled: bool,
    arguments: ?AsmAst.IndexRange
) !void {
    const section = self.current_emitting_section();
    const token = self.source.tokens[node.token];
    const string = token.location.slice(self.source.buffer);

    switch (token.tag) {
        .instruction,
        .pseudo_instruction => {
            const tag = if (is_modified)
                Instruction.modifier_map.get(string) else
                Instruction.instruction_map.get(string);
            astgen_assert(is_modified or tag != null);

            if (tag == null and is_modified)
                return try self.add_error(error.UnknownModifiedInstruction, token);
            const instruction = try self.cast_arguments(token, tag.?, arguments) orelse return;
            try section.content.append(self.allocator, .{
                .token = token,
                .is_labeled = is_labeled,
                .instruction = instruction });
        },

        .identifier => {
            if (!std.mem.startsWith(u8, string, "@") or string.len == 1) {
                try self.add_error(error.UnknownInstruction, token);

                const symbol = self.fetch_symbol_inner(string) orelse return;
                if (symbol.symbol == .header)
                    try self.add_error(error.NoteDidYouMean, .{ "call the header @", string, symbol.token });
                return;
            }

            const origin = ForeignToken { .sema = self, .token = self.source.tokens[node.token] };
            const header = try Expression(Symbol.Header).lower_tree(self, node, origin) orelse return;
            // fixme: is_labeled first header instruction
            try self.unroll_header(header, arguments);
        },

        else => unreachable
    }
}

fn cast_arguments(self: *AsmSemanticAir, token: Token, instruction_tag: Instruction.Tag, arguments: ?AsmAst.IndexRange) !?Instruction {
    inline for (@typeInfo(Instruction).@"union".fields) |instruction| {
        if (std.mem.eql(u8, instruction.name, @tagName(instruction_tag))) {
            const Arguments = instruction.@"type";
            const arguments_len = if (arguments) |arguments_|
                arguments_.rhs - arguments_.lhs else
                0;
            const fields = if (Arguments != void)
                @typeInfo(Arguments).@"struct".fields else
                .{};
            if (fields.len != arguments_len) {
                try self.add_error(error.ExpectedArgumentsLen, .{ token, fields.len, arguments_len });
                return null;
            }

            if (fields.len == 0)
                return @unionInit(Instruction, instruction.name, {});
            var iterator = ContainerIterator.init_range(self, arguments.?);
            var casted_arguments: Arguments = undefined;

            @setEvalBranchQuota(9999);

            inline for (fields, 0..) |argument, i| {
                const Type = argument.@"type";
                const user_argument = iterator.next() orelse unreachable;
                const origin = ForeignToken { .sema = self, .token = self.source.tokens[user_argument.token] };

                casted_arguments[i] = switch (Type) {
                    usize => astgen_failure(),
                    inline else => try Type.lower_tree(self, user_argument, origin)
                } orelse return null;
            }

            return @unionInit(Instruction, instruction.name, casted_arguments);
        }
    }

    astgen_failure();
}

fn unroll_header(self: *AsmSemanticAir, header: Expression(Symbol.Header), arguments: ?AsmAst.IndexRange) !void {
    var foreign_sema = header.executed_token.sema;
    const is_origin = self.emit_reference == null; // non-null when this sema is currently lowering header
    const is_reference_owner = foreign_sema.emit_reference == null; // first call also cleans up last

    var mapping = try foreign_sema.map_header_arguments(self, header, arguments orelse .zero) orelse return;
    defer mapping.deinit(self.allocator);

    var emit_reference = if (is_origin)
        try EmitReference.init(self.allocator, header.token, self.current_section.?) else
        self.emit_reference.?;
    defer if (is_origin) emit_reference.deinit(self.allocator);

    foreign_sema.emit_reference = emit_reference;
    defer { if (is_reference_owner) foreign_sema.emit_reference = null; }

    try emit_reference.push_scope(self.allocator, mapping);
    defer emit_reference.pop_scope(self.allocator);

    try foreign_sema.analyse_container(header.result.content.lhs, header.result.content.rhs);
}

fn map_header_arguments(
    self: *AsmSemanticAir,
    calling_sema: *AsmSemanticAir,
    header: Expression(Symbol.Header),
    argument_range: AsmAst.IndexRange
) !?SymbolMap {
    var parameters = ContainerIterator.init_range(self, header.result.arguments);
    var arguments = ContainerIterator.init_range(calling_sema, argument_range);

    if (parameters.left() != arguments.left()) {
        try calling_sema.add_error(error.ExpectedArgumentsLen, .{ header.token.token, parameters.left(), arguments.left() });
        try self.add_error(error.NoteDefinedHere, .{ header.executed_token.token.tag, header.executed_token.token });
        return null;
    }

    var mappings = SymbolMap.empty;
    try mappings.ensureTotalCapacity(self.allocator, parameters.left());
    errdefer mappings.deinit(self.allocator);

    while (parameters.next()) |parameter_node| {
        const parameter_token = self.source.tokens[parameter_node.token];
        const name = parameter_token.location.slice(self.source.buffer);

        // fixme: header arguments cannot be used as arguments to headers
        // fixme: cross-sema header arguments are not supported
        const mapping = Symbol.Define {
            .value_node = arguments.next_index(),
            .is_public = false };
        if (mappings.contains(name))
            try self.add_error(error.HeaderDuplicateParameter, parameter_token);
        try self.maybe_emit_duplicate_error(.{
            .name = name,
            .token = parameter_token,
            .symbol = .{ .define = mapping } });

        mappings.putAssumeCapacity(name, .{
            .token = parameter_token,
            .symbol = .{ .define = mapping } });
    }

    return mappings;
}

fn Expression(comptime ResultType: type) type {
    return struct {

        const ExpressionType = @This();

        token: ForeignToken, // the argument / origin of the expression
        executed_token: ForeignToken, // first evaluated token after lowering tree
        result: ResultType,

        const EvaluationError = std.mem.Allocator.Error || SemanticError;

        pub fn lower_tree(sema: *AsmSemanticAir, node: AsmAst.Node, origin_token: ForeignToken) EvaluationError!?ExpressionType {
            const token = sema.source.tokens[node.token];
            const is_define = node.tag == .identifier;
            const is_header = ResultType == Symbol.Header and node.tag == .instruction;

            if (is_define or is_header) {
                astgen_assert(token.tag == .identifier);
                const identifier = token.location.slice(sema.source.buffer);

                const symbols_sema,
                const symbol,
                const namespace = try sema.fetch_symbol(identifier, origin_token, token) orelse return null;

                // for liveness pass
                if (namespace) |namespace_|
                    namespace_.is_used = true;
                symbol.is_used = true;

                return switch (symbol.symbol) {
                    .label => unreachable, // labels cannot start with @
                    .define => |define| try ExpressionType.lower_tree(symbols_sema, symbols_sema.nodes[define.value_node], origin_token),
                    .header => |header| blk: {
                        if (ResultType == Symbol.Header)
                            break :blk .{ .token = origin_token, .executed_token = .{ .sema = symbols_sema, .token = symbol.token }, .result = header }; // headers aren't expanded in arguments
                        try origin_token.sema.add_error(error.HeaderResultType, origin_token.token);
                        break :blk null;
                    },
                    .file => unreachable // handled in look-up
                };
            }

            return switch (ResultType) {
                // if expressions aren't allowed
                u8, u16, u24,
                i8, i16, i24 => .{
                    .token = origin_token,
                    .executed_token = .{ .sema = sema, .token = token },
                    .result = try sema.cast_numeric_literal(ResultType, node) orelse return null },

                // if lowered tree isn't a header (handled above in lowering)
                Symbol.Header => blk: {
                    try origin_token.sema.add_error(error.HeaderResultType, origin_token.token);
                    break :blk null;
                },

                else => if (try ResultType.analyse(sema, node, origin_token)) |result|
                    .{ .token = origin_token, .executed_token = .{ .sema = sema, .token = token }, .result = result } else
                    null
            };
        }
    };
}

fn cast_numeric_literal(self: *AsmSemanticAir, comptime T: type, node: AsmAst.Node) !?T {
    const token = self.source.tokens[node.token];
    const string = token.location.slice(self.source.buffer);

    if (token.tag != .numeric_literal) {
        const origin = ForeignToken { .sema = self, .token = self.source.tokens[node.token] };
        try self.emit_resolved_expected_error(AsmAst.Node.Tag.integer, origin, token);
        return null;
    }

    const inherit_base = 0;

    return std.fmt.parseInt(T, string, inherit_base) catch |err| switch (err) {
        error.InvalidCharacter => astgen_failure(),
        error.Overflow => {
            const origin = ForeignToken { .sema = self, .token = self.source.tokens[node.token] };
            try self.emit_resolved_generic_error("numeric literal doesn't fit in type ", @typeName(T), origin, token);
            return null;
        }
    };
}

const ForeignToken = struct {
    // fixme: token location eql has an edge case when working in different files
    sema: *AsmSemanticAir,
    token: Token
};

fn fetch_symbol(self: *AsmSemanticAir, path: []const u8, origin_token: ForeignToken, token: Token) !?struct {
    *AsmSemanticAir,
    *Symbol.Locatable,
    ?*Symbol.Locatable
} {
    if (!self.is_valid_symbol(path)) {
        try self.emit_resolved_error(error.AmbiguousIdentifier, origin_token, token, token);
        return null;
    }

    var components = std.mem.splitScalar(u8, path[1..], '.');
    const namespace = components.next() orelse unreachable;
    const is_label = std.mem.startsWith(u8, path, ".");

    if (namespace.len == 0) {
        try self.emit_resolved_error(error.AmbiguousIdentifier, origin_token, token, token);
        return null;
    }

    const own_symbol = self.fetch_symbol_inner(namespace) orelse {
        try self.emit_resolved_error(error.UnknownSymbol, origin_token, token, token);
        return null;
    };

    const result_sema,
    const result_symbol,
    const result_namespace = switch (own_symbol.symbol) {
        .file => |file| blk: {
            const symbol_name = components.next() orelse {
                try self.emit_resolved_error(error.Namespace, origin_token, token, token);
                return null;
            };

            // fixme: sema unit not available error
            const foreign_symbol = file.sema.?.*.?.symbols.getPtr(symbol_name) orelse {
                try self.emit_resolved_error(error.UnknownSymbol, origin_token, token, token);
                return null;
            };

            if (!foreign_symbol.symbol.is_public()) {
                try self.emit_resolved_error(error.NamespacePrivateSymbol, origin_token, token, token);
                return null;
            }

            break :blk .{ &file.sema.?.*.?, foreign_symbol, own_symbol };
        },

        else => blk: {
            if (components.next() != null) {
                try self.emit_resolved_error(error.AmbiguousIdentifier, origin_token, token, token);
                return null;
            }

            break :blk .{ self, own_symbol, null };
        }
    };

    const is_result_label = result_symbol.symbol == .label;

    if (is_label != is_result_label) {
        try self.emit_resolved_error(error.NonConformingSymbol, origin_token, token, .{ token, result_symbol.token });
        try result_sema.add_error(error.NoteDefinedHere, .{ result_symbol.token.tag, result_symbol.token });
        return null;
    }

    return .{ result_sema, result_symbol, result_namespace };
}

// fixme: add foreign symbols because of mapping
fn fetch_symbol_inner(self: *AsmSemanticAir, key: []const u8) ?*Symbol.Locatable {
    const scoped_symbol = if (self.emit_reference) |emit_reference|
        if (emit_reference.scope) |scope| scope.symbols.getPtr(key) else null else
        null;
    return scoped_symbol orelse blk: {
        @branchHint(.likely);
        break :blk self.symbols.getPtr(key);
    };
}

const NumericResult = union(enum) {

    relative,
    agnostic, // i8 or u8
    constant,
    literal: type, // eval as type

    pub fn FittingType(self: NumericResult) type {
        return switch (self) {
            .relative => i8,
            .agnostic => u8, // @bitCast
            .constant => u16,
            .literal => |the_type| the_type
        };
    }

    pub fn bytes(self: NumericResult) usize {
        return @sizeOf(self.FittingType());
    }

    pub fn is_signed(self: NumericResult) bool {
        return switch (self) {
            .relative,
            .agnostic => true,
            .constant => false,
            .literal => |the_type| @typeInfo(the_type).@"int".signedness == .signed
        };
    }
};

fn Numeric(comptime Type: NumericResult) type {
    return struct {

        const NumericType = @This();
        const ExpressionType = Expression(NumericType);
        pub const ResultType = Type;

        const LinkLabel = struct {
            sema: *AsmSemanticAir,
            name: []const u8,
            unified_name: []const u8, // arena allocated
            modifier: ?u8
        };

        tag: AsmAst.Node.Tag,
        linktime_label: ?LinkLabel = null,
        assembletime_offset: ?i32 = null,

        pub fn analyse(sema: *AsmSemanticAir, node: AsmAst.Node, origin_token: ForeignToken) !?NumericType {
            const token = sema.source.tokens[node.token];

            return result: switch (node.tag) {
                .neg,
                .inv => {
                    const operand = try ExpressionType.lower_tree(sema, sema.nodes[node.operands.lhs], origin_token) orelse return null;
                    const assembletime_operand = operand.result.assembletime_offset orelse {
                        try operand.token.sema.emit_resolved_error(error.IllegalUnaryOp, origin_token, operand.token.token, .{ @tagName(node.tag), operand.token.token });
                        return null;
                    };

                    const assembletime_eval = try math(node.tag, assembletime_operand, 0);
                    break :result .{ .tag = operand.result.tag, .assembletime_offset = assembletime_eval };
                },

                .add,
                .sub,
                .mult,
                .lsh,
                .rsh => {
                    const lhs = try ExpressionType.lower_tree(sema, sema.nodes[node.operands.lhs], origin_token) orelse return null;
                    const rhs = try ExpressionType.lower_tree(sema, sema.nodes[node.operands.rhs], origin_token) orelse return null;

                    break :result expr: switch (node.tag) {
                        // add(ref, ref) = illegal
                        // add(int, ref) = offset/int
                        // add(ref, int) = offset/int
                        // add(int, int) = int
                        .add => {
                            if (lhs.result.linktime_label != null and rhs.result.linktime_label != null) {
                                try sema.emit_resolved_error(error.GenericToken, origin_token, token, .{ "unable to analyse assemble-time expression", "", token });
                                return null;
                            }

                            if (lhs.result.assembletime_offset != null and rhs.result.linktime_label != null) {
                                const evaluation = try math(
                                    node.tag,
                                    lhs.result.assembletime_offset.?,
                                    rhs.result.assembletime_offset orelse 0);
                                break :expr .{
                                    .tag = node.tag,
                                    .linktime_label = rhs.result.linktime_label,
                                    .assembletime_offset = evaluation };
                            }

                            if (lhs.result.linktime_label != null and rhs.result.assembletime_offset != null) {
                                const evaluation = try math(
                                    node.tag,
                                    lhs.result.assembletime_offset orelse 0,
                                    rhs.result.assembletime_offset.?);
                                break :expr .{
                                    .tag = node.tag,
                                    .linktime_label = lhs.result.linktime_label,
                                    .assembletime_offset = evaluation };
                            }

                            if (lhs.result.assembletime_offset != null and rhs.result.assembletime_offset != null) {
                                const evaluation = try math(
                                    node.tag,
                                    lhs.result.assembletime_offset.?,
                                    rhs.result.assembletime_offset.?);
                                break :expr .{
                                    .tag = node.tag,
                                    .assembletime_offset = evaluation };
                            }

                            unreachable;
                        },

                        // sub(int, ref) = illegal
                        // sub(ref, ref) = diff/int         ; diff is calculated at link time
                        // sub(ref, int) = offset/int
                        // sub(int, int) = int
                        .sub => {
                            if (lhs.result.assembletime_offset != null and rhs.result.linktime_label != null) {
                                try sema.emit_resolved_error(error.GenericToken, origin_token, token, .{ "illegal behaviour", "", token });
                                return null;
                            }

                            if (lhs.result.linktime_label != null and rhs.result.linktime_label != null) {
                                break :expr .{
                                    .tag = node.tag, // fixme: relative diff
                                    .assembletime_offset = 0 }; // + offsets on either side
                            }

                            if (lhs.result.linktime_label != null and rhs.result.assembletime_offset != null) {
                                const evaluation = try math(
                                    node.tag,
                                    lhs.result.assembletime_offset orelse 0,
                                    rhs.result.assembletime_offset.?);
                                break :expr .{
                                    .tag = node.tag,
                                    .linktime_label = lhs.result.linktime_label,
                                    .assembletime_offset = evaluation };
                            }

                            if (lhs.result.assembletime_offset != null and rhs.result.assembletime_offset != null) {
                                const evaluation = try math(
                                    node.tag,
                                    lhs.result.assembletime_offset.?,
                                    rhs.result.assembletime_offset.?);
                                break :expr .{
                                    .tag = node.tag,
                                    .assembletime_offset = evaluation };
                            }

                            unreachable;
                        },

                        // lsh/rsh/mult(int, ref) = illegal
                        // lsh/rsh/mult(ref, ref) = illegal
                        // lsh/rsh/mult(ref, int) = illegal
                        // lsh/rsh/mult(int, int) = int
                        .mult,
                        .lsh,
                        .rsh => {
                            if (lhs.result.linktime_label != null or rhs.result.linktime_label != null) {
                                try sema.emit_resolved_error(error.GenericToken, origin_token, token, .{ "unable to evaluate assemble-time expression", "", token });
                                return null;
                            }

                            const evaluation = try math(
                                node.tag,
                                lhs.result.assembletime_offset orelse 0,
                                rhs.result.assembletime_offset orelse 0);
                            break :expr .{
                                .tag = .integer,
                                .assembletime_offset = evaluation };
                        },

                        else => unreachable
                    };
                },

                .reference => blk: {
                    const name = token.location.slice(sema.source.buffer);
                    const qualified_name = token.content_slice(sema.source.buffer);

                    const symbols_sema,
                    const symbol,
                    const namespace = try sema.fetch_symbol(name, origin_token, token) orelse return null;

                    // for liveness pass
                    if (namespace) |namespace_|
                        namespace_.is_used = true;
                    symbol.is_used = true;

                    astgen_assert(symbol.symbol == .label);

                    const modifier = if (sema.node_unwrap(node.operands.lhs)) |modifier_node| mbl: {
                        const slice = sema.source.tokens[modifier_node.token].content_slice(sema.source.buffer);
                        astgen_assert(slice.len <= 1);
                        break :mbl if (slice.len == 0) 0 else slice[0];
                    } else null;

                    const label = LinkLabel {
                        .sema = symbols_sema,
                        .name = qualified_name,
                        .unified_name = try symbols_sema.unified_label(sema.arena.allocator(), qualified_name),
                        .modifier = modifier };
                    break :blk .{
                        .tag = node.tag,
                        .linktime_label = label };
                },

                .char => {
                    const ascii = token.content_slice(sema.source.buffer);
                    astgen_assert(ascii.len == 1);
                    break :result .{ .tag = node.tag, .assembletime_offset = @intCast(ascii[0]) };
                },

                .integer => .{
                    .tag = node.tag,
                    .assembletime_offset = try sema.cast_numeric_literal(i32, node) },

                else => {
                    try sema.emit_resolved_error(error.UnlinkableToken, origin_token, token, token);
                    return null;
                }
            };
        }

        fn math(operation: AsmAst.Node.Tag, lhs: i32, rhs: i32) !i32 {
            return switch (operation) {
                .inv => ~lhs,
                .neg => -lhs,
                .add => lhs + rhs,
                .sub => lhs - rhs,
                .mult => lhs * rhs,

                .lsh => if (rhs >= 0)
                    lhs << @intCast(rhs) else
                    lhs >> @intCast(-rhs),
                .rsh => if (rhs >= 0)
                    lhs >> @intCast(rhs) else
                    lhs << @intCast(-rhs),

                else => unreachable
            };
        }

        const AddressResolution = struct {
            absolute_address: i32,
            real_address: i32,
            result: ResultType.FittingType()
        };

        pub fn resolve(
            self: *const NumericType,
            origin_token: ForeignToken,
            token: ForeignToken,
            current_address: i32,
            label_address: i32
        ) !?AddressResolution {
            const absolute_address = (self.assembletime_offset orelse 0) + label_address;

            const real_address: i32 = switch (ResultType) {
                // only perform relative offset if a label was used
                .relative => if (self.linktime_label != null)
                    absolute_address - current_address else
                    absolute_address,
                else => absolute_address
            };

            if (!ResultType.is_signed() and real_address < 0) {
                try token.sema.emit_resolved_error(error.AddressResolutionUnsigned, origin_token, token.token, .{ real_address, token.token });
                return null;
            }

            const ResolutionType = ResultType.FittingType();

            if (real_address > std.math.maxInt(ResolutionType) or real_address < std.math.minInt(ResolutionType)) {
                try token.sema.emit_resolved_error(error.AddressResolutionOverflow, origin_token, token.token, .{ real_address, @typeName(ResolutionType), token.token });
                return null;
            }

            const intermediate_type = @Type(.{ .@"int" = .{
                .signedness = if (comptime ResultType.is_signed()) .signed else .unsigned,
                .bits = @bitSizeOf(i32) } });
            // we already did the validation, so truncate doesn't lose any info
            const result: ResolutionType = @truncate(@as(intermediate_type, @bitCast(real_address)));

            return .{
                .absolute_address = absolute_address,
                .real_address = real_address,
                .result = result };
        }
    };
}

pub const GpRegister = enum(u3) {

    zr,
    ra,
    rb,
    rc,
    rd,
    rx,
    ry,
    rz,

    pub fn analyse(sema: *AsmSemanticAir, node: AsmAst.Node, origin_token: ForeignToken) !?GpRegister {
        const token = sema.source.tokens[node.token];
        const name = token.content_slice(sema.source.buffer);

        return std.meta.stringToEnum(GpRegister, name) orelse {
            try sema.emit_resolved_expected_error(Token.string("a general-purpose register"), origin_token, token);
            return null;
        };
    }
};

pub const SpRegister = enum(u2) {

    zr,
    sp,
    sf,
    adr,

    pub fn analyse(sema: *AsmSemanticAir, node: AsmAst.Node, origin_token: ForeignToken) !?SpRegister {
        const token = sema.source.tokens[node.token];
        const name = token.content_slice(sema.source.buffer);

        return std.meta.stringToEnum(SpRegister, name) orelse {
            try sema.emit_resolved_expected_error(Token.string("a special-purpose register"), origin_token, token);
            return null;
        };
    }
};

const StringContent = struct {

    memory: []const u8,
    sentinel: ?Expression(u8),

    pub fn analyse(sema: *AsmSemanticAir, node: AsmAst.Node, origin_token: ForeignToken) !?StringContent {
        const token = sema.source.tokens[node.token];
        const string = token.content_slice(sema.source.buffer);

        if (token.tag != .string_literal) {
            try sema.emit_resolved_expected_error(AsmAst.Node.Tag.string, origin_token, token);
            return null;
        }

        // fixme: non-integer sentinel nulls out without error
        const sentinel = if (sema.node_unwrap(node.operands.lhs)) |sentinel_node| blk: {
            const origin = ForeignToken { .sema = sema, .token = sema.source.tokens[sentinel_node.token] };
            const expression = try Expression(u8).lower_tree(sema, sentinel_node, origin) orelse return null;
            break :blk expression;
        } else null;

        return .{
            .memory = string,
            .sentinel = sentinel };
    }

    pub fn size(self: StringContent) usize {
        const sentinel_len: usize = if (self.sentinel != null) 1 else 0;
        return self.memory.len + sentinel_len;
    }
};

const TypeSize = struct {

    size: u16,

    pub fn analyse(sema: *AsmSemanticAir, node: AsmAst.Node, origin_token: ForeignToken) !?TypeSize {
        const token = sema.source.tokens[node.token];
        const string = token.location.slice(sema.source.buffer);

        if (token.tag != .instruction and
            token.tag != .pseudo_instruction and
            token.tag != .identifier
        ) {
            try sema.emit_resolved_expected_error(Token.string("a basic opaque"), origin_token, token);
            return null;
        }

        const size = switch (token.tag) {
            .instruction,
            .pseudo_instruction => Instruction.instruction_map
                .get(string).?
                .basic_size(),
            // fixme: get size of header (and check if header exists)
            // won't support recursive headers as arguments aren't inputted
            .identifier => 0,
            else => astgen_failure()
        };

        return .{ .size = @intCast(size) };
    }
};

pub fn unified_label(self: *AsmSemanticAir, allocator: std.mem.Allocator, label: []const u8) ![]const u8 {
    if (self.qcu) |qcu| {
        const file = std.fs.path.stem(qcu.file_name);
        return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ file, label });
    } else {
        return try allocator.dupe(u8, label);
    }
}

// Tests

const options = @import("options");
const Tokeniser = @import("AsmTokeniser.zig");

const stderr = std.io
    .getStdErr()
    .writer();

fn testSema(input: [:0]const u8) !struct { AsmAst, AsmSemanticAir } {
    var tokeniser = Tokeniser.init(input);
    const source = try Source.init(std.testing.allocator, &tokeniser);
    errdefer source.deinit();
    var ast = try AsmAst.init(std.testing.allocator, source);
    errdefer ast.deinit();

    for (ast.errors) |err|
        try err.write("test.s", input, stderr);
    try std.testing.expect(ast.errors.len == 0);

    return .{ ast, try AsmSemanticAir.init_freestanding(std.testing.allocator, source, ast.nodes) };
}

fn testSemaFree(ast: *AsmAst, sema: *AsmSemanticAir) void {
    ast.deinit();
    sema.deinit();
    sema.source.deinit();
}

fn testSema1(input: [:0]const u8) !void {
    var ast, var sema = try testSema(input);
    defer testSemaFree(&ast, &sema);
    try sema.semantic_analyse();

    if (options.dump) {
        try stderr.print("Symbols ({}):\n", .{ sema.symbols.count() });
        for (sema.symbols.keys()) |symbol_name| {
            const symbol = sema.symbols.get(symbol_name) orelse unreachable;
            switch (symbol.symbol) {
                .label => |label| try stderr.print("    {s} = instr:{} public:{}\n", .{
                    symbol_name,
                    label.instr_node,
                    label.is_public }),
                .define => |define| try stderr.print("    {s} = root:{} public:{}\n", .{
                    symbol_name,
                    define.value_node,
                    define.is_public }),
                .header => |header| try stderr.print("    {s} = args:{}..{} nodes:{}..{} public:{}\n", .{
                    symbol_name,
                    header.arguments.lhs,
                    header.arguments.rhs,
                    header.content.lhs,
                    header.content.rhs,
                    header.is_public }),
                .file => |file| try stderr.print("    {s} = {s}\n", .{
                    symbol_name,
                    file.path })
            }
        }
        try stderr.print("AIR ({}):\n", .{ sema.sections.count() });
        try sema.dump(stderr);
    }

    for (sema.errors.items) |err|
        try err.write("test.s", input, stderr);
    try std.testing.expect(sema.errors.items.len == 0);
}

fn testSemaErr(input: [:0]const u8, errors: []const SemanticError) !void {
    var ast, var sema = try testSema(input);
    defer testSemaFree(&ast, &sema);
    try sema.semantic_analyse();

    var sema_errors = std.ArrayList(anyerror).init(std.testing.allocator);
    defer sema_errors.deinit();
    for (sema.errors.items) |err|
        try sema_errors.append(err.id);
    if (!std.mem.eql(anyerror, errors, sema_errors.items)) {
        for (sema.errors.items) |err|
            try err.write("test.s", input, stderr);
        try std.testing.expectEqualSlices(anyerror, errors, sema_errors.items);
    }
}

fn testSemaGen(input: [:0]const u8, output: []const Instruction) !void {
    try testSemaGenAnd(input, output, struct {
        fn run(_: *AsmSemanticAir) !void {}
    }.run);
}

fn testSemaResult(input: [:0]const u8, func: anytype) !void {
    try testSemaGenAnd(input, null, func);
}

fn testSemaGenAnd(input: [:0]const u8, output: ?[]const Instruction, func: anytype) !void {
    var ast, var sema = try testSema(input);
    defer testSemaFree(&ast, &sema);
    try sema.semantic_analyse();

    for (sema.errors.items) |err|
        try err.write("test.s", input, stderr);
    try std.testing.expect(sema.errors.items.len == 0);
    if (output) |output_|
        try std.testing.expectEqualSlices(Instruction, sema.current_section.?.content.items(.instruction), output_);
    try func(&sema);
}

test "@define" {
    try testSemaErr("@define", &.{ error.ExpectedContext });
    try testSemaErr("@define 5", &.{ error.Expected });
    try testSemaErr("@define ra", &.{ error.Expected });
    try testSemaErr("@define foo", &.{ error.ExpectedContext });
    try testSemaErr("@define foo, foo", &.{});
    try testSemaErr("@define foo, foo, foo", &.{ error.Unexpected });

    try testSemaErr(
        \\@define foo, foo
        \\@define bar, foo
    , &.{});

    try testSemaErr(
        \\@define foo, foo
        \\@define foo, foo
    , &.{
        error.DuplicateSymbol,
        error.NoteDefinedHere
    });
}

test "@header" {
    try testSemaErr("@header\n@end", &.{ error.ExpectedContext });
    try testSemaErr("@header 5\n@end", &.{ error.Expected });
    try testSemaErr("@header ra\n@end", &.{ error.Expected });
    try testSemaErr("@header foo\n@end", &.{});
    try testSemaErr("@header foo, bar\n@end", &.{});
    try testSemaErr("@header foo, bar, roo\n@end", &.{});
    try testSemaErr("@header foo, 5, roo\n@end", &.{ error.Expected });
    // fixme: provide two errors instead of one
    try testSemaErr("@header foo, ra, 5\n@end", &.{ error.Expected });

    try testSemaErr(
        \\@header foo
        \\@end
        \\@header bar, roo, doo
        \\@end
        \\@define roo, foo
    , &.{});

    try testSemaErr(
        \\@header foo
        \\@end
        \\@define foo, foo
    , &.{
        error.DuplicateSymbol,
        error.NoteDefinedHere
    });
}

test "@import" {
    try testSemaErr("@import", &.{ error.ExpectedContext });
    try testSemaErr("@import foo", &.{ error.ExpectedContext });
    try testSemaErr("@import 5", &.{ error.Expected });
    try testSemaErr("@import bar, \"foo\"", &.{});
    try testSemaErr("@import \"foo\"", &.{ error.Expected });
    try testSemaErr("@import \"foo\" 0", &.{ error.Expected });
    try testSemaErr("@import foo, \"foo\" 0", &.{ error.UselessSentinel});
    // fixme: adds additional unexpected error instead of moving on
    // try testSemaErr("@import \"foo\", 0", &.{ error.Expected, error.Unexpected });
    try testSemaErr("@import foo, \"foo\", foo", &.{ error.Unexpected });
}

test "@section" {
    try testSemaErr("@section", &.{ error.ExpectedContext });
    try testSemaErr("@section 5", &.{ error.Expected });
    try testSemaErr("@section ra", &.{ error.Expected });
    try testSemaErr("@section foo", &.{});

    try testSemaErr(
        \\@section foo
        \\          cli
    , &.{});

    try testSemaErr(
        \\@section foo
        \\          cli
        \\@section bar
        \\          cli
    , &.{});

    try testSemaGenAnd(
        \\@section foo
        \\cli
    , &.{
        .{ .cli = {} }
    }, struct {
        fn run(sema: *AsmSemanticAir) !void {
            const section = sema.current_section.?;
            try std.testing.expect(section.is_removable);
        }
    }.run);

    try testSemaGenAnd(
        \\@section(noelimination) foo
        \\cli
    , &.{
        .{ .cli = {} }
    }, struct {
        fn run(sema: *AsmSemanticAir) !void {
            const section = sema.current_section.?;
            try std.testing.expect(!section.is_removable);
        }
    }.run);
}

test "labels" {
    try testSemaErr(
        \\@section foo
        \\.label:   cli
    , &.{});
}

test "instruction validation" {
    try testSemaErr("@section foo\ncli", &.{});
    try testSemaErr("@section foo\ncli'", &.{ error.UnknownModifiedInstruction });
    try testSemaErr("@section foo\nmst' sf, 0", &.{});
    try testSemaErr("@section foo\ncli ra", &.{ error.ExpectedArgumentsLen });
    try testSemaErr("@section foo\nast", &.{ error.ExpectedArgumentsLen });
    try testSemaErr("@section foo\nast u8", &.{ error.ExpectedElsewhere });
    try testSemaErr("@section foo\nu8 255", &.{});
    // fixme: get rid of generic errors
    // try testSemaErr("@section foo\nu8 256", &.{ error.ResultType, error.NoteCalledFromHere });
    try testSemaErr("@section foo\nfoo", &.{ error.UnknownInstruction });
    try testSemaErr("@header foo\n@end\n@section foo\n@foo", &.{});
}

// fixme: testing without token location
// test "instruction codegen" {
//     try testSemaGen("@section foo\ncli", &.{ .{ .cli = {} } });
//     try testSemaGen("@section foo\nast ra", &.{ .{ .ast = .{ .ra } } });
//     // fixme: represent/check values
//     // try testSemaGen("@section foo\nu8 0", &.{ .{ .u8 = .{ 0 } } });
//     // try testSemaGen("@section foo\nu8 255", &.{ .{ .u8 = .{ 255 } } });
//     // fixme: different slice pointers... Zig problem
//     // try testSemaGen("@section foo\nascii \"hello world!\"", &.{ .{ .ascii = .{ .{ .memory = "hello world!", .sentinel = null } } } });
//     // try testSemaGen("@section foo\nascii \"hello world!\" 0", &.{ .{ .ascii = .{ .{ .memory = "hello world!", .sentinel = 0 } } } });
//     // fixme: represent/check 0xFFFF
//     // try testSemaGen("@section foo\nmst sf, 0xFFFF", &.{ .{ .mst = .{ .sf, 0xFFFF } } });
//     // try testSemaGen("@section foo\nmst' sf, 0xFFFF", &.{ .{ .mst_ = .{ .sf, 0xFFFF } } });
// }

test "@region" {
    try testSemaGen(
        \\@section foo
        \\@region 1
        \\cli
        \\@end
    , &.{
        .{ .cli = {} },
        .{ .ld_padding = .{ 0 } }
    });

    try testSemaGen(
        \\@section foo
        \\@region 24
        \\cli
        \\@end
    , &.{
        .{ .cli = {} },
        .{ .ld_padding = .{ 23 } }
    });

    try testSemaErr(
        \\@section foo
        \\@region 1
        \\u16 0
        \\@end
    , &.{
        error.RegionExceedsSize
    });
}

test "@align" {
    try testSemaErr(
        \\@section foo
        \\@align 5
    , &.{
        error.AlignPowerTwo
    });

    try testSemaGen(
        \\@section foo
        \\@align 8
    , &.{
        .{ .ld_padding = .{ 0 } }
    });

    try testSemaGenAnd(
        \\@section foo
        \\cli
        \\@align 8
    , &.{
        .{ .cli = {} },
        .{ .ld_padding = .{ 7 } }
    }, struct {
        fn run(sema: *AsmSemanticAir) !void {
            const section = sema.current_section.?;
            try std.testing.expectEqual(@as(u16, 8), section.alignment);
        }
    }.run);

    try testSemaGenAnd(
        \\@section foo
        \\cli
        \\@align 8
        \\@align 16
    , &.{
        .{ .cli = {} },
        .{ .ld_padding = .{ 7 } },
        .{ .ld_padding = .{ 8 } }
    }, struct {
        fn run(sema: *AsmSemanticAir) !void {
            const section = sema.current_section.?;
            try std.testing.expectEqual(@as(u16, 16), section.alignment);
        }
    }.run);

    try testSemaGenAnd(
        \\@section foo
        \\cli
        \\@align 16
        \\@align 8
    , &.{
        .{ .cli = {} },
        .{ .ld_padding = .{ 15 } },
        .{ .ld_padding = .{ 0 } }
    }, struct {
        fn run(sema: *AsmSemanticAir) !void {
            const section = sema.current_section.?;
            try std.testing.expectEqual(@as(u16, 16), section.alignment);
        }
    }.run);
}

test "@barrier" {
    try testSemaErr(
        \\@section foo
        \\@barrier foo
        \\@barrier 5
    , &.{
        error.Unexpected,
        error.Unexpected
    });

    try testSemaErr(
        \\@barrier
        \\@section foo
    , &.{
        error.MissingBarrierContext
    });

    // try testSemaGen(
    //     \\@section foo
    //     \\cli
    //     \\@barrier
    //     \\ast ra
    // , &.{
    //     // checks only last added section
    //     .{ .ast = .{ .ra } }
    // });

    try testSemaGenAnd(
        \\@section foo
        \\@align 16
        \\@barrier
        \\@align 8
    , &.{
        .{ .ld_padding = .{ 0 } }
    }, struct {
        fn run(sema: *AsmSemanticAir) !void {
            const section = sema.current_section.?;
            try std.testing.expectEqual(@as(u16, 8), section.alignment);
        }
    }.run);

    try testSemaGenAnd(
        \\@section foo
        \\@barrier
    , &.{}, struct {
        fn run(sema: *AsmSemanticAir) !void {
            const section = sema.current_section.?;
            try std.testing.expect(section.is_removable);
        }
    }.run);

    try testSemaGenAnd(
        \\@section(noelimination) foo
        \\@barrier
    , &.{}, struct {
        fn run(sema: *AsmSemanticAir) !void {
            const section = sema.current_section.?;
            try std.testing.expect(!section.is_removable);
        }
    }.run);
}

test "linking .label symbols" {
    try testSemaErr(
        \\@define bar, .foo
        \\@section foo
        \\.foo: jmpr .bar
    , &.{
        error.NonConformingSymbol,
        error.NoteDefinedHere
    });

    try testSemaErr(
        \\@define bar, .foo
        \\@define roo, .bar
        \\@section foo
        \\.foo: jmpr @roo
    , &.{
        error.NonConformingSymbol,
        error.NoteCalledFromHere,
        error.NoteDefinedHere
    });

    try testSemaErr(
        \\@section foo
        \\.foo: jmpr @foo
    , &.{
        error.NonConformingSymbol,
        error.NoteDefinedHere
    });

    try testSemaErr(
        \\@define bar, @foo
        \\@section foo
        \\.foo: jmpr @bar
    , &.{
        error.NonConformingSymbol,
        error.NoteCalledFromHere,
        error.NoteDefinedHere
    });

    try testSemaResult(
        \\@section foo
        \\.foo: jmpr .foo
    , struct {
        fn run(sema: *AsmSemanticAir) !void {
            try std.testing.expectEqual(@as(usize, 1), sema.references.count());
            const foo = sema.references.get("foo");
            try std.testing.expect(foo != null);
            try std.testing.expectEqual(@as(usize, 0), foo.?.instruction_index);
        }
    }.run);

    try testSemaResult(
        \\@define bar, .foo
        \\@section foo
        \\      cli
        \\      jmpr @bar
        \\      cli
        \\.foo: cli
        \\      jmpr .foo
    , struct {
        fn run(sema: *AsmSemanticAir) !void {
            try std.testing.expectEqual(@as(usize, 1), sema.references.count());
            const foo = sema.references.get("foo");
            try std.testing.expect(foo != null);
            try std.testing.expectEqual(@as(usize, 3), foo.?.instruction_index);
        }
    }.run);
}

test "@linkinfo" {
    try testSemaErr(
        \\@linkinfo(expose) text, 0
        \\@linkinfo(noelimination) text, 0
        \\@linkinfo(origin) text, 0
        \\@linkinfo(align) text, 0
    , &.{
        error.UnsupportedOption,
        error.UnsupportedOption
    });

    try testSemaErr(
        \\@linkinfo(origin) text, "baaah"
    , &.{
        error.Expected
    });

    try testSemaResult(
        \\@linkinfo foo, 5
    , struct {
        fn run(sema: *AsmSemanticAir) !void {
            try std.testing.expectEqual(@as(usize, 1), sema.link_info.items.len);
            const foo = sema.link_info.items[0];
            try std.testing.expectEqualSlices(u8, "foo", foo.key);
            try std.testing.expectEqual(@as(?[]const u8, null), foo.subject);
            try std.testing.expectEqual(@as(u32, 5), foo.value);
        }
    }.run);

    try testSemaResult(
        \\@linkinfo(origin) text, 5
    , struct {
        fn run(sema: *AsmSemanticAir) !void {
            try std.testing.expectEqual(@as(usize, 1), sema.link_info.items.len);
            const foo = sema.link_info.items[0];
            try std.testing.expectEqualSlices(u8, "origin", foo.key);
            try std.testing.expect(foo.subject != null);
            try std.testing.expectEqualSlices(u8, "text", foo.subject.?);
            try std.testing.expectEqual(@as(u32, 5), foo.value);
        }
    }.run);
}

test "lowering @define symbols" {
    // fixme: represent/check values
    // try testSemaGen(
    //     \\@define foo, 24
    //     \\@section foo
    //     \\          u16 @foo
    // , &.{
    //     .{ .u16 = .{ 24 } }
    // });

    // fixme: represent/check values
    // try testSemaGen(
    //     \\@define foo, @bar
    //     \\@define bar, 24
    //     \\@section foo
    //     \\          u16 @foo
    // , &.{
    //     .{ .u16 = .{ 24 } }
    // });

    try testSemaErr(
        \\@define foo, 0
        \\@section foo
        \\          u8 @foo
    , &.{});

    // fixme: numeric bounds checking are done at linktime
    // try testSemaErr(
    //     \\@define foo, 256
    //     \\@section foo
    //     \\          u8 @foo
    // , &.{
    //     error.ResultType,
    //     // error.NoteDefinedHere // fixme: add type-defined-here error
    //     error.NoteCalledFromHere // fixme: only add this note when error is generated from @define
    // });

    try testSemaErr(
        \\@define foo, ra
        \\@section foo
        \\          u8 @foo
    , &.{
        error.UnlinkableToken,
        error.NoteCalledFromHere
    });

    try testSemaErr(
        \\@header foo
        \\@end
        \\@section foo
        \\          u8 @foo
    , &.{
        error.HeaderResultType
    });
}

test "unrolling @header symbols" {
    try testSemaErr(
        \\@header foo
        \\@end
        \\@section text
        \\          foo
    , &.{
        error.UnknownInstruction,
        error.NoteDidYouMean
    });

    try testSemaErr(
        \\@header foo
        \\@end
        \\@section text
        \\          bar
    , &.{
        error.UnknownInstruction
    });

    try testSemaErr(
        \\@header foo
        \\@end
        \\@section text
        \\          @foo
    , &.{});

    try testSemaErr(
        \\@header foo, a
        \\@end
        \\@section text
        \\          @foo
    , &.{
        error.ExpectedArgumentsLen,
        error.NoteDefinedHere
    });

    try testSemaErr(
        \\@header foo, a
        \\          jmpr @a
        \\@end
        \\@section text
        \\          @foo 5
    , &.{});

    try testSemaErr(
        \\@header foo, a
        \\          jmpr @a
        \\@end
        \\@section text
        \\          @foo ra
    , &.{
        error.UnlinkableToken,
        error.NoteCalledFromHere
    });

    try testSemaErr(
        \\@header foo
        \\          @bar 0xFF
        \\@end
        \\@header bar, a
        \\          jmpr @a
        \\@end
        \\@section text
        \\          @foo
    , &.{});

    try testSemaErr(
        \\@header foo, a, b
        \\          jmpr @b
        \\          @a u24
        \\@end
        \\@header bar, a
        \\          reserve @a, 4
        \\@end
        \\@section text
        \\          @foo @bar, 0xFF
    , &.{});
}

test "full fledge" {
    try testSema1(
        \\@import foo, "foo"
        \\@define doo, rz
        \\@define(expose) bar, @doo
        \\@header roo
        \\          ast
        \\@end
        \\@section foo
        \\          ast ra
        \\.aaa:     ast rb
        \\bbb:      ast @bar
        \\@barrier
        \\          ast rd
        \\@define awd, this + lazy + eval + wont + error
    );

    try testSema1(
        \\@define foo, @bar
        \\@define bar, 0xFFFF
        \\
        \\@header roo, doo
        \\.doo:         ast ; lazily analysed
        \\@end
        \\
        \\@define doo, sf
        \\
        \\@section(noelimination) foo
        \\          @region 32
        \\              cli
        \\              ast rb
        \\              ascii "333"
        \\              @align 4
        \\              u16 @foo
        \\              u8 0b10101111
        \\              ascii "foo" 0
        \\              reserve u16, 4
        \\              mst' sf, @bar
        \\              mstw @doo, @bar
        \\          @end
    );
}
