
const std = @import("std");

const Token = @This();

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
    bang,
    lsh,
    rsh,
    mult,

    label,
    private_label,
    reference_label,
    numeric_literal,
    char_literal,
    string_literal,
    modifier,

    identifier,
    option,
    instruction,
    pseudo_instruction,
    reserved_argument,

    builtin_align,
    builtin_barrier,
    builtin_define,
    builtin_end,
    builtin_header,
    builtin_linkinfo,
    builtin_region,
    builtin_section,
    builtin_symbols,

    pub fn builtin_opaque(self: Tag) bool {
        return switch (self) {
            .builtin_align,
            .builtin_define,
            .builtin_end,
            .builtin_linkinfo,
            .builtin_symbols => false,

            .builtin_header,
            .builtin_region,
            .builtin_section,
            .builtin_barrier => true,

            else => unreachable
        };
    }

    pub fn is_builtin(self: Tag) bool {
        return switch (self) {
            .builtin_align,
            .builtin_barrier,
            .builtin_define,
            .builtin_end,
            .builtin_header,
            .builtin_linkinfo,
            .builtin_region,
            .builtin_section,
            .builtin_symbols => true,

            else => false
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
            .plus => "a plus sign",
            .minus => "a minus sign",
            .bang => "an exclamation point",
            .lsh => "a left-shift operator",
            .rsh => "a right-shift operator",
            .mult => "a multiplication operator",

            .label => "a label",
            .private_label => "a private label",
            .reference_label => "a reference label",
            .numeric_literal => "a numeric literal",
            .char_literal => "a character literal",
            .string_literal => "a string literal",
            .modifier => "a modifier",

            .identifier => "an identifier",
            .option => "an option",
            .instruction,
            .pseudo_instruction => "an instruction",
            .reserved_argument => "a reserved argument",

            .builtin_align => "@align",
            .builtin_barrier => "@barrier",
            .builtin_define => "@define",
            .builtin_end => "@end",
            .builtin_header => "@header",
            .builtin_linkinfo => "@linkinfo",
            .builtin_region => "@region",
            .builtin_section => "@section",
            .builtin_symbols => "@symbols"
        };
    }
};

pub const Location = struct {

    start_byte: usize,
    end_byte: usize,

    pub fn eql(self: Location, location: Location) bool {
        return self.start_byte == location.start_byte and
            self.end_byte == location.end_byte;
    }

    pub fn slice(self: Location, from_buffer: [:0]const u8) []const u8 {
        return from_buffer[self.start_byte..self.end_byte];
    }
};

tag: Tag,
location: Location,

pub fn content_slice(self: Token, from_buffer: [:0]const u8) []const u8 {
    const slice = self.location.slice(from_buffer);
    return switch (self.tag) {
        .label => slice[0..(slice.len - 1)],            // remove punctuation
        .private_label,                                 // remove punctuation
        .char_literal,                                  // remove quotes
        .string_literal => slice[1..(slice.len - 1)],   // remove quotes
        .reference_label => blk: {                      // remove dots/namespace
            const last_index = std.mem.lastIndexOfScalar(u8, slice, '.') orelse unreachable;
            break :blk slice[(last_index + 1)..];
        },
        else => slice
    };
}

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
    .{ "@linkinfo", .builtin_linkinfo },
    .{ "@region", .builtin_region },
    .{ "@section", .builtin_section },
    .{ "@symbols", .builtin_symbols },

    .{ "expose", .option },
    .{ "noelimination", .option },
    .{ "origin", .option },
    .{ "align", .option },

    // Instructions
    .{ "ast", .instruction },
    .{ "cli", .instruction },
    .{ "rst", .instruction },
    .{ "jmp", .instruction },
    .{ "jmpr", .instruction },
    .{ "jmpd", .instruction },
    .{ "mst", .instruction },
    .{ "mstw", .instruction },
    .{ "mld", .instruction },
    .{ "mldw", .instruction },

    .{ "ascii", .pseudo_instruction },
    .{ "i16", .pseudo_instruction },
    .{ "i24", .pseudo_instruction },
    .{ "i8", .pseudo_instruction },
    .{ "u16", .pseudo_instruction },
    .{ "u24", .pseudo_instruction },
    .{ "u8", .pseudo_instruction },

    .{ "reserve", .instruction },

    // Operators
    .{ "lsh", .lsh },
    .{ "rsh", .rsh },

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

comptime {
    const AsmSemanticAir = @import("AsmSemanticAir.zig");
    @setEvalBranchQuota(999_999_999);

    for (keywords.keys()) |keyword| {
        const value = keywords.get(keyword) orelse unreachable;
        if (value != .instruction and value != .pseudo_instruction)
            continue;
        if (std.meta.stringToEnum(AsmSemanticAir.Instruction.Tag, keyword) == null)
            @compileError("bug: unmapped instruction: " ++ keyword);
    }
}

pub fn reserved(identifier: []const u8) ?Tag {
    return keywords.get(identifier);
}

// For use in errors, where the argument is expected to be a struct containing
// a fmt() method.
pub fn string(argument: []const u8) type {
    return struct {
        pub fn fmt() []const u8 {
            return argument;
        }
    };
}
