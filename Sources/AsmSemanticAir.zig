
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
source: Source,
nodes: []const AsmAst.Node,
/// May not be modified during semantic analysis.
/// fixme: force namespaces to remove cross duplication problem?
imports: FileList,
/// Any symbol in the current unit. May not be modified during semantic
/// analysis.
symbols: SymbolMap,
sections: SectionMap,
current_section: ?*Section,
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
        .source = source,
        .nodes = nodes,
        .imports = .empty,
        .symbols = .empty,
        .sections = .empty,
        .current_section = null,
        .errors = .empty };
    errdefer self.deinit();
    try self.prepare_root();
    return self;
}

pub fn init_freestanding(allocator: std.mem.Allocator, source: Source, nodes: []const AsmAst.Node) !AsmSemanticAir {
    var self = AsmSemanticAir {
        .qcu = null,
        .allocator = allocator,
        .source = source,
        .nodes = nodes,
        .imports = .empty,
        .symbols = .empty,
        .sections = .empty,
        .current_section = null,
        .errors = .empty };
    errdefer self.deinit();
    try self.prepare_root();
    return self;
}

fn destroy_section(self: *AsmSemanticAir, section: *Section) void {
    if (section.next) |next|
        self.destroy_section(next);
    section.content.deinit(self.allocator);
    self.allocator.destroy(section);
}

pub fn deinit(self: *AsmSemanticAir) void {
    self.imports.deinit(self.allocator);
    self.symbols.deinit(self.allocator);

    for (self.sections.values()) |section|
        self.destroy_section(section);
    self.sections.deinit(self.allocator);
    self.current_section = null;

    for (self.errors.items) |err|
        self.allocator.free(err.message);
    self.errors.deinit(self.allocator);
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

pub const SymbolFile = struct {
    path: []const u8,
    token: Token,
    namespace: ?[]const u8,
    /// optional (1): unavailable (freestanding)
    /// pointer:      Qcu's sema field
    /// optional (2): whether file exists
    sema: ?*?AsmSemanticAir
};

pub const Symbol = union(enum) {

    pub const Locatable = struct {
        token: Token,
        symbol: Symbol,
        // fixme: instead of a boolean, use a check for a resolved value at
        // analysis time? inconsistencies with a @header due to args
        is_used: bool = false
    };

    label: Label,
    define: Define,
    header: Header,

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

    pub fn is_public(self: Symbol) bool {
        return switch (self) {
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
    /// Opaque list of (pseudo)instructions. All addresses during assembletime
    /// are relative to the start of the section.
    content: InstructionList = .empty,
    /// A section is allowed to be split by @barrier or duplicate @section
    /// tags, which links to a new, unnamed section.
    next: ?*Section = null,

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

const FileList = std.ArrayListUnmanaged(SymbolFile);
const SymbolMap = std.StringArrayHashMapUnmanaged(Symbol.Locatable);
const SectionMap = std.StringArrayHashMapUnmanaged(*Section);
const InstructionList = std.MultiArrayList(Instruction.Locatable);
const ErrorList = std.ArrayListUnmanaged(Error);
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
    for (from_address..std.math.maxInt(usize)) |address|
        if (address % mask == 0)
            return address;
    unreachable;
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

fn not_null(self: *AsmSemanticAir, index: AsmAst.Index) bool {
    _ = self;
    return index != AsmAst.Null;
}

fn is_null(self: *AsmSemanticAir, index: AsmAst.Index) bool {
    _ = self;
    return index == AsmAst.Null;
}

fn node_unwrap(self: *AsmSemanticAir, index: AsmAst.Index) ?AsmAst.Node {
    return if (self.not_null(index)) self.nodes[index] else null;
}

fn is_valid_symbol(self: *AsmSemanticAir, string: []const u8) bool {
    _ = self;
    return std.mem.startsWith(u8, string, "@") and string.len > 1;
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

    pub fn next(self: *ContainerIterator) ?AsmAst.Node {
        if (self.is_the_end())
            return null;
        const index = self.current();
        self.cursor += 1;
        return self.sema.nodes[index];
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
    ImportNotFound,
    IllegalUnaryOp,
    UnlinkableToken,
    UnlinkableExpression,
    ResultType,
    NoteDefinedHere,
    NoteCalledFromHere,
    NoteDidYouMean,
    Generic,
    GenericToken
};

fn add_error(self: *AsmSemanticAir, comptime err: SemanticError, argument: anytype) !void {
    @branchHint(.unlikely);

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
        error.ImportNotFound => "file to import not found",
        error.IllegalUnaryOp => "illegal {s} operation with {s}",
        error.UnlinkableToken => "{s} is not supported in a linkable result type",
        error.UnlinkableExpression => "expression is unlinkable",
        error.ResultType => "numeric literal doesn't fit in result type {s}",
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
        error.ExpectedArgumentsLen => argument[0],
        error.Expected,
        error.ExpectedContext,
        error.DuplicateSymbol,
        error.AlignPowerTwo,
        error.NonEmptyModifier,
        error.ResultType,
        error.IllegalUnaryOp,
        error.NoteDefinedHere => argument[1],
        error.ExpectedElsewhere,
        error.RegionExceedsSize,
        error.NoteDidYouMean,
        error.GenericToken => argument[2],
        error.Unexpected,
        error.UnsupportedOption,
        error.UselessSentinel,
        error.UnknownModifiedInstruction,
        error.UnknownInstruction,
        error.AmbiguousIdentifier,
        error.UnknownSymbol,
        error.ImportNotFound,
        error.MissingBarrierContext,
        error.UnlinkableToken,
        error.UnlinkableExpression,
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
        error.UnlinkableToken => .{ argument.tag.fmt() },
        error.UnsupportedOption,
        error.UnknownModifiedInstruction,
        error.AmbiguousIdentifier,
        error.UnknownSymbol => .{ token_slice.? },
        error.UselessSentinel,
        error.UnknownInstruction,
        error.ImportNotFound,
        error.MissingBarrierContext,
        error.UnlinkableExpression,
        error.NoteCalledFromHere => .{},
        error.DuplicateSymbol,
        error.AlignPowerTwo,
        error.NonEmptyModifier,
        error.ResultType => .{ argument[0] },
        error.RegionExceedsSize,
        error.NoteDidYouMean,
        error.GenericToken => .{ argument[0], argument[1] },
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

fn return_error(self: *AsmSemanticAir, comptime err: SemanticError, argument: anytype) (SemanticError || std.mem.Allocator.Error)!noreturn {
    try self.add_error(err, argument);
    return err;
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
                    .builtin_define => {
                        const define = try self.prepare_define(node) orelse continue;
                        try self.maybe_emit_duplicate_error(define);
                        try symbol_map.put(self.allocator, define.name, .{
                            .token = define.token,
                            .symbol = define.symbol });
                    },

                    .builtin_header => {
                        const header = try self.prepare_header(node) orelse continue;
                        try self.maybe_emit_duplicate_error(header);
                        try symbol_map.put(self.allocator, header.name, .{
                            .token = header.token,
                            .symbol = header.symbol });
                    },

                    .builtin_symbols => {
                        const symbols = try self.prepare_symbols(node) orelse continue;
                        // fixme: check for duplicate namespace or existing symbol?
                        try self.imports.append(self.allocator, symbols);
                    },

                    .builtin_region,
                    .builtin_section,
                    .builtin_barrier => {
                        if (self.node_unwrap(composite.operands.rhs)) |opaque_|
                            try self.prepare_opaque_container(opaque_, symbol_map);
                    },

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

                if (self.is_null(node.operands.rhs))
                    continue;
                const composite = self.nodes[node.operands.rhs];
                astgen_assert(self.node_is_null_or(composite.operands.lhs, .container));
                astgen_assert(self.node_is_null_or(composite.operands.rhs, .modifier));

                if (self.is_null(composite.operands.lhs))
                    continue;
                var labels = ContainerIterator.init_index(self, composite.operands.lhs);

                while (try labels.gracefully_expect(.label)) |label_node| {
                    astgen_assert(self.is_null(label_node.operands.lhs));
                    astgen_assert(self.is_null(label_node.operands.rhs));

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

// fixme: remove
fn emit_resolved_expected_error(
    self: *AsmSemanticAir,
    expected_token: anytype,
    origin_token: Token,
    resolved_token: Token
) !void {
    // called after resolve, which means identifiers are guaranteed to be
    // unlowered headers
    if (resolved_token.tag == .identifier)
        try self.add_error(error.ExpectedElsewhere, .{ expected_token, Token.string("a @header call"), origin_token }) else
        try self.add_error(error.ExpectedElsewhere, .{ expected_token, resolved_token.tag, origin_token });
    if (!origin_token.location.eql(resolved_token.location))
        try self.add_error(error.NoteDefinedHere, .{ resolved_token.tag, resolved_token });
}

// fixme: remove
fn emit_resolved_generic_error(
    self: *AsmSemanticAir,
    message: anytype,
    topic: anytype,
    origin_token: Token,
    resolved_token: Token
) !void {
    try self.add_error(error.GenericToken, .{ message, topic, origin_token });
    if (!origin_token.location.eql(resolved_token.location))
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
    astgen_assert(self.is_null(composite.operands.rhs));

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
        .content = if (self.not_null(composite.operands.rhs))
            self.nodes[composite.operands.rhs].operands else
            .{},
        .is_public = self.contains_option(options_, .expose) };
    return .{
        .name = name,
        .token = header_token,
        .symbol = .{ .header = header } };
}

fn prepare_symbols(self: *AsmSemanticAir, node: AsmAst.Node) !?SymbolFile {
    const composite = self.nodes[node.operands.rhs];
    if (self.node_unwrap(composite.operands.lhs)) |options_|
        _ = try self.parse_options(options_, &.{});
    const symbols_token = self.source.tokens[node.token];
    var arguments = ContainerIterator.init_index_context(self, node.operands.lhs, symbols_token);

    const path_string_node = try arguments.expect(.string) orelse return null;
    const path_string_token = self.source.tokens[path_string_node.token];
    const path_string = path_string_token.content_slice(self.source.buffer);
    astgen_assert(path_string_token.tag == .string_literal);
    try self.maybe_emit_sentinel_error(path_string_node.operands.lhs);

    const namespace_node = try arguments.gracefully_expect(.identifier);
    const namespace = if (namespace_node) |namespace_node_|
        self.source.tokens[namespace_node_.token].location.slice(self.source.buffer) else
        null;
    try arguments.expect_end();
    astgen_assert(self.is_null(composite.operands.rhs));

    const sema = if (self.qcu) |qcu| qcu.resolve(path_string) catch |err| switch (err) {
        error.FileNotFound => blk: {
            try self.add_error(error.ImportNotFound, path_string_token);
            break :blk null;
        },
        else => |err_| return err_
    } else null;

    return .{
        .path = path_string,
        .token = symbols_token,
        .namespace = namespace,
        .sema = sema };
}

const Option = enum {
    expose,
    noelimination
};

const options_map = std.StaticStringMap(Option).initComptime(.{
    .{ "expose", .expose },
    .{ "noelimination", .noelimination }
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
        astgen_assert(self.not_null(option_node.token));
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
    astgen_assert(self.is_null(node.operands.rhs));

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
    try self.analyse_container(self.nodes[0]);
}

fn analyse_container(self: *AsmSemanticAir, parent_node: AsmAst.Node) !void {
    for (parent_node.operands.lhs..parent_node.operands.rhs) |node_idx| {
        const node = self.nodes[node_idx];
        const token = self.source.tokens[node.token];

        switch (node.tag) {
            .builtin => switch (token.tag) {
                .builtin_align => try self.emit_align(node),

                .builtin_barrier => {
                    try self.emit_barrier(node);
                    const composite = self.nodes[node.operands.rhs];
                    if (self.node_unwrap(composite.operands.rhs)) |opaque_|
                        try self.analyse_container(opaque_);
                },

                .builtin_region => {
                    const section = self.current_section orelse astgen_failure();
                    const begin_address = section.size();
                    const composite = self.nodes[node.operands.rhs];
                    if (self.node_unwrap(composite.operands.rhs)) |opaque_|
                        try self.analyse_container(opaque_);

                    const len = section.size() - begin_address;
                    try self.emit_region(node, len);
                },

                .builtin_section => {
                    self.emit_section(node) catch |err| switch (err) {
                        error.SectionCreateFailed => continue,
                        else => |err_| return err_
                    };

                    const composite = self.nodes[node.operands.rhs];
                    if (self.node_unwrap(composite.operands.rhs)) |opaque_|
                        try self.analyse_container(opaque_);
                },

                // nothing to do here
                .builtin_define,
                .builtin_header,
                .builtin_symbols => {},

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
    const section = self.current_section orelse return astgen_failure();
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
        is_labeled: bool,
        instruction: Instruction
    };

    // fixme: IMM: allow both signed and unsigned values

    cli,
    ast: struct { GpRegister },
    rst: struct { GpRegister },
    jmp: struct { Expression(u16) },
    jmpr: struct { Expression(i8) }, // fixme: interpret as u16, calculate relative automatically to i8
    jmpd,
    mst: struct { SpRegister, Expression(u16) },
    mst_: struct { SpRegister, Expression(u16) },
    mstw: struct { SpRegister, Expression(u16) },
    mstw_: struct { SpRegister, Expression(u16) },
    mld: struct { SpRegister, Expression(u16) },
    mld_: struct { SpRegister, Expression(u16) },
    mldw: struct { SpRegister, Expression(u16) },
    mldw_: struct { SpRegister, Expression(u16) },

    // mst: struct { u1, u2, LinkNode },
    // mstd: struct { u1, u2, LinkNode },

    // pseudoinstructions
    u8: struct { Expression(u8) },
    u16: struct { Expression(u16) },
    u24: struct { Expression(u24) },
    i8: struct { Expression(i8) },
    i16: struct { Expression(i16) },
    i24: struct { Expression(i24) },
    ascii: struct { StringContent },
    reserve: struct { TypeSize, Expression(u16) }, // fixme: force constant

    // adds fixed zero bytes
    ld_padding: struct { usize },

    // symbol reference during link time
    // symbol address, section address, calculated offset from offset and
    // name
    // ld_symbol: LinkNode.Symbol,

    pub const Tag = enum {

        cli,
        ast,
        rst,
        jmp,
        jmpr,
        jmpd,
        mst,
        mst_,
        mstw,
        mstw_,
        mld,
        mld_,
        mldw,
        mldw_,
        u8,
        u16,
        u24,
        i8,
        i16,
        i24,
        ascii,
        reserve,
        ld_padding,
        // ld_symbol,

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
                .mst_,
                .mstw,
                .mstw_,
                .mld,
                .mld_,
                .mldw,
                .mldw_ => 3,

                .u8, .i8 => 1,
                .u16, .i16 => 2,
                .u24, .i24 => 3,

                .ascii,
                .reserve,
                .ld_padding => 0
            };
        }
    };

    pub const GpRegister = enum(u3) {
        zr,
        ra,
        rb,
        rc,
        rd,
        rx,
        ry,
        rz
    };

    pub const SpRegister = enum(u2) {
        sp,
        sf,
        adr,
        zr
    };

    pub const StringContent = struct {

        memory: []const u8,
        sentinel: ?u8,

        pub fn size(self: StringContent) usize {
            const sentinel_: usize = if (self.sentinel != null) 1 else 0;
            return self.memory.len + sentinel_;
        }
    };

    pub const TypeSize = struct {
        size: u16
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
        .{ "mst", .mst_ },
        .{ "mstw", .mstw_ },
        .{ "mld", .mst_ },
        .{ "mldw", .mldw_ }
    });

    comptime {
        // Zig comptime validation, hell yeah!
        for (@typeInfo(Tag).@"enum".fields) |instruction_tag| {
            if (std.mem.startsWith(u8, instruction_tag.name, "ld_"))
                continue;
            const real_instruction = std.mem.trimRight(u8, instruction_tag.name, "_");
            const mapping: ?Instruction.Tag = instruction_map.get(real_instruction) orelse
                modifier_map.get(real_instruction);
            if (mapping) |mapping_| {
                const real_mapping = std.mem.trimRight(u8, instruction_tag.@"name", "_");
                if (!std.mem.eql(u8, real_mapping, @tagName(mapping_)))
                    @compileError("bug: mismatching mapping/instruction: " ++ @tagName(mapping_) ++ " / " ++ real_instruction);
            } else @compileError("bug: unmapped instruction: " ++ real_instruction);
        }
    }

    pub fn size(self: Instruction) usize {
        return switch (self) {
            .ascii => |args| args[0].size(),
            .reserve => |args| args[0].size * (args[1].assembletime_offset orelse 0),
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

    const section = self.current_section orelse return astgen_failure();
    try self.emit_labels(section, labels);

    const arguments = if (self.node_unwrap(node.operands.lhs)) |arguments_node|
        arguments_node.operands else
        null;
    const is_labeled = (labels.rhs - labels.lhs) > 0;
    try self.emit_instructions(token, is_modified, is_labeled, arguments);
}

fn emit_labels(self: *AsmSemanticAir, section: *Section, labels: AsmAst.IndexRange) !void {
    // fixme: for all labels, append to symbol table
    const current_address = section.size();
    _ = current_address;
    _ = self;
    _ = labels;
}

fn emit_instructions(
    self: *AsmSemanticAir,
    token: Token,
    is_modified: bool,
    is_labeled: bool,
    arguments: ?AsmAst.IndexRange
) !void {
    const section = self.current_section orelse return astgen_failure();
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
                // fixme: lookup imports
                const symbol = self.symbols.get(string) orelse return;
                if (symbol.symbol == .header)
                    try self.add_error(error.NoteDidYouMean, .{ "call the header @", string, symbol.token });
                return;
            }

            // fixme: add identifier header lookup and recursive analyse_container() call
            // ...
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

                casted_arguments[i] = switch (Type) {
                    Instruction.GpRegister => try self.cast_gp_register(user_argument),
                    Instruction.SpRegister => try self.cast_sp_register(user_argument),
                    // fixme: remove fixed types?
                    u8, u16, u24, i8, i16, i24 => try self.cast_numeric_expression(Type, user_argument),
                    Instruction.StringContent => try self.cast_string_content(user_argument),
                    Instruction.TypeSize => try self.cast_type_size(user_argument),

                    Expression(i8) => try Type.lower_root_tree(self, user_argument, token),
                    Expression(u8) => try Type.lower_root_tree(self, user_argument, token),
                    Expression(i16) => try Type.lower_root_tree(self, user_argument, token),
                    Expression(u16) => try Type.lower_root_tree(self, user_argument, token),
                    Expression(i24) => try Type.lower_root_tree(self, user_argument, token),
                    Expression(u24) => try Type.lower_root_tree(self, user_argument, token),

                    usize => astgen_failure(),
                    else => @compileError("bug: missing casting implementation for " ++ @typeName(Type))
                } orelse return null;
            }

            return @unionInit(Instruction, instruction.name, casted_arguments);
        }
    }

    astgen_failure();
}

fn cast_gp_register(self: *AsmSemanticAir, node: AsmAst.Node) !?Instruction.GpRegister {
    const expression = try self.lower_expression_tree(node) orelse return null;
    const string = expression.token.content_slice(self.source.buffer);

    return std.meta.stringToEnum(Instruction.GpRegister, string) orelse {
        try self.emit_resolved_expected_error(Token.string("a general-purpose register"), self.source.tokens[node.token], expression.token);
        return null;
    };
}

fn cast_sp_register(self: *AsmSemanticAir, node: AsmAst.Node) !?Instruction.SpRegister {
    const expression = try self.lower_expression_tree(node) orelse return null;
    const string = expression.token.content_slice(self.source.buffer);

    return std.meta.stringToEnum(Instruction.SpRegister, string) orelse {
        try self.emit_resolved_expected_error(Token.string("a special-purpose register"), self.source.tokens[node.token], expression.token);
        return null;
    };
}

fn cast_string_content(self: *AsmSemanticAir, node: AsmAst.Node) !?Instruction.StringContent {
    const expression = try self.lower_expression_tree(node) orelse return null;
    const string = expression.token.content_slice(self.source.buffer);

    if (expression.token.tag != .string_literal) {
        try self.emit_resolved_expected_error(AsmAst.Node.Tag.string, self.source.tokens[node.token], expression.token);
        return null;
    }

    const sentinel = if (self.node_unwrap(node.operands.lhs)) |sentinel_node|
        try self.cast_numeric_literal(u8, sentinel_node) else
        null;
    return .{
        .memory = string,
        .sentinel = sentinel };
}

const inherit_base = 0;

fn cast_numeric_literal(self: *AsmSemanticAir, comptime T: type, node: AsmAst.Node) !?T {
    const expression = try self.lower_expression_tree(node) orelse return null;
    const string = expression.token.location.slice(self.source.buffer);

    if (expression.token.tag != .numeric_literal) {
        try self.emit_resolved_expected_error(AsmAst.Node.Tag.integer, self.source.tokens[node.token], expression.token);
        return null;
    }

    return std.fmt.parseInt(T, string, inherit_base) catch |err| switch (err) {
        error.InvalidCharacter => astgen_failure(),
        error.Overflow => {
            try self.emit_resolved_generic_error("numeric literal doesn't fit in type ", @typeName(T), self.source.tokens[node.token], expression.token);
            return null;
        }
    };
}

fn cast_numeric_expression(self: *AsmSemanticAir, comptime T: type, node: AsmAst.Node) !?T {
    // fixme: expression support, not only unsigned integers
    return self.cast_numeric_literal(T, node);
}

fn cast_type_size(self: *AsmSemanticAir, node: AsmAst.Node) !?Instruction.TypeSize {
    const expression = try self.lower_expression_tree(node) orelse return null;
    const string = expression.token.location.slice(self.source.buffer);

    if (expression.token.tag != .instruction and
        expression.token.tag != .pseudo_instruction and
        expression.token.tag != .identifier
    ) {
        try self.emit_resolved_expected_error(Token.string("a basic opaque"), self.source.tokens[node.token], expression.token);
        return null;
    }

    const size = switch (expression.token.tag) {
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

// fixme: expression evaluation
pub fn lower_expression_tree(self: *AsmSemanticAir, node: AsmAst.Node) !?struct { token: Token } {
    const token = self.source.tokens[node.token];

    if (token.tag != .identifier)
        return .{ .token = token };
    const identifier = token.location.slice(self.source.buffer);

    if (!self.is_valid_symbol(identifier)) {
        try self.add_error(error.AmbiguousIdentifier, token);
        return null;
    }

    const sema, const symbol = self.fetch_symbol(identifier[1..]) orelse {
        try self.add_error(error.UnknownSymbol, token);
        return null;
    };

    // for liveness pass
    symbol.is_used = true;

    return switch (symbol.symbol) {
        .label => unreachable, // labels cannot start with @
        .define => |define| try sema.lower_expression_tree(sema.nodes[define.value_node]),
        .header => .{ .token = token } // headers aren't expanded in arguments
    };
}

fn Expression(comptime ResultType: type) type {
    comptime {
        const allowedTypes = [_]type { u8, u16, u24, i8, i16, i24 };
        if (std.mem.indexOfScalar(type, &allowedTypes, ResultType) == null)
            @compileError("bug: type " ++ @typeName(ResultType) ++ " is illegal");
    }

    return struct {

        const ExpressionType = @This();
        const result_info = @typeInfo(ResultType).int;

        // fixme: change Expression(type) into a link node, change Node tag to
        // linknode type
        // const LinkNode = union(enum) {

        //     constant8: u8,
        //     constant16: u16,
        //     label8l: struct { AsmAst.Index, u8 },
        //     label8h: struct { AsmAst.Index, u8 },
        //     label16: struct { AsmAst.Index, u16 }
        // };

        tag: AsmAst.Node.Tag,
        token: Token,
        linktime_label: ?AsmAst.Index = null,
        assembletime_offset: ?ResultType = null,

        pub fn lower_root_tree(sema: *AsmSemanticAir, node: AsmAst.Node, reference_token: Token) !?ExpressionType {
            return ExpressionType.lower_tree(sema, node) catch |err| switch (err) {
                error.OutOfMemory => |err_| return err_,
                else => blk: {
                    try sema.add_error(error.NoteCalledFromHere, reference_token);
                    break :blk null;
                }
            };
        }

        // fixme: this should be illegal: (.label + 5) * @foo
        pub fn lower_tree(sema: *AsmSemanticAir, node: AsmAst.Node) !ExpressionType {
            const token = sema.source.tokens[node.token];

            return result: switch (node.tag) {
                .identifier => {
                    astgen_assert(token.tag == .identifier);
                    const identifier = token.location.slice(sema.source.buffer);

                    if (!sema.is_valid_symbol(identifier))
                        return try sema.return_error(error.AmbiguousIdentifier, token);
                    const symbols_sema, const symbol = sema.fetch_symbol(identifier[1..]) orelse
                        return try sema.return_error(error.UnknownSymbol, token);

                    // for liveness pass
                    symbol.is_used = true;

                    break :result switch (symbol.symbol) {
                        .label => unreachable, // labels cannot start with @
                        .define => |define| try ExpressionType.lower_tree(symbols_sema, symbols_sema.nodes[define.value_node]),
                        .header => .{ .tag = node.tag, .token = token } // headers aren't expanded in arguments
                    };
                },

                .neg,
                .inv => {
                    const operand = try ExpressionType.lower_tree(sema, sema.nodes[node.operands.lhs]);
                    const assembletime_operand = operand.assembletime_offset orelse
                        return try sema.return_error(error.IllegalUnaryOp, .{ @tagName(node.tag), operand.token });
                    const assembletime_evaluation = try ExpressionType.evaluate(sema, node.tag, token, assembletime_operand, 0);

                    break :result .{
                        .tag = operand.tag,
                        .token = token,
                        .assembletime_offset = assembletime_evaluation };
                },

                .add,
                .sub,
                .mult,
                .lsh,
                .rsh => {
                    const lhs = try ExpressionType.lower_tree(sema, sema.nodes[node.operands.lhs]);
                    const rhs = try ExpressionType.lower_tree(sema, sema.nodes[node.operands.rhs]);

                    break :result expr: switch (node.tag) {
                        // add(ref, ref) = illegal
                        // add(int, ref) = offset/int
                        // add(ref, int) = offset/int
                        // add(int, int) = int
                        .add => {
                            if (lhs.linktime_label != null and rhs.linktime_label != null)
                                return try sema.return_error(error.GenericToken, .{ "unable to evaluate assemble-time expression", "", token });
                            if (lhs.assembletime_offset != null and rhs.linktime_label != null)
                                break :expr .{
                                    .tag = node.tag,
                                    .token = token,
                                    .linktime_label = rhs.linktime_label,
                                    .assembletime_offset = try ExpressionType.evaluate(sema, node.tag, token, lhs.assembletime_offset.?, rhs.assembletime_offset orelse 0) };
                            if (lhs.linktime_label != null and rhs.assembletime_offset != null)
                                break :expr .{
                                    .tag = node.tag,
                                    .token = token,
                                    .linktime_label = lhs.linktime_label,
                                    .assembletime_offset = try ExpressionType.evaluate(sema, node.tag, token, lhs.assembletime_offset orelse 0, rhs.assembletime_offset.?) };
                            if (lhs.assembletime_offset != null and rhs.assembletime_offset != null)
                                break :expr .{
                                    .tag = node.tag,
                                    .token = token,
                                    .assembletime_offset = try ExpressionType.evaluate(sema, node.tag, token, lhs.assembletime_offset.?, rhs.assembletime_offset.?) };
                            unreachable;
                        },

                        // sub(int, ref) = illegal
                        // sub(ref, ref) = diff/int         ; this can only be done on local
                        // sub(ref, int) = offset/int
                        // sub(int, int) = int
                        .sub => {
                            if (lhs.assembletime_offset != null and rhs.linktime_label != null)
                                return try sema.return_error(error.GenericToken, .{ "illegal behaviour", "", token });
                            if (lhs.linktime_label != null and rhs.linktime_label != null)
                                break :expr .{
                                    .tag = node.tag,
                                    .token = token, // fixme: relative diff
                                    .assembletime_offset = 0 }; // + offsets on either side
                            if (lhs.linktime_label != null and rhs.assembletime_offset != null)
                                break :expr .{
                                    .tag = node.tag,
                                    .token = token,
                                    .linktime_label = lhs.linktime_label,
                                    .assembletime_offset = try ExpressionType.evaluate(sema, node.tag, token, lhs.assembletime_offset orelse 0, rhs.assembletime_offset.?) };
                            if (lhs.assembletime_offset != null and rhs.assembletime_offset != null)
                                break :expr .{
                                    .tag = node.tag,
                                    .token = token,
                                    .assembletime_offset = try ExpressionType.evaluate(sema, node.tag, token, lhs.assembletime_offset.?, rhs.assembletime_offset.?) };
                            unreachable;
                        },

                        // lsh/rsh/mult(int, ref) = illegal
                        // lsh/rsh/mult(ref, ref) = illegal
                        // lsh/rsh/mult(ref, int) = illegal
                        // lsh/rsh/mult(int, int) = int
                        .mult,
                        .lsh,
                        .rsh => if (lhs.assembletime_offset == null or rhs.assembletime_offset == null)
                            return try sema.return_error(error.GenericToken, .{ "unable to evaluate assemble-time expression", "", token }) else
                            .{
                                .tag = .integer,
                                .token = token,
                                .assembletime_offset = try ExpressionType.evaluate(sema, node.tag, token, lhs.assembletime_offset.?, rhs.assembletime_offset.?) },

                        else => unreachable
                    };
                },

                .reference => .{
                    .tag = node.tag,
                    .token = token,
                    .linktime_label = 0 }, // fixme: relative address

                .char => {
                    const ascii = token.location.slice(sema.source.buffer);
                    astgen_assert(ascii.len == 3); // 'a'

                    break :result .{
                        .tag = node.tag,
                        .token = token,
                        .assembletime_offset = @intCast(ascii[1]) };
                },

                .integer => .{
                    .tag = node.tag,
                    .token = token,
                    .assembletime_offset = try ExpressionType.parse_result_type(sema, token) },

                else => return try sema.return_error(error.UnlinkableToken, token)
            };
        }

        pub fn evaluate(sema: *AsmSemanticAir, operation: AsmAst.Node.Tag, token: Token, lhs: ResultType, rhs: ResultType) !ResultType {
            return switch (operation) {
                .inv => ~lhs,

                // fixme: negative numbers added to positive numbers should be allowed?
                .neg => if (result_info.signedness == .unsigned)
                    try sema.return_error(error.GenericToken, .{ "illegal negation for unsigned result type ", @typeName(ResultType), token }) else
                    -lhs,

                .add => lhs + rhs,
                .sub => lhs - rhs,
                .mult => lhs * rhs,
                .lsh => 0, // fixme: bitcast
                .rsh => 0,

                else => unreachable
            };
        }

        pub fn parse_result_type(sema: *AsmSemanticAir, token: Token) !?ResultType {
            const string = token.location.slice(sema.source.buffer);
            const inherit = 0;

            return std.fmt.parseInt(ResultType, string, inherit) catch |err| switch (err) {
                error.InvalidCharacter => astgen_failure(),
                error.Overflow => return try sema.return_error(error.ResultType, .{ @typeName(ResultType), token })
            };
        }
    };
}

fn fetch_symbol(self: *AsmSemanticAir, symbol_name: []const u8) ?struct { *AsmSemanticAir, *Symbol.Locatable } {
    const own_symbol = self.symbols.getPtr(symbol_name) orelse {
        // for (self.imports.items) |import| {
        //     const foreign_symbol = import.sema.?.*.?.symbols.getPtr(symbol_name) orelse continue;
        //     if (foreign_symbol.symbol.is_public())
        //         return .{ &import.sema.?.*.?, foreign_symbol };
        // }
        return null;
    };

    return .{ self, own_symbol };
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

    if (options.dump) {
        try stderr.print("Imports ({}):\n", .{ sema.imports.items.len });
        for (sema.imports.items) |import|
            try stderr.print("    {s} = {s}\n", .{ import.namespace orelse "_", import.path });
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
                    header.is_public })
            }
        }
    }

    for (sema.errors.items) |err|
        try err.write("test.s", input, stderr);
    try std.testing.expect(sema.errors.items.len == 0);
}

fn testSema2(input: [:0]const u8) !void {
    var ast, var sema = try testSema(input);
    defer testSemaFree(&ast, &sema);
    try sema.semantic_analyse();

    if (options.dump)
        try sema.dump(stderr);
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

fn testSemaGenAnd(input: [:0]const u8, output: []const Instruction, func: anytype) !void {
    var ast, var sema = try testSema(input);
    defer testSemaFree(&ast, &sema);
    try sema.semantic_analyse();

    for (sema.errors.items) |err|
        try err.write("test.s", input, stderr);
    try std.testing.expect(sema.errors.items.len == 0);
    try std.testing.expectEqualSlices(Instruction, sema.current_section.?.content.items(.instruction), output);
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

test "@symbols" {
    try testSemaErr("@symbols", &.{ error.ExpectedContext });
    try testSemaErr("@symbols foo", &.{ error.Expected });
    try testSemaErr("@symbols 5", &.{ error.Expected });
    try testSemaErr("@symbols \"foo\"", &.{});
    try testSemaErr("@symbols \"foo\" 0", &.{ error.UselessSentinel });
    // fixme: adds additional unexpected error instead of moving on
    // try testSemaErr("@symbols \"foo\", 0", &.{ error.Expected, error.Unexpected });
    try testSemaErr("@symbols \"foo\", foo", &.{});
    try testSemaErr("@symbols \"foo\", foo, foo", &.{ error.Unexpected });
}

test "@section" {
    // try testSemaErr("@section", &.{ error.ExpectedContext });
    // try testSemaErr("@section 5", &.{ error.Expected });
    // try testSemaErr("@section ra", &.{ error.Expected });
    // try testSemaErr("@section foo", &.{});

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
    try testSemaErr("@section foo\nu8 256", &.{ error.ResultType, error.NoteCalledFromHere });
    try testSemaErr("@section foo\nfoo", &.{ error.UnknownInstruction });
    // fixme: add headers
    // try testSemaErr("@section foo\n@foo", &.{});
}

test "instruction codegen" {
    try testSemaGen("@section foo\ncli", &.{ .{ .cli = {} } });
    try testSemaGen("@section foo\nast ra", &.{ .{ .ast = .{ .ra } } });
    // fixme: represent/check values
    // try testSemaGen("@section foo\nu8 0", &.{ .{ .u8 = .{ 0 } } });
    // try testSemaGen("@section foo\nu8 255", &.{ .{ .u8 = .{ 255 } } });
    // fixme: different slice pointers... Zig problem
    // try testSemaGen("@section foo\nascii \"hello world!\"", &.{ .{ .ascii = .{ .{ .memory = "hello world!", .sentinel = null } } } });
    // try testSemaGen("@section foo\nascii \"hello world!\" 0", &.{ .{ .ascii = .{ .{ .memory = "hello world!", .sentinel = 0 } } } });
    // fixme: represent/check 0xFFFF
    // try testSemaGen("@section foo\nmst sf, 0xFFFF", &.{ .{ .mst = .{ .sf, 0xFFFF } } });
    // try testSemaGen("@section foo\nmst' sf, 0xFFFF", &.{ .{ .mst_ = .{ .sf, 0xFFFF } } });
}

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

    try testSemaGen(
        \\@section foo
        \\cli
        \\@barrier
        \\ast ra
    , &.{
        // checks only last added section
        .{ .ast = .{ .ra } }
    });

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

test "lowering @define symbols" {
    // fixme: represent/check values
    // try testSemaGen(
    //     \\@define foo, 24
    //     \\@section foo
    //     \\          u16 @foo
    // , &.{
    //     .{ .u16 = .{ 24 } }
    // });

    try testSemaErr(
        \\@define foo, 256
        \\@section foo
        \\          u8 @foo
    , &.{
        error.ResultType,
        // error.NoteDefinedHere // fixme: add type-defined-here error
        error.NoteCalledFromHere // fixme: only add this note when error is generated from @define
    });

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
        \\@header foo
        \\@end
        \\@section foo
        \\          u8 @foo
    , &.{
        // error.ExpectedElsewhere // fixme: disallow usage of headers in expressions
    });
}

test "full fledge" {
    try testSema1(
        \\@symbols "foo", foo
        \\@symbols "bar"
        \\@define(expose) foo, bar
        \\@header bar
        \\          ast
        \\@end
        \\@section foo
        \\          ast
        \\.aaa:     ast
        \\bbb:      ast
        \\@define awd, awd
    );

    try testSema2(
        \\@define foo, @bar
        \\@define bar, 0xFFFF
        \\
        \\@header roo, doo
        \\.doo:         ast
        \\@end
        \\
        \\@define doo, sf
        \\
        \\@section(noelimination) foo
        \\          @region 32
        \\              cli
        \\              ast rb
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
