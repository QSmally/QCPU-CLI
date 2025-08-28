
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
// virtual_memory: MappedMemory,
instruction_ptr: u16,
total_cycles: u64,
accumulator: u8,
flags: Flags,
registers: [registers_len]u8,

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

const RegisterAddress = @typeInfo(AsmSemanticAir.GpRegister).@"enum".tag_type;
const registers_len = std.math.maxInt(RegisterAddress);

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
        .registers = @splat(0) };
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

const ExecutionMode = enum {
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

    switch (instruction) {
        .cli => self.rst(.ra, 0),
        .ast => |gpr| self.ast(self.register(gpr), .{}),
        .rst => |gpr| self.rst(gpr, self.accumulator),

        .jmp => return vm.read_type(u16, self.instruction_ptr + 1),
        .jmpr => {
            const safe_ptr: i32 = @intCast(self.instruction_ptr);
            const offset: i32 = @intCast(vm.read_type(i8, self.instruction_ptr + 1));
            return @intCast(safe_ptr + offset);
        },
        .jmpd => return error.InstructionNotSupported,

        .mst => |spr| try vm.write(try self.addr(vm, spr), .{ .raw_value = self.accumulator }),
        .mstx,
        .mstw,
        .mstwx => return error.InstructionNotSupported,
        .mld => |spr| self.ast(vm.to_byte(vm.read(try self.addr(vm, spr))), .{}),
        .mldx,
        .mldw,
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
    self.registers[@intFromEnum(reg)] = value;
}

fn register(self: *Virtualiser, reg: AsmSemanticAir.GpRegister) u8 {
    return self.registers[@intFromEnum(reg)];
}

fn addr(self: *Virtualiser, vm: anytype, reg: AsmSemanticAir.SpRegister) !u16 {
    const absolute = vm.read_type(u16, self.instruction_ptr + 1);

    return switch (reg) {
        .zr => absolute,
        else => return error.AddressModeNotSupported
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

fn render_terminal(self: *Virtualiser) !void {
    var buffer = std.io.bufferedWriter(stderr);
    defer buffer.flush() catch {};
    const writer = buffer.writer();

    try term.clear_termio(writer);
    try term.move_termio(writer, 0, 0);

    try writer.print("ip: {}\n", .{ self.instruction_ptr });
}

fn dump_interesting_trace(self: *Virtualiser) !void {
    try stderr.print("a crash occurred. ip was at {} (ran {} cycles)\n", .{
        self.instruction_ptr,
        self.total_cycles });
    try self.qcu.linker.dump_block_trace_near(.{
        .address = self.instruction_ptr,
        .message = "problem occurred here" }, stderr);
}
