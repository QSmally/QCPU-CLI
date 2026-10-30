
// Abstract Syntax Tree

const std = @import("std");
const indexable_list = @import("indexable_list.zig");
const SourceFile = @import("SourceFile.zig");
const AsmTokeniser = @import("AsmTokeniser.zig");
const Token = @import("Token.zig");
const Error = @import("Error.zig");

const AsmAst = @This();

/// Guaranteed to have at least one element (the end of file token).
tokens: Token.List.Slice,
/// UntypedIndex = 0 is the root container node which references the other nodes.
nodes: Node.List.Slice,

/// From a source location, tokenises the buffer and parses them into an
/// Abstract Syntax Tree and deallocating the intermediate results. Errors are
/// emitted to the bridge. If any errors exist, the tree cannot be guaranteed
/// to be complete or valid.
pub fn init(
    allocator: std.mem.Allocator,
    source_file: *const SourceFile,
    bridge: Bridge
) !AsmAst {
    var ast_gen = try AstGen.init(allocator, source_file, bridge);
    defer ast_gen.deinit();

    std.debug.assert(ast_gen.tokens.items.len > 0);
    std.debug.assert(ast_gen.tokens.items[ast_gen.tokens.items.len - 1].tag == .eof);

    try ast_gen.parseRoot();

    std.debug.assert(ast_gen.nodes.items.len > 0);
    std.debug.assert(ast_gen.temporary.items.len == 0);

    const nodes = try ast_gen.nodes.toOwnedSlice(allocator);

    return .{
        .tokens = ast_gen.tokens,
        .nodes = .{ .items = nodes } };
}

pub fn deinit(self: *const AsmAst, allocator: std.mem.Allocator) void {
    self.tokens.deinit(allocator);
    self.nodes.deinit(allocator);
}

const AutoIndentingStream = @import("AutoIndentingStream.zig");

fn dumpSingleNode(self: *const AsmAst, ais: *AutoIndentingStream, poke_map: []bool, index: UntypedIndex) !void {
    const node = self.nodes.get(.at(index));
    try ais.print("{s}({})\n", .{ @tagName(node.tag), index });

    try ais.pushIndent(.normal);
    defer ais.popIndent();

    if (poke_map[index]) {
        if (index != 0)
            try ais.print("warning: recursive node reference!\n", .{});
        return;
    }
    poke_map[index] = true;

    switch (node.tag) {
        .container => for (node.operands.lhs..node.operands.rhs) |i|
            try self.dumpSingleNode(ais, poke_map, @intCast(i)),

        .composite,
        .builtin,
        .instruction,
        .index,
        .addition,
        .subtraction,
        .multiplication,
        .bitwise_or,
        .bitwise_and,
        .left_shift,
        .right_shift,
        .less_than,
        .greater_than,
        .equals => {
            try self.dumpSingleNode(ais, poke_map, node.operands.lhs);
            try self.dumpSingleNode(ais, poke_map, node.operands.rhs);
        },

        .negation,
        .inversion,
        .mask,
        .predecrement,
        .postincrement => try self.dumpSingleNode(ais, poke_map, node.operands.lhs),

        .string,
        .reference => if (node.operands.lhs > 0)
            try self.dumpSingleNode(ais, poke_map, node.operands.lhs),

        .label,
        .identifier,
        .integer,
        .character,
        .argument => {}
    }
}

pub fn dump(self: *const AsmAst, allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    var renderer = AutoIndentingStream.init(allocator, writer, 2);
    defer renderer.deinit();
    const poke_map = try allocator.alloc(bool, self.nodes.items.len);
    defer allocator.free(poke_map);

    try self.dumpSingleNode(&renderer, poke_map, 0);

    for (poke_map, 0..) |poked, index| {
        if (poked) continue;
        const token = self.nodes.get(.at(@intCast(index)));
        try writer.print("warning: node {}={s} not poked\n", .{ index, @tagName(token.tag) });
    }
}

pub const Bridge = struct {

    const AllocatorError = std.mem.Allocator.Error;

    pub const VTable = struct {
        emitError: *const fn (*anyopaque, Error) AllocatorError!void
    };

    vtable: VTable,
    context: *anyopaque,

    fn emitError(self: *const Bridge, err: Error) !void {
        try self.vtable.emitError(self.context, err);
    }
};

pub const Node = struct {

    tag: Tag,
    token: Token.List.Index,
    operands: Operands,

    pub const List = indexable_list.IndexableList(Node);

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
        /// token: the public or private label
        label,
        /// token: the identifier
        identifier,
        /// lhs: unary operand
        /// token: the unary operator
        negation,
        /// lhs: unary operand
        /// token: the unary operator
        inversion,
        /// lhs: unary operand
        /// token: the unary operator
        predecrement,
        /// lhs: unary operand
        /// token: the post unary operator
        mask,
        /// lhs: unary operand
        /// token: the post unary operator
        postincrement,
        /// lhs: the primary expression
        /// rhs: the grouped expression
        /// token: primary expression token
        index,
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
        /// lhs: left binary operand
        /// rhs: right binary operand
        /// token: the less than operator
        less_than,
        /// lhs: left binary operand
        /// rhs: right binary operand
        /// token: the greater than operator
        greater_than,
        /// lhs: left binary operand
        /// rhs: right binary operand
        /// token: the equal operator
        equals,
        /// token: the numeric literal
        integer,
        /// token: the char literal
        character,
        /// lhs: sentinel operand, optional
        /// token: the string literal
        string,
        /// token: the normal or difference reference
        reference,
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
        lhs: UntypedIndex = untypedNull,
        rhs: UntypedIndex = untypedNull,
    };

    pub const none = Node {
        .tag = .composite,
        .token = .root,
        .operands = .{} };
};

pub const UntypedIndex = indexable_list.UnderlyingType;
pub const untypedNull = 0;

/// Recursive-descent parser that generates the Abstract Syntax Tree.
const AstGen = struct {

    allocator: std.mem.Allocator,
    source_file: *const SourceFile,
    tokens: Token.List.Slice,
    nodes: std.ArrayList(Node),
    temporary: std.ArrayList(Node),
    bridge: Bridge,
    cursor: UntypedIndex,

    pub fn init(
        allocator: std.mem.Allocator,
        source_file: *const SourceFile,
        bridge: Bridge
    ) !AstGen {
        var tokeniser = AsmTokeniser.init(source_file.buffer);
        var tokens = try Token.List.initCapacity(allocator, source_file.buffer.len / 4 + 1);
        errdefer tokens.deinit(allocator);
        
        while (true) {
            const token = tokeniser.next();
            try tokens.append(allocator, token);
            if (token.tag == .eof) break;
        }

        return .{
            .allocator = allocator,
            .source_file = source_file,
            .tokens = try tokens.toOwnedSlice(allocator),
            .nodes = .empty,
            .temporary = .empty,
            .bridge = bridge,
            .cursor = 0 };
    }

    pub fn deinit(self: *AstGen) void {
        self.nodes.deinit(self.allocator);
        self.temporary.deinit(self.allocator);
    }

    fn currentTag(self: *AstGen) Token.Tag {
        return self.tokens.items[self.cursor].tag;
    }

    fn advance(self: *AstGen) void {
        if (self.tokens.items.len != self.cursor + 1)
            self.cursor += 1;
    }

    fn nextCursor(self: *AstGen) UntypedIndex {
        const cursor = self.cursor;
        self.advance();
        return cursor;
    }

    /// Moves the cursor to the next newline or EOF.
    fn consumeLine(self: *AstGen) void {
        while (std.mem.indexOfScalar(Token.Tag, &[_]Token.Tag { .newline, .eof }, self.tokens.items[self.nextCursor()].tag) == null) {}
    }

    /// Expect a tag, emit an error if the cursor isn't pointing to a token
    /// containing the tag, and always advances to the next token.
    fn expect(self: *AstGen, tag: Token.Tag) !UntypedIndex {
        if (self.tokens.items[self.cursor].tag != tag)
            try self.addError(error.Expected, tag);
        return self.nextCursor();
    }

    fn expectNewline(self: *AstGen) !void {
        const tag = self.tokens.items[self.cursor].tag;
        if (tag != .newline and tag != .eof)
            try self.addError(error.Unexpected, .{});
        self.consumeLine();
    }

    /// Expect a tag, optionally emits an error if the cursor isn't pointing to
    /// a token containing the tag, and only advances the cursor if the tag
    /// matches.
    fn eat(self: *AstGen, expected_tag: Token.Tag, comptime mode: enum {
        silent,
        err
    }) !?UntypedIndex {
        const tag = self.tokens.items[self.cursor].tag;
        const is_newline = tag == .eof or tag == .newline;

        if (expected_tag == .newline and is_newline)
            return self.nextCursor();

        if (tag != expected_tag) {
            if (mode == .err)
                try self.addError(error.Expected, expected_tag);
            return null;
        }

        return self.nextCursor();
    }

    fn addNode(self: *AstGen, node: Node) !UntypedIndex {
        const index: UntypedIndex = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, node);
        return index;
    }

    fn addNodes(self: *AstGen, list: []const Node) !Node.Operands {
        std.debug.assert(list.len > 0);
        try self.nodes.appendSlice(self.allocator, list);
        return .{
            .lhs = @intCast(self.nodes.items.len - list.len),
            .rhs = @intCast(self.nodes.items.len) };
    }

    fn addIndexRange(self: *AstGen, index_range: Node.Operands) !UntypedIndex {
        if (index_range.lhs == untypedNull or index_range.rhs == untypedNull)
            return untypedNull;
        return try self.addNode(.{
            .tag = .container,
            .token = .root,
            .operands = index_range });
    }

    fn createListFrame(self: *AstGen) usize {
        return self.temporary.items.len;
    }

    fn popFrame(self: *AstGen, len: usize) void {
        self.temporary.shrinkRetainingCapacity(len);
    }

    fn addFrameNode(self: *AstGen, node: Node) !void {
        try self.temporary.append(self.allocator, node);
    }

    fn copyFrameNodes(self: *AstGen, frame: usize) !Node.Operands {
        const frame_diff = self.temporary.items[frame..];
        return if (frame_diff.len > 0)
            try self.addNodes(frame_diff) else
            .{};
    }

    pub const AstError = error {
        Expected,
        Unexpected,
        Unsupported,
        RootInstruction,
        RootLabel,
        RootBuiltin,
        NonRootBuiltin,
        ExtraEndScope,
        NoteDefinedHere,
        Note
    };

    pub const ParseError = std.mem.Allocator.Error;

    fn addError(self: *AstGen, comptime err: AstError, argument: anytype) !void {
        @branchHint(.cold);

        const token = self.tokens.items[self.cursor];

        const format = switch (err) {
            error.Expected => .{ "expected {s}, found {s}", .{
                if (@TypeOf(argument) == Token.Tag) argument.fmt() else argument,
                token.tag.fmt() } }, // argument = tag
            error.Unexpected => .{ "unexpectedly got {s}", .{ token.tag.fmt() } },
            error.Unsupported => .{ "{s} are not supported", .{ argument } }, // argument = message
            error.RootInstruction => .{ "instructions cannot be defined at the root level", .{} },
            error.RootLabel => .{ "labels cannot be declared at the root level", .{} },
            error.RootBuiltin => .{ "{s} cannot appear at the root level", .{ token.tag.fmt() } },
            error.NonRootBuiltin => .{ "{s} must appear at the root level", .{ token.tag.fmt() } },
            error.ExtraEndScope => .{ "extra @end", .{} },
            error.NoteDefinedHere => .{ "{s} defined here", .{ argument.tag.fmt() } }, // argument = token
            error.Note => .{ "{s}", .{ argument } } // argument = message
        };

        const message = try self.allocator.print(format[0], format[1]);
        errdefer self.allocator.free(message);

        try self.bridge.emitError(.{
            .err = err,
            .token = switch (err) {
                error.NoteDefinedHere => argument,
                else => token,
            },
            .source_file = self.source_file,
            .is_note = switch (err) {
                error.NoteDefinedHere,
                error.Note => true,
                else => false
            },
            .is_preview = err != error.Note,
            .message = message });
    }

    /// Root <- Builtin* Eof
    pub fn parseRoot(self: *AstGen) ParseError!void {
        std.debug.assert(self.nodes.items.len == 0);

        try self.nodes.append(self.allocator, .{
            .tag = .container,
            .token = .root,
            .operands = .{} });
        const frame = self.createListFrame();
        defer self.popFrame(frame);

        while (self.currentTag() != .eof) switch(self.currentTag()) {
            .identifier,
            .instruction => {
                try self.addError(error.RootInstruction, .{});
                self.consumeLine();
            },

            .label,
            .local_label,
            .private_label => {
                try self.addError(error.RootLabel, .{});
                self.consumeLine();
            },

            .builtin_else => {
                try self.addError(error.Unexpected, .{});
                self.consumeLine();
            },

            .builtin_end => {
                try self.addError(error.ExtraEndScope, .{});
                self.consumeLine();
            },

            .newline => self.advance(),

            .eof => unreachable,

            else => |tag| if (tag.isBuiltin()) {
                if (tag.isBuiltinScoped())
                    try self.addError(error.RootBuiltin, .{});
                const builtin = try self.parseBuiltin();
                try self.addFrameNode(builtin);
            } else {
                try self.addError(error.Unexpected, .{});
                self.advance();
            }
        };

        const container = try self.copyFrameNodes(frame);
        self.nodes.items[0].operands = container;
        _ = try self.eat(.eof, .err);
    }

    /// Builtin <- Section / SimpleBuiltin / OpaqueBuiltin
    /// Section <- SectionKeyword BuiltinArguments Opaque [^SectionKeyword]
    /// SimpleBuiltin <- SimpleBuiltinKeyword BuiltinArguments
    /// OpaqueBuiltin <- OpaqueBuiltinKeyword BuiltinArguments Opaque EndKeyword Eol
    /// BuiltinArguments <- (LParan OptionList RParan)? ArgumentList Eol
    /// SectionKeyword <- '@section' / '@barrier'
    /// SimpleBuiltinKeyword <- '@align' / '@define' / '@err' / '@import' / '@linkinfo'
    /// OpaqueBuiltinKeyword <- '@else' / '@header' / '@if' / '@region'
    /// EndKeyword <- '@end'
    fn parseBuiltin(self: *AstGen) ParseError!Node {
        const cursor = self.nextCursor();
        const builtin_options = try self.parseBuiltinOptions();
        const builtin_arguments = try self.parseArguments();
        try self.expectNewline();

        const token = self.tokens.items[cursor];

        const payload: UntypedIndex = if (token.tag.isBuiltinOpaque()) blk: {
            const payload = try self.parseOpaque();

            // @sections aren't delimited by @end
            if (token.tag.isBuiltinSection())
                break :blk payload;
            // it'll shit itself when @else is given out of context
            const else_scope = token.tag == .builtin_if and self.currentTag() == .builtin_else;
            const is_end = self.currentTag() == .builtin_end;

            if (!is_end and !else_scope) {
                try self.addError(error.Expected, Token.Tag.builtin_end);
                try self.addError(error.NoteDefinedHere, token);
            }

            if (!is_end) break :blk payload;

            // @end consumes itself, verify that there's no @end-@else construction
            self.advance();
            try self.expectNewline();

            if (self.currentTag() == .builtin_else)
                try self.addError(error.Unexpected, .{});
            break :blk payload;
        } else untypedNull;

        const composite = if (builtin_options != untypedNull or payload != untypedNull)
            try self.addNode(.{ .tag = .composite, .token = .root, .operands = .{ .lhs = builtin_options, .rhs = payload } }) else
            untypedNull;
        return .{
            .tag = .builtin,
            .token = .at(cursor),
            .operands = .{ .lhs = builtin_arguments, .rhs = composite } };
    }

    /// OptionList <- (LParan ArgumentList RParan)?
    fn parseBuiltinOptions(self: *AstGen) ParseError!UntypedIndex {
        _ = try self.eat(.l_paran, .silent) orelse return untypedNull;
        const arguments = try self.parseArguments();
        _ = try self.eat(.r_paran, .err);
        return arguments;
    }

    /// ArgumentList <- (Expression Comma)* Expression?
    fn parseArguments(self: *AstGen) ParseError!UntypedIndex {
        const frame = self.createListFrame();
        defer self.popFrame(frame);

        while (true) switch (self.currentTag()) {
            .l_paran,
            .minus,
            .bang,
            .plusplus,
            .minusminus,
            .reference_label,
            .difference_label,
            .numeric_literal,
            .char_literal,
            .string_literal,
            .identifier,
            .instruction,
            .argument => {
                const expression = try self.parseExpression();
                try self.addFrameNode(expression);

                switch (self.currentTag()) {
                    .newline,
                    .eof,
                    .r_paran => break,

                    .comma => self.advance(),

                    else => {
                        try self.addError(error.Expected, Token.Tag.comma);
                        self.advance();
                        break;
                    }
                }

                switch (self.currentTag()) {
                    .newline,
                    .eof => try self.addError(error.Expected, "an argument"),
                    else => {}
                }
            },

            .newline,
            .eof,
            .r_paran => break,

            else => {
                try self.addError(error.Expected, "an expression");
                self.advance();
            }
        };

        const container = try self.copyFrameNodes(frame);
        return try self.addIndexRange(container);
    }

    /// Expression <- (Expression BinaryOperator)* UnaryExpression GroupedExpression?
    /// BinaryOperator <- '+' / '-' / '*' / '|' / '&' / '<<' / '>>'
    fn parseExpression(self: *AstGen) ParseError!Node {
        const unary_expression = try self.parseUnaryExpression();

        const binary_tag: Node.Tag = switch (self.currentTag()) {
            .plus => .addition,
            .minus => .subtraction,
            .asterisk => .multiplication,
            .pipe => .bitwise_or,
            .ampersand => .bitwise_and,
            .lsh => .left_shift,
            .rsh => .right_shift,
            .lt => .less_than,
            .gt => .greater_than,
            .eq => .equals,
            .l_paran => {
                const index_expression = try self.parseGroupedExpression();
                const lhs = try self.addNode(unary_expression);
                const rhs = try self.addNode(index_expression);

                return .{
                    .tag = .index,
                    .token = index_expression.token,
                    .operands = .{ .lhs = lhs, .rhs = rhs } };
            },
            else => return unary_expression
        };

        const binary_cursor = self.nextCursor();
        const operand_expression = try self.parseExpression();
        const lhs = try self.addNode(unary_expression);
        const rhs = try self.addNode(operand_expression);

        return .{
            .tag = binary_tag,
            .token = .at(binary_cursor),
            .operands = .{ .lhs = lhs, .rhs = rhs } };
    }

    /// UnaryExpression <- UnaryOperator? PostUnaryExpression
    /// UnaryOperator <- '-' / '!' / Decrement
    fn parseUnaryExpression(self: *AstGen) ParseError!Node {
        const unary_tag: Node.Tag = switch (self.currentTag()) {
            .minus => .negation,
            .bang => .inversion,
            .plusplus => {
                try self.addError(error.Unsupported, "pre-increment operations");
                self.advance();
                return try self.parsePostUnaryExpression();
            },
            .minusminus => .predecrement,
            else => return try self.parsePostUnaryExpression()
        };

        const unary_cursor = self.nextCursor();
        const expression = try self.parsePostUnaryExpression();
        const rhs = try self.addNode(expression);

        return .{
            .tag = unary_tag,
            .token = .at(unary_cursor),
            .operands = .{ .lhs = rhs } };
    }

    /// PostUnaryExpression <- PrimaryExpression PostUnaryOperation?
    /// PostUnaryOperation <- Modifier / Increment
    /// Modifier <- Apostrophe .
    fn parsePostUnaryExpression(self: *AstGen) ParseError!Node {
        const primary_expression = try self.parsePrimaryExpression();

        const unary_tag: Node.Tag = switch (self.currentTag()) {
            .modifier => .mask,
            .plusplus => .postincrement,
            .minusminus => {
                try self.addError(error.Unsupported, "post-decrement operations");
                self.advance();
                return primary_expression;
            },
            else => return primary_expression
        };

        return .{
            .tag = unary_tag,
            .token = .at(self.nextCursor()),
            .operands = .{ .lhs = try self.addNode(primary_expression) } };
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
    /// Integer <- Decimal / Binary / Hexadecimal
    fn parsePrimaryExpression(self: *AstGen) ParseError!Node {
        const expression_tag: Node.Tag = switch (self.currentTag()) {
            .numeric_literal => .integer,
            .char_literal => .character,
            .identifier => .identifier,
            .instruction, .argument => .argument,

            .difference_label,
            .reference_label => return try self.parseReferenceExpression(),

            .string_literal => return try self.parseStringExpression(),

            .l_paran => return try self.parseGroupedExpression(),

            else => {
                try self.addError(error.Expected, "an expression");
                self.consumeLine();
                return .none;
            }
        };

        return .{
            .tag = expression_tag,
            .token = .at(self.nextCursor()),
            .operands = .{} };
    }

    /// GroupedExpression <- LParan Expression RParan
    fn parseGroupedExpression(self: *AstGen) ParseError!Node {
        std.debug.assert(self.currentTag() == .l_paran);

        self.advance();
        const paranthesis = try self.parseExpression();
        _ = try self.eat(.r_paran, .err);
        return paranthesis;
    }

    /// Reference <- ReferenceLabel / DifferenceLabel
    /// ReferenceLabel <- Dot Identifier
    /// DifferenceLabel <- Ampersand Identifier
    fn parseReferenceExpression(self: *AstGen) ParseError!Node {
        const hosted_tag = self.currentTag();
        std.debug.assert(hosted_tag == .reference_label or hosted_tag == .difference_label);
        const reference_cursor = self.nextCursor();

        return .{
            .tag = .reference,
            .token = .at(reference_cursor),
            .operands = .{} };
    }

    /// String <- '"' .* '"' Integer?
    fn parseStringExpression(self: *AstGen) ParseError!Node {
        std.debug.assert(self.currentTag() == .string_literal);
        const string_cursor = self.nextCursor();

        const sentinel = if (try self.eat(.numeric_literal, .silent)) |numeric_cursor|
            try self.addNode(.{ .tag = .integer, .token = .at(numeric_cursor), .operands = .{} }) else
            untypedNull;
        return .{
            .tag = .string,
            .token = .at(string_cursor),
            .operands = .{ .lhs = sentinel } };
    }

    /// Opaque <- (Builtin / Instruction / Label)*
    fn parseOpaque(self: *AstGen) ParseError!UntypedIndex {
        const frame = self.createListFrame();
        defer self.popFrame(frame);

        while (true) switch (self.currentTag()) {
            .identifier,
            .instruction => {
                const instruction = try self.parseInstruction();
                try self.addFrameNode(instruction);
            },

            .label,
            .local_label,
            .private_label => {
                const label = try self.parseLabel();
                try self.addFrameNode(label);
            },

            .builtin_import => {
                try self.addError(error.NonRootBuiltin, .{});
                self.consumeLine();
            },

            .eof,
            .builtin_else,
            .builtin_end,
            .builtin_section,
            .builtin_barrier => break,

            .newline => self.advance(),

            else => |tag| if (tag.isBuiltin()) {
                const builtin = try self.parseBuiltin();
                try self.addFrameNode(builtin);

                // conditionally parse @else after @if's end
                if (self.currentTag() == .builtin_else) {
                    const builtin_token = self.tokens.get(builtin.token);
                    if (builtin_token.tag != .builtin_if)
                        try self.addError(error.Unexpected, .{});
                    const else_builtin = try self.parseBuiltin();
                    try self.addFrameNode(else_builtin);
                }
            } else {
                try self.addError(error.Unexpected, .{});
                self.advance();
            }
        };

        const container = try self.copyFrameNodes(frame);
        return try self.addIndexRange(container);
    }

    /// Instruction <- Opcode ArgumentList Eol
    /// Opcode <- ...
    fn parseInstruction(self: *AstGen) ParseError!Node {
        const hosted_tag = self.currentTag();
        std.debug.assert(hosted_tag == .identifier or hosted_tag == .instruction);

        const instruction_cursor = self.nextCursor();
        const arguments = try self.parseArguments();
        try self.expectNewline();

        return .{
            .tag = .instruction,
            .token = .at(instruction_cursor),
            .operands = .{ .lhs = arguments } };
    }

    /// Label <- PublicLabel / LocalLabel / PrivateLabel
    /// PublicLabel <- Identifier Colon
    /// LocalLabel <- Underscore Identifier Colon
    /// PrivateLabel <- Dot Identifier Colon
    fn parseLabel(self: *AstGen) ParseError!Node {
        const hosted_tag = self.currentTag();
        std.debug.assert(hosted_tag == .label or hosted_tag == .local_label or hosted_tag == .private_label);

        return .{
            .tag = .label,
            .token = .at(self.nextCursor()),
            .operands = .{} };
    }

    // Increment <- '++'
    // Decrement <- '--'
    // Decimal <- [0-9]+
    // Binary <- '0b' [01]+
    // Hexadecimal <- '0x' [0-9A-F]+
    // Character <- '\'' . '\''
    // Identifier <- '@'? [a-zA-Z_]+
    // Argument <- ...
    // Dot <- '.'
    // Comma <- ','
    // Colon <- ':'
    // Underscore <- '_'
    // Apostrophe <- '\''
    // Eol <- ('//' .*)? (';' .*)? '\n'
    // Eof <- '\0'
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

    fn emitError(context: *anyopaque, err: Error) !void {
        const self: *TestBridge = @alignCast(@ptrCast(context));
        try self.errors.append(self.allocator, err);
    }

    pub fn bridge(self: *TestBridge) Bridge {
        return .{ .vtable = astTable, .context = self };
    }
};

fn testAstGen(input: [:0]const u8, errors: []const AstGen.AstError) !void {
    const stderr_file = std.Io.File.stderr();
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = stderr_file.writer(std.testing.io, &stderr_buffer);
    defer stderr.flush() catch {};

    const source_file = SourceFile {
        .pwd = std.Io.Dir.cwd(),
        .real_path = "Sources/AsmAst.zig",
        .buffer = input,
        .inode = undefined,
        .size = undefined };
    var bridge = TestBridge { .allocator = std.testing.allocator };
    defer bridge.deinit();
    var ast = try AsmAst.init(std.testing.allocator, &source_file, bridge.bridge());
    defer ast.deinit(std.testing.allocator);

    if (errors.len != bridge.errors.items.len) {
        for (bridge.errors.items) |err|
            try err.write(&stderr.interface);
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
    try testAstGen("@define foo, -5 3", &.{ error.Expected });
    try testAstGen("@define foo, +3", &.{ error.Expected });
    try testAstGen("@define foo, 5'l", &.{});
    try testAstGen("@define foo, 5 + 1'l", &.{});
    try testAstGen("@define foo, 5'l + 1", &.{});
    try testAstGen("@define foo, 5 > 1", &.{});
    try testAstGen("@define foo, 5 = 1", &.{});
    try testAstGen("@define foo, 5< 1", &.{});
    try testAstGen("@define foo, 5'w< 1", &.{});
    try testAstGen("@define foo, (.foo - .label) << 2", &.{});
    try testAstGen("@define foo, (.foo - .label) << 2'u", &.{});
    try testAstGen("@define foo, (.foo - .label'u) << 2", &.{});
    try testAstGen("@define foo, (.foo - .label)'l << 2", &.{});
    try testAstGen("@define foo, (.foo - .label) <<'u 2", &.{ error.Expected });
    try testAstGen("@define foo, --(.label)", &.{});
    try testAstGen("@define foo, (.label)++", &.{});
    try testAstGen("@define foo, ++(.label)", &.{ error.Unsupported });
    try testAstGen("@define foo, (.label)--", &.{ error.Unsupported });
    try testAstGen("@define foo, 5(rp)", &.{});
    try testAstGen("@define foo, .label(rp)", &.{});
    try testAstGen("@define foo, 1 + .label(rp)", &.{}); // validated in AsmCompute
    try testAstGen("@define foo, (1 + .label)(rp)", &.{}); // validated in AsmCompute
}

test "labels" {
    try testAstGen("@section foo\nlabel:", &.{});
    try testAstGen("@section foo\nlabel: bkpt", &.{});
    try testAstGen("@section foo\n_label:", &.{});
    try testAstGen("@section foo\n_label: bkpt", &.{});
    try testAstGen("@section foo\n.label:", &.{});
    try testAstGen("@section foo\n.label: kbpt", &.{});

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
    , &.{});
}

test "strings" {
    try testAstGen("@define foo, \"foo bar roo\"", &.{});
    try testAstGen("@define foo, \"foo bar roo\" 0", &.{});
    try testAstGen("@define foo, \"foo bar roo\" 0 + 5", &.{}); // string sentinel + integer
    try testAstGen("@define foo, \"foo bar roo\" -1", &.{});
    try testAstGen("@section foo\nascii \"foo bar roo\" -1", &.{});
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
        \\@err "hello world!"
        \\@section foo
        \\@if foo
        \\@else
        \\@end
    , &.{
        error.RootBuiltin
    });

    try testAstGen(
        \\@section foo
        \\@if foo
        \\.foo:
        \\@err "hello world!"
        \\.foo.bar:
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
        \\              reserve type, len
        \\@end
        \\
        \\.queue:       Queue u16, foo
    , &.{});
}
