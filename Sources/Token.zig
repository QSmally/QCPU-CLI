
const std = @import("std");
const indexable_list = @import("indexable_list.zig");
const instruction = @import("instruction.zig");

const Token = @This();

pub const List = indexable_list.IndexableList(Token);

pub const Tag = enum {

    invalid,
    newline,
    eof,

    l_paran,
    r_paran,
    comma,
    plus,
    plusplus,
    minus,
    minusminus,
    bang,
    asterisk,
    pipe,
    ampersand,
    dollar,
    lsh,
    lt,
    rsh,
    gt,
    eq,

    label,
    local_label,
    private_label,
    reference_label,
    difference_label,
    modifier,
    numeric_literal,
    char_literal,
    string_literal,

    identifier,
    instruction,
    argument,

    builtin_invalid,
    builtin_align,
    builtin_barrier,
    builtin_define,
    builtin_else,
    builtin_end,
    builtin_err,
    builtin_header,
    builtin_if,
    builtin_import,
    builtin_linkinfo,
    builtin_region,
    builtin_section,

    pub fn isBuiltinOpaque(self: Tag) bool {
        return switch (self) {
            .builtin_align,
            .builtin_define,
            .builtin_end,
            .builtin_err,
            .builtin_import,
            .builtin_linkinfo => false,

            .builtin_barrier,
            .builtin_else,
            .builtin_header,
            .builtin_if,
            .builtin_region,
            .builtin_section => true,

            else => unreachable
        };
    }

    pub fn isBuiltinScoped(self: Tag) bool {
        return switch (self) {
            .builtin_barrier,
            .builtin_define,
            .builtin_header,
            .builtin_import,
            .builtin_linkinfo,
            .builtin_section => false,

            .builtin_align,
            .builtin_else,
            .builtin_end,
            .builtin_err,
            .builtin_if,
            .builtin_region => true,

            else => false
        };
    }

    pub fn isBuiltinSection(self: Tag) bool {
        return switch (self) {
            .builtin_align,
            .builtin_define,
            .builtin_else,
            .builtin_end,
            .builtin_err,
            .builtin_header,
            .builtin_if,
            .builtin_import,
            .builtin_linkinfo,
            .builtin_region => false,

            .builtin_barrier,
            .builtin_section => true,

            else => false
        };
    }

    pub fn isBuiltin(self: Tag) bool {
        return switch (self) {
            .builtin_align,
            .builtin_barrier,
            .builtin_define,
            .builtin_else,
            .builtin_end,
            .builtin_err,
            .builtin_header,
            .builtin_if,
            .builtin_import,
            .builtin_linkinfo,
            .builtin_region,
            .builtin_section => true,

            else => false
        };
    }

    pub fn fmt(self: Tag) []const u8 {
        return switch (self) {
            .invalid => "an invalid symbol",
            .newline => "a newline",
            .eof => "EOF",

            .l_paran => "'('",
            .r_paran => "')'",
            .comma => "a comma",
            .plus => "a plus sign",
            .plusplus => "an increment operator",
            .minus => "a minus sign",
            .minusminus => "a decrement operator",
            .bang => "an exclamation point",
            .asterisk => "an asterisk",
            .pipe => "a pipe",
            .ampersand => "an ampersand",
            .dollar => "a dollar sign",
            .lsh => "a left-shift operator",
            .rsh => "a right-shift operator",
            .lt => "a less-than operator",
            .gt => "a greater-than operator",
            .eq => "an equal sign",

            .label => "a label",
            .local_label => "a local label",
            .private_label => "a private label",
            .reference_label => "a reference label",
            .difference_label => "a difference label",
            .modifier => "a modifier",
            .numeric_literal => "a numeric literal",
            .char_literal => "a character literal",
            .string_literal => "a string literal",

            .identifier => "an identifier",
            .instruction => "an instruction",
            .argument => "an argument",

            .builtin_invalid => "an invalid builtin",
            .builtin_align => "@align",
            .builtin_barrier => "@barrier",
            .builtin_define => "@define",
            .builtin_else => "@else",
            .builtin_end => "@end",
            .builtin_err => "@err",
            .builtin_header => "@header",
            .builtin_if => "@if",
            .builtin_import => "@import",
            .builtin_linkinfo => "@linkinfo",
            .builtin_region => "@region",
            .builtin_section => "@section"
        };
    }

    pub fn operationFmt(self: Tag) []const u8 {
        return switch (self) {
            .plus => "addition",
            .plusplus => "increment",
            .minus => "subtraction",
            .minusminus => "decrement",
            .bang => "negation",
            .asterisk => "multiplication",
            .pipe => "bitwise OR",
            .ampersand => "bitwise AND",
            .lsh => "left-shift",
            .rsh => "right-shift",
            .modifier => "bitwise AND",
            else => self.fmt()
        };
    }
};

pub const Location = struct {

    start: usize,
    end: usize,

    pub fn eql(self: Location, location: Location) bool {
        return self.start == location.start and self.end == location.end;
    }

    pub fn slice(self: Location, buffer: [:0]const u8) []const u8 {
        return buffer[self.start..self.end];
    }
};

tag: Tag,
location: Location,

pub fn slice(self: Token, buffer: [:0]const u8) []const u8 {
    const string = self.location.slice(buffer);
    return switch (self.tag) {
        .label => string[0..(string.len - 1)],              // remove punctuation
        .local_label,                                       // remove punctuation
        .private_label,                                     // remove punctuation
        .char_literal,                                      // remove quotes
        .string_literal => string[1..(string.len - 1)],     // remove quotes
        .reference_label, .difference_label => string[1..], // remove prefix dot
        .modifier => string[1..],                           // remove leading quote
        else => string
    };
}

pub fn keyword(identifier: []const u8) ?Tag {
    if (std.meta.stringToEnum(instruction.MachineInstr.Tag, identifier) != null)
        return .instruction;
    if (std.meta.stringToEnum(instruction.Register, identifier) != null)
        return .argument;
    if (std.meta.stringToEnum(instruction.Flag, identifier) != null)
        return .argument;
    return null;
}

const builtins = std.StaticStringMap(Tag).initComptime(.{
    .{ "@align", .builtin_align },
    .{ "@barrier", .builtin_barrier, },
    .{ "@define", .builtin_define, },
    .{ "@else", .builtin_else, },
    .{ "@end", .builtin_end, },
    .{ "@err", .builtin_err, },
    .{ "@header", .builtin_header, },
    .{ "@if", .builtin_if, },
    .{ "@import", .builtin_import, },
    .{ "@linkinfo", .builtin_linkinfo, },
    .{ "@region", .builtin_region, },
    .{ "@section", .builtin_section, }
});

pub fn builtin(identifier: []const u8) ?Tag {
    return builtins.get(identifier);
}

// Tests

const test_buffer = "aaaaa\nhello\n";

fn testTokenSlice(tag: Tag, content: [:0]const u8) []const u8 {
    const location = Location { .start = 0, .end = content.len };
    const token = Token { .tag = tag, .location = location };
    return token.slice(content);
}

test "location" {
    const location_a = Location { .start = 6, .end = 9 };
    const location_b = Location { .start = 6, .end = 9 };

    try std.testing.expect(location_a.eql(location_b));
    try std.testing.expectEqualSlices(u8, "hel", location_a.slice(test_buffer));
}

test "slices" {
    try std.testing.expectEqualSlices(u8, testTokenSlice(.identifier, "foo"), "foo");
    try std.testing.expectEqualSlices(u8, testTokenSlice(.instruction, "bkpt"), "bkpt");
    try std.testing.expectEqualSlices(u8, testTokenSlice(.builtin_end, "@end"), "@end");
    try std.testing.expectEqualSlices(u8, testTokenSlice(.label, "label:"), "label");
    try std.testing.expectEqualSlices(u8, testTokenSlice(.local_label, "_label:"), "label");
    try std.testing.expectEqualSlices(u8, testTokenSlice(.private_label, ".label:"), "label");
    try std.testing.expectEqualSlices(u8, testTokenSlice(.reference_label, ".label"), "label");
    try std.testing.expectEqualSlices(u8, testTokenSlice(.difference_label, "&label"), "label");
    try std.testing.expectEqualSlices(u8, testTokenSlice(.char_literal, "'a'"), "a");
    try std.testing.expectEqualSlices(u8, testTokenSlice(.string_literal, "\"foo\""), "foo");
    try std.testing.expectEqualSlices(u8, testTokenSlice(.modifier, "'f"), "f");
}
