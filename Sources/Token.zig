
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

    // Instructions, pseudoinstructions and builtins are already decoded in the
    // tokeniser because their argument reguirements are validated in AstGen
    instr_ast,

    psinstr_u8,
    psinstr_u16,
    psinstr_u24,
    psinstr_i8,
    psinstr_i16,
    psinstr_i24,
    psinstr_ascii,

    builtin_symbols,
    builtin_define,
    builtin_if,
    builtin_align,
    builtin_end,
    builtin_section
};

pub fn slice(self: *const Token, from_buffer: [:0]const u8) []const u8 {
    return from_buffer[self.start_byte..(self.end_byte + 1)];
}

pub fn is_barrier(self: *const Token) bool {
    return self.tag == .eof or
        self.tag == .newline or
        self.tag == .comma;
}

pub fn is_any_fault(self: *const Token) bool {
    return self.tag == .invalid or
        self.tag == .unexpected_eof or
        self.tag == .invalid_mod;
}

const TagMap = std.StaticStringMap(Tag);

const keywords = TagMap.initComptime(.{
    .{ "ast", .instr_ast },
    .{ "u8", .psinstr_u8 },
    .{ "u16", .psinstr_u16 },
    .{ "u24", .psinstr_u24 },
    .{ "i8", .psinstr_i8 },
    .{ "i16", .psinstr_i16 },
    .{ "i24", .psinstr_i24 },
    .{ "ascii", .psinstr_ascii },
    .{ "@symbols", .builtin_symbols },
    .{ "@define", .builtin_define },
    .{ "@if", .builtin_if },
    .{ "@align", .builtin_align },
    .{ "@end", .builtin_end },
    .{ "@section", .builtin_section }
});

pub fn reserved(identifier: []const u8) ?Tag {
    return keywords.get(identifier);
}
