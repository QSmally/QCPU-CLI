
const std = @import("std");
const SourceLocation = @import("SourceLocation.zig");

const Instruction = @This();

op: Operation,
token: ?SourceLocation.Token,
label: ?[]const u8,

pub const Operation = union(Tag) {

    /// instr rd, rs1, rs2
    const RegReg = struct {
        rd: Register,
        rs1: Register,
        rs2: Register
    };

    /// instr rw, imm8
    fn RegImm(comptime signedness: std.builtin.Signedness) type {
        return struct {
            rw: Register,
            imm: Immediate(.b8, signedness)
        };
    }

    /// instr rw, uimm6
    const Csr = struct {
        rw: Register,
        imm: Immediate(.b6, .unsigned)
    };

    /// instr rd, rs, uimm4
    const BarrelShift = struct {
        rd: Register,
        rs: Register,
        shift: Immediate(.b4, .unsigned)
    };

    /// instr cond, imm8
    const Branch = struct {
        condition: Condition,
        imm: Immediate(.b8, .signed)
    };

    /// instr rw, rb, uimm
    fn Memory(comptime immediateType: ImmediateType) type {
        return struct {
            rw: Register,
            rb: Register,
            imm: Immediate(immediateType, .unsigned)
        };
    }

    // /// instr r1, r2
    // const RegReg2 = struct {
    //     r1: Register,
    //     r2: Register
    // };

    // /// instr rb, uimm
    // fn Memory2(comptime immediateType: ImmediateType) type {
    //     return struct {
    //         rb: Register,
    //         imm: Immediate(immediateType, .unsigned)
    //     };
    // }

    add: RegReg,
    addc: RegReg,
    sub: RegReg,
    subb: RegReg,
    addi: RegImm(.signed),
    cmpi: RegImm(.signed),
    csrr: Csr,
    csrw: Csr,
    slt: RegReg,
    sltu: RegReg,
    szr: RegReg,
    ior: RegReg,
    @"and": RegReg,
    xor: RegReg,
    iori: RegImm(.signed),
    ioriu: RegImm(.unsigned),
    andi: RegImm(.signed),
    andiu: RegImm(.unsigned),
    xori: RegImm(.signed),
    xoriu: RegImm(.unsigned),
    bsl: BarrelShift,
    bsr: BarrelShift,
    bsrs: BarrelShift,
    brr: BarrelShift,
    bsld: RegReg,
    bsrd: RegReg,
    bsrsd: RegReg,
    brrd: RegReg,
    //
    //
    //
    //
    lli: RegImm(.signed),
    lui: RegImm(.unsigned),
    jmp: Immediate(.b11a32, .unsigned),
    jmpl: Immediate(.b11a32, .unsigned),
    jmpr: Immediate(.b11a2, .signed),
    jmprl: Immediate(.b11a2, .signed),
    jmpd: Register,
    jmpdl: Register,
    brh: Branch,
    prfi: Immediate(.b11a32, .signed),
    mld: Memory(.b5),
    mldw: Memory(.b5a2),
    mst: Memory(.b5),
    mstw: Memory(.b5a2),
    xch: Memory(.b5),
    xchw: Memory(.b5a2),

    // bkpt,
    // mov: RegReg2,
    // @"test": Register,
    // neg: RegReg2,
    // cmp: RegReg2,
    // nop,
    // inc: Register,
    // dec: Register,
    // alloc: Immediate(.b8, .signed),
    // ip: Register,
    // clri,
    // sneg: RegReg2,
    // spos: RegReg2,
    // snez: RegReg2,
    // cut4: Register,
    // cut8: Register,
    // clrl: Register,
    // not: Register,
    // not8: Register,
    // clr: Register,
    // sysc: Immediate(.b8, .unsigned),
    // ret,
    // fence,
    // ftlb,
    // rfi,
    // wfi,
    // scf,
    // rscf,
    // //
    // //
    // prfd: Memory2(.b5a2),
    // mclr: Memory2(.b5),
    // mclrw: Memory2(.b5a2),

    u8: Immediate(.b8, .unsigned),
    u16: Immediate(.b16, .unsigned),
    u24: Immediate(.b24, .unsigned),
    u32: Immediate(.b32, .unsigned),
    i8: Immediate(.b8, .signed),
    i16: Immediate(.b16, .signed),
    i24: Immediate(.b24, .signed),
    i32: Immediate(.b32, .signed),

    ld_padding: usize
};

pub const Tag = enum {
    // Instructions
    add,
    addc,
    sub,
    subb,
    addi,
    cmpi,
    csrr,
    csrw,
    slt,
    sltu,
    szr,
    ior,
    @"and",
    xor,
    iori,
    ioriu,
    andi,
    andiu,
    xori,
    xoriu,
    bsl,
    bsr,
    bsrs,
    brr,
    bsld,
    bsrd,
    bsrsd,
    brrd,
    //
    //
    //
    //
    lli,
    lui,
    jmp,
    jmpl,
    jmpr,
    jmprl,
    jmpd,
    jmpdl,
    brh,
    prfi,
    mld,
    mldw,
    mst,
    mstw,
    xch,
    xchw,

    // // Alias Instructions
    // bkpt,
    // mov,
    // @"test",
    // neg,
    // cmp,
    // nop,
    // inc,
    // dec,
    // alloc,
    // ip,
    // clri,
    // sneg,
    // spos,
    // snez,
    // cut4,
    // cut8,
    // clrl,
    // not,
    // not8,
    // clr,
    // sysc,
    // ret,
    // fence,
    // ftlb,
    // rfi,
    // wfi,
    // scf,
    // rscf,
    // //
    // //
    // prfd,
    // mclr,
    // mclrw,

    // Pseudo Instructions
    u8,
    u16,
    u24,
    u32,
    i8,
    i16,
    i24,
    i32,

    ld_padding
};

pub const List = std.ArrayListUnmanaged(Instruction);

pub const Register = enum(u3) {

    r0, // zr
    r1, // rp
    r2, // sp
    r3, // x1
    r4, // x2
    r5, // x3
    r6, // t1
    r7  // t2
};

pub const Condition = enum(u3) {
    carry,
    sign,
    zero,
    not_carry,
    not_sign,
    not_zero
};

pub const ImmediateOffset = enum {
    addition,
    subtraction
};

pub const ImmediateType = enum {

    b8,     // addi, lli, lui, brh, ...
    b6,     // csrr, csrw
    b4,     // bsl, bsr, ...
    b11a32, // jmp, ...
    b11a2,  // jmpr, ...
    b5,     // mst, mld, ...
    b5a2,   // mstw, mldw, ...

    b16,    // u16, i16
    b24,    // u24, i24
    b32,    // u32, i32

    pub fn mask(self: ImmediateType) u16 {
        return switch (self) {
            .b8 =>     0b00000000_11111111,
            .b6 =>     0b00000000_00111111,
            .b4 =>     0b00000000_00001111,
            .b11a32 => 0b11111111_11100000,
            .b11a2 =>  0b00001111_11111110,
            .b5 =>     0b00000000_00011111,
            .b5a2 =>   0b00000000_00111110
        };
    }

    pub fn left_shift(self: ImmediateType) i5 {
        return switch (self) {
            .b8 => 0,
            .b6 => 0,
            .b4 => 3,
            .b11a32 => -5,
            .b11a2 => -1,
            .b5 => 3,
            .b5a2 => 2
        };
    }

    pub fn alignment(self: ImmediateType) std.mem.Alignment {
        return switch (self) {
            .b8 => .@"1",
            .b6 => .@"1",
            .b4 => .@"1",
            .b11a32 => .@"32",
            .b11a2 => .@"2",
            .b5 => .@"1",
            .b5a2 => .@"2"
        };
    }
};

pub fn Immediate(comptime immediateType: ImmediateType, comptime signednessType: std.builtin.Signedness) type {
    return struct {

        pub const ty = immediateType;
        pub const si = signednessType;

        address: ?struct {
            label: []const u8,
            mask: isize
        },
        op: ImmediateOffset,
        offset: isize
    };
}
