
const Token = @import("Token.zig");

const AsmTokeniser = @This();

const Helper = struct {

    tokeniser: *AsmTokeniser,
    token: *Token,

    pub fn init(tokeniser_: *AsmTokeniser, token_: *Token) Helper {
        return .{
            .tokeniser = tokeniser_,
            .token = token_ };
    }

    pub inline fn current(self: *Helper) u8 {
        return self.tokeniser.buffer[self.tokeniser.cursor];
    }

    pub inline fn next(self: *Helper) u8 {
        self.tokeniser.cursor += 1;
        return self.current();
    }

    pub inline fn tag(self: *Helper, tag_: Token.Tag) void {
        self.token.tag = tag_;
        self.token.end_byte = self.tokeniser.cursor;
    }

    pub inline fn tag_lookahead(self: *Helper, tag_: Token.Tag) void {
        self.token.tag = tag_;
        self.token.end_byte = self.tokeniser.cursor - 1;
    }

    pub inline fn tag_next(self: *Helper, tag_: Token.Tag) void {
        self.tag(tag_);
        self.tokeniser.cursor += 1;
    }

    pub inline fn discard(self: *Helper) void {
        self.tokeniser.cursor += 1;
        self.token.start_byte = self.tokeniser.cursor;
    }
};

buffer: [:0]const u8,
cursor: usize = 0,

pub fn init(buffer_: [:0]const u8) AsmTokeniser {
    return .{ .buffer = buffer_ };
}

fn is_eof(self: *AsmTokeniser) bool {
    return self.cursor == self.buffer.len;
}

const State = enum {
    start,
    invalid,
    identifier,
    label,
    slash,
    comment,
    numeric_literal,
    string_literal,
    modifier
};

pub fn next(self: *AsmTokeniser) Token {
    var result: Token = .{
        .tag = undefined,
        .start_byte = self.cursor,
        .end_byte = undefined };
    var helper = Helper.init(self, &result);

    state: switch (State.start) {
        .start => switch (helper.current()) {
            0 => if (self.is_eof())
                helper.tag(.eof) else
                helper.tag_next(.unexpected_eof),

            ' ', '\t', '\r' => {
                helper.discard();
                continue :state .start;
            },

            // single character tags
            '\n' => helper.tag_next(.newline),
            '(' => helper.tag_next(.l_paran),
            ')' => helper.tag_next(.r_paran),
            ',' => helper.tag_next(.comma),
            '+' => helper.tag_next(.plus),
            '-' => helper.tag_next(.minus),

            // beginning of tags
            'a'...'z', 'A'...'Z', '_', '@' => continue :state .identifier,
            '.' => continue :state .label,
            '/' => continue :state .slash,
            ';' => continue :state .comment,
            '0'...'9' => continue :state .numeric_literal,
            '"' => continue :state .string_literal,
            '\'' => continue :state .modifier,

            else => continue :state .invalid
        },

        // Mark current token as invalid until a barrier character, after which
        // the tokeniser can continue (either providing as many errors to the
        // user, or abort the process).
        .invalid => switch (helper.next()) {
            0, '\n', ',', ' ' => helper.tag_lookahead(.invalid),
            else => continue :state .invalid
        },

        // Tags any token starting with a-zA-Z_ and continuing with a-zA-Z0-9_
        // as identifier, or if found, a (pseudo)instruction or builtin.
        .identifier => switch (helper.next()) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '.'  => continue :state .identifier,
            ':' => helper.tag_next(.label),
            else => {
                const identifier_ = self.buffer[result.start_byte..self.cursor];
                helper.tag_lookahead(if (Token.reserved(identifier_)) |reserved|
                    reserved else
                    .identifier);
            }
        },

        // A private label is started with a period, but public labels are
        // identifiers until a colon. An address reference 
        .label => switch (helper.next()) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '.' => continue :state .label,
            ':' => helper.tag_next(.private_label),
            0, '\n', ' ', '\'' => helper.tag_lookahead(.reference_label),
            else => continue :state .invalid
        },

        // A slash is the beginning of a comment, which extends to the end of
        // the line.
        .slash => switch (helper.next()) {
            0 => helper.tag(.unexpected_eof),
            '/' => continue :state .comment,
            else => continue :state .invalid
        },

        .comment => switch (helper.next()) {
            0 => continue :state .start,
            // newline tokens have a start-byte at the comment, which doesn't
            // really matter as they're not used anyway
            // tag:newline-comment
            '\n' => helper.tag_next(.newline),
            else => continue :state .comment
        },

        // Any; decimal, hexadecimal. Further validation of the numeric literal
        // is done at a later stage based on prefixing (like 0x and 0b).
        .numeric_literal => switch (helper.next()) {
            '0'...'9', 'A'...'F', 'x', 'b' => continue :state .numeric_literal,
            0, '\n', ' ', ',' => helper.tag_lookahead(.numeric_literal),
            else => continue :state .invalid
        },

        // A string literal is just a range of characters. There's no null byte
        // added automatically, which must be added by the programmer:
        //  ascii 'foo bar' 0
        //  ascii 'foo bar' 0x00
        .string_literal => switch (helper.next()) {
            '"' => helper.tag_next(.string_literal),
            0 => helper.tag(.unexpected_eof),
            '\n' => continue :state .invalid,
            else => continue :state .string_literal
        },

        // An address modifier a ' character with an identifier, like 'u. How
        // something is interpreted depends on the type context in relation to
        // the parent's content. For example, a u16 interpreting a .reference
        // will fit just fine, but a u8 interpreting a .reference will need an
        // explicit modifier.
        .modifier => switch (helper.next()) {
            'a'...'z' => continue :state .modifier,
            0, '\n', ' ', ',' => helper.tag_lookahead(.modifier),
            else => continue :state .invalid
        }
    }

    return result;
}

// Tests

const std = @import("std");

fn testTokenise(input: [:0]const u8, expected_tokens: []const Token.Tag) !void {
    var tokeniser = AsmTokeniser.init(input);
    for (expected_tokens) |expected_token|
        try std.testing.expectEqual(expected_token, tokeniser.next().tag);
}

const SlicedToken = struct { Token.Tag, []const u8 };

fn testTokeniseSlices(input: [:0]const u8, expected_slices: []const SlicedToken) !void {
    var tokeniser = AsmTokeniser.init(input);
    for (expected_slices) |expected_slice| {
        const token = tokeniser.next();
        try std.testing.expectEqual(expected_slice[0], token.tag);

        // see tag:newline-comment
        if (token.tag != .newline)
            try std.testing.expectEqualSlices(u8, expected_slice[1], token.slice(input));
    }
}

test "eof" {
    try testTokenise("", &.{ .eof });
    try testTokenise("   ", &.{ .eof });
    try testTokenise("%", &.{ .invalid, .eof });
    try testTokenise("\x00", &.{ .unexpected_eof, .eof });
    try testTokenise("", &.{ .eof, .eof, .eof, .eof });
}

test "identifiers" {
    try testTokenise("x", &.{ .identifier, .eof });
    try testTokenise("  x", &.{ .identifier, .eof });
    try testTokenise("ascii", &.{ .pseudo_instruction, .eof });
    try testTokenise("ast, ascii", &.{ .instruction, .comma, .pseudo_instruction, .eof });

    try testTokenise("@symbols", &.{ .builtin_symbols, .eof });
    try testTokenise("@section", &.{ .builtin_section, .eof });
    try testTokenise("@section foo", &.{ .builtin_section, .identifier, .eof });
    try testTokenise("@symbols*", &.{ .builtin_symbols, .invalid, .eof });
    try testTokenise("@nevergonnagiveyouup", &.{ .identifier, .eof });

    // validated at a later stage
    try testTokenise("@", &.{ .identifier, .eof });
}

test "labels" {
    try testTokenise("public_label", &.{ .identifier, .eof });
    try testTokenise("public_label:", &.{ .label, .eof });
    try testTokenise(".public_label:", &.{ .private_label, .eof });
    try testTokenise(".public_label: ast", &.{ .private_label, .instruction, .eof });
    try testTokenise(".reference_label", &.{ .reference_label, .eof });
    try testTokenise("bar .reference_label // foo", &.{ .identifier, .reference_label, .eof });
    try testTokenise(".bar.reference_label", &.{ .reference_label, .eof });

    // check whether used, this is for categorised references
    try testTokenise("bar.kinky_identifier", &.{ .identifier, .eof });

    // validated at a later stage
    try testTokenise("@weird_label:", &.{ .label, .eof });
}

test "comments" {
    try testTokenise("/", &.{ .unexpected_eof, .eof });
    try testTokenise("/\n", &.{ .invalid, .eof });
    try testTokenise("/ ", &.{ .invalid, .eof });
    try testTokenise("/f", &.{ .invalid, .eof });
    try testTokenise("//", &.{ .eof });
    try testTokenise("////", &.{ .eof });
    try testTokenise("// foo bar", &.{ .eof });
    try testTokenise("foo // bar doo", &.{ .identifier, .eof });
    try testTokenise("foo, // bar doo", &.{ .identifier, .comma, .eof });
    try testTokenise(
        \\foo, // roo doo
        \\bar,
    , &.{ .identifier, .comma, .newline, .identifier, .comma, .eof });
}

test "numeric literals" {
    try testTokenise("6", &.{ .numeric_literal, .eof });
    try testTokenise("666", &.{ .numeric_literal, .eof });
    try testTokenise("0xFF", &.{ .numeric_literal, .eof });
    try testTokenise("0b10101111", &.{ .numeric_literal, .eof });
    try testTokenise("x0FF", &.{ .identifier, .eof });
    try testTokenise("0xZZ", &.{ .invalid, .eof });

    // enforce uppercase
    try testTokenise("0xaa", &.{ .invalid, .eof });

    // validated at a later stage
    try testTokenise("0x", &.{ .numeric_literal, .eof });
    try testTokenise("0xxx", &.{ .numeric_literal, .eof });
    try testTokenise("5xbx", &.{ .numeric_literal, .eof });
}

test "string literals" {
    try testTokenise(" \" foo bar \" ", &.{ .string_literal, .eof });
    try testTokenise("\" foo bar \" 0x00 ", &.{ .string_literal, .numeric_literal, .eof });
    try testTokenise("\" foo bar ", &.{ .unexpected_eof, .eof });
    try testTokenise("\" foo bar \n", &.{ .invalid, .eof });
    try testTokenise("\" foo bar '", &.{ .unexpected_eof, .eof });
}

test "modifiers" {
    try testTokenise("'u", &.{ .modifier, .eof });
    try testTokenise("'u   ", &.{ .modifier, .eof });
    try testTokenise("'upper", &.{ .modifier, .eof });
    try testTokenise("'u foo", &.{ .modifier, .identifier, .eof });
    try testTokenise("foo'u foo", &.{ .identifier, .modifier, .identifier, .eof });
    try testTokenise(".foo'u foo", &.{ .reference_label, .modifier, .identifier, .eof });

    // validated at a later stage
    try testTokenise("'", &.{ .modifier, .eof });
    try testTokenise("' foo", &.{ .modifier, .identifier, .eof });
}

test "full fledge" {
    try testTokeniseSlices(
        \\
        \\@symbols not_implemented_yet
        \\
        \\ascii "foo bar roo" 0x00 // comment
        \\
        \\.label:     ast ; comment foo(bar)
        \\            ast @callable(a, b)
        \\label:      ast .ref
        \\0xZZ        ast
    , &.{
        .{ .newline, "" },
        .{ .builtin_symbols, "@symbols" },
        .{ .identifier, "not_implemented_yet" },
        .{ .newline, "" },
        .{ .newline, "" },
        .{ .pseudo_instruction, "ascii" },
        .{ .string_literal, "\"foo bar roo\"" },
        .{ .numeric_literal, "0x00" },
        .{ .newline, "" },
        .{ .newline, "" },
        .{ .private_label, ".label:" },
        .{ .instruction, "ast" },
        .{ .newline, "" },
        .{ .instruction, "ast" },
        .{ .identifier, "@callable" },
        .{ .l_paran, "(" },
        .{ .identifier, "a" },
        .{ .comma, "," },
        .{ .identifier, "b" },
        .{ .r_paran, ")" },
        .{ .newline, "" },
        .{ .label, "label:" },
        .{ .instruction, "ast" },
        .{ .reference_label, ".ref" },
        .{ .newline, "" },
        .{ .invalid, "0xZZ" },
        .{ .instruction, "ast" },
        .{ .eof, "\x00" }
    });
}
