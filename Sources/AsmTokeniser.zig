
// Tokeniser

const Token = @import("Token.zig");

const AsmTokeniser = @This();

buffer: [:0]const u8,
cursor: usize = 0,

pub fn init(buffer: [:0]const u8) AsmTokeniser {
    return .{ .buffer = buffer };
}

pub fn isEof(self: *AsmTokeniser) bool {
    return self.cursor == self.buffer.len;
}

const State = enum {
    start,
    invalid,
    identifier,
    builtin,
    underscore,
    plus,
    minus,
    label,
    ampersand,
    difference_label,
    left_angled_bracket,
    right_angled_bracket,
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
            0 => if (self.isEof())
                helper.tag(.eof) else
                helper.tagNext(.invalid),

            ' ', '\t', '\r' => {
                helper.discard();
                continue :state .start;
            },

            // single character tags
            '\n' => helper.tagNext(.newline),
            '(' => helper.tagNext(.l_paran),
            ')' => helper.tagNext(.r_paran),
            ',' => helper.tagNext(.comma),
            '!' => helper.tagNext(.bang),
            '*' => helper.tagNext(.asterisk),
            '|' => helper.tagNext(.pipe),
            '$' => helper.tagNext(.dollar),
            '=' => helper.tagNext(.eq),

            // beginning of tags
            'a'...'z', 'A'...'Z' => continue :state .identifier,
            '@' => continue :state .builtin,
            '_' => continue :state .underscore,
            '+' => continue :state .plus,
            '-' => continue :state .minus,
            '.' => continue :state .label,
            '&' => continue :state .ampersand,
            '<' => continue :state .left_angled_bracket,
            '>' => continue :state .right_angled_bracket,
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
            else => if (helper.isNextBoundary())
                helper.tagPrevious(.invalid) else
                continue :state .invalid
        },

        // Tags any token starting with a-zA-Z_ and continuing with a-zA-Z0-9_
        // as identifier, or if found, a (pseudo)instruction or other reserved
        // identifier.
        .identifier => switch (helper.next()) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => continue :state .identifier,
            '.' => switch (helper.peek()) {
                'a'...'z', 'A'...'Z', '_' => continue :state .identifier,
                else => continue :state .invalid
            },
            ':' => helper.tagNext(.label),
            else => {
                const identifier = self.buffer[result.location.start..self.cursor];
                helper.tagPrevious(if (Token.keyword(identifier)) |keyword|
                    keyword else
                    .identifier);
            }
        },

        .builtin => switch (helper.next()) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => continue :state .builtin,
            else => {
                const identifier = self.buffer[result.location.start..self.cursor];
                helper.tagPrevious(if (Token.builtin(identifier)) |builtin|
                    builtin else
                    .builtin_invalid);
            }
        },

        // Tokens starting with an underscore can only be local labels.
        .underscore => switch (helper.next()) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => continue :state .underscore,
            '.' => switch (helper.peek()) {
                'a'...'z', 'A'...'Z', '_' => continue :state .underscore,
                else => continue :state .invalid
            },
            ':' => helper.tagNext(.local_label),
            else => continue :state .identifier
        },

        // A plus sign can either really be a plus sign, or the increment
        // operator.
        .plus => switch (helper.next()) {
            '+' => helper.tagNext(.plusplus),
            else => helper.tagPrevious(.plus)
        },

        // A minus sign can either really be a minus sign, or the decrement
        // operator.
        .minus => switch (helper.next()) {
            '-' => helper.tagNext(.minusminus),
            else => helper.tagPrevious(.minus)
        },

        // A private label starts with a period and ends with a colon, whilst
        // references end with a boundary character. Public labels start as
        // identifiers.
        .label => switch (helper.next()) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => continue :state .label,
            '.' => switch (helper.peek()) {
                'a'...'z', 'A'...'Z', '_' => continue :state .label,
                else => continue :state .invalid
            },
            ':' => helper.tagNext(.private_label),
            else => if (helper.isBoundary())
                helper.tagPrevious(.reference_label) else
                continue :state .invalid
        },

        // An ampersand can either be a difference label when it is followed
        // by a-zA-Z_ or just a regular ampersand otherwise.
        .ampersand => switch (helper.next()) {
            'a'...'z', 'A'...'Z', '_' => continue :state .difference_label,
            else => helper.tagPrevious(.ampersand)
        },

        .difference_label => switch (helper.next()) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => continue :state .difference_label,
            '.' => switch (helper.peek()) {
                'a'...'z', 'A'...'Z', '_' => continue :state .difference_label,
                else => continue :state .invalid
            },
            else => if (helper.isBoundary())
                helper.tagPrevious(.difference_label) else
                continue :state .invalid
        },

        // A less-than (<) or left shift (<<) operator.
        .left_angled_bracket => switch (helper.next()) {
            '<' => helper.tagNext(.lsh),
            else => helper.tagPrevious(.lt)
        },

        // A greater-than (>) or right shift (>>) operator.
        .right_angled_bracket => switch (helper.next()) {
            '>' => helper.tagNext(.rsh),
            else => helper.tagPrevious(.gt)
        },

        // A type of comment starts with two forward slashes.
        .slash => switch (helper.next()) {
            '/' => continue :state .comment,
            else => continue :state .invalid
        },

        .comment => switch (helper.next()) {
            0 => continue :state .start,
            '\n' => helper.tagNext(.newline),
            else => continue :state .comment
        },

        // Any decimal, hexadecimal or octal numeric literal. Further
        // validation is done during semantic analysis.
        .numeric_literal => switch (helper.next()) {
            '0'...'9', 'A'...'F', 'x', 'b' => continue :state .numeric_literal,
            else => if (helper.isBoundary())
                helper.tagPrevious(.numeric_literal) else
                continue :state .invalid
        },

        // A string literal is just a range of characters until the second
        // double quotes delimiter.
        .string_literal => switch (helper.next()) {
            '"' => helper.tagNext(.string_literal),
            0, '\n' => continue :state .invalid,
            else => continue :state .string_literal
        },

        // An apostrophe can mean a character literal ('a') or a modifier ('u),
        // which is mainly used in address masking.
        .apostrophe => switch (helper.next()) {
            // TODO: support \ escape notation
            ' '...'[', ']'...'`', '{'...'~' => switch (helper.next()) {
                '\'' => helper.tagNext(.char_literal),
                else => continue :state .invalid
            },
            'a'...'z' => switch (helper.next()) {
                '\'' => helper.tagNext(.char_literal),
                else => if (helper.isBoundary())
                    helper.tagPrevious(.modifier) else
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

    pub inline fn isBoundary(self: *Helper) bool {
        return switch (self.current()) {
            0, '\n', '\t', '\r', ' ',
            ',', '(', ')',
            '+', '-', '!', '*', '|', '&', '$', '<', '>',
            '\'' => true,

            else => false
        };
    }

    pub inline fn isNextBoundary(self: *Helper) bool {
        self.tokeniser.cursor += 1;
        return self.isBoundary();
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

    pub inline fn tagPrevious(self: *Helper, tagged: Token.Tag) void {
        self.token.tag = tagged;
        self.token.location.end = self.tokeniser.cursor;
    }

    pub inline fn tagNext(self: *Helper, tagged: Token.Tag) void {
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

fn testTokenise(input: [:0]const u8, expected_tokens: []const Token.Tag) !void {
    var tokeniser = AsmTokeniser.init(input);
    for (expected_tokens) |expected_token|
        try std.testing.expectEqual(expected_token, tokeniser.next().tag);
}

const SlicedToken = struct { Token.Tag, []const u8 };

fn testTokeniseSlices(input: [:0]const u8, expected_slices: []const SlicedToken) !void {
    const stderr_file = std.Io.File.stderr();
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = stderr_file.writer(std.testing.io, &stderr_buffer);
    defer stderr.flush() catch {};

    var tokeniser = AsmTokeniser.init(input);

    for (expected_slices) |expected_slice| {
        const token = tokeniser.next();

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
}

test "builtins" {
    try testTokenise("@import", &.{ .builtin_import, .eof });
    try testTokenise("@define(expose) boob", &.{ .builtin_define, .l_paran, .identifier, .r_paran, .identifier, .eof });
    try testTokenise("@define(0x00) boob", &.{ .builtin_define, .l_paran, .numeric_literal, .r_paran, .identifier, .eof });
    try testTokenise("@define(.reference) boob", &.{ .builtin_define, .l_paran, .reference_label, .r_paran, .identifier, .eof });
    try testTokenise("@define(.label:) boob", &.{ .builtin_define, .l_paran, .private_label, .r_paran, .identifier, .eof });
    try testTokenise("@section", &.{ .builtin_section, .eof });
    try testTokenise("@section foo", &.{ .builtin_section, .identifier, .eof });
    try testTokenise("@import&", &.{ .builtin_import, .ampersand, .eof });

    try testTokenise("@nevergonnagiveyouup", &.{ .builtin_invalid, .eof });
    try testTokenise("@", &.{ .builtin_invalid, .eof });
}

test "labels" {
    try testTokenise("public_label", &.{ .identifier, .eof });
    try testTokenise("public_label:", &.{ .label, .eof });
    try testTokenise("public_label:,", &.{ .label, .comma, .eof });
    try testTokenise("public_label,:", &.{ .identifier, .comma, .invalid, .eof });
    try testTokenise("public_label.", &.{ .invalid, .eof });
    try testTokenise(".private_label:", &.{ .private_label, .eof });
    try testTokenise("._private_internal_label:", &.{ .private_label, .eof }); // disallow this?
    try testTokenise(".private_label.offset:", &.{ .private_label, .eof });
    try testTokenise(".private_label: lui", &.{ .private_label, .instruction, .eof });
    try testTokenise("_local_label: lui", &.{ .local_label, .instruction, .eof });
    try testTokenise("_local_label.foo:", &.{ .local_label, .eof });
    try testTokenise("_:", &.{ .local_label, .eof });
    try testTokenise(".reference_label", &.{ .reference_label, .eof });
    try testTokenise(".reference_label(0)", &.{ .reference_label, .l_paran, .numeric_literal, .r_paran, .eof });
    try testTokenise(".reference_label.", &.{ .invalid, .eof });
    try testTokenise("bar .reference_label // foo", &.{ .identifier, .reference_label, .eof });
    try testTokenise(".bar.reference_label", &.{ .reference_label, .eof });
    try testTokenise(".bar..reference_label", &.{ .invalid, .eof });
    try testTokenise("&bar.difference_label", &.{ .difference_label, .eof });
    try testTokenise("&bar.", &.{ .invalid, .eof });
    try testTokenise("_xd,", &.{ .identifier, .eof });
    try testTokenise("_xd:", &.{ .local_label, .eof });
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
    try testTokenise("++3", &.{ .plusplus, .numeric_literal, .eof });
    try testTokenise("(5)++", &.{ .l_paran, .numeric_literal, .r_paran, .plusplus, .eof });
    try testTokenise("++(5)++", &.{ .plusplus, .l_paran, .numeric_literal, .r_paran, .plusplus, .eof });
    try testTokenise("--(5)--", &.{ .minusminus, .l_paran, .numeric_literal, .r_paran, .minusminus, .eof });
    try testTokenise("--.foo", &.{ .minusminus, .reference_label, .eof });
    try testTokenise("1 * 1", &.{ .numeric_literal, .asterisk, .numeric_literal, .eof });
    try testTokenise("1 << 1", &.{ .numeric_literal, .lsh, .numeric_literal, .eof });
    try testTokenise("1 >> 1", &.{ .numeric_literal, .rsh, .numeric_literal, .eof });
    try testTokenise("1 <", &.{ .numeric_literal, .lt, .eof });
    try testTokenise("1 <>", &.{ .numeric_literal, .lt, .gt, .eof });
    try testTokenise("1 <\n", &.{ .numeric_literal, .lt, .newline, .eof });
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
    try testTokenise(".foo'u(a1)", &.{ .reference_label, .modifier, .l_paran, .argument, .r_paran, .eof });
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
        \\_:                lua a1, .label'u
        \\                  ioriu a1, 'aa'
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
        .{ .local_label, "_:" },
        .{ .instruction, "lua" },
        .{ .argument, "a1" },
        .{ .comma, "," },
        .{ .reference_label, ".label" },
        .{ .modifier, "'u" },
        .{ .newline, "" },
        .{ .instruction, "ioriu" },
        .{ .argument, "a1" },
        .{ .comma, "," },
        .{ .invalid, "'aa" }, // because ' is a boundary
        .{ .invalid, "'\n" },
        .{ .newline, "" },
        .{ .private_label, ".label:" },
        .{ .instruction, "bkpt" },
        .{ .eof, "\x00" }
    });
}
