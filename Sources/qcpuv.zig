
const Memory = @import("mem/mem.zig").Memory;
const Page_ = @import("mem/pages/page.zig").Page;
const Region_ = @import("mem/regions/region.zig").Region;
const clap = @import("clap");
const std = @import("std");

const Self = @This();

pub const Address = u16;
pub const Result = u8;

pub const registers = 7;
pub const pages = 256;
pub const page_bytes = 256;
pub const total_bytes = pages * page_bytes;
pub const io_section_bytes = 24 * page_bytes;
pub const userland_bytes = userland_size * page_bytes;

pub const Page = Page_(Address, Result, page_bytes);
pub const Region = Region_(Page);

pub const Flags = packed struct {
    zero: bool = false,
    sign: bool = false,
    carry: bool = false,
    underflow: bool = false
};

pub const ExecutionMode = enum {
    direct,
    exec
};

comptime {
    std.debug.assert(pages * page_bytes == std.math.pow(usize, 2, @bitSizeOf(Address)));
}

flags: Flags = .{},
accumulator: Result = 0,
registers: [registers]Result = .{ 0 } ** registers,

memory: *Memory(Page),
vmemory: *Memory(Region),
interrupts: *Interrupts,
ireference: Address,

pub fn init(memory_: *Memory(Page), vmemory_: *Memory(Region), interrupt_: *Interrupts, entrypoint: Address) Self {
    return .{
        .memory = memory_,
        .vmemory = vmemory_,
        .interrupts = interrupt_,
        .ireference = entrypoint };
}

const parameters = clap.parseParamsComptime(
    \\--mode <mode>             execution mode, defaults to exec
    \\--endianness <endian>     endianness, defaults to Little
    \\--boot <file>             boot instance page
    \\<file>
    \\
);

const parsers = .{
    .file = clap.parsers.string,
    .mode = clap.parsers.enumeration(ExecutionMode),
    .endian = clap.parsers.enumeration(std.builtin.Endian)
};

pub fn main() !void {
    var source = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = source.deinit();

    var global = std.heap.ArenaAllocator.init(source.allocator());
    defer _ = global.deinit();

    // Mark: parse CLI options
    var diagnostics = clap.Diagnostic{};
    var result = clap.parse(clap.Help, &parameters, parsers, .{
        .diagnostic = &diagnostics,
        .allocator = global.allocator()
    }) catch |err| {
        const stderr = std.io.getStdErr();
        return diagnostics.report(stderr.writer(), err) catch {};
    };

    defer result.deinit();

    const options = .{
        .exec_mode = result.args.mode orelse .exec,
        .endianness = result.args.endianness orelse .Little };
    var interrupts_ = Interrupts {};

    // Mark: memory population
    const context = .{
        .options = options,
        .allocator = global.allocator(),
        .interrupts = &interrupts_ };
    var memory_ = Memory(Page).init(try physical_memory(context));
    var vmemory_ = Memory(Region).init(try virtual_memory(context, &memory_));

    // TODO: connect dmac storage with virtual memory
    if (result.positionals.len != 1)
        return std.debug.print("expected 1 file argument, got {}\n", .{ result.positionals.len });
    const kernel = try std.fs
        .cwd()
        .readFileAlloc(source.allocator(), result.positionals[0], total_bytes - io_section_bytes);
    for (kernel, 0..) |byte, index|
        memory_.write(@intCast(io_section_bytes + index), byte);
    source.allocator().free(kernel);

    // Mark: init boot-instance
    if (result.args.boot) |boot_instance_file| {
        const boot_instance = try std.fs
            .cwd()
            .readFileAlloc(source.allocator(), boot_instance_file, page_bytes);
        for (boot_instance, 0..) |byte, index|
            memory_.write(@intCast(index), byte);
        source.allocator().free(boot_instance);
    }

    // Mark: runloop
    const entrypoint = if (options.exec_mode == .direct) 
        memory_.dread(0, options.endianness) else
        memory_.dread(userland_bytes, options.endianness);
    var system = Self.init(&memory_, &vmemory_, &interrupts_, entrypoint);

    while (true) {
        const stderr = std.io
            .getStdErr()
            .writer();
        system.step(stderr);
        // TODO: check interrupts here
        // TODO: update terminal here
    }
}

fn is_kmode(address: Address) bool {
    return address >= userland_bytes;
}

const StorePage = @import("mem/pages/store.zig").StorePage(Page);

fn physical_memory(context: anytype) ![]Page {
    var source = try context.allocator.alloc(Page, pages);
    source[0] = try empty_page(context.allocator); // boot
    source[1] = try empty_page(context.allocator); // dmac
    source[2] = try empty_page(context.allocator); // TODO: I/O device configuration
    source[3] = try empty_page(context.allocator);
    source[4] = try empty_page(context.allocator);
    source[5] = try empty_page(context.allocator);
    source[6] = try empty_page(context.allocator);
    source[7] = try empty_page(context.allocator);
    source[8] = try empty_page(context.allocator);
    source[9] = try empty_page(context.allocator);
    source[10] = try empty_page(context.allocator);
    source[11] = try empty_page(context.allocator);
    source[12] = try empty_page(context.allocator);
    source[13] = try empty_page(context.allocator);
    source[14] = try empty_page(context.allocator);
    source[15] = try empty_page(context.allocator);
    source[16] = try empty_page(context.allocator);
    source[17] = try empty_page(context.allocator);
    source[18] = try empty_page(context.allocator);
    source[19] = try empty_page(context.allocator);
    source[20] = try empty_page(context.allocator);
    source[21] = try empty_page(context.allocator);
    source[22] = try empty_page(context.allocator);
    source[23] = try empty_page(context.allocator);

    for (24..256) |page_address|
        source[page_address] = try empty_page(context.allocator);
    return source;
}

fn empty_page(allocator: std.mem.Allocator) !Page {
    const store_page = try allocator.create(StorePage);
    store_page.* = StorePage.init(0);
    return store_page.page();
}

const LinearRegion = @import("mem/regions/linear.zig").LinearRegion(Memory(Page));
const MapRegion = @import("mem/regions/map.zig").MapRegion(Memory(Page), Bridge);

const kfixed_size = 48;
const kvariable_size = 16;
const userland_size = 192;

fn virtual_memory(context: anytype, source: *Memory(Page)) ![]Region {
    switch (context.options.exec_mode) {
        .direct => {
            const direct = try context.allocator.create(LinearRegion);
            direct.* = LinearRegion {
                .source = source,
                .size_pages = pages,
                .offset_pages = 0 };
            const interfaces = try context.allocator.alloc(Region, 1);
            interfaces[0] = direct.region();
            return interfaces;
        },
        .exec => {
            const bridge = try context.allocator.create(Bridge);
            bridge.* = context.interrupts.bridge(1); // 1 = dmac page

            const kfixed = try context.allocator.create(LinearRegion);
            kfixed.* = LinearRegion {
                .source = source,
                .size_pages = kfixed_size,
                .offset_pages = 0 };
            const kvariable = try context.allocator.create(MapRegion);
            kvariable.* = MapRegion {
                .source = source,
                .size_pages = kvariable_size,
                .map_region = kfixed.region(),
                .map_offset = 0,
                .bridge = bridge };
            const userland = try context.allocator.create(MapRegion);
            userland.* = MapRegion {
                .source = source,
                .size_pages = userland_size,
                .map_region = kvariable.region_unprivileged(),
                .map_offset = 0,
                .bridge = bridge };

            const interfaces = try context.allocator.alloc(Region, 3);
            interfaces[0] = userland.region();
            interfaces[1] = kfixed.region();
            interfaces[2] = kvariable.region();
            return interfaces;
        }
    }
}

const Instruction = enum(u8) {

    mldw   = 0b1_1111_000,
    mld    = 0b1_1110_000,
    mstw   = 0b1_1101_000,
    mst    = 0b1_1100_000,
    jmpl   = 0b1_1011_000,
    jmp    = 0b1_1010_000,
    brh    = 0b1_1001_000,

    push   = 0b1_1000_000,
    sysc   = 0b1_01_00000,

    bsrd   = 0b1_0011_000,
    bsr    = 0b1_0010_000,
    bsld   = 0b1_0001_000,
    bsl    = 0b1_0000_000,

    xor    = 0b0_1111_000,
    @"and" = 0b0_1110_000,
    ior    = 0b0_1101_000,
    sub    = 0b0_1100_000,
    add    = 0b0_1011_000,
    rsh    = 0b0_1010_000,
    neg    = 0b0_1001_000,
    dec    = 0b0_1000_000,
    inc    = 0b0_0111_000,

    rst    = 0b0_0110_000,
    ast    = 0b0_0101_000,
    xch    = 0b0_0100_000,
    msp    = 0b0_001_0000,
    imm    = 0b0_0001_000,

    // ... 3
    bti    = 0b0_0000_100,
    dfr    = 0b0_0000_011,
    pcm    = 0b0_0000_010,
    nta    = 0b0_0000_001,
    ret    = 0b0_0000_000,

    pub fn decode(binary: u8) Instruction {
        inline for (@typeInfo(Instruction).Enum.fields) |instruction| {
            if (binary >= instruction.value)
                return std.meta.stringToEnum(Instruction, instruction.name).?;
        }
    }

    pub fn exec(self: Instruction, system: *Self, binary: u8) ?Address {
        const operand: u3 = @intCast(binary & 0b111);

        switch (self) {
            // ret
            .nta => system.set_accumulator(~system.accumulator),
            // pcm
            // dfr
            // bti
            .imm => {
                const immediate = system.vmemory.read(system.ireference);
                system.dwrite(operand, immediate);
                system.ireference += 1;
            },
            // msp
            .xch => {
                const accumulator = system.accumulator;
                system.set_accumulator(system.zrread(operand));
                system.zrwrite(operand, accumulator);
            },
            .ast => system.set_accumulator(system.zrread(operand)),
            .rst => system.zrwrite(operand, system.accumulator),
            .inc => {
                const increment = @addWithOverflow(system.dread(operand), 1);
                system.dwrite(operand, increment[0]);
            },
            .dec => {
                const decrement = @subWithOverflow(system.dread(operand), 1);
                system.dwrite(operand, decrement[0]);
            },
            .neg => {
                const inversion = ~system.dread(operand);
                const negation = @addWithOverflow(inversion, 1);
                system.dwrite(operand, negation[0]);
            },
            .rsh => {
                const value = system.dread(operand);
                system.dwrite(operand, value >> 1);
                system.flags.underflow = (value & 0x1) > 0;
            },
            .add => {
                const addition = @addWithOverflow(system.accumulator, system.zrread(operand));
                system.set_accumulator(addition[0]);
                system.flags.carry = addition[1] > 0;
            },
            .sub => {
                const subtraction = @subWithOverflow(system.accumulator, system.zrread(operand));
                system.set_accumulator(subtraction[0]);
                system.flags.carry = subtraction[1] > 0;
            },
            .ior => system.set_accumulator(system.accumulator | system.zrread(operand)),
            .@"and" => system.set_accumulator(system.accumulator & system.zrread(operand)),
            .xor => system.set_accumulator(system.accumulator ^ system.zrread(operand)),
            .bsl => system.set_accumulator(system.accumulator << operand),
            .bsld => system.set_accumulator(system.accumulator << @intCast(system.zrread(operand) & 0b111)),
            .bsr => system.set_accumulator(system.accumulator >> operand),
            .bsrd => system.set_accumulator(system.accumulator >> @intCast(system.zrread(operand) & 0b111)),
            // sysc
            // push
            // brh
            // jmp
            // jmpl
            // mst
            // mstw
            // mld
            // mldw
            else => return null
        }

        return null;
    }
};

const Interrupts = struct {

    pub const stride = 2;

    vector: Bridge.Type = 0,

    pub fn bridge(self: *Interrupts, page: usize) Bridge {
        return .{ .context = self, .page = page };
    }
};

const Bridge = struct {

    pub const Type = u96; // 24 * 4
    pub const SandboxAddress = u2;
    pub const interrupts = std.math.pow(usize, 2, @bitSizeOf(SandboxAddress));

    context: *Interrupts,
    page: usize,

    pub fn interrupt(self: *Bridge, flag: SandboxAddress) void {
        const index = self.page * interrupts + flag;
        std.debug.assert(@bitSizeOf(Type) > index);
        self.context.vector |= @as(Type, 1) << @intCast(index);
    }
};

fn step(self: *Self, log: anytype) void {
    const byte = self.vmemory.read(self.ireference);
    const instruction = Instruction.decode(byte);
    log.print("{} : {s} ({b})\n", .{ self.ireference, @tagName(instruction), byte }) catch {};

    const goto = instruction.exec(self, byte) orelse self.ireference + 1;
    if (!is_kmode(self.ireference) and is_kmode(goto))
        self.interrupts.vector |= 1 << 4; // TODO: better interrupt system
    self.ireference = goto;
}

fn set_accumulator(self: *Self, byte: Result) void {
    self.accumulator = byte;
    self.flags.zero = byte == 0;
    self.flags.sign = (byte & 0x80) > 0;
    self.flags.carry = false;
    self.flags.underflow = false;
}

fn dwrite(self: *Self, register: anytype, byte: Result) void {
    if (register == 0)
        self.set_accumulator(byte) else
        self.registers[register] = byte;
}

fn dread(self: *Self, register: anytype) Result {
    return if (register == 0)
        self.accumulator else
        self.registers[register];
}

fn zrwrite(self: *Self, register: anytype, byte: Result) void {
    if (register > 0)
        self.registers[register] = byte;
}

fn zrread(self: *Self, register: anytype) Result {
    return if (register == 0)
        0 else
        self.registers[register];
}
