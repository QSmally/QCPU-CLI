
const std = @import("std");
const Token = @import("Token.zig");
const AsmTokeniser = @import("AsmTokeniser.zig");

const AsmAst = @This();

const Source = struct {

    allocator: std.mem.Allocator,
    buffer: [:0]const u8,
    tokens: []const Token,

    pub fn init(allocator: std.mem.Allocator, tokeniser: *AsmTokeniser) !Source {
        var tokens = std.ArrayList(Token).init(allocator);

        while (true) {
            const token = tokeniser.next();
            try tokens.append(token);
            if (token.tag == .eof)
                break;
        }

        return .{
            .allocator = allocator,
            .buffer = tokeniser.buffer,
            .tokens = try tokens.toOwnedSlice() };
    }

    pub fn deinit(self: Source) void {
        self.allocator.free(self.tokens);
    }
};

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

    pub const Container = struct {
        section: []const u8,
        // alignment: u32 = 1,
        // max_size: ?u32 = null,
        nodes: NodeList
    };

    pub const Instruction = struct {
        labels: []const TokenLocation,
        instruction_token: Token,
        is_alternate: bool,
        arguments: NodeList // Node.expression
    };

    const Argument = struct {
        tokens: TokenList
    };

    // @section .. @section
    // @align .. @end
    // @if .. @end
    container: Container,

    // (pseudo)instructions
    instruction: Instruction,

    // Arguments can only appear in an instruction's argument list, but it's
    // still represented as a Node due to the stack.
    //  instr. 0x00 + 666 666 .reference'u + 2
    //         ^--------^ ^-^ ^--------------^
    argument: Argument//,

    // @identifier(arg, arg, arg)
    // header: Header
};

const Error = struct {
    message: []const u8,
    line: u32
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
            _ = ais.write("\n") catch {};
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

            for (instruction.arguments.items) |argument| {
                _ = try ais.write(", ");
                switch (argument.*) {
                    .argument => |argument_| {
                        for (argument_.tokens.items) |token| {
                            _ = try ais.write(token.slice(self.buffer));
                        }
                    },
                    else => unreachable
                }
            }
        },
        else => {}
    }
}

const AstGen = struct {

    const LinkedNodeList = struct {
        previous: ?*LinkedNodeList,
        node: *Node
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
    first_error: bool = false,

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
            .node = root_node };
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

    const State = enum {
        start,
        flush,
        expect_flush,
        expect_full_flush,
        unexpected_token,
        top_level_builtin,
        scoped_builtin,
        new_section,
        instruction,
        argument,
        reference_argument,
        numeric_argument,
        offset_argument
    };

    pub fn parse(self: *AstGen) !void {
        parse_loop: while (self.cursor < self.source.tokens.len) {
            state: switch (State.start) {
                .start => switch (self.current()) {
                    .unexpected_eof => {
                        try self.fault("unexpected eof", .{});
                        break :parse_loop;
                    },

                    .eof, .newline, .comma => self.advance(),

                    .private_label, .label => {
                        const token_location = TokenLocation.from_token(self.current_token());
                        try self.label_bucket.append(token_location);
                        self.advance();
                    },

                    .builtin_symbols,
                    .builtin_define => continue :state .top_level_builtin,
                    .builtin_align,
                    .builtin_if,
                    .builtin_end => continue :state .scoped_builtin,
                    .builtin_section => continue :state .new_section,

                    .instruction,
                    .pseudo_instruction => continue :state .instruction,

                    else => continue :state .unexpected_token
                },

                .flush => switch (self.next_token()) {
                    .eof, .newline, .comma => self.advance(),
                    else => continue :state .flush
                },

                .expect_flush => switch (self.next_token()) {
                    .eof, .newline, .comma => self.advance(),
                    else => try self.expected(.newline)
                },

                .expect_full_flush => switch (self.next_token()) {
                    .eof, .newline => self.advance(),
                    else => try self.expected(.newline)
                },

                .unexpected_token => {
                    const tag = @tagName(self.current());
                    const input = self.buffer_token(self.current_token());
                    try self.fault("unexpectedly got {s} '{s}'", .{ tag, input });
                    self.advance();
                },

                // A top-level builtin.
                // @define
                // @symbols
                .top_level_builtin => {
                    @panic("not implemented");
                },

                // A builtin which can only be used in level one.
                // @section -> @anybuiltin
                // A builtin which can only be used in level one or two.
                // @define -> end
                // @if -> end (doesn't pass)
                // @section -> @define -> end
                .scoped_builtin => {
                    @panic("not implemented");
                },

                // A section is a top-level memory area container.
                // Additionally, @defines, @symbols and other simple builtins
                // can only be put in the top-level.
                .new_section => switch (self.next_token()) {
                    .identifier => {
                        const stack_size_ = self.stack_size();
                        // validated in other state that no 'new_section' is passed?
                        std.debug.assert(stack_size_ <= 1);

                        const new_section = try self.allocator.create(Node);
                        new_section.* = .{ .container = .{
                            .section = self.buffer_token(self.current_token()),
                            .nodes = NodeList.init(self.allocator) } };
                        var sections_ = self.sections();
                        try sections_.append(new_section);

                        // fixme: verify that last stack frame is a section
                        if (stack_size_ == 1)
                            self.stack_pop(); // pop current section
                        try self.stack_push(new_section);
                        continue :state .expect_full_flush;
                    },
                    else => try self.expected(.identifier)
                },

                // Any instruction.
                .instruction => {
                    if (self.stack_size() == 0) {
                        try self.fault("instructions cannot be defined at the top level", .{});
                        continue :state .flush;
                    }

                    // move the label bucket into the new hoisting instruction
                    const instruction_ = try self.allocator.create(Node);
                    instruction_.* = .{ .instruction = .{
                        .labels = try self.label_bucket.toOwnedSlice(),
                        .instruction_token = self.current_token(),
                        .is_alternate = false,
                        .arguments = NodeList.init(self.allocator) } };
                    self.label_bucket = TokenLocationList.init(self.allocator);

                    var container_ = self.container();
                    try container_.nodes.append(instruction_);
                    try self.stack_push(instruction_);

                    if (self.next_token() == .modifier) {
                        var hoisting = self.instruction();
                        hoisting.is_alternate = true;
                        self.advance();
                    }

                    continue :state .argument;
                },

                // From an instruction or argument loopback, must have the
                // cursor already on the argument. The top-of-stack must be
                // populated with the instruction.
                // fixme: this depends on instruction being top-of-stack, but
                // it might be used for comma-separated @headercalls()
                .argument => switch (self.current()) {
                    .identifier,
                    .plus,
                    .minus,
                    .reference_label,
                    .numeric_literal,
                    .string_literal,
                    .pseudo_instruction => {
                        const argument_ = try self.allocator.create(Node);
                        argument_.* = .{ .argument = .{
                            .tokens = TokenList.init(self.allocator) }};

                        var instruction_ = self.instruction();
                        try instruction_.arguments.append(argument_);
                        try self.stack_push(argument_);
                        try self.add_token(self.current_token());

                        switch (self.current()) {
                            .plus,
                            .minus => continue :state .offset_argument,
                            .reference_label => continue :state .reference_argument,
                            .identifier,
                            .numeric_literal => continue :state .numeric_argument,
                            .string_literal,
                            .pseudo_instruction => {
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
                        self.stack_pop();
                        try self.fault("unsupported argument {s}", .{ @tagName(self.current()) });
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
                        try self.fault("invalid offset argument {s}", .{ @tagName(self.current()) });
                        self.stack_pop();
                        continue :state .argument;
                    }
                }
            }
        }

        // either top-level or sectioned container
        // fixme: report missing @end for top-level @defines, but that's in the
        // state machine
        std.debug.assert(self.stack_size() <= 1);
    }

    inline fn current(self: *AstGen) Token.Tag {
        return self.source.tokens[self.cursor].tag;
    }

    inline fn current_token(self: *AstGen) Token {
        return self.source.tokens[self.cursor];
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

    inline fn is_top_level(self: *AstGen) bool {
        return self.stack.previous == null;
    }

    fn sections(self: *AstGen) *NodeList {
        switch (self.root_node.*) {
            .container => |*container_| return &container_.nodes,
            else => @panic("bug: root node must be a container")
        }
    }

    fn container(self: *AstGen) *Node.Container {
        // maybe nicer to do this in a 'generic' way but that's not really
        // necessary to be fair
        switch (self.stack.node.*) {
            .container => |*container_| return container_,
            else => @panic("bug: container() expected top-of-stack to be a node container")
        }
    }

    fn instruction(self: *AstGen) *Node.Instruction {
        switch (self.stack.node.*) {
            .instruction => |*instruction_| return instruction_,
            else => @panic("bug: instruction() expected top-of-stack to be an instruction")
        }
    }

    fn add_token(self: *AstGen, token: Token) !void {
        switch (self.stack.node.*) {
            .argument => |*argument| try argument.tokens.append(token),
            else => @panic("bug: add_token() unsupported top-of-stack type")
        }
    }

    fn stack_push(self: *AstGen, section: *Node) !void {
        const new_frame = try self.allocator.create(LinkedNodeList);
        new_frame.* = .{
            .previous = self.stack,
            .node = section };
        self.stack = new_frame;
    }

    fn stack_pop(self: *AstGen) void {
        const popper = self.stack.previous;
        std.debug.assert(popper != null);
        self.allocator.destroy(self.stack);
        self.stack = popper.?;
    }

    fn stack_size(self: *AstGen) usize {
        var size: usize = 0;
        var stack_iterator = self.stack.previous;

        while (stack_iterator) |stack_frame_| {
            stack_iterator = stack_frame_.previous;
            size += 1;
        }

        return size;
    }

    fn expected(self: *AstGen, tag: Token.Tag) !void {
        @branchHint(.cold);
        try self.fault("expected {s}, found {s}", .{
            @tagName(tag),
            @tagName(self.current()) });
    }

    fn fault(self: *AstGen, comptime message: []const u8, arguments: anytype) !void {
        @branchHint(.cold);
        const format = try std.fmt.allocPrint(self.allocator, message, arguments);
        try self.errors.append(.{
            .message = format,
            // fixme: cursor to line
            .line = 0 });
        if (self.first_error)
            return error.Abort;
    }
};

// Tests

fn testAstGen(input: [:0]const u8) !void {
    var tokeniser = AsmTokeniser.init(input);
    const source = try Source.init(std.testing.allocator, &tokeniser);
    defer source.deinit();

    var ast = try AsmAst.init(std.testing.allocator, source);
    defer ast.deinit();

    // begin dump
    std.debug.print("\n", .{});
    for (source.tokens) |token|
        std.debug.print("{s}\n", .{ @tagName(token.tag) });
    try ast.dump(std.io.getStdOut().writer());
    // end dump

    for (ast.errors) |error_|
        std.debug.print("{s}\n", .{ error_.message });
    try std.testing.expect(ast.errors.len == 0);
}

test "sections" {
    try testAstGen(
        \\@section bar
        \\
        \\            ascii "foo" 0x00
        \\            u8 -1
        \\            u16 .label - .foo
        \\            reserve u8 test
        \\
        \\.another:
        \\.label:     ast
        \\foo:        ast
        \\
        \\@section bar
        \\
        \\            ast 0x00 + 0x00 0x00
        \\.aaaaaa:    ast' memory
        \\            ast 1 + .foo'u
        \\            ast .foo'u + 1 .bar
    );
}
