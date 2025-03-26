
// Abstract Syntax Tree

const std = @import("std");
const Error = @import("Error.zig");
const Source = @import("Source.zig");
const Token = @import("Token.zig");

const AsmAst = @This();

allocator: std.mem.Allocator,
source: Source,
// Index=0 is the root node which references the other nodes.
nodes: []const Node,
// If any errors are present in the AST result, the node list cannot be
// guaranteed to be complete or valid.
errors: []const Error,

// From a list of tokens, parses them into an Abstract Syntax Tree and
// deallocating intermediate results. Tokens can be deallocated after parsing,
// but the source buffer cannot. The caller owns 'nodes' and 'errors' until
// deinit is called.
pub fn init(allocator: std.mem.Allocator, source: Source) !AsmAst {
    var ast_gen = AstGen.init(allocator, source);
    defer ast_gen.deinit();

    std.debug.assert(source.tokens.len > 0);
    std.debug.assert(source.tokens[source.tokens.len - 1].tag == .eof);

    const estimated_node_count = source.tokens.len + 2;
    try ast_gen.nodes.ensureTotalCapacity(allocator, estimated_node_count);
    try ast_gen.parse_root();

    std.debug.assert(ast_gen.nodes.items.len > 0);
    std.debug.assert(ast_gen.temporary.items.len == 0);

    return .{
        .allocator = allocator,
        .source = source,
        .nodes = try ast_gen.nodes.toOwnedSlice(allocator),
        .errors = try ast_gen.errors.toOwnedSlice(allocator) };
}

pub fn deinit(self: *AsmAst) void {
    self.allocator.free(self.nodes);
    for (self.errors) |err|
        self.allocator.free(err.message);
    self.allocator.free(self.errors);
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
        .container => for (node.operands.lhs..node.operands.rhs) |index_|
            try self.dump_node(ais, pm, @intCast(index_)),
        .composite,
        .builtin,
        .instruction => {
            try self.dump_node(ais, pm, @intCast(node.operands.lhs));
            try self.dump_node(ais, pm, @intCast(node.operands.rhs));
        },
        .label => if (node.operands.lhs > 0)
            try ais.print("(public)\n", .{}),
        else => {}
    }
}

pub fn dump(self: *AsmAst, writer: anytype) !void {
    const DumpStream = render.AutoIndentingStream(@TypeOf(writer));
    var renderer = DumpStream {
        .underlying_writer = writer,
        .indent_delta = 4 };
    const poke_map = try self.allocator.alloc(bool, self.nodes.len);
    defer self.allocator.free(poke_map);

    try self.dump_node(&renderer, poke_map, 0);

    for (poke_map, 0..) |poked, idx| {
        if (!poked)
            try renderer.print("warning: node {}={s} not poked\n", .{ idx, @tagName(self.nodes[idx].tag) });
    }
}

pub const Node = struct {

    token: Index,
    tag: Tag,
    operands: Operands,

    comptime {
        std.debug.assert(@sizeOf(Node) == 16);
    }

    pub const Tag = enum {
        container,      // nodes[lhs..rhs]
        composite,      // lhs and rhs refer to other nodes
        builtin,        // lhs is arguments container, rhs is compositie of options container, opaque
        option,         // both unused, token is option
        label,          // lhs is public bit, rhs is unused, token is label
        instruction,    // lhs is arguments container, rhs is composite of labels container, modifier
        modifier,       // both unused, token is modifier
        identifier,     // both unused, token is identifier
        // add,            // lhs + rhs
        // sub,            // lhs - rhs
        // neg,            // -lhs, rhs is unused
        // integer,        // both unused, token is integer
        // string          // lhs is sentinel, rhs is unused, token is string
    };

    pub const Operands = struct {
        lhs: Index = Null,
        rhs: Index = Null,
    };
};

const Null = 0;
const Index = u32;
const IndexRange = Node.Operands;
const NodeList = std.ArrayListUnmanaged(Node);
const ErrorList = std.ArrayListUnmanaged(Error);

// Recursive-descent parser that generates the Abstract Syntax Tree.
const AstGen = struct {

    allocator: std.mem.Allocator,
    source: Source,
    nodes: NodeList,
    temporary: NodeList,
    errors: ErrorList,
    cursor: Index,

    pub fn init(allocator: std.mem.Allocator, source: Source) AstGen {
        return .{
            .allocator = allocator,
            .source = source,
            .nodes = .empty,
            .temporary = .empty,
            .errors = .empty,
            .cursor = 0 };
    }

    pub fn deinit(self: *AstGen) void {
        self.temporary.deinit(self.allocator);
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
        return try self.add_node(.{
            .tag = .container,
            .token = self.cursor,
            .operands = index_range });
    }

    fn mark_frame(self: *AstGen) usize {
        return self.temporary.items.len;
    }

    fn reset_frame(self: *AstGen, len: usize) void {
        self.temporary.shrinkRetainingCapacity(len);
    }

    fn add_frame_node(self: *AstGen, node: Node) !void {
        try self.temporary.append(self.allocator, node);
    }

    fn lower_frame_nodes(self: *AstGen, frame: usize) !IndexRange {
        const frame_diff = self.temporary.items[frame..];
        return if (frame_diff.len > 0)
            self.add_nodes(frame_diff) else
            .{ .lhs = Null, .rhs = Null };
    }

    fn expect_token(self: *AstGen, tag: Token.Tag) !Index {
        if (tag == .newline and
            (self.source.tokens[self.cursor].tag == .eof or
            self.source.tokens[self.cursor].tag == .newline)
        ) return self.next_token();

        if (self.source.tokens[self.cursor].tag != tag)
            try self.add_error_arg(error.Expected, tag);
        return self.next_token();
    }

    fn next_token(self: *AstGen) Index {
        const cursor_ = self.cursor;
        if (self.source.tokens.len != cursor_ + 1)
            self.cursor += 1;
        return cursor_;
    }

    fn eat_token(self: *AstGen, tag: Token.Tag) ?Index {
        return if (self.source.tokens[self.cursor].tag == tag)
            self.next_token() else
            null;
    }

    fn harshly_eat_token(self: *AstGen, tag: Token.Tag) !?Index {
        if (tag == .newline and
            (self.source.tokens[self.cursor].tag == .eof or
            self.source.tokens[self.cursor].tag == .newline)
        ) return self.next_token();

        if (self.source.tokens[self.cursor].tag != tag) {
            try self.add_error_arg(error.Expected, tag);
            return null;
        }

        return self.next_token();
    }

    const endings = [_]Token.Tag {
        .newline,
        .eof,
        .unexpected_eof };
    fn consume_line(self: *AstGen) void {
        while (std.mem.indexOfScalar(Token.Tag, &endings, self.source.tokens[self.next_token()].tag) == null) {}
    }

    fn current_tag(self: *AstGen) Token.Tag {
        return self.source.tokens[self.cursor].tag;
    }

    fn current_token(self: *AstGen) Token {
        return self.source.tokens[self.cursor];
    }

    fn from_buffer(self: *AstGen, index: Index) []const u8 {
        const token = self.source.tokens[index];
        return token.location.slice(self.source.buffer);
    }

    const ParseError = error {
        UnexpectedEof,
        Expected,
        Unexpected,
        RootLevelInstruction,
        RootLevelLabel,
        ExtraEndScope,
        BuiltinRootLevel,
        BuiltinOpaqueLevel
    };

    const EvalError = std.mem.Allocator.Error;

    fn add_error_arg(self: *AstGen, comptime err: ParseError, argument: anytype) !void {
        @branchHint(.unlikely);

        const message = switch (err) {
            error.UnexpectedEof => "unexpected EOF",
            error.Expected => "expected {s}, found {s}",
            error.Unexpected => "unexpectedly got {s} '{s}'",
            error.RootLevelInstruction => "instructions cannot be defined at the root level",
            error.RootLevelLabel => "labels cannot be declared at the root level",
            error.ExtraEndScope => "extra @end",
            error.BuiltinRootLevel => "builtin '{s}' cannot appear at an opaque level",
            error.BuiltinOpaqueLevel => "builtin '{s}' cannot appear at the root level"
        };

        const is_previous = switch (err) {
            else => false
        };

        const token = if (is_previous)
            self.source.tokens[self.cursor - 1] else
            self.source.tokens[self.cursor];
        const arguments = switch (err) {
            error.Expected => .{ argument.fmt(), token.tag.fmt() },
            error.Unexpected => .{ token.tag.fmt(), self.from_buffer(self.cursor) },
            error.BuiltinRootLevel,
            error.BuiltinOpaqueLevel => .{ token.tag.fmt() },
            else => argument
        };

        const format = try std.fmt.allocPrint(self.allocator, message, arguments);
        const token_location = self.source.location_of(token.location);

        try self.errors.append(self.allocator, .{
            .id = err,
            .token = token,
            .message = format,
            .line = token_location.line,
            .line_cursor = token_location.line_cursor,
            .end_cursor = token_location.end_cursor });
    }

    fn add_error(self: *AstGen, comptime err: ParseError) !void {
        return self.add_error_arg(err, .{});
    }

    // Root <- TopBuiltin* Eof
    pub fn parse_root(self: *AstGen) EvalError!void {
        try self.nodes.append(self.allocator, .{
            .tag = .container,
            .token = Null,
            .operands = .{} });
        const frame = self.mark_frame();
        defer self.reset_frame(frame);

        while (self.current_tag() != .eof) {
            switch (self.current_tag()) {
                .builtin_define,
                .builtin_header,
                .builtin_section,
                .builtin_symbols => {
                    const builtin = try self.parse_builtin();
                    try self.add_frame_node(builtin);
                },

                .builtin_align,
                .builtin_barrier,
                .builtin_region => {
                    try self.add_error(error.BuiltinOpaqueLevel);
                    // recover by parsing the rest so the Ast reports other
                    // possible errors.
                    const builtin = try self.parse_builtin();
                    try self.add_frame_node(builtin);
                },

                .builtin_end => {
                    try self.add_error(error.ExtraEndScope);
                    self.consume_line();
                },

                .identifier,
                .instruction,
                .pseudo_instruction => {
                    try self.add_error(error.RootLevelInstruction);
                    self.consume_line();
                },

                .label,
                .private_label => {
                    try self.add_error(error.RootLevelLabel);
                    self.consume_line();
                },

                .unexpected_eof => {
                    try self.add_error(error.UnexpectedEof);
                    _ = self.next_token();
                    break;
                },

                .newline => _ = self.next_token(),

                else => {
                    try self.add_error(error.Unexpected);
                    _ = self.next_token();
                }
            }
        }

        const container = try self.lower_frame_nodes(frame);
        self.nodes.items[0].operands = container;
        _ = try self.expect_token(.eof);
    }

    // TopBuiltin <- SimpleBuiltin / IndentedBuiltin / Section
    // Builtin <- SimpleBuiltin / IndentedBuiltin
    // SimpleBuiltin <- SimpleBuiltinIdentifier (LParan OptionList RParan)? ArgumentList Eol
    // IndentedBuiltin <- IndentedBuiltinIdentifier (LParan OptionList RParan)? ArgumentList Eol Opaque End Eol
    // Section <- '@section' Identifier Eol Opaque [^Section]
    // SimpleBuiltinIdentifier <- '@barrier' / '@define' / '@symbols'
    // IndentedBuiltin <- '@align' / '@header' / '@region'
    // End <- '@end'
    fn parse_builtin(self: *AstGen) EvalError!Node {
        const token = self.next_token();
        const builtin_options = try self.parse_builtin_options();
        const builtin_arguments = try self.parse_arguments();
        _ = try self.expect_token(.newline);

        const tag = self.source.tokens[token].tag;
        const has_opaque = tag.builtin_opaque();

        const opaque_ = if (has_opaque) blk: {
            const payload = try self.parse_opaque();
            if (tag != .builtin_section) {
                _ = try self.expect_token(.builtin_end);
                _ = try self.expect_token(.newline);
            }
            break :blk payload;
        } else Null;

        const composite = try self.add_node(.{
            .tag = .composite,
            .token = Null,
            .operands = .{ .lhs = builtin_options, .rhs = opaque_ } });
        return .{
            .tag = .builtin,
            .token = token,
            .operands = .{ .lhs = builtin_arguments, .rhs = composite } };
    }

    // OptionList <- (Option Comma)* Option?
    // Option <- 'expose' / 'noelimination'
    fn parse_builtin_options(self: *AstGen) !Index {
        _ = self.eat_token(.l_paran) orelse return Null;
        const frame = self.mark_frame();
        defer self.reset_frame(frame);

        while (true) {
            switch (self.current_tag()) {
                .option => {
                    try self.add_frame_node(.{
                        .tag = .option,
                        .token = self.cursor,
                        .operands = .{} });
                    _ = self.next_token();

                    _ = self.eat_token(.comma) orelse {
                        _ = try self.harshly_eat_token(.r_paran);
                        break;
                    };
                },

                .r_paran => {
                    _ = self.next_token();
                    break;
                },

                .newline,
                .eof,
                .unexpected_eof => {
                    try self.add_error_arg(error.Expected, Token.Tag.r_paran);
                    break;
                },

                else => {
                    try self.add_error_arg(error.Expected, Token.Tag.option);
                    _ = self.next_token();
                }
            }
        }

        const range = try self.lower_frame_nodes(frame);
        return try self.add_index_range(range);
    }

    // ArgumentList <- (Argument Comma)* Argument?
    fn parse_arguments(self: *AstGen) EvalError!Index {
        const frame = self.mark_frame();
        defer self.reset_frame(frame);

        while (true) {
            switch (self.current_tag()) {
                .plus,
                .minus,
                .reference_label,
                .numeric_literal,
                .string_literal,
                .identifier,
                .pseudo_instruction,
                .reserved_argument => {
                    const expression = try self.parse_expression();
                    try self.add_frame_node(expression);
                    _ = self.eat_token(.comma) orelse break;

                    switch (self.current_tag()) {
                        .newline,
                        .eof,
                        .unexpected_eof => try self.add_error_arg(error.Expected, Token.Tag.identifier),
                        else => {}
                    }
                },

                .newline,
                .eof,
                .unexpected_eof => break,

                else => {
                    try self.add_error(error.Unexpected);
                    _ = self.next_token();
                }
            }
        }

        const range = try self.lower_frame_nodes(frame);
        return try self.add_index_range(range);
    }

    // Argument <- ReservedArgument / PseudoOpcode / Expression
    // Expression <- (Expression Operation)* Target
    // Operation <- ArithmeticOp
    // Target <- NegatableTarget / Reference
    // NegatableTarget <- '-'? (Identifier / Integer)
    // Reference <- Dot Identifier (Apostrophe ReferenceSelector)?
    // Integer <- Decimal / Binary / Hexadecimal
    // Decimal <- [0-9] [0-9]*
    // Binary <- '0b' [01] [01]*
    // Hexadecimal <- '0x' [0-9a-fA-F] [0-9a-fA-F]*
    // ReferenceSelector <- 'l' / 'h'
    // ArithmeticOp <- '+' / '-'
    // ReservedArgument <- 'ra' / 'rb' / 'rc' / 'rd' / 'rx' / 'ry' /
    //     'rz' / 's' / 'ns' / 'z' / 'nz' / 'c' / 'nc' / 'u' / 'nu' /
    //     'sf' / 'sp' / 'xy'
    fn parse_expression(self: *AstGen) EvalError!Node {
        // fixme: expression implementation
        defer _ = self.next_token();
        return .{
            .tag = .identifier,
            .token = self.cursor,
            .operands = .{} };
    }

    // Opaque <- (Builtin / Instruction)*
    fn parse_opaque(self: *AstGen) EvalError!Index {
        const frame = self.mark_frame();
        defer self.reset_frame(frame);

        while (true) {
            switch (self.current_tag()) {
                .builtin_align,
                .builtin_barrier,
                .builtin_define,
                .builtin_region => {
                    const builtin = try self.parse_builtin();
                    try self.add_frame_node(builtin);
                },

                .builtin_header,
                .builtin_symbols => {
                    try self.add_error(error.BuiltinRootLevel);
                    // recover by parsing the rest so the Ast reports other
                    // possible errors.
                    const builtin = try self.parse_builtin();
                    try self.add_frame_node(builtin);
                },

                .identifier,
                .instruction,
                .pseudo_instruction => {
                    const instruction = try self.parse_instruction();
                    try self.add_frame_node(instruction);
                },

                .label,
                .private_label => {
                    const label = try self.parse_labeled_instruction();
                    try self.add_frame_node(label);
                },

                .unexpected_eof => {
                    try self.add_error(error.UnexpectedEof);
                    _ = self.next_token();
                    break;
                },

                .eof,
                .builtin_end,
                .builtin_section => break,

                .newline => _ = self.next_token(),

                else => {
                    try self.add_error(error.Unexpected);
                    _ = self.next_token();
                }
            }
        }

        const range = try self.lower_frame_nodes(frame);
        return try self.add_index_range(range);
    }

    // Instruction <- (Label Eol)* Label? AnyOpcode ArgumentList Eol
    // AnyOpcode <- Opcode / PseudoOpcode / TypedOpcode
    // Opcode <- 'ast'
    // PseudoOpcode <- 'ascii' / 'i16' / 'i24' / 'i8' / 'u16' / 'u24' / 'u8'
    // TypedOpcode <- 'reserve'
    fn parse_instruction(self: *AstGen) EvalError!Node {
        const instruction = self.cursor;
        _ = self.next_token();

        const composite = if (self.eat_token(.modifier)) |modifier| blk: {
            const modifier_node = try self.add_node(.{
                .tag = .modifier,
                .token = modifier,
                .operands = .{} });
            const node = try self.add_node(.{
                .tag = .composite,
                .token = Null,
                .operands = .{ .rhs = modifier_node } });
            break :blk node;
        } else Null;

        const instruction_arguments = try self.parse_arguments();

        return .{
            .tag = .instruction,
            .token = instruction,
            .operands = .{ .lhs = instruction_arguments, .rhs = composite } };
    }

    // Label <- PublicLabel / PrivateLabel
    // PublicLabel <- Identifier Colon
    // PrivateLabel <- Dot Identifier Colon
    fn parse_labeled_instruction(self: *AstGen) EvalError!Node {
        const frame = self.mark_frame();
        defer self.reset_frame(frame);

        const instruction = loop: while (true) {
            switch (self.current_tag()) {
                .identifier,
                .instruction,
                .pseudo_instruction => {
                    break :loop try self.parse_instruction();
                },

                .label,
                .private_label => {
                    const public_bit: Index = if (self.current_tag() == .label) 1 else 0;
                    try self.add_frame_node(.{
                        .tag = .label,
                        .token = self.cursor,
                        .operands = .{ .lhs = public_bit } });
                    _ = self.next_token();
                },

                .newline => _ = self.next_token(),

                .eof,
                .unexpected_eof => {
                    try self.add_error(error.UnexpectedEof);
                    // fixme: maybe add a parse fatal instead of adding a
                    // 'ghost' instruction, seeing as this is an eof anyway.
                    break :loop Node {
                        .tag = .instruction,
                        .token = Null,
                        .operands = .{} };
                },

                else => {
                    try self.add_error_arg(error.Expected, Token.Tag.instruction);
                    self.consume_line();
                }
            }
        };

        const range = try self.lower_frame_nodes(frame);
        const range_node = try self.add_index_range(range);
        const modifier = if (instruction.operands.rhs != Null)
            self.nodes.items[instruction.operands.rhs].operands.rhs else
            Null;
        const composite = try self.add_node(.{
            .tag = .composite,
            .token = Null,
            .operands = .{ .lhs = range_node, .rhs = modifier } });
        return .{
            .tag = .instruction,
            .token = instruction.token,
            .operands = .{ .lhs = instruction.operands.lhs, .rhs = composite } };
    }
};

// Tests

const options = @import("options");
const AsmTokeniser = @import("AsmTokeniser.zig");

const stderr = std.io
    .getStdErr()
    .writer();

fn testAst(input: [:0]const u8) !AsmAst {
    var tokeniser = AsmTokeniser.init(input);
    const source = try Source.init(std.testing.allocator, &tokeniser);
    return try AsmAst.init(std.testing.allocator, source);
}

fn testAstDeinit(ast: *AsmAst) void {
    ast.deinit();
    ast.source.deinit();
}

fn testAstGen(input: [:0]const u8) !void {
    var ast = try testAst(input);
    defer testAstDeinit(&ast);

    if (options.dump) {
        for (ast.nodes, 0..) |node, idx|
            try stderr.print("{}: {s} {s}({}) lhs={} rhs={}\n", .{
                idx,
                @tagName(node.tag),
                @tagName(ast.source.tokens[node.token].tag),
                node.token,
                node.operands.lhs,
                node.operands.rhs });
        try ast.dump(stderr);

        const estimated_node_count = ast.source.tokens.len + 2;
        try stderr.print("input len:            {} bytes ({}) (estimated={})\n", .{ ast.source.buffer.len, ast.source.tokens.len, input.len / 4 });
        try stderr.print("ast memory consumed:  {} bytes ({})\n", .{ ast.nodes.len * @sizeOf(Node), ast.nodes.len });
        try stderr.print("ast memory estimated: {} bytes ({})\n", .{ estimated_node_count * @sizeOf(Node), estimated_node_count });
    }

    for (ast.errors) |err|
        try err.write("test.s", input, stderr);
    try std.testing.expect(ast.errors.len == 0);
}

fn testAstGenErr(input: [:0]const u8, errors: []const AstGen.ParseError) !void {
    var ast = try testAst(input);
    defer testAstDeinit(&ast);

    var ast_errors = std.ArrayList(anyerror).init(std.testing.allocator);
    defer ast_errors.deinit();
    for (ast.errors) |err|
        try ast_errors.append(err.id);
    try std.testing.expectEqualSlices(anyerror, errors, ast_errors.items);
}

const ErrLine = struct { AstGen.ParseError, usize };

fn testAstGenErrLine(input: [:0]const u8, errors: []const ErrLine) !void {
    var ast = try testAst(input);
    defer testAstDeinit(&ast);

    if (options.dump)
        for (ast.errors) |err|
            try err.write("test.s", input, stderr);

    try std.testing.expectEqual(errors.len, ast.errors.len);

    for (errors, ast.errors) |expected_error, err| {
        try std.testing.expectEqual(expected_error[0], err.id);
        try std.testing.expectEqual(expected_error[1], err.line);
    }
}

test "format errors" {
    try testAstGenErr("", &.{});
    try testAstGenErr("/", &.{ error.UnexpectedEof });
    try testAstGenErr("0xZZ", &.{ error.Unexpected });
    try testAstGenErr("ast", &.{ error.RootLevelInstruction });
    try testAstGenErr(".label:", &.{ error.RootLevelLabel });
    try testAstGenErr("@end", &.{ error.ExtraEndScope });
}

test "forbid instructions at top level" {
    try testAstGenErr("ast", &.{ error.RootLevelInstruction });
    try testAstGenErr("@section foo\nast", &.{});
    try testAstGenErr("@header foo\nast\n@end", &.{});
}

test "error line number" {
    try testAstGenErrLine(
        \\
        \\ascii "foo"
        \\
        \\@define(foo
        \\@define foo)
        \\
        \\@section test
        \\
        \\            ast 0xZZ ; hmmmm
        \\
        \\            0x00
        \\            ra
    , &.{
        .{ error.RootLevelInstruction, 2 },
        .{ error.Expected, 4 },
        .{ error.Expected, 4 },
        .{ error.Expected, 5 },
        .{ error.Unexpected, 9 },
        .{ error.Unexpected, 11 },
        .{ error.Unexpected, 12 }
    });
}

test "full fledge" {
    try testAstGen(
        \\// foo
        \\
    );

    try testAstGen(
        \\// foo
        \\
        \\@section foo, foo
        \\@section(noelimination) bar
        \\              ast' foo, bar
        \\.label:
        \\label:        ast bar
    );
}
