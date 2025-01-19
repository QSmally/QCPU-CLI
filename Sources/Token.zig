
const std = @import("std");

const Token = @This();

pub const Location = struct {

    start_byte: usize,
    end_byte: usize,

    pub fn slice(self: Location, from_buffer: [:0]const u8) []const u8 {
        return from_buffer[self.start_byte..(self.end_byte + 1)];
    }
};

pub const Tag = enum {
    invalid,
    unexpected_eof,
    eof,
    newline,

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

    identifier,
    option,
    instruction,
    pseudo_instruction,
    reserved_argument,

    builtin_align,
    builtin_define,
    builtin_end,
    builtin_header,
    builtin_region,
    builtin_section,
    builtin_symbols
};

tag: Tag,
location: Location,

pub fn builtin_has_indentation(self: Token) bool {
    return switch (self.tag) {
        .builtin_align,
        .builtin_define,
        .builtin_end,
        .builtin_section,
        .builtin_symbols => false,

        .builtin_header,
        .builtin_region => true,

        else => unreachable
    };
}

pub fn builtin_rootonly(self: Token) bool {
    return switch (self.tag) {
        .builtin_define,
        .builtin_header,
        .builtin_symbols => true,

        .builtin_align,
        .builtin_end,
        .builtin_region,
        .builtin_section => false,

        else => unreachable
    };
}

const keywords = std.StaticStringMap(Tag).initComptime(.{
    .{ "@align", .builtin_align },
    .{ "@define", .builtin_define },
    .{ "@end", .builtin_end },
    .{ "@header", .builtin_header },
    .{ "@region", .builtin_region },
    .{ "@section", .builtin_section },
    .{ "@symbols", .builtin_symbols },
    .{ "ascii", .pseudo_instruction },
    .{ "ast", .instruction },
    .{ "expose", .option },
    .{ "i16", .pseudo_instruction },
    .{ "i24", .pseudo_instruction },
    .{ "i8", .pseudo_instruction },
    .{ "ra", .reserved_argument },
    .{ "rb", .reserved_argument },
    .{ "rc", .reserved_argument },
    .{ "rd", .reserved_argument },
    .{ "reserve", .pseudo_instruction },
    .{ "rx", .reserved_argument },
    .{ "ry", .reserved_argument },
    .{ "rz", .reserved_argument },
    .{ "u16", .pseudo_instruction },
    .{ "u24", .pseudo_instruction },
    .{ "u8", .pseudo_instruction }
});

pub fn reserved(identifier: []const u8) ?Tag {
    return keywords.get(identifier);
}
