
const std = @import("std");
const indexable_list = @import("indexable_list.zig");
const SourceFile = @import("SourceFile.zig");
const Qcu = @import("Qcu.zig");
const AsmIr = @import("AsmIr.zig");
const AsmSemanticAir = @import("AsmSemanticAir.zig");
const AsmCompute = @import("AsmCompute.zig");
const Linker = @import("Linker.zig");

const Section = @This();

identifier: []const u8,
origin: u32,
linkinfo_token: SourceFile.Token,

content: Mir.List = .empty,

pub const List = indexable_list.IndexableList(Section);

pub fn init(identifier: []const u8, origin: u32, linkinfo_token: SourceFile.Token) Section {
    return .{
        .identifier = identifier,
        .origin = origin,
        .linkinfo_token = linkinfo_token };
}

pub fn deinit(self: *Section, allocator: std.mem.Allocator) void {
    self.content.deinit(allocator);
}

pub fn nextAddress(self: *const Section) u32 {
    return self.origin + self.bytes();
}

pub fn localAddressOf(self: *const Section, index: Mir.List.Index) u32 {
    var total_bytes: u32 = 0;
    for (self.content.list.items[0..index.raw()]) |mir| total_bytes += mir.op.bytes();
    return total_bytes;
}

pub fn bytes(self: *const Section) u32 {
    return self.localAddressOf(.at(self.content.len()));
}

pub const Range = struct {
    min: u32,
    max: ?u32
};

pub const Note = struct {
    address: u32,
    message: []const u8
};

pub fn dumpTraceRange(
    self: *const Section,
    range: Range,
    note: ?Note,
    writer: *std.Io.Writer
) !void {
    try writer.print("@section {s} ({} bytes)\n", .{
        self.identifier,
        self.bytes() });
    if (range.min > 0) {
        try writer.writeAll("... (omitted)\n");
    }

    const len: u32 = if (range.max) |max| max else self.origin + self.bytes();

    for (self.content.list.items, 0..) |mir, index| {
        const global_address = self.origin + self.localAddressOf(.fromIndex(index));

        if (global_address < range.min)
            continue;
        if (global_address + mir.op.bytes() > len)
            continue;

        try writer.print("    0x{X:0>4}   ", .{ global_address });
        defer writer.writeByte('\n') catch {};

        if (mir.op == .instruction)
            try writer.print("0b{b:0>16}   ", .{ mir.binary });
        try mir.render(writer);

        if (note) |the_note| {
            if (the_note.address >= global_address and the_note.address < global_address + mir.op.bytes())
                try writer.print("   <-- {s}", .{ the_note.message });
        }
    }

    if (len != self.origin + self.bytes()) {
        try writer.writeAll("... (omitted)\n");
    }
}

pub fn dumpTrace(self: *const Section, writer: *std.Io.Writer) !void {
    try self.dumpTraceRange(.{ .min = 0, .max = null }, null, writer);
}

pub const Mir = struct {

    token: SourceFile.Token,
    op: Operation,

    binary: u32 = 0,

    pub const List = indexable_list.IndexableList(Mir);

    pub const Operation = union(enum) {

        instruction: MachineInstr,
        padding: u32,
        data: struct { bytes: u32, value: LinkerAddress },
        ascii: struct { text: []const u8, sentinel: ?u8 },

        pub fn bytes(self: Operation) u32 {
            return switch (self) {
                .instruction => 2,
                .padding => |padding| padding,
                .data => |data| data.bytes,
                .ascii => |ascii| blk: {
                    const text_len: u32 = @intCast(ascii.text.len);
                    const sentinel_len: u32 = if (ascii.sentinel != null) 1 else 0;
                    break :blk text_len + sentinel_len;
                }
            };
        }

        pub fn isJump(self: Operation) bool {
            return switch (self) {
                .instruction => |instr| switch (instr) {
                    // these can reference the instruction ptr, but are conditional
                    .movec_caa,
                    .movez_aaa => false,

                    // we know these can't jump unconditionally
                    .brh_ci,
                    .brhl_ci => false,

                    // these implicitly reference the instruction ptr
                    .bkpt,
                    .jmpl_i,
                    .jmprl_i => true,

                    // it's a jump if the `rd` operand is the instruction ptr
                    inline else => |operands| blk: {
                        const Ty = @TypeOf(operands);

                        if (Ty == void) {
                            break :blk false;
                        }

                        if (@hasField(Ty, "rd") and @TypeOf(operands.rd) == Register.AddressRegister) {
                            break :blk operands.rd == .ip;
                        }

                        break :blk false;
                    }
                },
                .padding,
                .data,
                .ascii => false
            };
        }
    };

    pub fn getAddress(self: *const Mir) u32 {
        return switch (self.op) {
            .instruction => |instr| switch (instr) {
                inline else => |operands| blk: {
                    const T = @TypeOf(operands);

                    if (T == void or !@hasDecl(T, "i_mask")) {
                        unreachable;
                    }

                    const imm_mask = @as(u16, T.i_mask);
                    const address = self.binary >> @ctz(imm_mask);
                    // TODO: fix for segmented masks and x_mask
                    const address_mask = std.math.pow(u32, 2, @popCount(imm_mask)) - 1;
                    break :blk address & address_mask;
                }
            },
            .padding => unreachable,
            .data => self.binary,
            .ascii => unreachable
        };
    }

    pub fn render(self: *const Mir, writer: *std.Io.Writer) !void {
        switch (self.op) {
            .instruction => |instr| {
                try writer.print("{s}", .{ instr.qualifiedName() });

                switch (instr) {
                    inline else => |operands| blk: {
                        const T = @TypeOf(operands);

                        if (T == void) {
                            break :blk;
                        }

                        const type_info = @typeInfo(T).@"struct";

                        inline for (type_info.field_names, type_info.field_types, 0..) |name, Type, i| {
                            const operand = @field(operands, name);

                            if (i > 0) {
                                try writer.writeByte(',');
                            }

                            switch (Type) {
                                Register.DataRegister,
                                Register.AddressRegister,
                                Flag => try writer.print(" {s}", .{ @tagName(operand) }),
                                LinkerAddress => if (operand.dynamic) |dynamic| {
                                    if (operand.bit_mask == -1) {
                                        try writer.print(" .{s} + {}", .{
                                            dynamic.label,
                                            operand.offset });
                                    } else {
                                        try writer.print(" .{s}'0x{X} + {}", .{
                                            dynamic.label,
                                            operand.bit_mask,
                                            operand.offset });
                                    }
                                } else {
                                    try writer.print(" {}", .{ operand.offset });
                                },
                                LinkerIndex => if (operand.address.dynamic) |dynamic| {
                                    if (operand.address.bit_mask == -1) {
                                        try writer.print(" (.{s} + {})({s})", .{
                                            dynamic.label,
                                            operand.address.offset,
                                            @tagName(operand.register) });
                                    } else {
                                        try writer.print(" (.{s}'0x{X} + {})({s})", .{
                                            dynamic.label,
                                            operand.address.bit_mask,
                                            operand.address.offset,
                                            @tagName(operand.register) });
                                    }
                                } else {
                                    try writer.print(" {}({s})", .{ operand.address.offset, @tagName(operand.register) });
                                },
                                else => comptime unreachable
                            }
                        }
                    }
                }
            },
            .padding => |padding| try writer.print("* {} byte{s}", .{
                padding,
                if (padding == 1) "" else "s" }),
            .data => try writer.print("0x{0X} ({0})", .{ self.getAddress() }),
            .ascii => |ascii| {
                if (ascii.sentinel) |sentinel|
                    try writer.print("\"{s}\" {}", .{ ascii.text, sentinel }) else
                    try writer.print("\"{s}\"", .{ ascii.text });
            }
        }
    }
};

pub const MachineInstr = union(enum) {

    bkpt,
    add_ddd: DDD,
    add_aaa: AAA,
    add_dad: DAD,
    add_aad: AAD,
    addi_di: DI,
    addi_ai: AI,
    cmpi_di: DI,
    movec_cdd: CDD,
    movec_caa: CAA,
    movez_ddd: DDD,
    movez_aaa: AAA,
    sub_ddd: DDD,
    sub_aaa: AAA,
    slt_ddd: DDD,
    sltu_ddd: DDD,
    ior_ddd: DDD,
    and_ddd: DDD,
    xor_ddd: DDD,
    iori_di: DI,
    ioriu_di: DI,
    andi_di: DI,
    andiu_di: DI,
    mask_di: DI,
    xori_di: DI,
    xoriu_di: DI,
    bsl_ddi: DDI,
    bsr_ddi: DDI,
    bsrs_ddi: DDI,
    brr_ddi: DDI,
    lli_di: DI,
    lui_di: DI,
    lua_ai: AI,
    jmpl_i: I,
    jmprl_i: I,
    brh_ci: CI,
    brhl_ci: CI,
    xch_dx: DX,
    xchw_dx: DX,
    move_dx: DX,
    movew_dx: DX,
    move_xd: XD,
    movew_xd: XD,
    move_dm: DM,
    movew_dm: DM,
    move_dp: DP,
    movew_dp: DP,
    move_md: MD,
    movew_md: MD,
    move_pd: PD,
    movew_pd: PD,
    sysc_i: II,
    csrr_dii: DII,
    csrw_dii: DII,
    reti,
    waiti,
    ftlb,
    fence,
    nop,
    ssf,
    rsf,

    pub const alignment: std.mem.Alignment = .@"2";

    pub const Tag = blk: {
        @setEvalBranchQuota(5000);

        const CommonTagTy = u8;
        const type_info = @typeInfo(@typeInfo(MachineInstr).@"union".tag_type.?).@"enum";

        var index = 0;
        var names: [512][]const u8 = undefined;
        var values: [512]CommonTagTy = undefined;

        const instr = type_info.field_names ++ .{
            // alias instructions
            "bkpt",
            "jmpr",
            // pseudo-instructions
            "i8",
            "i16",
            "i24",
            "i32",
            "u8",
            "u16",
            "u24",
            "u32",
            // special instructions
            "reserve",
            "ascii"
        };

        next: for (instr) |name| {
            const qualified_name = qualifiedInstrName(name);

            for (names[0..index]) |existing_name| {
                if (std.mem.eql(u8, existing_name, qualified_name))
                    continue :next;
            }

            names[index] = qualified_name;
            values[index] = index;
            index += 1;
        }

        break :blk @Enum(
            CommonTagTy,
            type_info.mode,
            names[0..index],
            values[0..index]);
    };

    fn qualifiedInstrName(full_identifier: []const u8) []const u8 {
        const underscore_index = std.mem.findScalar(u8, full_identifier, '_') orelse full_identifier.len;
        return full_identifier[0..underscore_index];
    }

    pub fn qualifiedName(self: MachineInstr) []const u8 {
        return qualifiedInstrName(@tagName(self));
    }

    pub fn opcode(self: MachineInstr) u16 {
        return switch (self) {
            .bkpt       => 0b0000000000000000,
            .add_ddd    => 0b00000_000_00_000_000,
            .add_aaa    => 0b00000_000_01_000_000,
            .add_dad    => 0b00000_000_10_000_000,
            .add_aad    => 0b00000_000_11_000_000,
            .addi_di    => 0b00001_00000000_000,
            .addi_ai    => 0b00010_00000000_000,
            .cmpi_di    => 0b00011_00000000_000,
            .movec_cdd  => 0b00100_000_00_000_000,
            .movec_caa  => 0b00100_000_01_000_000,
            .movez_ddd  => 0b00100_000_10_000_000,
            .movez_aaa  => 0b00100_000_11_000_000,
            .sub_ddd    => 0b00101_000_00_000_000,
            .sub_aaa    => 0b00101_000_01_000_000,
            .slt_ddd    => 0b00101_000_10_000_000,
            .sltu_ddd   => 0b00101_000_11_000_000,
            .ior_ddd    => 0b00110_000_01_000_000,
            .and_ddd    => 0b00110_000_10_000_000,
            .xor_ddd    => 0b00110_000_11_000_000,
            .iori_di    => 0b00111_00000000_000,
            .ioriu_di   => 0b01000_00000000_000,
            .andi_di    => 0b01001_00000000_000,
            .andiu_di   => 0b01010_00000000_000,
            .mask_di    => 0b01011_00000000_000,
            .xori_di    => 0b01100_00000000_000,
            .xoriu_di   => 0b01101_00000000_000,
            .bsl_ddi    => 0b01110_0_0000_000_000,
            .bsr_ddi    => 0b01110_1_0000_000_000,
            .bsrs_ddi   => 0b01111_0_0000_000_000,
            .brr_ddi    => 0b01111_1_0000_000_000,
            .lli_di     => 0b10010_00000000_000,
            .lui_di     => 0b10011_00000000_000,
            .lua_ai     => 0b10100_00000000_000,
            .jmpl_i     => 0b10101_00000000000,
            .jmprl_i    => 0b10110_00000000000,
            .brh_ci     => 0b10111_00000000_000,
            .brhl_ci    => 0b11000_00000000_000,
            .xch_dx     => 0b11001_00000_000_000,
            .xchw_dx    => 0b11010_00000_000_000,
            .move_dx    => 0b11011_00000_000_000,
            .movew_dx   => 0b11100_00000_000_000,
            .move_xd    => 0b11101_00000_000_000,
            .movew_xd   => 0b11110_00000_000_000,
            .move_dm    => 0b11111_000_00_000_000,
            .movew_dm   => 0b11111_001_00_000_000,
            .move_dp    => 0b11111_010_00_000_000,
            .movew_dp   => 0b11111_011_00_000_000,
            .move_md    => 0b11111_100_00_000_000,
            .movew_md   => 0b11111_101_00_000_000,
            .move_pd    => 0b11111_110_00_000_000,
            .movew_pd   => 0b11111_111_00_000_000,
            .sysc_i     => 0b11111_000_01_000_000,
            .csrr_dii   => 0b11111_000_10_000_000,
            .csrw_dii   => 0b11111_000_11_000_000,
            .reti       => 0b11111_000_11_000_000,
            .waiti      => 0b11111_000_11_001_000,
            .ftlb       => 0b11111_000_11_010_000,
            .fence      => 0b11111_000_11_011_000,
            .nop        => 0b11111_001_11_000_000,
            .ssf        => 0b11111_001_11_001_000,
            .rsf        => 0b11111_001_11_010_000
        };
    }

    pub fn immAlignment(self: MachineInstr) std.mem.Alignment {
        return switch (self) {
            // absolute jump, aligned by 32
            .jmpl_i => .@"32",

            // upper immediates, aligned by 256
            .lui_di,
            .lua_ai => .fromByteUnits(256),

            // word and jump/branch instructions, aligned by 2
            .jmprl_i,
            .brh_ci,
            .brhl_ci,
            .xchw_dx,
            .movew_dx,
            .movew_xd,
            .movew_dm,
            .movew_dp,
            .movew_md,
            .movew_pd => .@"2",

            // if the immediate/index has an `rd` operand pointing to `ip`
            inline else => |operands| blk: {
                const T = @TypeOf(operands);

                if (T == void or !@hasField(T, "rd") or @TypeOf(operands.rd) != Register.AddressRegister) {
                    break :blk .@"1";
                }

                const is_imm = @hasField(T, "i") or @hasField(T, "x");
                const is_ip = operands.rd == .ip;
                break :blk if (is_imm and is_ip) .@"2" else .@"1";
            }
        };
    }

    pub fn isRelativeIp(self: MachineInstr) bool {
        return switch (self) {
            .jmprl_i,
            .brh_ci,
            .brhl_ci => true,

            .addi_ai => |operands| operands.rd == .ip,

            else => false
        };
    }

    pub const DDD = struct {
        rd: Register.DataRegister,
        rs1: Register.DataRegister,
        rs2: Register.DataRegister,

        pub const rd_mask = 0b00000_111_00_000_000;
        pub const rs1_mask = 0b00000_000_00_111_000;
        pub const rs2_mask = 0b00000_000_00_000_111;
    };

    pub const AAA = struct {
        rd: Register.AddressRegister,
        rs1: Register.AddressRegister,
        rs2: Register.AddressRegister,

        pub const rd_mask = 0b00000_111_00_000_000;
        pub const rs1_mask = 0b00000_000_00_111_000;
        pub const rs2_mask = 0b00000_000_00_000_111;
    };

    pub const DAD = struct {
        rd: Register.DataRegister,
        rs1: Register.AddressRegister,
        rs2: Register.DataRegister,

        pub const rd_mask = 0b00000_111_00_000_000;
        pub const rs1_mask = 0b00000_000_00_111_000;
        pub const rs2_mask = 0b00000_000_00_000_111;
    };

    pub const AAD = struct {
        rd: Register.AddressRegister,
        rs1: Register.AddressRegister,
        rs2: Register.DataRegister,

        pub const rd_mask = 0b00000_111_00_000_000;
        pub const rs1_mask = 0b00000_000_00_111_000;
        pub const rs2_mask = 0b00000_000_00_000_111;
    };

    pub const DI = struct {
        rd: Register.DataRegister,
        i: LinkerAddress,

        pub const rd_mask = 0b00000_00000000_111;
        pub const i_mask = 0b00000_11111111_000;
    };

    pub const AI = struct {
        rd: Register.AddressRegister,
        i: LinkerAddress,

        pub const rd_mask = 0b00000_00000000_111;
        pub const i_mask = 0b00000_11111111_000;
    };

    pub const CDD = struct {
        cc: Flag,
        rd: Register.DataRegister,
        rs1: Register.DataRegister,

        pub const cc_mask = 0b00000_000_00_000_111;
        pub const rd_mask = 0b00000_111_00_000_000;
        pub const rs1_mask = 0b00000_000_00_111_000;
    };

    pub const CAA = struct {
        cc: Flag,
        rd: Register.AddressRegister,
        rs1: Register.AddressRegister,

        pub const cc_mask = 0b00000_000_00_000_111;
        pub const rd_mask = 0b00000_111_00_000_000;
        pub const rs1_mask = 0b00000_000_00_111_000;
    };

    pub const DDI = struct {
        rd: Register.DataRegister,
        rs1: Register.DataRegister,
        i: LinkerAddress,

        pub const rd_mask = 0b00000_0_0000_000_111;
        pub const rs1_mask = 0b00000_0_0000_111_000;
        pub const i_mask = 0b00000_0_1111_000_000;
    };

    pub const I = struct {
        i: LinkerAddress,

        pub const i_mask = 0b00000_11111111111;
    };

    pub const CI = struct {
        cc: Flag,
        i: LinkerAddress,

        pub const cc_mask = 0b00000_00000000_111;
        pub const i_mask = 0b00000_11111111_000;
    };

    pub const DX = struct {
        rd: Register.DataRegister,
        x: LinkerIndex,

        pub const rd_mask = 0b00000_00000_000_111;
        pub const x_mask = 0b00000_11111_000_000;
        pub const x_mask_src = 0b00000_00000_111_000;
    };

    pub const XD = struct {
        x: LinkerIndex,
        rs1: Register.DataRegister,

        pub const rs1_mask = 0b00000_00000_000_111;
        pub const x_mask = 0b00000_11111_000_000;
        pub const x_mask_src = 0b00000_00000_111_000;
    };

    pub const DM = struct {
        rd: Register.DataRegister,
        m: Register.AddressRegister,

        pub const rd_mask = 0b00000_00000_000_111;
        pub const m_mask = 0b00000_00000_111_000;
    };

    pub const DP = struct {
        rd: Register.DataRegister,
        p: Register.AddressRegister,

        pub const rd_mask = 0b00000_00000_000_111;
        pub const p_mask = 0b00000_00000_111_000;
    };

    pub const MD = struct {
        m: Register.AddressRegister,
        rs1: Register.DataRegister,

        pub const rs1_mask = 0b00000_00000_000_111;
        pub const m_mask = 0b00000_00000_111_000;
    };

    pub const PD = struct {
        p: Register.AddressRegister,
        rs1: Register.DataRegister,

        pub const rs1_mask = 0b00000_00000_000_111;
        pub const p_mask = 0b00000_00000_111_000;
    };

    pub const II = struct {
        i: LinkerAddress,

        pub const i_mask = 0b00000_111_00_111_000;
    };

    pub const DII = struct {
        r: Register.DataRegister,
        i: LinkerAddress,

        pub const r_mask = 0b00000_000_00_000_111;
        pub const i_mask = 0b00000_111_00_111_000;
    };

    pub const DD = struct {
        rd: Register.DataRegister,
        rs1: Register.DataRegister
    };

    pub const AA = struct {
        rd: Register.AddressRegister,
        rs1: Register.AddressRegister
    };

    pub const DA = struct {
        rd: Register.DataRegister,
        rs1: Register.AddressRegister
    };

    pub const AD = struct {
        rd: Register.AddressRegister,
        rs1: Register.DataRegister
    };
};

pub const LinkerAddress = struct {
    dynamic: ?DynamicAddress,
    bit_mask: AsmCompute.ComputeTimeInt,
    offset: AsmCompute.ComputeTimeInt,

    pub const DynamicAddress = struct {
        file_index: Qcu.File.List.Index,
        /// Asserts block.ty == .section
        block_index: AsmIr.Block.List.Index,
        mode: enum { normal, difference },
        locality: Linker.Locality,
        namespace: []const u8,
        label: []const u8
    };
};

pub const LinkerIndex = struct {
    address: LinkerAddress,
    register: Register.AddressRegister
};

pub const Register = enum {

    zr,
    rp,
    d1,
    d2,
    d3,
    d4,
    d5,
    d6,

    ip,
    sp,
    fp,
    a1,
    a2,
    a3,
    a4,

    pub const DataRegister = enum(u3) {

        zr,
        rp,
        d1,
        d2,
        d3,
        d4,
        d5,
        d6,

        pub fn fromGeneral(register: Register) DataRegister {
            return switch (register) {
                .zr => .zr,
                .rp => .rp,
                .d1 => .d1,
                .d2 => .d2,
                .d3 => .d3,
                .d4 => .d4,
                .d5 => .d5,
                .d6 => .d6,
                else => unreachable
            };
        }
    };

    pub const AddressRegister = enum(u3) {

        zr,
        ip,
        sp,
        fp,
        a1,
        a2,
        a3,
        a4,

        pub fn fromGeneral(register: Register) AddressRegister {
            return switch (register) {
                .zr => .zr,
                .ip => .ip,
                .sp => .sp,
                .fp => .fp,
                .a1 => .a1,
                .a2 => .a2,
                .a3 => .a3,
                .a4 => .a4,
                else => unreachable
            };
        }
    };

    pub const Domain = enum {
        zero_register,
        data_register,
        address_register
    };

    pub fn domain(self: Register) Domain {
        return switch (self) {
            .zr => .zero_register,
            .rp, .d1, .d2, .d3, .d4, .d5, .d6 => .data_register,
            .ip, .sp, .fp, .a1, .a2, .a3, .a4 => .address_register
        };
    }

    pub fn isAddressRegister(self: Register) bool {
        return switch (self.domain()) {
            .zero_register, .address_register => true,
            .data_register => false
        };
    }

    pub fn isDataRegister(self: Register) bool {
        return switch (self.domain()) {
            .zero_register, .data_register => true,
            .address_register => false
        };
    }
};

pub const Flag = enum(u3) {

    c,
    h,
    s,
    z,
    nc,
    nh,
    ns,
    nz
};
