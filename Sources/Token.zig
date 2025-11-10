
const std = @import("std");

const Token = @This();

pub const Tag = enum {

    invalid,
    newline,
    eof,

    l_paran,
    r_paran,
    comma,
    plus,
    minus,
    bang,
    asterisk,
    pipe,
    ampersand,
    dollar,
    lsh,
    rsh,

    label,
    private_label,
    reference_label,
    modifier,
    numeric_literal,
    char_literal,
    string_literal,

    identifier,
    instruction,
    argument,

    builtin_align,
    builtin_alignop,
    builtin_barrier,
    builtin_buildinfo,
    builtin_define,
    builtin_else,
    builtin_end,
    builtin_entrypoint,
    builtin_err,
    builtin_header,
    builtin_if,
    builtin_import,
    builtin_linkinfo,
    builtin_offset,
    builtin_region,
    builtin_section,

    pub fn is_builtin_opaque(self: Tag) bool {
        return switch (self) {
            .builtin_align,
            .builtin_alignop,
            .builtin_buildinfo,
            .builtin_define,
            .builtin_end,
            .builtin_entrypoint,
            .builtin_err,
            .builtin_import,
            .builtin_linkinfo,
            .builtin_offset => false,

            .builtin_barrier,
            .builtin_else,
            .builtin_header,
            .builtin_if,
            .builtin_region,
            .builtin_section => true,

            else => unreachable
        };
    }

    pub fn is_builtin_instruction(self: Tag) bool {
        return switch (self) {
            .builtin_barrier,
            .builtin_buildinfo,
            .builtin_define,
            .builtin_else,
            .builtin_end,
            .builtin_entrypoint,
            .builtin_err,
            .builtin_header,
            .builtin_if,
            .builtin_import,
            .builtin_linkinfo,
            .builtin_offset,
            .builtin_section => false,

            .builtin_align,
            .builtin_alignop,
            .builtin_region => true,

            else => false
        };
    }

    pub fn is_builtin_section(self: Tag) bool {
        return switch (self) {
            .builtin_align,
            .builtin_alignop,
            .builtin_buildinfo,
            .builtin_define,
            .builtin_else,
            .builtin_end,
            .builtin_entrypoint,
            .builtin_err,
            .builtin_header,
            .builtin_if,
            .builtin_import,
            .builtin_linkinfo,
            .builtin_offset,
            .builtin_region => false,

            .builtin_barrier,
            .builtin_section => true,

            else => false
        };
    }

    pub fn is_builtin(self: Tag) bool {
        return switch (self) {
            .builtin_align,
            .builtin_alignop,
            .builtin_barrier,
            .builtin_buildinfo,
            .builtin_define,
            .builtin_else,
            .builtin_end,
            .builtin_entrypoint,
            .builtin_err,
            .builtin_header,
            .builtin_if,
            .builtin_import,
            .builtin_linkinfo,
            .builtin_offset,
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
            .minus => "a minus sign",
            .bang => "an exclamation point",
            .asterisk => "an asterisk",
            .pipe => "a pipe",
            .ampersand => "an ampersand",
            .dollar => "a dollar sign",
            .lsh => "a left-shift operator",
            .rsh => "a right-shift operator",

            .label => "a label",
            .private_label => "a private label",
            .reference_label => "a reference label",
            .modifier => "a modifier",
            .numeric_literal => "a numeric literal",
            .char_literal => "a character literal",
            .string_literal => "a string literal",

            .identifier => "an identifier",
            .instruction => "an instruction",
            .argument => "an argument",

            .builtin_align => "@align",
            .builtin_alignop => "@alignop",
            .builtin_barrier => "@barrier",
            .builtin_buildinfo => "@buildinfo",
            .builtin_define => "@define",
            .builtin_else => "@else",
            .builtin_end => "@end",
            .builtin_entrypoint => "@entrypoint",
            .builtin_err => "@err",
            .builtin_header => "@header",
            .builtin_if => "@if",
            .builtin_import => "@import",
            .builtin_linkinfo => "@linkinfo",
            .builtin_offset => "@offset",
            .builtin_region => "@region",
            .builtin_section => "@section"
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

pub fn content_slice(self: Token, buffer: [:0]const u8) []const u8 {
    const slice = self.location.slice(buffer);
    return switch (self.tag) {
        .label => slice[0..(slice.len - 1)],            // remove punctuation
        .private_label,                                 // remove punctuation
        .char_literal,                                  // remove quotes
        .string_literal => slice[1..(slice.len - 1)],   // remove quotes
        .reference_label => blk: {                      // remove dots/namespace
            const last_index = std.mem.lastIndexOfScalar(u8, slice, '.') orelse unreachable;
            break :blk slice[(last_index + 1)..];
        },
        .modifier => slice[1..],                        // remove leading quote
        else => slice
    };
}

const keywords = std.StaticStringMap(Tag).initComptime(.{
    // Instructions
    .{ "add", .instruction },
    .{ "addc", .instruction },
    .{ "sub", .instruction },
    .{ "subb", .instruction },
    .{ "addi", .instruction },
    .{ "cmpi", .instruction },
    .{ "csrr", .instruction },
    .{ "csrw", .instruction },
    .{ "slt", .instruction },
    .{ "sltu", .instruction },
    .{ "szr", .instruction },
    .{ "ior", .instruction },
    .{ "and", .instruction },
    .{ "xor", .instruction },
    .{ "iori", .instruction },
    .{ "ioriu", .instruction },
    .{ "andi", .instruction },
    .{ "andiu", .instruction },
    .{ "xori", .instruction },
    .{ "xoriu", .instruction },
    .{ "bsl", .instruction },
    .{ "bsr", .instruction },
    .{ "bsrs", .instruction },
    .{ "brr", .instruction },
    .{ "bsld", .instruction },
    .{ "bsrd", .instruction },
    .{ "bsrsd", .instruction },
    .{ "brrd", .instruction },
    // .{ "", .instruction },
    // .{ "", .instruction },
    // .{ "", .instruction },
    // .{ "", .instruction },
    .{ "lli", .instruction },
    .{ "lui", .instruction },
    .{ "jmp", .instruction },
    .{ "jmpl", .instruction },
    .{ "jmpr", .instruction },
    .{ "jmprl", .instruction },
    .{ "jmpd", .instruction },
    .{ "jmpdl", .instruction },
    .{ "brh", .instruction },
    .{ "prfi", .instruction },
    .{ "mld", .instruction },
    .{ "mldw", .instruction },
    .{ "mst", .instruction },
    .{ "mstw", .instruction },
    .{ "xch", .instruction },
    .{ "xchw", .instruction },

    // Alias Instructions
    .{ "bkpt", .instruction },
    .{ "mov", .instruction },
    .{ "test", .instruction },
    .{ "neg", .instruction },
    .{ "cmp", .instruction },
    .{ "nop", .instruction },
    .{ "inc", .instruction },
    .{ "dec", .instruction },
    .{ "alloc", .instruction },
    .{ "ip", .instruction },
    .{ "clri", .instruction },
    .{ "sneg", .instruction },
    .{ "spos", .instruction },
    .{ "snez", .instruction },
    .{ "cut4", .instruction },
    .{ "cut8", .instruction },
    .{ "clrl", .instruction },
    .{ "not", .instruction },
    .{ "not8", .instruction },
    .{ "clr", .instruction },
    .{ "sysc", .instruction },
    .{ "ret", .instruction },
    .{ "fence", .instruction },
    .{ "ftlb", .instruction },
    .{ "rfi", .instruction },
    .{ "wfi", .instruction },
    .{ "scf", .instruction },
    .{ "rscf", .instruction },
    // .{ "", .instruction },
    // .{ "", .instruction },
    .{ "prfd", .instruction },
    .{ "mclr", .instruction },
    .{ "mclrw", .instruction },

    // Pseudo Instructions
    .{ "u8", .instruction },
    .{ "u16", .instruction },
    .{ "u24", .instruction },
    .{ "u32", .instruction },
    .{ "i8", .instruction },
    .{ "i16", .instruction },
    .{ "i24", .instruction },
    .{ "i32", .instruction },
    .{ "reserve", .instruction },
    .{ "ascii", .instruction },

    // Operands
    .{ "c", .argument },  // carry out
    .{ "s", .argument },  // sign
    .{ "z", .argument },  // zero
    .{ "nc", .argument }, // not carry out
    .{ "ns", .argument }, // not sign
    .{ "nz", .argument }, // not zero

    // Registers
    .{ "zr", .argument }, // zero reg
    .{ "r1", .argument },
    .{ "rp", .argument }, // return ptr
    .{ "r2", .argument },
    .{ "sp", .argument }, // stack pointer
    .{ "r3", .argument },
    .{ "x1", .argument }, // argument/return 1
    .{ "r4", .argument },
    .{ "x2", .argument }, // argument/return 2
    .{ "r5", .argument },
    .{ "x3", .argument }, // argument/return 3
    .{ "r6", .argument },
    .{ "t1", .argument }, // temporary 1
    .{ "r7", .argument },
    .{ "t2", .argument }, // temporary 2

    // Builtins
    .{ "@align", .builtin_align },
    .{ "@alignop", .builtin_alignop },
    .{ "@barrier", .builtin_barrier, },
    .{ "@buildinfo", .builtin_buildinfo, },
    .{ "@define", .builtin_define, },
    .{ "@else", .builtin_else, },
    .{ "@end", .builtin_end, },
    .{ "@entrypoint", .builtin_entrypoint, },
    .{ "@err", .builtin_err, },
    .{ "@header", .builtin_header, },
    .{ "@if", .builtin_if, },
    .{ "@import", .builtin_import, },
    .{ "@linkinfo", .builtin_linkinfo, },
    .{ "@offset", .builtin_offset },
    .{ "@region", .builtin_region, },
    .{ "@section", .builtin_section, }
});

pub fn keyword(identifier: []const u8) ?Tag {
    return keywords.get(identifier);
}

// Tests

const test_buffer = "aaaaa\nhello\n";

test "location" {
    const location_a = Location { .start = 6, .end = 9 };
    const location_b = Location { .start = 6, .end = 9 };

    try std.testing.expect(location_a.eql(location_b));
    try std.testing.expectEqualSlices(u8, "hel", location_a.slice(test_buffer));
}
