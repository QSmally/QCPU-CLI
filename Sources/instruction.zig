
const std = @import("std");
const Qcu = @import("Qcu.zig");
const AsmIr = @import("AsmIr.zig");
const AsmSemanticAir = @import("AsmSemanticAir.zig");
const AsmCompute = @import("AsmCompute.zig");

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
    sysc_i: I,
    csrr_di: DI,
    csrw_di: DI,
    reti,
    waiti,
    ftlb,
    fence,
    nop,
    ssf,
    rsf,

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

    pub fn qualifiedInstrName(full_identifier: []const u8) []const u8 {
        const underscore_index = std.mem.findScalar(u8, full_identifier, '_') orelse full_identifier.len;
        return full_identifier[0..underscore_index];
    }

    pub const DDD = struct {
        rd: Register.DataRegister,
        rs1: Register.DataRegister,
        rs2: Register.DataRegister
    };

    pub const AAA = struct {
        rd: Register.AddressRegister,
        rs1: Register.AddressRegister,
        rs2: Register.AddressRegister
    };

    pub const DAD = struct {
        rd: Register.DataRegister,
        rs1: Register.AddressRegister,
        rs2: Register.DataRegister
    };

    pub const AAD = struct {
        rd: Register.AddressRegister,
        rs1: Register.AddressRegister,
        rs2: Register.DataRegister
    };

    pub const DI = struct {
        rd: Register.DataRegister,
        i: LinkerAddress
    };

    pub const AI = struct {
        rd: Register.AddressRegister,
        i: LinkerAddress
    };

    pub const CDD = struct {
        cc: Flag,
        rd: Register.DataRegister,
        rs1: Register.DataRegister
    };

    pub const CAA = struct {
        cc: Flag,
        rd: Register.AddressRegister,
        rs1: Register.AddressRegister
    };

    pub const DDI = struct {
        rd: Register.DataRegister,
        rs1: Register.DataRegister,
        i: LinkerAddress
    };

    pub const I = struct {
        i: LinkerAddress
    };

    pub const CI = struct {
        cc: Flag,
        i: LinkerAddress
    };

    pub const DX = struct {
        rd: Register.DataRegister,
        x: LinkerIndex
    };

    pub const XD = struct {
        x: LinkerIndex,
        rs1: Register.DataRegister
    };

    pub const DM = struct {
        rd: Register.DataRegister,
        m: Register.AddressRegister
    };

    pub const DP = struct {
        rd: Register.DataRegister,
        p: Register.AddressRegister
    };

    pub const MD = struct {
        m: Register.AddressRegister,
        rs1: Register.DataRegister
    };

    pub const PD = struct {
        p: Register.AddressRegister,
        rs1: Register.DataRegister
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
        locality: AsmSemanticAir.Locality,
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
