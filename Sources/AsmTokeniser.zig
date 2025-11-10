
// Tokeniser

const AsmTokeniser = @This();

buffer: [:0]const u8,
cursor: usize = 0,

pub fn init(buffer: [:0]const u8) AsmTokeniser {
    return .{ .buffer = buffer };
}

pub const Token = @import("Token.zig");

pub fn is_eof(self: *AsmTokeniser) bool {
    return self.cursor == self.buffer.len;
}

const State = enum {
    start,
    invalid,
    identifier,
    label,
    left_shift,
    right_shift,
    slash,
    comment,
    numeric_literal,
    string_literal,
    apostrophe
};

pub fn next(self: *AsmTokeniser) Token {
    var result = Token {
        .tag = undefined,
        .location = .{
            .start = self.cursor,
            .end = undefined } };
    var helper = Helper.init(self, &result);

    state: switch (State.start) {
        .start => switch (helper.current()) {
            0 => if (self.is_eof())
                helper.tag(.eof) else
                helper.tag_next(.invalid),

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
            '!' => helper.tag_next(.bang),
            '*' => helper.tag_next(.asterisk),
            '|' => helper.tag_next(.pipe),
            '&' => helper.tag_next(.ampersand),
            '$' => helper.tag_next(.dollar),

            // beginning of tags
            'a'...'z', 'A'...'Z', '_', '@' => continue :state .identifier,
            '.' => continue :state .label,
            '<' => continue :state .left_shift,
            '>' => continue :state .right_shift,
            '/' => continue :state .slash,
            ';' => continue :state .comment,
            '0'...'9' => continue :state .numeric_literal,
            '"' => continue :state .string_literal,
            '\'' => continue :state .apostrophe,

            else => continue :state .invalid
        },

        // Mark current token as invalid until a boundary character, after
        // which the tokeniser can continue (either providing as many errors to
        // the user, or abort the process).
        .invalid => switch (helper.current()) {
            0, '\n', '\t', '\r' => helper.tag(.invalid),
            else => if (helper.is_next_boundary())
                helper.tag_previous(.invalid) else
                continue :state .invalid
        },

        // Tags any token starting with a-zA-Z_ and continuing with a-zA-Z0-9_
        // as identifier, or if found, a (pseudo)instruction or builtin.
        .identifier => switch (helper.next()) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => continue :state .identifier,
            '.' => switch (helper.peek()) {
                'a'...'z', 'A'...'Z', '_' => continue :state .identifier,
                else => continue :state .invalid
            },
            ':' => helper.tag_next(.label),
            else => {
                const identifier = self.buffer[result.location.start..self.cursor];
                helper.tag_previous(if (Token.keyword(identifier)) |keyword|
                    keyword else
                    .identifier);
            }
        },

        // A private label starts with a period and ends with a colon, whilst
        // references end with a boundary character. Public labels start as
        // identifiers.
        .label => switch (helper.next()) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '.' => continue :state .label,
            ':' => helper.tag_next(.private_label),
            else => if (helper.is_boundary())
                helper.tag_previous(.reference_label) else
                continue :state .invalid
        },

        // A left shfit (<<) operator.
        .left_shift => switch (helper.next()) {
            '<' => helper.tag_next(.lsh),
            else => continue :state .invalid
        },

        // A right shift (>>) operator.
        .right_shift => switch (helper.next()) {
            '>' => helper.tag_next(.rsh),
            else => continue :state .invalid
        },

        // A type of comment starts with two forward slashes.
        .slash => switch (helper.next()) {
            '/' => continue :state .comment,
            else => continue :state .invalid
        },

        .comment => switch (helper.next()) {
            0 => continue :state .start,
            '\n' => helper.tag_next(.newline),
            else => continue :state .comment
        },

        // Any decimal, hexadecimal or octal numeric literal. Further
        // validation is done during semantic analysis.
        .numeric_literal => switch (helper.next()) {
            '0'...'9', 'A'...'F', 'x', 'b' => continue :state .numeric_literal,
            else => if (helper.is_boundary())
                helper.tag_previous(.numeric_literal) else
                continue :state .invalid
        },

        // A string literal is just a range of characters until the second
        // double quotes delimiter.
        .string_literal => switch (helper.next()) {
            '"' => helper.tag_next(.string_literal),
            0, '\n' => continue :state .invalid,
            else => continue :state .string_literal
        },

        // An apostrophe can mean a character literal ('a') or a modifier ('u),
        // which is mainly used in address masking.
        .apostrophe => switch (helper.next()) {
            // TODO: support \ escape notation
            ' '...'[', ']'...'`', '{'...'~' => switch (helper.next()) {
                '\'' => helper.tag_next(.char_literal),
                else => continue :state .invalid
            },
            'a'...'z' => switch (helper.next()) {
                '\'' => helper.tag_next(.char_literal),
                else => if (helper.is_boundary())
                    helper.tag_previous(.modifier) else
                    continue :state .invalid
            },
            else => continue :state .invalid
        }
    }

    return result;
}

const Helper = struct {

    tokeniser: *AsmTokeniser,
    token: *Token,

    pub fn init(tokeniser: *AsmTokeniser, token: *Token) Helper {
        return .{
            .tokeniser = tokeniser,
            .token = token };
    }

    pub inline fn is_boundary(self: *Helper) bool {
        return switch (self.current()) {
            0, '\n', '\t', '\r', ' ',
            ',', '(', ')',
            '+', '-', '!', '*', '|', '&', '$', '<', '>',
            '\'' => true,

            else => false
        };
    }

    pub inline fn is_next_boundary(self: *Helper) bool {
        self.tokeniser.cursor += 1;
        return self.is_boundary();
    }

    pub inline fn current(self: *Helper) u8 {
        return self.tokeniser.buffer[self.tokeniser.cursor];
    }

    pub inline fn peek(self: *Helper) u8 {
        return self.tokeniser.buffer[self.tokeniser.cursor + 1];
    }

    pub inline fn next(self: *Helper) u8 {
        self.tokeniser.cursor += 1;
        return self.current();
    }

    pub inline fn tag(self: *Helper, tagged: Token.Tag) void {
        self.token.tag = tagged;
        self.token.location.end = self.tokeniser.cursor + 1;
    }

    pub inline fn tag_previous(self: *Helper, tagged: Token.Tag) void {
        self.token.tag = tagged;
        self.token.location.end = self.tokeniser.cursor;
    }

    pub inline fn tag_next(self: *Helper, tagged: Token.Tag) void {
        self.tag(tagged);
        self.tokeniser.cursor += 1;
    }

    pub inline fn discard(self: *Helper) void {
        self.tokeniser.cursor += 1;
        self.token.location.start = self.tokeniser.cursor;
    }
};

// Tests

const std = @import("std");
const options = @import("options");

const stderr = std.io.getStdErr().writer();

fn testTokenise(input: [:0]const u8, expected_tokens: []const Token.Tag) !void {
    var tokeniser = AsmTokeniser.init(input);
    for (expected_tokens) |expected_token|
        try std.testing.expectEqual(expected_token, tokeniser.next().tag);
}

const SlicedToken = struct { Token.Tag, []const u8 };

fn testTokeniseSlices(input: [:0]const u8, expected_slices: []const SlicedToken) !void {
    var tokeniser = AsmTokeniser.init(input);

    for (expected_slices, 0..) |expected_slice, idx| {
        const token = tokeniser.next();

        if (options.dump) {
            const slice = if (token.tag != .newline)
                token.location.slice(input) else
                "\\n";
            try stderr.print("{}: {s}={s}\n", .{
                idx,
                @tagName(token.tag),
                slice });
        }

        try std.testing.expectEqual(expected_slice[0], token.tag);

        if (token.tag != .newline) {
            try std.testing.expectEqualSlices(u8, expected_slice[1], token.location.slice(input));
        }
    }
}

test "eof" {
    try testTokenise("", &.{ .eof });
    try testTokenise("   ", &.{ .eof });
    try testTokenise("\n", &.{ .newline, .eof });
    try testTokenise("\x00", &.{ .invalid, .eof });
    try testTokenise("", &.{ .eof, .eof, .eof, .eof });
}

test "identifiers" {
    try testTokenise("x", &.{ .identifier, .eof });
    try testTokenise("x.", &.{ .invalid, .eof });
    try testTokenise("x.y", &.{ .identifier, .eof });
    try testTokenise("x. y", &.{ .invalid, .identifier, .eof });
    try testTokenise("x,y", &.{ .identifier, .comma, .identifier, .eof });
    try testTokenise("x, y", &.{ .identifier, .comma, .identifier, .eof });
    try testTokenise("  x", &.{ .identifier, .eof });
    try testTokenise("ascii", &.{ .instruction, .eof });
    try testTokenise("lui, ascii", &.{ .instruction, .comma, .instruction, .eof });

    try testTokenise("@import", &.{ .builtin_import, .eof });
    try testTokenise("@define(expose) boob", &.{ .builtin_define, .l_paran, .identifier, .r_paran, .identifier, .eof });
    try testTokenise("@define(0x00) boob", &.{ .builtin_define, .l_paran, .numeric_literal, .r_paran, .identifier, .eof });
    try testTokenise("@define(.reference) boob", &.{ .builtin_define, .l_paran, .reference_label, .r_paran, .identifier, .eof });
    try testTokenise("@define(.label:) boob", &.{ .builtin_define, .l_paran, .private_label, .r_paran, .identifier, .eof });
    try testTokenise("@section", &.{ .builtin_section, .eof });
    try testTokenise("@section foo", &.{ .builtin_section, .identifier, .eof });
    try testTokenise("@import&", &.{ .builtin_import, .ampersand, .eof });
    try testTokenise("@nevergonnagiveyouup", &.{ .identifier, .eof });

    // validated at a later stage
    try testTokenise("@", &.{ .identifier, .eof });
}

test "labels" {
    try testTokenise("public_label", &.{ .identifier, .eof });
    try testTokenise("public_label:", &.{ .label, .eof });
    try testTokenise("public_label:,", &.{ .label, .comma, .eof });
    try testTokenise("public_label,:", &.{ .identifier, .comma, .invalid, .eof });
    try testTokenise(".public_label:", &.{ .private_label, .eof });
    try testTokenise(".public_label: lui", &.{ .private_label, .instruction, .eof });
    try testTokenise(".reference_label", &.{ .reference_label, .eof });
    try testTokenise("bar .reference_label // foo", &.{ .identifier, .reference_label, .eof });
    try testTokenise(".bar.reference_label", &.{ .reference_label, .eof });

    // validated at a later stage
    try testTokenise("@weird_label:", &.{ .label, .eof });
}

test "comments" {
    try testTokenise("/", &.{ .invalid, .eof });
    try testTokenise("/\n", &.{ .invalid, .newline, .eof });
    try testTokenise("/ ", &.{ .invalid, .eof });
    try testTokenise("/f", &.{ .invalid, .eof });
    try testTokenise("//", &.{ .eof });
    try testTokenise(";", &.{ .eof });
    try testTokenise("////", &.{ .eof });
    try testTokenise("// foo bar", &.{ .eof });
    try testTokenise("; foo bar", &.{ .eof });
    try testTokenise("foo // bar doo", &.{ .identifier, .eof });
    try testTokenise("foo, // bar doo", &.{ .identifier, .comma, .eof });
    try testTokenise("foo, // roo doo\nbar,", &.{ .identifier, .comma, .newline, .identifier, .comma, .eof });
    try testTokenise("foo ; bar doo", &.{ .identifier, .eof });
    try testTokenise("foo; bar doo", &.{ .identifier, .eof });
    try testTokenise("foo, ; bar doo", &.{ .identifier, .comma, .eof });
    try testTokenise("foo, ; roo doo\nbar,", &.{ .identifier, .comma, .newline, .identifier, .comma, .eof });
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

test "numeric operators" {
    try testTokenise("5 + 3", &.{ .numeric_literal, .plus, .numeric_literal, .eof });
    try testTokenise("5-3", &.{ .numeric_literal, .minus, .numeric_literal, .eof });
    try testTokenise("5 -3", &.{ .numeric_literal, .minus, .numeric_literal, .eof });
    try testTokenise("-24", &.{ .minus, .numeric_literal, .eof });
    try testTokenise("1 * 1", &.{ .numeric_literal, .asterisk, .numeric_literal, .eof });
    try testTokenise("1 << 1", &.{ .numeric_literal, .lsh, .numeric_literal, .eof });
    try testTokenise("1 >> 1", &.{ .numeric_literal, .rsh, .numeric_literal, .eof });
    try testTokenise("1 <", &.{ .numeric_literal, .invalid, .eof });
    try testTokenise("1 <>", &.{ .numeric_literal, .invalid, .eof });
    try testTokenise("1 <\n", &.{ .numeric_literal, .invalid, .newline, .eof });
}

test "string literals" {
    try testTokenise(" \" foo bar \" ", &.{ .string_literal, .eof });
    try testTokenise(" \" foo, bar, \" ", &.{ .string_literal, .eof });
    try testTokenise("\" foo bar \" 0x00 ", &.{ .string_literal, .numeric_literal, .eof });
    try testTokenise("\" foo bar ", &.{ .invalid, .eof });
    try testTokenise("\" foo bar \n", &.{ .invalid, .newline, .eof });
    try testTokenise("\" foo bar '", &.{ .invalid, .eof });
}

test "modifiers" {
    try testTokenise("'u", &.{ .modifier, .eof });
    try testTokenise("'u   ", &.{ .modifier, .eof });
    try testTokenise("'upper", &.{ .invalid, .eof });
    try testTokenise("'u foo", &.{ .modifier, .identifier, .eof });
    try testTokenise("'u, foo", &.{ .modifier, .comma, .identifier, .eof });
    try testTokenise("'u+5", &.{ .modifier, .plus, .numeric_literal, .eof });
    try testTokenise("foo'u foo", &.{ .identifier, .modifier, .identifier, .eof });
    try testTokenise(".foo'u foo", &.{ .reference_label, .modifier, .identifier, .eof });
    try testTokenise("'", &.{ .invalid, .eof });
    // might be confusing
    // try testTokenise("' foo", &.{ .invalid, .eof });
}

test "char literals" {
    try testTokenise("'a'", &.{ .char_literal, .eof });
    try testTokenise("'a'b", &.{ .char_literal, .identifier, .eof });
    try testTokenise("'a'+", &.{ .char_literal, .plus, .eof });
    try testTokenise("-'a'", &.{ .minus, .char_literal, .eof });
    try testTokenise(".foo'u' foo", &.{ .reference_label, .char_literal, .identifier, .eof });
    // might be confusing
    // try testTokenise("'foo' foo", &.{ .invalid, .invalid, .eof });
}

test "full fledge" {
    try testTokeniseSlices(
        \\
        \\@import foo, "path/to/foo.s"
        \\
        \\@section text
        \\@align 2
        \\
        \\_:                lui x1, .label'u
        \\                  ioriu x1, 'aa'
        \\.label:           bkpt
    , &.{
        .{ .newline, "" },
        .{ .builtin_import, "@import" },
        .{ .identifier, "foo" },
        .{ .comma, "," },
        .{ .string_literal, "\"path/to/foo.s\"" },
        .{ .newline, "" },
        .{ .newline, "" },
        .{ .builtin_section, "@section" },
        .{ .identifier, "text" },
        .{ .newline, "" },
        .{ .builtin_align, "@align" },
        .{ .numeric_literal, "2" },
        .{ .newline, "" },
        .{ .newline, "" },
        .{ .label, "_:" },
        .{ .instruction, "lui" },
        .{ .argument, "x1" },
        .{ .comma, "," },
        .{ .reference_label, ".label" },
        .{ .modifier, "'u" },
        .{ .newline, "" },
        .{ .instruction, "ioriu" },
        .{ .argument, "x1" },
        .{ .comma, "," },
        .{ .invalid, "'aa" }, // because ' is a boundary
        .{ .invalid, "'\n" },
        .{ .newline, "" },
        .{ .private_label, ".label:" },
        .{ .instruction, "bkpt" },
        .{ .eof, "\x00" }
    });
}
