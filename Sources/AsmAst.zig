
const std = @import("std");
const AsmTokeniser = @import("AsmTokeniser.zig");
const Error = @import("Error.zig");
const Source = @import("Source.zig");
const Token = @import("Token.zig");

const AsmAst = @This();

// Tokens are copied anyway, and a TokenLocation for a specifically known tag
// is half of the memory of a Token due to padding.
const TokenLocation = struct {

    start_byte: usize,
    end_byte: usize,

    pub fn from_token(token: Token) TokenLocation {
        return .{
            .start_byte = token.start_byte,
            .end_byte = token.end_byte };
    }
};

const Node = union(enum) {

    const Container = struct {
        section: []const u8,
        nodes: NodeList
    };

    const Instruction = struct {
        labels: []const TokenLocation,
        instruction_token: Token,
        is_alternate: bool,
        arguments: NodeList // Node.argument
    };

    const Argument = struct {
        tokens: TokenList
    };

    const Builtin = struct {
        builtin_token: Token,
        arguments: NodeList, // Node.argument
        nodes: NodeList
    };

    container: Container,
    instruction: Instruction,
    argument: Argument,
    builtin: Builtin
};

const TokenList = std.ArrayList(Token);
const TokenLocationList = std.ArrayList(TokenLocation);
const NodeList = std.ArrayList(*Node);
const ErrorList = std.ArrayList(Error);

allocator: std.mem.Allocator,
buffer: [:0]const u8,
sections: []const *Node,
errors: []const Error,

// Tokens can be deallocated after parsing, but the source buffer cannot. The
// caller owns 'sections' and 'errors'.
pub fn init(allocator: std.mem.Allocator, source: Source) !AsmAst {
    const root_node = try allocator.create(Node);
    defer allocator.destroy(root_node);
    root_node.* = .{ .container = .{
        .section = "root",
        .nodes = NodeList.init(allocator) } };
    var errors = ErrorList.init(allocator);

    var ast_gen = try AstGen.init(allocator, source, root_node, &errors);
    defer ast_gen.deinit();

    std.debug.assert(source.tokens.len != 0);
    std.debug.assert(source.tokens[source.tokens.len - 1].tag == .eof);
    try ast_gen.parse();

    switch (root_node.*) {
        .container => |*container| return .{
            .allocator = allocator,
            .buffer = source.buffer,
            .sections = try container.nodes.toOwnedSlice(),
            .errors = try errors.toOwnedSlice() },
        else => unreachable
    }
}

pub fn deinit(self: *AsmAst) void {
    for (self.sections) |section|
        self.dealloc(section);
    self.allocator.free(self.sections);

    for (self.errors) |error_|
        self.allocator.free(error_.message);
    self.allocator.free(self.errors);
}

fn dealloc(self: *AsmAst, node: *Node) void {
    // fixme: clean up allocation/deallocation code by moving some stuff into
    // Node init/deinit
    switch (node.*) {
        .container => |*container| {
            for (container.nodes.items) |node_|
                self.dealloc(node_);
            container.nodes.deinit();
        },
        .instruction => |*instruction| {
            for (instruction.arguments.items) |argument|
                self.dealloc(argument);
            self.allocator.free(instruction.labels);
            instruction.arguments.deinit();
        },
        .argument => |*argument| {
            argument.tokens.deinit();
        },
        .builtin => |*builtin| {
            for (builtin.nodes.items) |node_|
                self.dealloc(node_);
            for (builtin.arguments.items) |argument|
                self.dealloc(argument);
            builtin.arguments.deinit();
            builtin.nodes.deinit();
        }
    }
    self.allocator.destroy(node);
}

const render = @import("render.zig");

// fixme: improve dump
fn dump(self: *AsmAst, writer: anytype) !void {
    const DumpStream = render.AutoIndentingStream(@TypeOf(writer));
    var renderer = DumpStream {
        .underlying_writer = writer,
        .indent_delta = 4 };
    for (self.sections) |section|
        try self.print_node(&renderer, section);
}

fn print_node(self: *AsmAst, ais: anytype, node: *Node) !void {
    _ = try ais.write("- ");
    _ = try ais.write(@tagName(node.*));
    defer _ = ais.write("\n") catch {};

    ais.pushIndent();
    defer ais.popIndent();

    switch (node.*) {
        .container => |container| {
            _ = try ais.write("\n");
            for (container.nodes.items) |node_|
                try self.print_node(ais, node_);
        },
        .instruction => |instruction| {
            ais.pushIndent();
            defer ais.popIndent();

            for (instruction.labels) |label| {
                _ = try ais.write("; ");
                _ = try ais.write(self.buffer[label.start_byte..(label.end_byte + 1)]);
            }

            for (instruction.arguments.items) |argument|
                try self.print_inline(ais, argument);
        },
        .builtin => |builtin| {
            ais.pushIndent();
            defer ais.popIndent();

            _ = try ais.write(" ");
            _ = try ais.write(@tagName(builtin.builtin_token.tag));

            for (builtin.arguments.items) |argument|
                try self.print_inline(ais, argument);
            _ = try ais.write("\n");
            for (builtin.nodes.items) |node_|
                try self.print_node(ais, node_);
        },
        else => {}
    }
}

fn print_inline(self: *AsmAst, ais: anytype, node: *Node) !void {
    _ = try ais.write(", ");
    switch (node.*) {
        .argument => |argument_| {
            for (argument_.tokens.items) |token|
                _ = try ais.write(token.slice(self.buffer));
        },
        else => {}
    }
}

const AstGen = struct {

    const ContainerType = enum {
        root,
        section,
        generic,
        none
    };

    const LinkedNodeList = struct {
        previous: ?*LinkedNodeList,
        node: *Node,
        container_type: ContainerType
    };

    allocator: std.mem.Allocator,
    source: Source,
    // The root node container may include simple builtins as well as
    // sections.  Instructions may not be directly in the top-level node
    // list. AstGen verifies these cases.
    root_node: *Node,
    errors: *ErrorList,
    // For tracking labels before moving them into the first available memory area.
    label_bucket: TokenLocationList,
    // For tracking the current block stack frame during gen. fixme: rename to container_stack?
    stack: *LinkedNodeList,
    cursor: usize = 0,
    // fixme: convert to options struct?
    abort_error: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        source: Source,
        root_node: *Node,
        errors: *ErrorList
    ) !AstGen {
        switch (root_node.*) {
            .container => {},
            else => unreachable
        }

        const stack = try allocator.create(LinkedNodeList);
        stack.* = .{
            .previous = null,
            .node = root_node,
            .container_type = .root };
        return .{
            .allocator = allocator,
            .source = source,
            .root_node = root_node,
            .errors = errors,
            .label_bucket = .init(allocator),
            .stack = stack };
    }

    // Frees everything except the created Nodes, Node lists and Error list.
    pub fn deinit(self: *AstGen) void {
        var stack_iterator = self.stack.previous;
        while (stack_iterator) |stack_frame_| {
            const next_linked_frame = stack_frame_.previous;
            self.allocator.destroy(stack_frame_);
            stack_iterator = next_linked_frame;
        }

        self.allocator.destroy(self.stack);
        self.label_bucket.deinit();
    }

    const AstGenError = error {
        UnexpectedEof,
        UnexpectedPrediction,
        Unexpected,
        RootLevelInstruction,
        RootLevelLabel,
        UnsupportedArgument,
        UnsupportedOffsetArgument,
        MissedEndScope,
        ExtraEndScope,
        BuiltinRootLevel,
        BuiltinGenericLevel
    };

    const ParseError = error {
        Abort
    } || std.mem.Allocator.Error;

    fn error_message(id: AstGenError) []const u8 {
        return switch (id) {
            AstGenError.UnexpectedEof => "unexpected eof",
            AstGenError.UnexpectedPrediction => "expected {s}, found {s}",
            AstGenError.Unexpected => "unexpectedly got {s} '{s}'",
            AstGenError.RootLevelInstruction => "instructions cannot be defined at the root level",
            AstGenError.RootLevelLabel => "labels cannot be declared at the root level",
            AstGenError.UnsupportedArgument => "unsupported argument {s}",
            AstGenError.UnsupportedOffsetArgument => "invalid offset argument {s}",
            AstGenError.MissedEndScope => "missed an @end scope or illegal use of {s}",
            AstGenError.ExtraEndScope => "extra @end",
            AstGenError.BuiltinRootLevel => "builtin '{s}' requires to be at the root level",
            AstGenError.BuiltinGenericLevel => "builtin '{s}' cannot appear at the root level"
        };
    }

    fn verify_root_section(self: *AstGen) !void {
        if (self.stack.container_type != .root and self.stack.container_type != .section)
            try self.fault(AstGenError.MissedEndScope, .{ @tagName(self.previous_token().tag) });
    }

    fn expected(self: *AstGen, tag: Token.Tag) ParseError!void {
        @branchHint(.cold);
        try self.fault(AstGenError.UnexpectedPrediction, .{
            @tagName(tag),
            @tagName(self.current()) });
    }

    fn fault(self: *AstGen, comptime id: AstGenError, arguments_: anytype) ParseError!void {
        @branchHint(.cold);
        const format = try std.fmt.allocPrint(self.allocator, error_message(id), arguments_);
        const token = if (id == AstGenError.MissedEndScope)
            self.previous_token() else // hack for pointing to erroring token
            self.current_token();
        const token_location = self.source.location_of(token);

        try self.errors.append(.{
            .id = id,
            .token = token,
            .message = format,
            .line = token_location.line,
            .line_cursor = token_location.line_cursor,
            .end_cursor = token_location.end_cursor });
        if (self.abort_error)
            return ParseError.Abort;
    }

    const State = enum {
        start,
        flush,
        full_flush,
        expect_flush,
        expect_full_flush,
        builtin,
        end_scope,
        new_section,
        instruction,
        argument,
        reference_argument,
        numeric_argument,
        offset_argument
    };

    pub fn parse(self: *AstGen) ParseError!void {
        parse_loop: while (self.cursor < self.source.tokens.len) {
            state: switch (State.start) {
                .start => switch (self.current()) {
                    .unexpected_eof => {
                        try self.fault(AstGenError.UnexpectedEof, .{});
                        break :parse_loop;
                    },

                    .eof, .newline, .comma => self.advance(),

                    .private_label, .label => {
                        if (self.stack.container_type == .root)
                            try self.fault(AstGenError.RootLevelLabel, .{});
                        const token_location = TokenLocation.from_token(self.current_token());
                        try self.label_bucket.append(token_location);
                        self.advance();
                    },

                    .builtin_symbols,
                    .builtin_define,
                    .builtin_header,
                    .builtin_align => continue :state .builtin,
                    .builtin_end => continue :state .end_scope,
                    .builtin_section => continue :state .new_section,

                    .identifier,
                    .instruction,
                    .pseudo_instruction => continue :state .instruction,

                    else => {
                        const tag = @tagName(self.current());
                        const input = self.buffer_token(self.current_token());
                        try self.fault(AstGenError.Unexpected, .{ tag, input });
                        self.advance();
                    },
                },

                .flush => switch (self.next_token()) {
                    .eof, .newline, .comma => self.advance(),
                    else => continue :state .flush
                },

                .full_flush => switch (self.next_token()) {
                    .eof, .newline => self.advance(),
                    else => continue :state .full_flush
                },

                .expect_flush => switch (self.next_token()) {
                    .eof, .newline, .comma => self.advance(),
                    else => try self.expected(.newline)
                },

                .expect_full_flush => switch (self.next_token()) {
                    .eof, .newline => self.advance(),
                    else => try self.expected(.newline)
                },

                // A builtin except @section or @end. There are builtins which
                // can only be declared at the root-level, or only in
                // sections/containers. There are also builtins which add an
                // indentation to the stack, popped with @end.
                .builtin => {
                    const token = self.current_token();
                    const root_only = token.builtin_rootonly();

                    if (root_only and self.stack.container_type != .root) {
                        try self.fault(AstGenError.BuiltinRootLevel, .{ @tagName(self.current()) });
                        continue :state .full_flush;
                    }

                    if (!root_only and
                        self.stack.container_type != .section and
                         self.stack.container_type != .generic
                    ) {
                        try self.fault(AstGenError.BuiltinGenericLevel, .{ @tagName(self.current()) });
                        continue :state .full_flush;
                    }

                    const builtin = try self.allocator.create(Node);
                    builtin.* = .{ .builtin = .{
                        .builtin_token = self.current_token(),
                        .arguments = NodeList.init(self.allocator),
                        .nodes = NodeList.init(self.allocator) } };
                    var container_ = self.container();
                    try container_.append(builtin);

                    // for nodes, the argument state will pop into this container
                    if (token.builtin_has_indentation())
                        try self.stack_push(builtin, .generic);

                    // for arguments
                    try self.stack_push(builtin, .none);
                    self.advance();
                    continue :state .argument;
                },

                .end_scope => switch (self.next_token()) {
                    .eof, .newline => {
                        if (self.stack.container_type == .root or self.stack.container_type == .section) {
                            try self.fault(AstGenError.ExtraEndScope, .{});
                            continue :state .full_flush;
                        }

                        self.stack_pop();
                        self.advance();
                    },
                    else => try self.expected(.newline)
                },

                // A section is a top-level memory area container.
                // Additionally, @defines, @symbols and other simple builtins
                // can only be put in the top-level.
                .new_section => switch (self.next_token()) {
                    .identifier => {
                        try self.verify_root_section();

                        const new_section = try self.allocator.create(Node);
                        new_section.* = .{ .container = .{
                            .section = self.buffer_token(self.current_token()),
                            .nodes = NodeList.init(self.allocator) } };
                        var sections_ = self.sections();
                        try sections_.append(new_section);

                        if (self.stack.container_type == .section)
                            self.stack_pop(); // pop current section
                        try self.stack_push(new_section, .section);
                        continue :state .expect_full_flush;
                    },
                    else => try self.expected(.identifier)
                },

                // Any instruction, including @callable arg arg.
                // fixme: do we want @callable() to have parans, or treat
                // headers like instructions with space arguments?
                .instruction => {
                    if (self.stack.container_type == .root) {
                        try self.fault(AstGenError.RootLevelInstruction, .{});
                        continue :state .flush;
                    }

                    std.debug.assert(self.stack.container_type == .section or
                        self.stack.container_type == .generic);

                    // move the label bucket into the new hoisting instruction
                    const instruction_ = try self.allocator.create(Node);
                    instruction_.* = .{ .instruction = .{
                        .labels = try self.label_bucket.toOwnedSlice(),
                        .instruction_token = self.current_token(),
                        .is_alternate = false,
                        .arguments = NodeList.init(self.allocator) } };
                    self.label_bucket = TokenLocationList.init(self.allocator);

                    var container_ = self.container();
                    try container_.append(instruction_);
                    try self.stack_push(instruction_, .none);

                    if (self.next_token() == .modifier) {
                        switch (instruction_.*) {
                            .instruction => |*hoist| hoist.is_alternate = true,
                            else => unreachable
                        }
                        self.advance();
                    }

                    continue :state .argument;
                },

                // From an instruction or argument loopback, must have the
                // cursor already on the argument. The top-of-stack must be
                // populated with the instruction.
                //
                // Arguments can only appear in an instruction's argument list,
                // but it's still represented as a Node due to the stack.
                //
                //  instr. ra rb 0x00 + 666 666 .reference'u + 2
                //         ^  ^  ^--------^ ^-^ ^--------------^
                .argument => switch (self.current()) {
                    .identifier,
                    .plus,
                    .minus,
                    .reference_label,
                    .numeric_literal,
                    .string_literal,
                    .pseudo_instruction,
                    .reserved_argument => {
                        const argument_ = try self.allocator.create(Node);
                        argument_.* = .{ .argument = .{
                            .tokens = TokenList.init(self.allocator) }};

                        var arguments_ = self.arguments();
                        try arguments_.append(argument_);
                        try self.stack_push(argument_, .none);
                        try self.add_token(self.current_token());

                        switch (self.current()) {
                            .plus,
                            .minus => continue :state .offset_argument,
                            .reference_label => continue :state .reference_argument,
                            .identifier,
                            .numeric_literal => continue :state .numeric_argument,
                            .string_literal,
                            .pseudo_instruction,
                            .reserved_argument => {
                                self.stack_pop();
                                self.advance();
                                continue :state .argument;
                            },
                            else => unreachable
                        }
                    },
                    .eof, .newline, .comma => {
                        self.stack_pop();
                        self.advance();
                    },
                    else => {
                        try self.fault(AstGenError.UnsupportedArgument, .{ @tagName(self.current()) });
                        self.advance();
                        continue :state .argument;
                    }
                },

                .reference_argument => switch (self.next_token()) {
                    .minus, .plus => {
                        try self.add_token(self.current_token());
                        continue :state .offset_argument;
                    },
                    .modifier => {
                        try self.add_token(self.current_token());
                        continue :state .reference_argument;
                    },
                    else => {
                        // nothing to chain, it may be another argument
                        self.stack_pop();
                        continue :state .argument;
                    }
                },

                .numeric_argument => switch (self.next_token()) {
                    .minus, .plus => {
                        try self.add_token(self.current_token());
                        continue :state .offset_argument;
                    },
                    else => {
                        // nothing to chain, it may be another argument
                        self.stack_pop();
                        continue :state .argument;
                    }
                },

                .offset_argument => switch (self.next_token()) {
                    .reference_label => {
                        try self.add_token(self.current_token());
                        continue :state .reference_argument;
                    },
                    .numeric_literal => {
                        try self.add_token(self.current_token());
                        continue :state .numeric_argument;
                    },
                    else => {
                        try self.fault(AstGenError.UnsupportedOffsetArgument, .{ @tagName(self.current()) });
                        self.stack_pop();
                        continue :state .argument;
                    }
                }
            }
        }

        // either top-level or sectioned container, otherwise we missed an @end
        // somewhere in the assembly
        try self.verify_root_section();
    }

    inline fn current(self: *AstGen) Token.Tag {
        return self.source.tokens[self.cursor].tag;
    }

    inline fn current_token(self: *AstGen) Token {
        return self.source.tokens[self.cursor];
    }

    inline fn previous_token(self: *AstGen) Token {
        return self.source.tokens[self.cursor -| 1];
    }

    inline fn advance(self: *AstGen) void {
        self.cursor += 1;
    }

    inline fn buffer_token(self: *AstGen, token: Token) []const u8 {
        return token.slice(self.source.buffer);
    }

    inline fn next_token(self: *AstGen) Token.Tag {
        self.advance();
        return self.current();
    }

    fn sections(self: *AstGen) *NodeList {
        switch (self.root_node.*) {
            .container => |*container_| return &container_.nodes,
            else => @panic("bug: root node must be a container")
        }
    }

    fn container(self: *AstGen) *NodeList {
        switch (self.stack.node.*) {
            .container => |*container_| return &container_.nodes,
            .builtin => |*builtin_| return &builtin_.nodes,
            else => @panic("bug: container() expected top-of-stack to be a node container")
        }
    }

    fn arguments(self: *AstGen) *NodeList {
        switch (self.stack.node.*) {
            .instruction => |*instruction_| return &instruction_.arguments,
            .builtin => |*builtin_| return &builtin_.arguments,
            else => @panic("bug: arguments() expected top-of-stack to be an argument-holding node")
        }
    }

    fn add_token(self: *AstGen, token: Token) !void {
        switch (self.stack.node.*) {
            .argument => |*argument| try argument.tokens.append(token),
            else => @panic("bug: add_token() unsupported top-of-stack type")
        }
    }

    fn stack_push(self: *AstGen, node: *Node, container_type: ContainerType) !void {
        const new_frame = try self.allocator.create(LinkedNodeList);
        new_frame.* = .{
            .previous = self.stack,
            .node = node,
            .container_type = container_type };
        self.stack = new_frame;
    }

    fn stack_pop(self: *AstGen) void {
        const popper = self.stack.previous;
        std.debug.assert(popper != null);
        self.allocator.destroy(self.stack);
        self.stack = popper.?;
    }
};

// Tests

const options = @import("options");

const stderr = std.io
    .getStdErr()
    .writer();

fn testAst(input: [:0]const u8) !AsmAst {
    var tokeniser = AsmTokeniser.init(input);
    const source = try Source.init(std.testing.allocator, &tokeniser);
    defer source.deinit();

    return try AsmAst.init(std.testing.allocator, source);
}

fn testAstGen(input: [:0]const u8) !void {
    var ast = try testAst(input);
    defer ast.deinit();

    if (options.dump)
        try ast.dump(stderr);

    for (ast.errors) |error_|
        std.debug.print("{s}\n", .{ error_.message });
    try std.testing.expect(ast.errors.len == 0);
}

fn testAstGenErr(input: [:0]const u8, errors: []const AstGen.AstGenError) !void {
    var ast = try testAst(input);
    defer ast.deinit();

    try std.testing.expectEqual(errors.len, ast.errors.len);

    for (errors, ast.errors) |expected_error, error_|
        try std.testing.expectEqual(expected_error, error_.id);
}

const ErrLine = struct { AstGen.AstGenError, usize };

fn testAstGenErrLine(input: [:0]const u8, errors: []const ErrLine) !void {
    var ast = try testAst(input);
    defer ast.deinit();

    if (options.dump)
        for (ast.errors) |error_|
            try error_.write("test.s", input, stderr);

    try std.testing.expectEqual(errors.len, ast.errors.len);

    for (errors, ast.errors) |expected_error, error_| {
        try std.testing.expectEqual(expected_error[0], error_.id);
        try std.testing.expectEqual(expected_error[1], error_.line);
    }
}

test "format errors" {
    try testAstGenErr("/", &.{ AstGen.AstGenError.UnexpectedEof });
}

test "protect section ids" {
    try testAstGenErr("@section", &.{ AstGen.AstGenError.UnexpectedPrediction });
}

test "forbid instructions at top level" {
    try testAstGenErr("ast", &.{ AstGen.AstGenError.RootLevelInstruction });
    try testAstGenErr("@section foo\nast", &.{});
}

test "error line number" {
    try testAstGenErrLine(
        \\
        \\
        \\ast
    , &.{
        .{ AstGen.AstGenError.RootLevelInstruction, 3 }
    });

    try testAstGenErrLine(
        \\
        \\@section test
        \\            ast .foo:
        \\            ast .foo
        \\            ast 5 .foo: 5
    , &.{
        .{ AstGen.AstGenError.UnsupportedArgument, 3 },
        .{ AstGen.AstGenError.UnsupportedArgument, 5 }
    });

    try testAstGenErrLine(
        \\
        \\ascii "foo"
        \\
        \\@section
        \\@section test
        \\
        \\            ast 0xZZ ; hmmmm
        \\
        \\            0x00
        \\            ra
    , &.{
        .{ AstGen.AstGenError.RootLevelInstruction, 2 },
        .{ AstGen.AstGenError.UnexpectedPrediction, 4 },
        .{ AstGen.AstGenError.UnsupportedArgument, 7 },
        .{ AstGen.AstGenError.Unexpected, 9 },
        .{ AstGen.AstGenError.Unexpected, 10 }
    });
}

test "full fledge" {
    try testAstGen(
        \\@symbols
        \\@symbols foo bar
        \\@define roo doo
        \\
        \\@section bar
        \\
        \\@align 24
        \\            ascii "foo" 0x00
        \\            u8 -1
        \\            u16 .label - .foo
        \\      @align awesome_enabled
        \\            reserve u8 test
        \\      @end
        \\@end
        \\
        \\.another:
        \\.label:     ast ra rb
        \\foo:        ast rb + 5
        \\
        \\@section bar
        \\
        \\            ast 0x00 + 0x00 0x00
        \\.aaaaaa:    ast' memory
        \\            ast 1 + .foo'u
        \\            ast .foo'u + 1 .bar
        \\            @callable ra - 0x00
    );
}
