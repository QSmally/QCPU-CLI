
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

    const estimated_node_count = (source.tokens.len + 2) / 2;
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
        .builtin => {
            try self.dump_node(ais, pm, @intCast(node.operands.lhs));
            try self.dump_node(ais, pm, @intCast(node.operands.rhs));
        },
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
        builtin,        // lhs is options data, rhs is compositie of arguments, container
        option,         // both unused, token is option
        // instruction,    // lhs is arguments data, rhs is labels data
        // add,            // lhs + rhs
        // sub,            // lhs - rhs
        // neg,            // -lhs, rhs is unused
        identifier,     // both unused, token is identifier
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
        BuiltinOpaqueLevel
    };

    fn add_error_arg(self: *AstGen, comptime err: ParseError, argument: anytype) !void {
        @branchHint(.unlikely);

        const message = switch (err) {
            error.UnexpectedEof => "unexpected EOF",
            error.Expected => "expected {s}, found {s}",
            error.Unexpected => "unexpectedly got {s} '{s}'",
            error.RootLevelInstruction => "instructions cannot be defined at the root level",
            error.RootLevelLabel => "labels cannot be declared at the root level",
            error.ExtraEndScope => "extra @end",
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
    //
    // TopBuiltin <- SimpleBuiltin / IndentedBuiltin / Section
    // Builtin <- SimpleBuiltin / IndentedBuiltin
    // SimpleBuiltin <- SimpleBuiltinIdentifier (LParan OptionList RParan)? ArgumentList Eol
    // IndentedBuiltin <- IndentedBuiltinIdentifier (LParan OptionList RParan)? ArgumentList Eol Opaque End Eol
    // Section <- '@section' Identifier Eol Opaque [^Section]
    //
    // Opaque <- (Builtin / Instruction)*
    // Instruction <- (Label Eol)* Label? AnyOpcode ArgumentList Eol
    // AnyOpcode <- Opcode / PseudoOpcode / TypedOpcode
    //
    // OptionList <- (Option Comma)* Option?
    //
    // ArgumentList <- (Argument Comma)* Argument?
    // Argument <- ReservedArgument / PseudoOpcode / Expression
    // Expression <- (Expression Operation)* Target
    // Operation <- ArithmeticOp
    // Target <- NegatableTarget / Reference
    // NegatableTarget <- '-'? (Identifier / Integer)
    //
    // Label <- PublicLabel / PrivateLabel
    // PublicLabel <- Identifier Colon
    // PrivateLabel <- Dot Identifier Colon
    // Reference <- Dot Identifier (Apostrophe ReferenceSelector)?
    //
    // Integer <- Decimal / Binary / Hexadecimal
    // Decimal <- [0-9] [0-9]*
    // Binary <- '0b' [01] [01]*
    // Hexadecimal <- '0x' [0-9a-fA-F] [0-9a-fA-F]*
    //
    // Dot <- '.'
    // Colon <- ':'
    // Apostrophe <- '\''
    // LParan <- '('
    // RParan <- ')'
    // Comment <- '//' [^\n]*
    // Eol <- Comment? '\n'
    // Eof <- !.
    //
    // SimpleBuiltinIdentifier <- '@barrier' / '@define' / '@symbols'
    // IndentedBuiltin <- '@align' / '@header' / '@region'
    // End <- '@end'
    // Option <- 'expose' / 'noelimination'
    // ReferenceSelector <- 'l' / 'h'
    // ArithmeticOp <- '+' / '-'
    // Opcode <- 'ast'
    // PseudoOpcode <- 'ascii' / 'i16' / 'i24' / 'i8' / 'u16' / 'u24' / 'u8'
    // TypedOpcode <- 'reserve'
    // ReservedArgument <- 'ra' / 'rb' / 'rc' / 'rd' / 'rx' / 'ry' /
    //     'rz' / 's' / 'ns' / 'z' / 'nz' / 'c' / 'nc' / 'u' / 'nu' /
    //     'sf' / 'sp' / 'xy'
    pub fn parse_root(self: *AstGen) std.mem.Allocator.Error!void {
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
                .pseudo_instruction,
                .typed_instruction => {
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

    fn parse_builtin(self: *AstGen) !Node {
        const main_token = self.next_token();
        const builtin_options = try self.parse_builtin_options();
        const builtin_arguments = try self.parse_arguments();
        _ = try self.expect_token(.newline);

        const composite = try self.add_node(.{
            .tag = .composite,
            .token = Null,
            .operands = .{ .lhs = builtin_arguments } });
        return .{
            .tag = .builtin,
            .token = main_token,
            .operands = .{ .lhs = builtin_options, .rhs = composite } };
    }

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
                .eof => {
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

    fn parse_arguments(self: *AstGen) !Index {
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
                .reserved_argument => {
                    const expression = try self.parse_expression();
                    try self.add_frame_node(expression);
                    _ = self.eat_token(.comma) orelse break;
                },

                .newline,
                .eof => break,

                else => {
                    try self.add_error(error.Unexpected);
                    _ = self.next_token();
                }
            }
        }

        const range = try self.lower_frame_nodes(frame);
        return try self.add_index_range(range);
    }

    fn parse_expression(self: *AstGen) !Node {
        return .{
            .tag = .identifier,
            .token = self.cursor,
            .operands = .{} };
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

        const estimated_node_count = (ast.source.tokens.len + 2) / 2;
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

test "format errors" {
    try testAstGenErr("", &.{});
    try testAstGenErr("/", &.{ error.UnexpectedEof });
    try testAstGenErr("0xZZ", &.{ error.Unexpected });
    try testAstGenErr("ast", &.{ error.RootLevelInstruction });
    try testAstGenErr(".label:", &.{ error.RootLevelLabel });
    try testAstGenErr("@end", &.{ error.ExtraEndScope });
}

test "full fledge" {
    try testAstGen(
        \\// foo
        \\
    );

    try testAstGen(
        \\// foo
        \\
        \\@section()
        \\@section(noelimination)
        \\@section(expose, noelimination)
    );
}
