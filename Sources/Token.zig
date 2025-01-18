
const std = @import("std");

const Token = @This();

tag: Tag,
start_byte: usize,
end_byte: usize,

pub const Tag = enum {
    invalid,
    unexpected_eof,
    eof,
    newline,

    identifier,
    l_paran,
    r_paran,
    comma,
    plus,
    minus,
    label,
    private_label,
    reference_label,
    numeric_literal,
    string_literal,
    modifier,

    instruction,
    pseudo_instruction,
    reserved_argument,

    builtin_symbols,
    builtin_define,
    builtin_header,
    builtin_align,
    builtin_end,
    builtin_section
};

pub fn slice(self: Token, from_buffer: [:0]const u8) []const u8 {
    return from_buffer[self.start_byte..(self.end_byte + 1)];
}

pub fn builtin_has_indentation(self: Token) bool {
    return switch (self.tag) {
        .builtin_symbols,
        .builtin_define,
        .builtin_end,
        .builtin_section => false,
        .builtin_header,
        .builtin_align => true,
        else => unreachable
    };
}

pub fn builtin_rootonly(self: Token) bool {
    return switch (self.tag) {
        .builtin_symbols,
        .builtin_define,
        .builtin_header => true,
        .builtin_align,
        .builtin_end,
        .builtin_section => false,
        else => unreachable
    };
}

const keywords = std.StaticStringMap(Tag).initComptime(.{
    .{ "ast", .instruction },
    .{ "u8", .pseudo_instruction },
    .{ "u16", .pseudo_instruction },
    .{ "u24", .pseudo_instruction },
    .{ "i8", .pseudo_instruction },
    .{ "i16", .pseudo_instruction },
    .{ "i24", .pseudo_instruction },
    .{ "ascii", .pseudo_instruction },
    .{ "reserve", .pseudo_instruction },
    .{ "ra", .reserved_argument },
    .{ "rb", .reserved_argument },
    .{ "rc", .reserved_argument },
    .{ "rd", .reserved_argument },
    .{ "rx", .reserved_argument },
    .{ "ry", .reserved_argument },
    .{ "rz", .reserved_argument },
    .{ "@symbols", .builtin_symbols },
    .{ "@define", .builtin_define },
    .{ "@header", .builtin_header },
    .{ "@align", .builtin_align },
    .{ "@end", .builtin_end },
    .{ "@section", .builtin_section }
});

pub fn reserved(identifier: []const u8) ?Tag {
    return keywords.get(identifier);
}
