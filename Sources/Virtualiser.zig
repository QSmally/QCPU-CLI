
// Virtualiser

const std = @import("std");
const term = @import("term.zig");
const Qcu = @import("Qcu.zig");
const AsmSemanticAir = @import("AsmSemanticAir.zig");
const Linker = @import("Linker.zig");
const Memory = @import("Memory.zig");

const Virtualiser = @This();

allocator: std.mem.Allocator,
qcu: *const Qcu,
options: Options,
physical_memory: Memory,
// fixme: add virtual memory and exec mode support
// virtual_memory: MappedMemory,
instruction_ptr: u16,
total_cycles: u64,
accumulator: u8,
flags: Flags,
gpr: [7]u8,
spr: [4]u16,
last_memory_addr: ?u16,

const Root = struct {
    entrypoint: u16,
    interrupt: u16,
    reserved: u16,
    flags: u16,

    // pub const virt_enabled = 1 << 0; // Virtualisation
    // pub const int_enabled = 1 << 1; // Interrupts
    // pub const btb_enabled = 1 << 2; // Branch Target Buffer
    // pub const bti_enabled = 1 << 3; // Branch Target Identification
};

const Flags = struct {
    zero: bool = false,
    carry: bool = false,
    underflow: bool = false,
    sign: bool = false
};

pub fn init(allocator: std.mem.Allocator, qcu: *const Qcu, options: Options) !Virtualiser {
    return .{
        .allocator = allocator,
        .qcu = qcu,
        .options = options,
        .physical_memory = try Memory.from_blocks(allocator, &qcu.linker.blocks),
        .instruction_ptr = 0,
        .total_cycles = 0,
        .accumulator = 0,
        .flags = .{},
        .gpr = @splat(0),
        .spr = @splat(0),
        .last_memory_addr = null };
}

pub fn deinit(self: *Virtualiser) void {
    self.physical_memory.deinit();
}

const stdin = std.io.getStdIn();

pub fn begin(allocator: std.mem.Allocator, qcu: *const Qcu, options: Options) !void {
    var virtualiser = try Virtualiser.init(allocator, qcu, options);
    defer virtualiser.deinit();
    errdefer virtualiser.dump_interesting_trace() catch {};
    defer term.move_termio(stderr, 0, 0) catch {};
    defer term.clear_termio(stderr) catch {};

    std.debug.assert(options.mode == .direct); // exec mode (virtual memory) is not supported yet

    const original_termio = try term.enable_raw(stdin);
    defer term.restore_termio(stdin, original_termio) catch {};
    try virtualiser.run();
}

pub const ExecutionMode = enum {
    direct,
    exec
};

pub const Options = struct {
    jit: bool = false,
    step: bool = false,
    maxcycles: u64 = 4096,
    iobatch: u64 = 16,
    mode: ExecutionMode = .direct
};

pub fn run(self: *Virtualiser) !void {
    const pm = self.physical_memory.reader();
    const root = pm.read_type(Root, 0);
    self.instruction_ptr = root.entrypoint;

    try self.render_terminal();
    try self.wait();

    while (true) {
        self.instruction_ptr = try self.single_step();
        self.total_cycles += 1;

        if (self.options.step or self.total_cycles % self.options.iobatch == 0)
            try self.render_terminal();
        if (self.total_cycles >= self.options.maxcycles)
            return error.MaxCyclesExceeded;
        try self.wait();
    }
}

fn wait(self: *Virtualiser) !void {
    if (!self.options.step)
        return;
    // fixme: non-step should be nonblocking
    const char = try stdin.reader().readByte();
    if (char == 'q') return error.Quit;
}

fn single_step(self: *Virtualiser) !u16 {
    var vm = self.physical_memory.reader(); // fixme: this should be mapped memory
    const location = vm.read(self.instruction_ptr) orelse Linker.Byte.pad;
    const instruction = location.compiled orelse try self.jit(location);

    impl: switch (instruction) {
        .sysc => return error.InstructionNotSupported,
        .ret => return error.InstructionNotSupported,
        .msp => return error.InstructionNotSupported,
        .nta => return error.InstructionNotSupported,
        .bmr => return error.InstructionNotSupported,
        .bms => return error.InstructionNotSupported,
        .ast => |gpr| self.ast(self.register(gpr), .{}),
        .clr => self.rst(.ra, 0),
        .xch => |gpr| {
            const acc = self.accumulator;
            self.ast(self.register(gpr), .{});
            self.rst(gpr, acc);
        },
        .stg => return error.InstructionNotSupported,
        .rst => |gpr| self.rst(gpr, self.accumulator),
        .inc => |gpr| self.alu(gpr, @addWithOverflow(self.register_acc(gpr), 1)),
        .dec => |gpr| self.alu(gpr, @subWithOverflow(self.register_acc(gpr), 1)),
        .neg => |gpr| self.alu(gpr, @subWithOverflow(0, self.register_acc(gpr))),
        .rsh => |gpr| {
            const value = self.register_acc(gpr);
            const is_underflow = value & 0x01 > 0;
            self.ast(value >> 1, .{ .underflow = is_underflow });
            self.rst(gpr, self.accumulator);
        },
        .add => |gpr| self.alu(.zr, @addWithOverflow(self.accumulator, self.register(gpr))),
        .addc => return error.InstructionNotSupported,
        .sub => |gpr| self.alu(.zr, @subWithOverflow(self.accumulator, self.register(gpr))),
        .subb => return error.InstructionNotSupported,
        .ior => |gpr| self.ast(self.accumulator | self.register(gpr), .{}),
        .@"and" => |gpr| self.ast(self.accumulator & self.register(gpr), .{}),
        .xor => |gpr| self.ast(self.accumulator ^ self.register(gpr), .{}),
        .bsl => |len| self.ast(self.accumulator << len, .{}),
        .bsld => |gpr| {
            const len: u3 = @truncate(self.register(gpr));
            self.ast(self.accumulator << len, .{});
        },
        .bsr => |len| self.ast(self.accumulator >> len, .{}),
        .bsrd => |gpr| {
            const len: u3 = @truncate(self.register(gpr));
            self.ast(self.accumulator >> len, .{});
        },
        .imm => |gpr| {
            self.ast(vm.read_type(u8, self.instruction_ptr + 1), .{});
            self.rst(gpr, self.accumulator);
        },
        .brh => |cond| if (self.condition(cond)) continue :impl .jmpr,
        .jmp => return vm.read_type(u16, self.instruction_ptr + 1),
        .jmpl => return error.InstructionNotSupported,
        .jmpr => {
            const safe_ptr: i32 = @intCast(self.instruction_ptr);
            const offset: i32 = @intCast(vm.read_type(i8, self.instruction_ptr + 1));
            return @intCast(safe_ptr + offset);
        },
        .jmprl => return error.InstructionNotSupported,
        .jmpd => return error.InstructionNotSupported,
        .jmpdl => return error.InstructionNotSupported,
        .prf => return error.InstructionNotSupported,
        .amr => return error.InstructionNotSupported,
        .mst => |spr| try vm.write(try self.addr(vm, spr), .{ .raw_value = self.accumulator }),
        .mstx => return error.InstructionNotSupported,
        .mstw => return error.InstructionNotSupported,
        .mstwx => return error.InstructionNotSupported,
        .mld => |spr| self.ast(vm.to_byte(vm.read(try self.addr(vm, spr))), .{}),
        .mldx => return error.InstructionNotSupported,
        .mldw => return error.InstructionNotSupported,
        .mldwx => return error.InstructionNotSupported
    }

    const instruction_ptr: usize = @intCast(self.instruction_ptr);
    const next_instruction_ptr = instruction_ptr + instruction.size();
    if (next_instruction_ptr > std.math.maxInt(u16))
        return error.InstructionPtrOverflow;
    return @truncate(next_instruction_ptr);
}

const ResultFlags = struct {
    carry: bool = false,
    underflow: bool = false
};

fn ast(self: *Virtualiser, value: u8, flags: ResultFlags) void {
    self.accumulator = value;
    self.flags.zero = self.accumulator == 0;
    self.flags.sign = self.accumulator & 0x80 > 0;
    self.flags.carry = flags.carry;
    self.flags.underflow = flags.underflow;
}

fn rst(self: *Virtualiser, reg: AsmSemanticAir.GpRegister, value: u8) void {
    if (reg != .zr)
        self.gpr[@intFromEnum(reg) - 1] = value else
        self.accumulator = value; // when unwanted, it's already written anyway
}

fn register(self: *Virtualiser, reg: AsmSemanticAir.GpRegister) u8 {
    return if (reg != .zr)
        self.gpr[@intFromEnum(reg) - 1] else
        0;
}

fn register_acc(self: *Virtualiser, reg: AsmSemanticAir.GpRegister) u8 {
    return if (reg != .zr) self.register(reg) else self.accumulator;
}

fn alu(self: *Virtualiser, writeback: AsmSemanticAir.GpRegister, result: anytype) void {
    self.ast(result[0], .{ .carry = result[1] > 0 });
    self.rst(writeback, self.accumulator); // zr possible
}

fn addr(self: *Virtualiser, vm: anytype, reg: AsmSemanticAir.SpRegister) !u16 {
    const absolute = vm.read_type(u16, self.instruction_ptr + 1);
    const kmode = 0;

    const address = switch (reg) {
        .zr => absolute,
        .sp => absolute + self.spr[0 + kmode],
        .sf => absolute + self.spr[2 + kmode],
        .adr => absolute + @as(u16, @intCast(self.gpr[4])) + (@as(u16, @intCast(self.gpr[5])) << 8)
    };

    self.last_memory_addr = address;
    return address;
}

fn condition(self: *Virtualiser, flag: AsmSemanticAir.Flag) bool {
    return switch (flag) {
        .c => self.flags.carry,
        .s => self.flags.sign,
        .u => self.flags.underflow,
        .z => self.flags.zero,
        .nc => !self.flags.carry,
        .ns => !self.flags.sign,
        .nu => !self.flags.underflow,
        .nz => !self.flags.zero
    };
}

fn jit(self: *Virtualiser, location: Linker.Byte) !Linker.Byte.Tag {
    if (!self.options.jit)
        return error.IllegalInstruction;
    // fixme: add JIT for non-mapped instructions
    _ = location;
    return error.JitNotSupported;
}

const stderr = std.io
    .getStdErr()
    .writer();
const Buffer = std.io.BufferedWriter(8192, @TypeOf(stderr));
const TermWriter = term.TermColumnWriter(Buffer.Writer);

fn render_terminal(self: *Virtualiser) !void {
    var buffer = Buffer { .unbuffered_writer = stderr };
    defer buffer.flush() catch {};
    const writer = buffer.writer();

    try term.clear_termio(writer);

    for (&[_]*const fn (*Virtualiser, TermWriter.Writer) TermWriter.Error!void {
        render_col_instructions,
        render_col_data,
        render_col_stats
    }, 0..) |render_col, i| {
        var column = TermWriter {
            .underlying_writer = writer,
            .col = i * 80 + 2,
            .row = 2 };
        try render_col(self, column.writer());
    }
}

fn render_col_instructions(self: *Virtualiser, writer: TermWriter.Writer) !void {
    try writer.writeAll("Instruction\n");
    const l1_len = self.qcu.linker.options.l1;
    const l1_line = self.instruction_ptr & ~(l1_len - 1); // aligns downwards
    try self.render_memory_page(l1_line, l1_len, self.instruction_ptr, true, writer);
}

fn render_col_data(self: *Virtualiser, writer: TermWriter.Writer) !void {
    try writer.writeAll("Data\n");
    const l1_len = self.qcu.linker.options.l1;
    const l1_line = self.last_memory_addr orelse 0 & ~(l1_len - 1); // aligns downwards
    try self.render_memory_page(l1_line, l1_len, self.last_memory_addr orelse 0, false, writer);
}

fn render_memory_page(
    self: *Virtualiser,
    address: usize,
    len: usize,
    accessing_address: usize,
    render_jit: bool,
    writer: anytype
) !void {
    for (address..(address + len)) |absolute_addr| {
        const instr = self.physical_memory.read(@intCast(absolute_addr)) orelse Linker.Byte.pad;

        try writer.print("{s: <23}{s} {x:0>4}:{s}0b{b:0>8}    ", .{
            instr.label orelse "",
            if (absolute_addr == accessing_address) ">" else " ",
            absolute_addr,
            if (instr.is_padding) " * " else " ",
            instr.raw_value });
        defer writer.writeAll("\n") catch {};

        if (render_jit) {
            if (instr.compiled) |instruction| switch (instruction) {
                inline else => |operand, tag| switch (@typeInfo(@TypeOf(operand))) {
                    .@"enum" => try writer.print(" {s} {s}", .{ @tagName(tag), @tagName(operand) }),
                    .int => try writer.print(" {s} {}", .{ @tagName(tag), operand }),
                    .@"void" => try writer.print(" {s}", .{ @tagName(tag) }),
                    else => @compileError("bug: unable to render operand")
                }
            };

            // what in the hell is this kind of if-chain?
            if (instr.long) |instruction| if (get_instr_address(instruction)) |operand| if (operand.label) |label|
                if (operand.offset == 0)
                    try writer.print(" .{s}", .{ label }) else
                    try writer.print(" .{s} + {}", .{ label, operand.offset }) else
                try writer.print(" {}", .{ operand.offset });
        }

        if (instr.address_hint) |hint|
            try writer.print(" ({})", .{ hint });
    }
}

fn get_instr_address(instruction: *const AsmSemanticAir.Instruction) ?struct {
    label: ?[]const u8,
    offset: i32
} {
    return switch (instruction.*) {
        // only constant
        .ascii,
        .reserve,
        .ld_padding => null,

        // free game
        inline else => |operands| blk: {
            if (@TypeOf(operands) == void)
                break :blk null;
            const operand = operands[operands.len - 1];

            if (!@hasField(@TypeOf(operand), "result") or !@hasField(@TypeOf(operand.result), "linktime_label"))
                break :blk null;
            return .{
                .label = if (operand.result.linktime_label) |lbl| lbl.unified_name else null,
                .offset = operand.result.assembletime_offset orelse 0 };
        }
    };
}

fn render_col_stats(self: *Virtualiser, writer: TermWriter.Writer) !void {
    try writer.print("instr. ptr: {}\n", .{ self.instruction_ptr });
    try writer.print("total cycles: {}\n", .{ self.total_cycles });
    try writer.print("mem addr.: {}\n", .{ self.last_memory_addr orelse 0 });
    try writer.print("mode {s}\n", .{ @tagName(self.options.mode) });
    try writer.writeAll("\n");

    try writer.writeAll("Registers\n");
    try writer.print("acc 0b{b:0>8} ({})\n", .{ self.accumulator, self.accumulator });
    for (&self.gpr, 0..) |value, reg|
        try writer.print("r{c}: 0b{b:0>8} ({})\n", .{ gpr_name(reg), value, value });
    try writer.writeAll("\n");

    try writer.writeAll("Indexes\n");
    for (&self.spr, 0..) |value, reg|
        try writer.print("{s}: 0b{b:0>16} {X:0>4} ({})\n", .{ spr_name(reg), value, value, value });
}

fn dump_interesting_trace(self: *Virtualiser) !void {
    try stderr.print("a crash occurred. ip was at {} (ran {} cycles)\n", .{
        self.instruction_ptr,
        self.total_cycles });
    try stderr.print("gpr dump  acc  : 0b{b:0>8} ({})\n", .{ self.accumulator, self.accumulator });
    for (&self.gpr, 0..) |value, reg|
        try stderr.print("          r{c}   : 0b{b:0>8} ({})\n", .{ gpr_name(reg), value, value });
    for (&self.spr, 0..) |value, reg|
        try stderr.print("{s: <8}  {s}: 0b{b:0>16} {X:0>4} ({})\n", .{
            if (reg == 0) "spr dump" else "",
            spr_name(reg),
            value,
            value,
            value });
    try self.qcu.linker.dump_block_trace_near(.{
        .address = self.instruction_ptr,
        .message = "problem occurred here" }, stderr);
}

fn gpr_name(reg: usize) u8 {
    return switch (reg) {
        0...3 => @truncate('a' + reg),
        4...6 => @truncate('x' + reg - 4),
        else => unreachable
    };
}

fn spr_name(reg: usize) []const u8 {
    return switch (reg) {
        0 => "sf   ",
        1 => "sf(k)",
        2 => "sp   ",
        3 => "sp(k)",
        else => unreachable
    };
}
