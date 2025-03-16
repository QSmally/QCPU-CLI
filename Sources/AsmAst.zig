
// Abstract Syntax Tree

const std = @import("std");
const AsmTokeniser = @import("AsmTokeniser.zig");
const Error = @import("Error.zig");
const Source = @import("Source.zig");
const Token = @import("Token.zig");

const AsmAst = @This();

pub const Node = union(enum) {

    const Section = struct {
        name: []const u8,
        nodes: NodeList
    };

    const Instruction = struct {
        labels: []const Token.Location,
        instruction_token: Token,
        modifier_token: ?Token,
        type_token: ?Token,
        arguments: NodeList // Node.argument
    };

    pub const Builtin = struct {
        builtin_token: Token,
        options: NodeList, // Node.argument
        arguments: NodeList, // Node.argument
        nodes: NodeList
    };

    const Argument = struct {
        tokens: TokenList
    };

    section: Section,
    instruction: Instruction,
    builtin: Builtin,
    argument: Argument
};

const TokenList = std.ArrayList(Token);
const TokenLocationList = std.ArrayList(Token.Location);
const NodeList = std.ArrayList(*Node);
const ErrorList = std.ArrayList(Error);

allocator: std.mem.Allocator,
// fixme: kept track due to dumping Ast to writer
buffer: [:0]const u8,
nodes: []const *Node,
errors: []const Error,

// Tokens can be deallocated after parsing, but the source buffer cannot. The
// caller owns 'nodes' and 'errors' until deinit is called.
pub fn init(allocator: std.mem.Allocator, source: Source) !AsmAst {
    const root_node = try allocator.create(Node);
    defer allocator.destroy(root_node);
    root_node.* = .{ .section = .{
        .name = "root",
        .nodes = NodeList.init(allocator) } };
    var errors = ErrorList.init(allocator);

    var ast_gen = try AstGen.init(allocator, source, root_node, &errors);
    defer ast_gen.deinit();

    std.debug.assert(source.tokens.len != 0);
    std.debug.assert(source.tokens[source.tokens.len - 1].tag == .eof);
    try ast_gen.parse();

    switch (root_node.*) {
        .section => |*section| return .{
            .allocator = allocator,
            .buffer = source.buffer,
            .nodes = try section.nodes.toOwnedSlice(),
            .errors = try errors.toOwnedSlice() },
        else => unreachable
    }
}

pub fn deinit(self: *AsmAst) void {
    for (self.nodes) |section|
        self.dealloc(section);
    self.allocator.free(self.nodes);

    for (self.errors) |error_|
        self.allocator.free(error_.message);
    self.allocator.free(self.errors);
}

fn dealloc(self: *AsmAst, node: *Node) void {
    // fixme: move this into Node and also include clone()
    switch (node.*) {
        .section => |*section| {
            self.dealloc_nodelist(&section.nodes);
        },
        .instruction => |*instruction| {
            self.allocator.free(instruction.labels);
            self.dealloc_nodelist(&instruction.arguments);
        },
        .argument => |*argument| {
            argument.tokens.deinit();
        },
        .builtin => |*builtin| {
            self.dealloc_nodelist(&builtin.options);
            self.dealloc_nodelist(&builtin.arguments);
            self.dealloc_nodelist(&builtin.nodes);
        }
    }
    self.allocator.destroy(node);
}

fn dealloc_nodelist(self: *AsmAst, nodelist: *NodeList) void {
    for (nodelist.items) |node_|
        self.dealloc(node_);
    nodelist.deinit();
}

const render = @import("render.zig");

// fixme: improve dump
fn dump(self: *AsmAst, writer: anytype) !void {
    const DumpStream = render.AutoIndentingStream(@TypeOf(writer));
    var renderer = DumpStream {
        .underlying_writer = writer,
        .indent_delta = 4 };
    for (self.nodes) |section|
        try self.print_node(&renderer, section);
}

fn print_node(self: *AsmAst, ais: anytype, node: *Node) !void {
    _ = try ais.write("- ");
    _ = try ais.write(@tagName(node.*));
    defer _ = ais.write("\n") catch {};

    ais.pushIndent();
    defer ais.popIndent();

    switch (node.*) {
        .section => |section| {
            _ = try ais.write("\n");
            for (section.nodes.items) |node_|
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

            if (builtin.options.items.len > 0) {
                _ = try ais.write("(");
                for (builtin.options.items) |option|
                    try self.print_inline(ais, option);
                _ = try ais.write(")");
            }

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
                _ = try ais.write(token.location.slice(self.buffer));
        },
        else => {}
    }
}

const AstGen = struct {

    const ContainerType = enum {
        root,
        section,
        generic,
        option_list,
        argument_list,
        unspecified
    };

    const LinkedNodeList = struct {
        previous: ?*LinkedNodeList,
        node: *Node,
        container_type: ContainerType
    };

    allocator: std.mem.Allocator,
    source: Source,
    // The root node container may include simple builtins as well as sections.
    // Instructions may not be directly in the top-level node list. AstGen
    // verifies these cases.
    root_node: *Node,
    errors: *ErrorList,
    // For tracking labels before moving them into the first available memory
    // area.
    label_bucket: TokenLocationList,
    // For tracking the current block stack frame during gen.
    stack: *LinkedNodeList,
    cursor: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        source: Source,
        root_node: *Node,
        errors: *ErrorList
    ) !AstGen {
        std.debug.assert(root_node.* == .section);

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
        Expected,
        Unexpected,
        UnexpectedTag,
        RootLevelInstruction,
        RootLevelLabel,
        UnsupportedOffsetArgument,
        MissedEndScope,
        ExtraEndScope,
        BuiltinRootLevel,
        BuiltinGenericLevel
    };

    const ParseError = std.mem.Allocator.Error;

    fn verify_root_section(self: *AstGen) !void {
        if (self.stack.container_type != .root and self.stack.container_type != .section)
            try self.fault(error.MissedEndScope, .{ self.previous_token().tag.fmt() });
    }

    fn expected(self: *AstGen, tag: Token.Tag) ParseError!void {
        try self.fault(error.Expected, .{
            tag.fmt(),
            self.current().fmt() });
    }

    fn fault(self: *AstGen, comptime id: AstGenError, arguments_: anytype) ParseError!void {
        @branchHint(.likely);

        const message = switch (id) {
            error.UnexpectedEof => "unexpected EOF",
            error.Expected => "expected {s}, found {s}",
            error.Unexpected => "unexpectedly got {s} '{s}'",
            error.UnexpectedTag => "unexpectedly got {s}",
            error.RootLevelInstruction => "instructions cannot be defined at the root level",
            error.RootLevelLabel => "labels cannot be declared at the root level",
            error.UnsupportedOffsetArgument => "invalid offset argument {s}",
            error.MissedEndScope => "missed an @end scope or illegal use of {s}",
            error.ExtraEndScope => "extra @end",
            error.BuiltinRootLevel => "builtin '{s}' requires to be at the root level",
            error.BuiltinGenericLevel => "builtin '{s}' cannot appear at the root level"
        };

        const format = try std.fmt.allocPrint(self.allocator, message, arguments_);
        const token = if (id == error.MissedEndScope)
            self.previous_token() else // hack for pointing to erroring token
            self.current_token();
        const token_location = self.source.location_of(token.location);

        try self.errors.append(.{
            .id = id,
            .token = token,
            .message = format,
            .line = token_location.line,
            .line_cursor = token_location.line_cursor,
            .end_cursor = token_location.end_cursor });
    }

    const State = enum {
        start,
        full_flush,
        argument_flush,
        expect_flush,
        expect_full_flush,
        builtin,
        end_scope,
        new_section,
        instruction,
        argument,
        argument_end,
        reference_argument,
        numeric_argument,
        offset_argument,
        string_argument
    };

    pub fn parse(self: *AstGen) ParseError!void {
        parse_loop: while (self.cursor < self.source.tokens.len) {
            state: switch (State.start) {
                .start => switch (self.current()) {
                    .unexpected_eof => {
                        try self.fault(error.UnexpectedEof, .{});
                        break :parse_loop;
                    },

                    .eof, .newline => self.advance(),

                    .private_label, .label => {
                        if (self.stack.container_type == .root)
                            try self.fault(error.RootLevelLabel, .{});
                        const token = self.current_token();
                        try self.label_bucket.append(token.location);
                        self.advance();
                    },

                    .builtin_align,
                    .builtin_define,
                    .builtin_header,
                    .builtin_region,
                    .builtin_symbols => continue :state .builtin,
                    .builtin_end => continue :state .end_scope,
                    .builtin_section => continue :state .new_section,

                    .identifier,
                    .instruction,
                    .pseudo_instruction,
                    .typed_instruction => continue :state .instruction,

                    else => {
                        const tag = self.current();
                        const input = self.buffer_token(self.current_token());
                        try self.fault(error.Unexpected, .{ tag.fmt(), input });
                        self.advance();
                    },
                },

                .full_flush => switch (self.next_token()) {
                    .eof, .newline => self.advance(),
                    else => continue :state .full_flush
                },

                .argument_flush => switch (self.next_token()) {
                    .comma => {
                        self.advance();
                        continue :state .argument;
                    },
                    .eof, .newline => {
                        self.stack_pop();
                        self.advance();
                    },
                    else => continue :state .argument_flush
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
                    const in_root = token.tag.builtin_root();
                    const in_body = token.tag.builtin_body();

                    if (!in_root and self.stack.container_type == .root) {
                        try self.fault(error.BuiltinRootLevel, .{ self.current().fmt() });
                        continue :state .full_flush;
                    }

                    if (!in_body and
                        (self.stack.container_type == .section or
                        self.stack.container_type == .generic)
                    ) {
                        try self.fault(error.BuiltinGenericLevel, .{ self.current().fmt() });
                        continue :state .full_flush;
                    }

                    const builtin = try self.allocator.create(Node);
                    builtin.* = .{ .builtin = .{
                        .builtin_token = self.current_token(),
                        .options = NodeList.init(self.allocator),
                        .arguments = NodeList.init(self.allocator),
                        .nodes = NodeList.init(self.allocator) } };
                    var container_ = self.container();
                    try container_.append(builtin);

                    // for nodes, the argument state will pop into this container
                    if (token.tag.builtin_indented())
                        try self.stack_push(builtin, .generic);

                    // for arguments, the argument state will pop into this container
                    try self.stack_push(builtin, .argument_list);

                    // for options
                    if (self.next_token() == .l_paran) {
                        try self.stack_push(builtin, .option_list);
                        self.advance();
                    }

                    continue :state .argument;
                },

                .end_scope => switch (self.next_token()) {
                    .eof, .newline => {
                        if (self.stack.container_type == .root or self.stack.container_type == .section) {
                            try self.fault(error.ExtraEndScope, .{});
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
                        new_section.* = .{ .section = .{
                            .name = self.buffer_token(self.current_token()),
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
                        try self.fault(error.RootLevelInstruction, .{});
                        continue :state .full_flush;
                    }

                    std.debug.assert(self.stack.container_type == .section or
                        self.stack.container_type == .generic);

                    // move the label bucket into the new hoisting instruction
                    const instruction_ = try self.allocator.create(Node);
                    instruction_.* = .{ .instruction = .{
                        .labels = try self.label_bucket.toOwnedSlice(),
                        .instruction_token = self.current_token(),
                        .modifier_token = null,
                        .type_token = null,
                        .arguments = NodeList.init(self.allocator) } };
                    self.label_bucket = TokenLocationList.init(self.allocator);

                    var container_ = self.container();
                    try container_.append(instruction_);
                    try self.stack_push(instruction_, .argument_list);

                    var token = self.next_token();
                    const instruction_token = instruction_.*.instruction.instruction_token;
                    const modifier_token = &instruction_.*.instruction.modifier_token;
                    const type_token = &instruction_.*.instruction.type_token;

                    if (token == .modifier) {
                        modifier_token.* = self.current_token();
                        token = self.next_token();
                    }

                    if (instruction_token.tag == .typed_instruction and
                        (token == .pseudo_instruction or
                        token == .identifier)
                    ) {
                        type_token.* = self.current_token();
                        token = self.next_token();
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
                //  instr. ra, rb, 0x00 + 666, 666, .reference'u + 2
                //         ^   ^   ^--------^  ^-^  ^--------------^
                .argument => switch (self.current()) {
                    .identifier,
                    .option,
                    .plus,
                    .minus,
                    .reference_label,
                    .numeric_literal,
                    .string_literal,
                    .pseudo_instruction,
                    .reserved_argument => {
                        std.debug.assert(self.stack.container_type == .argument_list or
                            self.stack.container_type == .option_list);

                        const argument_ = try self.allocator.create(Node);
                        argument_.* = .{ .argument = .{
                            .tokens = TokenList.init(self.allocator) }};

                        var arguments_ = self.arguments();
                        try arguments_.append(argument_);
                        try self.stack_push(argument_, .unspecified);
                        try self.add_token(self.current_token());

                        switch (self.current()) {
                            .plus,
                            .minus => continue :state .offset_argument,
                            .reference_label => continue :state .reference_argument,
                            .identifier,
                            .numeric_literal => continue :state .numeric_argument,
                            .string_literal => continue :state .string_argument,
                            .option,
                            .pseudo_instruction,
                            .reserved_argument => {
                                self.stack_pop();
                                self.advance();
                                continue :state .argument_end;
                            },
                            else => unreachable
                        }
                    },
                    .comma => {
                        try self.fault(error.Expected, .{ "an argument", self.current().fmt() });
                        self.stack_pop();
                        continue :state .full_flush;
                    },
                    else => continue :state .argument_end
                },

                .argument_end => switch (self.current()) {
                    .comma => {
                        self.advance();
                        continue :state .argument;
                    },
                    .eof, .newline, .r_paran => {
                        defer {
                            self.stack_pop();
                            self.advance();
                        }

                        if (self.current() == .r_paran) {
                            if (self.stack.container_type != .option_list) {
                                try self.expected(.newline);
                                continue :state .full_flush;
                            }
                            // fixme: option lists always need to pop to arguments,
                            // so it has a multi-layer stack dependency
                            continue :state .argument;
                        }

                        if (self.stack.container_type != .argument_list) {
                            try self.expected(.r_paran);
                            // option lists are always followed by argument
                            // lists currently
                            self.stack_pop();
                        }
                    },
                    else => {
                        try self.fault(error.UnexpectedTag, .{ self.current().fmt() });
                        continue :state .argument_flush;
                    }
                },

                // A reference label is the usage of a defined (private) label.
                // As it's an address, an offset may be added using arithmetic
                // symbols. A reference can also can contain a modifier.
                //
                //  instr. .reference'l + 0x04
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
                        continue :state .argument_end;
                    }
                },

                // Any numeric literal, which also allows an offset using the
                // arithmetic symbols.
                .numeric_argument => switch (self.next_token()) {
                    .minus, .plus => {
                        try self.add_token(self.current_token());
                        continue :state .offset_argument;
                    },
                    else => {
                        // nothing to chain, it may be another argument
                        self.stack_pop();
                        continue :state .argument_end;
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
                        try self.fault(error.UnsupportedOffsetArgument, .{ self.current().fmt() });
                        self.stack_pop();
                        continue :state .argument_end;
                    }
                },

                // A string literal is an array of characters delimited by
                // double quotes, but it may optionally add a single 'sentinel'
                // character defined by the numeric literal at the end.
                //
                //  ascii "foo bar roo" 0x00
                //        ^----------------^
                .string_argument => switch (self.next_token()) {
                    .string_literal => {
                        try self.add_token(self.current_token());
                        continue :state .string_argument;
                    },
                    .numeric_literal => {
                        try self.add_token(self.current_token());
                        self.stack_pop();
                        self.advance();
                        continue :state .argument_end;
                    },
                    else => {
                        // nothing to chain, it may be another argument
                        self.stack_pop();
                        continue :state .argument_end;
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
        return token.location.slice(self.source.buffer);
    }

    inline fn next_token(self: *AstGen) Token.Tag {
        self.advance();
        return self.current();
    }

    fn sections(self: *AstGen) *NodeList {
        switch (self.root_node.*) {
            .section => |*section| return &section.nodes,
            else => @panic("bug: root node must be a section")
        }
    }

    fn container(self: *AstGen) *NodeList {
        switch (self.stack.node.*) {
            .section => |*section| return &section.nodes,
            .builtin => |*builtin_| return &builtin_.nodes,
            else => @panic("bug: container() expected top-of-stack to be a node container")
        }
    }

    fn arguments(self: *AstGen) *NodeList {
        switch (self.stack.node.*) {
            .instruction => |*instruction_| return &instruction_.arguments,
            .builtin => |*builtin_| return if (self.stack.container_type == .option_list)
                &builtin_.options else
                &builtin_.arguments,
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

    if (options.dump) {
        try ast.dump(stderr);
        for (ast.errors) |error_|
            try error_.write("test.s", input, stderr);
    }

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
    try testAstGenErr("/", &.{ error.UnexpectedEof });
}

test "protect section ids" {
    try testAstGenErr("@section", &.{ error.Expected });
    try testAstGenErr("@section foo", &.{});
    try testAstGenErr("@section foo bar", &.{ error.Expected });
}

test "forbid instructions at top level" {
    try testAstGenErr("ast", &.{ error.RootLevelInstruction });
    try testAstGenErr("@section foo\nast", &.{});
    try testAstGenErr("@header foo\nast\n@end", &.{});
}

test "error line number" {
    try testAstGenErrLine(
        \\
        \\
        \\ast
    , &.{
        .{ error.RootLevelInstruction, 3 }
    });

    try testAstGenErrLine(
        \\
        \\@section test
        \\            ast ra, ; trailing commas allowed
        \\            ast ra,, ; double commas not allowed
        \\            ast, ; commas after instruction not allowed
        \\            ast 5 +, ; commas after expected arguments not allowed
    , &.{
        .{ error.Expected, 4 },
        .{ error.Expected, 5 },
        .{ error.UnsupportedOffsetArgument, 6 }
    });

    try testAstGenErrLine(
        \\
        \\@section test
        \\            ast .foo:
        \\            ast .foo
        \\            ast 5 foo 5 ; emits unsupported argument instead of unexpected token
        \\            ast 5, .foo:, 5
    , &.{
        .{ error.UnexpectedTag, 3 },
        .{ error.UnexpectedTag, 5 },
        .{ error.UnexpectedTag, 6 }
    });

    try testAstGenErrLine(
        \\
        \\ascii "foo"
        \\
        \\@define(foo
        \\@define foo)
        \\
        \\@section
        \\@section test
        \\
        \\            ast 0xZZ ; hmmmm
        \\
        \\            0x00
        \\            ra
    , &.{
        .{ error.RootLevelInstruction, 2 },
        .{ error.Expected, 4 },
        .{ error.Expected, 5 },
        .{ error.Expected, 7 },
        .{ error.UnexpectedTag, 10 },
        .{ error.Unexpected, 12 },
        .{ error.Unexpected, 13 }
    });
}

test "full fledge" {
    try testAstGen(
        \\
        \\@symbols "awd/space @symbols test.s"
        \\@define foo, bar
        \\@define(expose) aaa
        \\@define(.reference) bbb
        \\
        \\@header(expose) ma, dude
        \\            ascii "foo" 0x00
        \\@end
        \\
        \\@section bar
        \\
        \\            u8 -1
        \\            u16 .label - .foo
        \\      @align 16
        \\      @region awesome_enabled
        \\            reserve u8 test
        \\      @end
        \\
        \\.another:
        \\.label:     ast ra, rb
        \\foo:        ast +5
        \\
        \\@section bar
        \\
        \\            ast 0x00 + 0x00, 0x00
        \\.aaaaaa:    ast' memory
        \\            ast 1 + .foo'u
        \\            ast .foo'u + 1, .bar
        \\            @callable -0x01 - 0x001
    );

    try testAstGen(
        \\
        \\@header Queue, type, len
        \\            @align 16
        \\            reserve type len
        \\@end
        \\
        \\@section globals
        \\
        \\.myqueue:   @Queue u16, 24 ; custom type
        \\
        \\@define awd, 5
        \\.newqueue:  @Queue u16, @awd
        \\
        \\@section text
        \\
        \\main:       ast thisistheonlyinstructioncurrentlylol
        \\            ast .myqueue + 4
    );
}
