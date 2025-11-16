
// Abstract Syntax Tree

const std = @import("std");
const SourceLocation = @import("SourceLocation.zig");
const AsmTokeniser = @import("AsmTokeniser.zig");
const Token = @import("Token.zig");

const AsmAst = @This();

/// Guaranteed to have at least one element (the end of file token).
tokens: []const Token,
/// Index = 0 is the root container node which references the other nodes.
nodes: []const Node,

/// From a source location, tokenises the buffer and parses them into an
/// Abstract Syntax Tree and deallocating the intermediate results. Errors are
/// emitted to the bridge. If any errors exist, the tree cannot be guaranteed
/// to be complete or valid.
pub fn init(
    allocator: std.mem.Allocator,
    source_location: *const SourceLocation,
    bridge: Bridge
) !AsmAst {
    var ast_gen = try AstGen.init(allocator, source_location, bridge);
    defer ast_gen.deinit();

    std.debug.assert(ast_gen.tokens.len > 0);
    std.debug.assert(ast_gen.tokens[ast_gen.tokens.len - 1].tag == .eof);

    try ast_gen.parse_root();

    std.debug.assert(ast_gen.nodes.items.len > 0);
    std.debug.assert(ast_gen.temporary.items.len == 0);

    return .{
        .tokens = ast_gen.tokens,
        .nodes = try ast_gen.nodes.toOwnedSlice(allocator) };
}

pub fn deinit(self: *AsmAst, allocator: std.mem.Allocator) void {
    allocator.free(self.tokens);
    allocator.free(self.nodes);
}

const render = @import("render.zig");

fn dump_node(self: *AsmAst, ais: anytype, pm: anytype, index: Index) !void {
    const node = self.nodes[index];
    try ais.print("{s}({})\n", .{ @tagName(node.tag), index });

    ais.pushIndent();
    defer ais.popIndent();

    if (pm[index]) {
        if (index != 0)
            try ais.print("warning: recursive node reference!\n", .{});
        return;
    }
    pm[index] = true;

    switch (node.tag) {
        .container => for (node.operands.lhs..node.operands.rhs) |i|
            try self.dump_node(ais, pm, @intCast(i)),

        .composite,
        .builtin,
        .instruction,
        .addition,
        .subtraction,
        .multiplication,
        .bitwise_or,
        .bitwise_and,
        .left_shift,
        .right_shift => {
            try self.dump_node(ais, pm, @intCast(node.operands.lhs));
            try self.dump_node(ais, pm, @intCast(node.operands.rhs));
        },

        .negation,
        .inversion => try self.dump_node(ais, pm, @intCast(node.operands.lhs)),

        .string,
        .reference => if (node.operands.lhs > 0)
            try self.dump_node(ais, pm, @intCast(node.operands.lhs)),

        .label,
        .identifier,
        .integer,
        .character,
        .modifier,
        .argument => {}
    }
}

pub fn dump(self: *AsmAst, allocator: std.mem.Allocator, writer: anytype) !void {
    const DumpStream = render.AutoIndentingStream(@TypeOf(writer));
    var renderer = DumpStream {
        .underlying_writer = writer,
        .indent_delta = 4 };
    const poke_map = try allocator.alloc(bool, self.nodes.len);
    defer allocator.free(poke_map);

    try self.dump_node(&renderer, poke_map, 0);

    for (poke_map, 0..) |poked, idx| {
        if (!poked)
            try renderer.print("warning: node {}={s} not poked\n", .{ idx, @tagName(self.nodes[idx].tag) });
    }
}

pub const Bridge = struct {

    const AllocatorError = std.mem.Allocator.Error;

    pub const VTable = struct {
        emit_error: *const fn (*anyopaque, SourceLocation.Error) AllocatorError!void
    };

    vtable: VTable,
    context: *anyopaque,

    fn emit_error(self: *Bridge, err: SourceLocation.Error) !void {
        try self.vtable.emit_error(self.context, err);
    }
};

pub const Node = struct {

    token: Index,
    tag: Tag,
    operands: Operands,

    pub const Tag = enum {
        /// nodes[lhs..rhs], hosted optionally
        container,
        /// lhs and rhs refer to other nodes, generically
        composite,
        /// lhs: arguments container
        /// rhs: composite of options identifier container and opaque
        /// token: the @builtin
        builtin,
        /// lhs: label, optional
        /// rhs: arguments container
        /// token: the instruction
        instruction,
        /// token: the label
        label,
        /// token: the identifier
        identifier,
        /// lhs: unary operand
        /// token: the unary operator
        negation,
        /// lhs: unary operand
        /// token: the unary operator
        inversion,
        /// lhs: left binary operand
        /// rhs: right binary operand
        /// token: the binary operator
        addition,
        /// lhs: left binary operand
        /// rhs: right binary operand
        /// token: the binary operator
        subtraction,
        /// lhs: left binary operand
        /// rhs: right binary operand
        /// token: the binary operator
        multiplication,
        /// lhs: left bitwise operand
        /// rhs: right bitwise operand
        /// token: the bitwise operator
        bitwise_or,
        /// lhs: left bitwise operand
        /// rhs: right bitwise operand
        /// token: the bitwise operator
        bitwise_and,
        /// lhs: left operand
        /// rhs: right shift operand
        /// token: the bitshift operator
        left_shift,
        /// lhs: left operand
        /// rhs: right shift operand
        /// token: the bitshift operator
        right_shift,
        /// token: the numeric literal
        integer,
        /// token: the char literal
        character,
        /// lhs: sentinel operand, optional
        /// token: the string literal
        string,
        /// lhs: modifier, optional
        /// token: the label
        reference,
        /// token: the modifier
        modifier,
        /// token: the argument
        argument,

        pub fn fmt(self: Tag) []const u8 {
            return switch (self) {
                .identifier => "an identifier",
                .string => "a string",
                else => @tagName(self)
            };
        }
    };

    pub const Operands = struct {

        lhs: Index = Null,
        rhs: Index = Null,

        pub const none = Operands {
            .lhs = Null,
            .rhs = Null };
    };

    pub const none = Node {
        .tag = .composite,
        .token = Null,
        .operands = .none };
};

pub const Null = 0;
pub const Index = u32;
pub const IndexRange = Node.Operands;

const NodeList = std.ArrayListUnmanaged(Node);

/// Recursive-descent parser that generates the Abstract Syntax Tree.
const AstGen = struct {

    allocator: std.mem.Allocator,
    source_location: *const SourceLocation,
    tokens: []const Token,
    nodes: NodeList,
    temporary: NodeList,
    bridge: Bridge,
    cursor: Index,

    pub fn init(
        allocator: std.mem.Allocator,
        source_location: *const SourceLocation,
        bridge: Bridge
    ) !AstGen {
        var tokeniser = AsmTokeniser.init(source_location.buffer);
        var tokens = try std.ArrayList(Token).initCapacity(allocator, source_location.buffer.len / 4 + 1);
        errdefer tokens.deinit();
        
        while (true) {
            const token = tokeniser.next();
            try tokens.append(token);
            if (token.tag == .eof) break;
        }

        return .{
            .allocator = allocator,
            .source_location = source_location,
            .tokens = try tokens.toOwnedSlice(),
            .nodes = .empty,
            .temporary = .empty,
            .bridge = bridge,
            .cursor = 0 };
    }

    pub fn deinit(self: *AstGen) void {
        self.nodes.deinit(self.allocator);
        self.temporary.deinit(self.allocator);
    }

    fn current_tag(self: *AstGen) Token.Tag {
        return self.tokens[self.cursor].tag;
    }

    fn advance(self: *AstGen) void {
        if (self.tokens.len != self.cursor + 1)
            self.cursor += 1;
    }

    fn next_cursor(self: *AstGen) Index {
        const cursor = self.cursor;
        self.advance();
        return cursor;
    }

    /// Moves the cursor to the next newline or EOF.
    fn consume_line(self: *AstGen) void {
        while (std.mem.indexOfScalar(Token.Tag, &[_]Token.Tag { .newline, .eof }, self.tokens[self.next_cursor()].tag) == null) {}
    }

    /// Expect a tag, emit an error if the cursor isn't pointing to a token
    /// containing the tag, and always advances to the next token.
    fn expect(self: *AstGen, tag: Token.Tag) !Index {
        if (self.tokens[self.cursor].tag != tag)
            try self.add_error(error.Expected, tag);
        return self.next_cursor();
    }

    fn expect_newline(self: *AstGen) !void {
        const tag = self.tokens[self.cursor].tag;
        if (tag != .newline and tag != .eof)
            try self.add_error(error.Unexpected, .{});
        self.consume_line();
    }

    /// Expect a tag, optionally emits an error if the cursor isn't pointing to
    /// a token containing the tag, and only advances the cursor if the tag
    /// matches.
    fn eat(self: *AstGen, expected_tag: Token.Tag, comptime mode: enum {
        silent,
        err
    }) !?Index {
        const tag = self.tokens[self.cursor].tag;
        const is_newline = tag == .eof or tag == .newline;

        if (expected_tag == .newline and is_newline)
            return self.next_cursor();

        if (tag != expected_tag) {
            if (mode == .err)
                try self.add_error(error.Expected, expected_tag);
            return null;
        }

        return self.next_cursor();
    }

    fn add_node(self: *AstGen, node: Node) !Index {
        const idx: Index = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, node);
        return idx;
    }

    fn add_nodes(self: *AstGen, list: []const Node) !IndexRange {
        std.debug.assert(list.len > 0);
        try self.nodes.appendSlice(self.allocator, list);
        return .{
            .lhs = @intCast(self.nodes.items.len - list.len),
            .rhs = @intCast(self.nodes.items.len) };
    }

    fn add_index_range(self: *AstGen, index_range: IndexRange) !Index {
        if (index_range.lhs == Null or index_range.rhs == Null)
            return Null;
        return try self.add_node(.{
            .tag = .container,
            .token = Null,
            .operands = index_range });
    }

    fn create_list_frame(self: *AstGen) usize {
        return self.temporary.items.len;
    }

    fn pop_frame(self: *AstGen, len: usize) void {
        self.temporary.shrinkRetainingCapacity(len);
    }

    fn add_frame_node(self: *AstGen, node: Node) !void {
        try self.temporary.append(self.allocator, node);
    }

    fn copy_frame_nodes(self: *AstGen, frame: usize) !IndexRange {
        const frame_diff = self.temporary.items[frame..];
        return if (frame_diff.len > 0)
            try self.add_nodes(frame_diff) else
            .{ .lhs = Null, .rhs = Null };
    }

    pub const AstError = error {
        Expected,
        Unexpected,
        RootInstruction,
        RootLabel,
        RootBuiltin,
        NonRootBuiltin,
        ExtraEndScope,
        NoteDefinedHere,
        Note
    };

    pub const ParseError = std.mem.Allocator.Error;

    fn add_error(self: *AstGen, comptime err: AstError, argument: anytype) !void {
        @branchHint(.cold);

        const token = self.tokens[self.cursor];

        const format = switch (err) {
            error.Expected => .{ "expected {s}, found {s}", .{
                if (@TypeOf(argument) == Token.Tag) argument.fmt() else argument,
                token.tag.fmt() } }, // argument = tag
            error.Unexpected => .{ "unexpectedly got {s}", .{ token.tag.fmt() } },
            error.RootInstruction => .{ "instructions cannot be defined at the root level", .{} },
            error.RootLabel => .{ "labels cannot be declared at the root level", .{} },
            error.RootBuiltin => .{ "{s} cannot appear at the root level", .{ token.tag.fmt() } },
            error.NonRootBuiltin => .{ "{s} must appear at the root level", .{ token.tag.fmt() } },
            error.ExtraEndScope => .{ "extra @end", .{} },
            error.NoteDefinedHere => .{ "{s} defined here", .{ argument.tag.fmt() } }, // argument = token
            error.Note => .{ "{s}", .{ argument } } // argument = message
        };

        const message = try std.fmt.allocPrint(self.allocator, format[0], format[1]);
        errdefer self.allocator.free(message);

        const is_note = switch (err) {
            error.NoteDefinedHere,
            error.Note => true,
            else => false
        };

        try self.bridge.emit_error(.{
            .err = err,
            .token = switch (err) {
                error.NoteDefinedHere => argument,
                else => token,
            },
            .source_location = self.source_location,
            .is_note = is_note,
            .is_preview = err != error.Note,
            .message = message });
    }

    /// Root <- Builtin* Eof
    pub fn parse_root(self: *AstGen) ParseError!void {
        std.debug.assert(self.nodes.items.len == 0);

        try self.nodes.append(self.allocator, .{
            .tag = .container,
            .token = Null,
            .operands = .{} });
        const frame = self.create_list_frame();
        defer self.pop_frame(frame);

        while (self.current_tag() != .eof) switch(self.current_tag()) {
            .identifier,
            .instruction => {
                try self.add_error(error.RootInstruction, .{});
                self.consume_line();
            },

            .label,
            .private_label => {
                try self.add_error(error.RootLabel, .{});
                self.consume_line();
            },

            .builtin_else => {
                try self.add_error(error.Unexpected, .{});
                self.consume_line();
            },

            .builtin_end => {
                try self.add_error(error.ExtraEndScope, .{});
                self.consume_line();
            },

            .newline => self.advance(),

            .eof => unreachable,

            else => |tag| if (tag.is_builtin()) {
                if (tag.is_builtin_scoped())
                    try self.add_error(error.RootBuiltin, .{});
                const builtin = try self.parse_builtin();
                try self.add_frame_node(builtin);
            } else {
                try self.add_error(error.Unexpected, .{});
                self.advance();
            }
        };

        const container = try self.copy_frame_nodes(frame);
        self.nodes.items[0].operands = container;
        _ = try self.eat(.eof, .err);
    }

    /// Builtin <- Section / SimpleBuiltin / OpaqueBuiltin
    /// Section <- SectionKeyword BuiltinArguments Opaque [^SectionKeyword]
    /// SimpleBuiltin <- SimpleBuiltinKeyword BuiltinArguments
    /// OpaqueBuiltin <- OpaqueBuiltinKeyword BuiltinArguments Opaque EndKeyword Eol
    /// BuiltinArguments <- (LParan OptionList RParan)? ArgumentList Eol
    /// SectionKeyword <- '@section' / '@barrier'
    /// SimpleBuiltinKeyword <- '@align' / '@alignop' / '@buildinfo' / '@define' / '@entrypoint' / '@err' / '@import' / '@linkinfo' / '@offset'
    /// OpaqueBuiltinKeyword <- '@else' / '@header' / '@if' / '@region'
    /// EndKeyword <- '@end'
    fn parse_builtin(self: *AstGen) ParseError!Node {
        const cursor = self.next_cursor();
        const builtin_options = try self.parse_builtin_options();
        const builtin_arguments = try self.parse_arguments();
        try self.expect_newline();

        const token = self.tokens[cursor];

        const payload = if (token.tag.is_builtin_opaque()) blk: {
            const payload = try self.parse_opaque();

            // @sections aren't delimited by @end
            if (token.tag.is_builtin_section())
                break :blk payload;

            if (self.current_tag() != .builtin_end) {
                try self.add_error(error.Expected, Token.Tag.builtin_end);
                try self.add_error(error.NoteDefinedHere, token);
            }

            // @else doesn't consume the @end
            if (token.tag != .builtin_else) {
                self.advance();
                try self.expect_newline();
            }

            break :blk payload;
        } else Null;

        const composite = if (builtin_options != Null or payload != Null)
            try self.add_node(.{ .tag = .composite, .token = Null, .operands = .{ .lhs = builtin_options, .rhs = payload } }) else
            Null;
        return .{
            .tag = .builtin,
            .token = cursor,
            .operands = .{ .lhs = builtin_arguments, .rhs = composite } };
    }

    /// OptionList <- (LParan ArgumentList RParan)?
    fn parse_builtin_options(self: *AstGen) ParseError!Index {
        _ = try self.eat(.l_paran, .silent) orelse return Null;
        const arguments = try self.parse_arguments();
        _ = try self.eat(.r_paran, .err);
        return arguments;
    }

    /// ArgumentList <- (Expression Comma)* Expression?
    fn parse_arguments(self: *AstGen) ParseError!Index {
        const frame = self.create_list_frame();
        defer self.pop_frame(frame);

        while (true) switch (self.current_tag()) {
            .l_paran,
            .minus,
            .bang,
            .dollar,
            .reference_label,
            .numeric_literal,
            .string_literal,
            .identifier,
            .instruction,
            .argument => {
                const expression = try self.parse_expression();
                try self.add_frame_node(expression);

                switch (self.current_tag()) {
                    .newline,
                    .eof,
                    .r_paran => break,

                    .comma => self.advance(),

                    else => {
                        try self.add_error(error.Expected, Token.Tag.comma);
                        self.advance();
                        break;
                    }
                }

                switch (self.current_tag()) {
                    .newline,
                    .eof => try self.add_error(error.Expected, "an argument"),
                    else => {}
                }
            },

            .newline,
            .eof,
            .r_paran => break,

            else => {
                try self.add_error(error.Expected, "an expression");
                self.advance();
            }
        };

        const container = try self.copy_frame_nodes(frame);
        return try self.add_index_range(container);
    }

    /// Expression <- (Expression BinaryOperator)* UnaryExpression
    /// BinaryOperator <- '+' / '-' / '*' / '|' / '&' / '<<' / '>>'
    fn parse_expression(self: *AstGen) ParseError!Node {
        const unary_expression = try self.parse_unary_expression();

        const binary_tag: Node.Tag = switch (self.current_tag()) {
            .plus => .addition,
            .minus => .subtraction,
            .asterisk => .multiplication,
            .pipe => .bitwise_or,
            .ampersand => .bitwise_and,
            .lsh => .left_shift,
            .rsh => .right_shift,
            else => return unary_expression
        };

        const binary_cursor = self.next_cursor();
        const operand_expression = try self.parse_expression();
        const lhs = try self.add_node(unary_expression);
        const rhs = try self.add_node(operand_expression);

        return .{
            .tag = binary_tag,
            .token = binary_cursor,
            .operands = .{ .lhs = lhs, .rhs = rhs } };
    }

    /// UnaryExpression <- UnaryOperator? PrimaryExpression
    /// UnaryOperator <- '-' / '!'
    fn parse_unary_expression(self: *AstGen) ParseError!Node {
        const unary_tag: Node.Tag = switch (self.current_tag()) {
            .minus => .negation,
            .bang => .inversion,
            else => return try self.parse_primary_expression()
        };

        const unary_cursor = self.next_cursor();
        const expression = try self.parse_primary_expression();
        const rhs = try self.add_node(expression);

        return .{
            .tag = unary_tag,
            .token = unary_cursor,
            .operands = .{ .lhs = rhs } };
    }

    /// PrimaryExpression <-
    ///             GroupedExpression /
    ///             Reference /
    ///             Integer /
    ///             Chararcter /
    ///             String /
    ///             Identifier /
    ///             Opcode /
    ///             Argument
    /// GroupedExpression <- LParan Expression RParan
    /// Integer <- Decimal / Binary / Hexadecimal
    /// Decimal <- [0-9]+
    /// Binary <- '0b' [01]+
    /// Hexadecimal <- '0x' [0-9A-F]+
    /// Character <- '\'' . '\''
    /// Identifier <- '@'? [a-zA-Z_]+
    /// Argument <- ...
    fn parse_primary_expression(self: *AstGen) ParseError!Node {
        const expression_tag: Node.Tag = switch (self.current_tag()) {
            .numeric_literal => .integer,
            .char_literal => .character,
            .identifier => .identifier,
            .instruction, .argument => .argument,

            .dollar,
            .reference_label => return try self.parse_reference_expression(),
            .string_literal => return try self.parse_string_expression(),

            .l_paran => {
                self.advance();
                const paranthesis = try self.parse_expression();
                _ = try self.eat(.r_paran, .err);
                return paranthesis;
            },

            else => {
                try self.add_error(error.Expected, "an expression");
                self.advance();
                return .none;
            }
        };

        return .{
            .tag = expression_tag,
            .token = self.next_cursor(),
            .operands = .none };
    }

    /// Reference <- (ReferenceLabel / CurrentAddress) (Apostrophe AddressModifier)?
    /// ReferenceLabel <- Dot Identifier
    /// CurrentAddress <- '$'
    /// AddressModifier <- 'l' / 'h'
    fn parse_reference_expression(self: *AstGen) ParseError!Node {
        const hosted_tag = self.current_tag();
        std.debug.assert(hosted_tag == .reference_label or hosted_tag == .dollar);
        const reference_cursor = self.next_cursor();

        const modifier = if (try self.eat(.modifier, .silent)) |modifier_cursor|
            try self.add_node(.{ .tag = .modifier, .token = modifier_cursor, .operands = .none }) else
            Null;
        return .{
            .tag = .reference,
            .token = reference_cursor,
            .operands = .{ .lhs = modifier } };
    }

    /// String <- '"' .* '"' Integer?
    fn parse_string_expression(self: *AstGen) ParseError!Node {
        std.debug.assert(self.current_tag() == .string_literal);
        const string_cursor = self.next_cursor();

        const sentinel = if (try self.eat(.numeric_literal, .silent)) |numeric_cursor|
            try self.add_node(.{ .tag = .integer, .token = numeric_cursor, .operands = .{} }) else
            Null;
        return .{
            .tag = .string,
            .token = string_cursor,
            .operands = .{ .lhs = sentinel } };
    }

    /// Opaque <- (Builtin / Instruction)*
    fn parse_opaque(self: *AstGen) ParseError!Index {
        const frame = self.create_list_frame();
        defer self.pop_frame(frame);

        while (true) switch (self.current_tag()) {
            .identifier,
            .instruction => {
                const instruction = try self.parse_instruction();
                try self.add_frame_node(instruction);
            },

            .label,
            .private_label => {
                const instruction = try self.parse_labeled_instruction();
                try self.add_frame_node(instruction);
            },

            .builtin_import => {
                try self.add_error(error.NonRootBuiltin, .{});
                self.consume_line();
            },

            .eof,
            .builtin_end,
            .builtin_section,
            .builtin_barrier => break,

            .newline => self.advance(),

            else => |tag| if (tag.is_builtin()) {
                const builtin = try self.parse_builtin();
                try self.add_frame_node(builtin);
            } else {
                try self.add_error(error.Unexpected, .{});
                self.advance();
            }
        };

        const container = try self.copy_frame_nodes(frame);
        return try self.add_index_range(container);
    }

    /// Instruction <- Label? Opcode ArgumentList Eol
    /// Opcode <- ...
    fn parse_instruction(self: *AstGen) ParseError!Node {
        const hosted_tag = self.current_tag();
        std.debug.assert(hosted_tag == .identifier or hosted_tag == .instruction);

        const instruction_cursor = self.next_cursor();
        const arguments = try self.parse_arguments();
        try self.expect_newline();

        return .{
            .tag = .instruction,
            .token = instruction_cursor,
            .operands = .{ .rhs = arguments } };
    }

    /// Label <- PublicLabel / PrivateLabel
    /// PublicLabel <- Identifier Colon
    /// PrivateLabel <- Dot Identifier Colon
    fn parse_labeled_instruction(self: *AstGen) ParseError!Node {
        const hosted_tag = self.current_tag();
        std.debug.assert(hosted_tag == .label or hosted_tag == .private_label);

        const label_cursor = self.next_cursor();

        const label_node = try self.add_node(.{
            .tag = .label,
            .token = label_cursor,
            .operands = .none });
        const instruction = search: while (true) switch (self.current_tag()) {
            .identifier,
            .instruction => break :search try self.parse_instruction(),

            .newline => self.advance(),

            else => |tag| {
                try self.add_error(error.Expected, Token.Tag.instruction);
                try self.add_error(error.NoteDefinedHere, self.tokens[label_cursor]);

                if (tag.is_builtin_section() or tag == .builtin_end)
                    try self.add_error(error.Note, "use 'reserve <type>, <len>' to occupy opaque space")
                else if (tag.is_builtin())
                    try self.add_error(error.Note, "label cannot bind to builtin or opaque without assembletime-known size");
                self.consume_line();
                break :search Node.none;
            }
        };

        return .{
            .tag = .instruction,
            .token = instruction.token,
            .operands = .{ .lhs = label_node, .rhs = instruction.operands.rhs } };
    }

    // Dot <- '.'
    // Comma <- ','
    // Colon <- ':'
    // Apostrophe <- '\''
    // Eol <- ('//' .*)? (';' .*)? '\n'
    // Eof <- '\0'
};

pub fn is_null_or(self: *const AsmAst, index: Index, tag: Node.Tag) bool {
    return index == Null or self.nodes[index].tag == tag;
}

pub fn unwrap(self: *const AsmAst, index: Index) ?Node {
    return if (index != Null)
        self.nodes[index] else
        null;
}

pub fn optional_range(self: *const AsmAst, index: Index) IndexRange {
    return if (self.unwrap(index)) |node|
        node.operands else
        .none;
}

pub fn is_empty(operands: AsmAst.Node.Operands) bool {
    return operands.lhs == operands.rhs;
}

pub inline fn assert(ok: bool) void {
    if (!ok) failure();
}

pub inline fn failure() noreturn {
    @panic("AstGen failed to comply to consumed assumption");
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

    const astTable = AsmAst.Bridge.VTable {
        .emit_error = emit_error
    };

    fn emit_error(context: *anyopaque, err: SourceLocation.Error) !void {
        const self: *TestBridge = @alignCast(@ptrCast(context));
        try self.errors.append(self.allocator, err);
    }

    pub fn bridge(self: *TestBridge) Bridge {
        return .{ .vtable = astTable, .context = self };
    }
};

const stderr = std.io.getStdErr().writer();

fn testAstGen(input: [:0]const u8, errors: []const AstGen.AstError) !void {
    const source_location = SourceLocation {
        .cwd = std.fs.cwd(),
        .file_name = "AsmAst.zig",
        .real_path = "Sources/AsmAst.zig",
        .buffer = input,
        .inode = undefined,
        .size = undefined };
    var bridge = TestBridge { .allocator = std.testing.allocator };
    defer bridge.deinit();
    var ast = try AsmAst.init(std.testing.allocator, &source_location, bridge.bridge());
    defer ast.deinit(std.testing.allocator);

    if (build_options.dump and errors.len == 0)
        try ast.dump(std.testing.allocator, stderr);

    if (errors.len != bridge.errors.items.len) {
        for (bridge.errors.items) |err|
            try err.write(stderr);
    }

    try std.testing.expectEqual(errors.len, bridge.errors.items.len);
    for (errors, 0..) |err, i| try std.testing.expectEqual(err, bridge.errors.items[i].err);
}

test "basic" {
    try testAstGen("", &.{});
    try testAstGen("/", &.{ error.Unexpected });
    try testAstGen("0x00", &.{ error.Unexpected });
    try testAstGen(".label:", &.{ error.RootLabel });
    try testAstGen("@end", &.{ error.ExtraEndScope });
}

test "root instructions" {
    try testAstGen("bkpt", &.{ error.RootInstruction });
    try testAstGen("@section foo\nbkpt", &.{});
    try testAstGen("@header foo\nbkpt\n@end", &.{});
}

test "builtins" {
    try testAstGen("@align", &.{ error.RootBuiltin });
    try testAstGen("@define", &.{});
    try testAstGen("@define()", &.{});
    try testAstGen("@define() foo", &.{});
    try testAstGen("@define foo bar", &.{ error.Expected });
    try testAstGen("@define foo, bar", &.{});
    try testAstGen("@define(expose, \"Hello world\") foo, bar", &.{});
}

test "root-only builtins" {
    try testAstGen("@import foo, \"hello world!\"", &.{});

    try testAstGen(
        \\@section foo
        \\@import foo, "hello world!"
    , &.{
        error.NonRootBuiltin
    });
}

test "expressions" {
    try testAstGen("@define foo, r1", &.{});
    try testAstGen("@define foo, sp | zr", &.{});
    try testAstGen("@define foo, 0b1111 & .label", &.{});
    try testAstGen("@define foo, 5", &.{});
    try testAstGen("@define foo, 5 + 3", &.{});
    try testAstGen("@define foo, 5 + 3 << 8", &.{});
    try testAstGen("@define foo, (5 + 3) << 8", &.{});
    try testAstGen("@define foo, -5 + 3", &.{});
    try testAstGen("@define foo, !5", &.{});
    try testAstGen("@define foo, 5'l", &.{ error.Expected });
    try testAstGen("@define foo, -5 3", &.{ error.Expected });
    try testAstGen("@define foo, +3", &.{ error.Expected });
    try testAstGen("@define foo, ($ - .label) << 2", &.{});
    try testAstGen("@define foo, ($ - .label'u) << 2", &.{});
    try testAstGen("@define foo, \"Hello world!\"", &.{});
    try testAstGen("@define foo, \"Hello world!\" 1 + 2", &.{}); // string sentinel + integer
}

test "labels" {
    try testAstGen(
        \\@section foo
        \\.label:       kbpt
    , &.{});

    try testAstGen(
        \\@section foo
        \\.label:
    , &.{
        error.Expected,
        error.NoteDefinedHere
    });

    try testAstGen(
        \\@section foo
        \\@region
        \\              bkpt
    , &.{
        error.Expected,
        error.NoteDefinedHere
    });

    try testAstGen(
        \\@section foo
        \\.label:
        \\@define foo, bar
    , &.{
        error.Expected,
        error.NoteDefinedHere,
        error.Note
    });
}

test "sections" {
    try testAstGen(
        \\@barrier ; verified in IrGen
        \\@section foo
        \\              bkpt
        \\@region 32
        \\@end
        \\@barrier
        \\@section bar
        \\              bkpt
    , &.{});

    try testAstGen(
        \\@header foo
        \\@barrier
        \\@end
    , &.{
        error.Expected,
        error.NoteDefinedHere,
        error.ExtraEndScope
    });

    try testAstGen(
        \\@entrypoint
        \\@err "hello world!"
        \\@if @foo
        \\@offset q, b
        \\@else
        \\@end
        \\@section foo
    , &.{
        error.RootBuiltin,
        error.RootBuiltin,
        error.RootBuiltin
    });

    try testAstGen(
        \\@section foo
        \\@entrypoint
        \\@if @foo
        \\@offset q, b
        \\@err "hello world!"
        \\@end
    , &.{});
}

test "full fledge" {
    try testAstGen(
        \\
        \\// foo
        \\
        \\@section foo
        \\@section(noelimination) foo
        \\@align 2
        \\
        \\@define(expose) foo, 5 + 3
        \\
        \\@header Queue, type, len
        \\              @align 16
        \\              reserve @type, @len
        \\@end
        \\
        \\.queue:       @Queue u16, @foo
    , &.{});
}
