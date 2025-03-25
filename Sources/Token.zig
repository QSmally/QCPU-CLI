
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
    typed_instruction,
    reserved_argument,

    builtin_align,
    builtin_barrier,
    builtin_define,
    builtin_end,
    builtin_header,
    builtin_region,
    builtin_section,
    builtin_symbols,

    pub fn builtin_indented(self: Tag) bool {
        return switch (self) {
            .builtin_align,
            .builtin_barrier,
            .builtin_define,
            .builtin_end,
            .builtin_section,
            .builtin_symbols => false,

            .builtin_header,
            .builtin_region => true,

            else => unreachable
        };
    }

    pub fn builtin_root(self: Tag) bool {
        return switch (self) {
            .builtin_align,
            .builtin_barrier,
            .builtin_region => false,

            .builtin_define,
            .builtin_header,
            .builtin_symbols => true,

            else => unreachable
        };
    }

    pub fn builtin_body(self: Tag) bool {
        return switch (self) {
            .builtin_header,
            .builtin_symbols => false,

            .builtin_align,
            .builtin_barrier,
            .builtin_define,
            .builtin_region => true,

            else => unreachable
        };
    }

    pub fn fmt(self: Tag) []const u8 {
        return switch (self) {
            .invalid => "an invalid symbol",
            .unexpected_eof => "an unexpected EOF",
            .eof => "EOF",
            .newline => "a newline",

            .l_paran => "'('",
            .r_paran => "')'",
            .comma => "a comma",
            .plus => "a + sign",
            .minus => "a - sign",

            .private_label => "a private label",
            .reference_label => "a reference label",
            .numeric_literal => "a numeric literal",
            .string_literal => "a string literal",
            .modifier => "a modifier",

            .identifier => "an identifier",
            .option => "an option",
            .instruction,
            .pseudo_instruction,
            .typed_instruction => "an instruction",
            .reserved_argument => "an argument",

            .builtin_align => "@align",
            .builtin_barrier => "@barrier",
            .builtin_define => "@define",
            .builtin_end => "@end",
            .builtin_header => "@header",
            .builtin_region => "@region",
            .builtin_section => "@section",
            .builtin_symbols => "@symbols",

            else => @tagName(self)
        };
    }
};

tag: Tag,
location: Location,

// Precheck list used in the generation of the Abstract Syntax Tree. There's
// probably a corresponding section in SemAir to further support a keyword,
// e.g. builtin, option, instruction, etc.
const keywords = std.StaticStringMap(Tag).initComptime(.{
    // Builtins
    .{ "@align", .builtin_align },
    .{ "@barrier", .builtin_barrier },
    .{ "@define", .builtin_define },
    .{ "@end", .builtin_end },
    .{ "@header", .builtin_header },
    .{ "@region", .builtin_region },
    .{ "@section", .builtin_section },
    .{ "@symbols", .builtin_symbols },

    .{ "expose", .option },
    .{ "noelimination", .option },

    // Instructions
    .{ "ast", .instruction },

    .{ "ascii", .pseudo_instruction },
    .{ "i16", .pseudo_instruction },
    .{ "i24", .pseudo_instruction },
    .{ "i8", .pseudo_instruction },
    .{ "u16", .pseudo_instruction },
    .{ "u24", .pseudo_instruction },
    .{ "u8", .pseudo_instruction },

    .{ "reserve", .typed_instruction },

    // Operands
    .{ "c", .reserved_argument },   // carry out
    .{ "s", .reserved_argument },   // sign
    .{ "u", .reserved_argument },   // underflow
    .{ "z", .reserved_argument },   // zero
    .{ "nc", .reserved_argument },  // not carry out
    .{ "ns", .reserved_argument },  // not sign
    .{ "nu", .reserved_argument },  // not underflow
    .{ "nz", .reserved_argument },  // not zero

    // Registers
    .{ "sf", .reserved_argument },  // stack frame
    .{ "sp", .reserved_argument },  // stack pointer
    .{ "xy", .reserved_argument },  // index reg
    .{ "zr", .reserved_argument },  // zero reg
    .{ "mah", .reserved_argument }, // async a l/h
    .{ "mal", .reserved_argument },
    .{ "mbh", .reserved_argument }, // async b l/h
    .{ "mbl", .reserved_argument },
    .{ "mch", .reserved_argument }, // async c l/h
    .{ "mcl", .reserved_argument },
    .{ "mdh", .reserved_argument }, // async d l/h
    .{ "mdl", .reserved_argument },
    .{ "zr", .reserved_argument },
    .{ "ra", .reserved_argument },
    .{ "rb", .reserved_argument },
    .{ "rc", .reserved_argument },
    .{ "rd", .reserved_argument },
    .{ "rx", .reserved_argument },
    .{ "ry", .reserved_argument },
    .{ "rz", .reserved_argument }
});

pub fn reserved(identifier: []const u8) ?Tag {
    return keywords.get(identifier);
}
