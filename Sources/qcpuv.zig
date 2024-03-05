
const Memory = @import("mem/mem.zig").Memory;
const Page_ = @import("mem/pages/page.zig").Page;
const Region_ = @import("mem/regions/region.zig").Region;
const std = @import("std");

const Self = @This();

pub const Address = u16;
pub const Result = u8;

pub const pages = 256;
pub const page_bytes = 256;
pub const registers = 7;

pub const Page = Page_(Address, Result, page_bytes);
pub const Region = Region_(Page);

pub const ExecutionMode = enum {
    direct,
    exec
};

pub const Interrupts = struct {

    pub const stride = 2;

    vector: Bridge.Type = 0,

    pub fn bridge(self: *Interrupts, page: usize) Bridge {
        return .{ .context = self, .page = page };
    }
};

pub const Bridge = struct {

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

comptime {
    std.debug.assert(pages * page_bytes == std.math.pow(usize, 2, @bitSizeOf(Address)));
}

accumulator: Result = 0,
registers: [registers]Result = .{ 0 } ** registers,
kmode: bool = true,

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

pub fn main() !void {
    var source = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = source.deinit();

    var global = std.heap.ArenaAllocator.init(source.allocator());
    defer _ = global.deinit();

    // TODO: CLI options
    const exec_mode: ExecutionMode = .exec;
    const endianness: std.builtin.Endian = .Little;

    var interrupts_ = Interrupts {};
    var memory_ = Memory(Page).init(try physical_memory(global.allocator(), &interrupts_));
    var vmemory_ = Memory(Region).init(try virtual_memory(global.allocator(), &memory_, &interrupts_));

    // TODO: initialise boot sector memory
    // TODO: initialise dmac storage
    // TODO: flag to load dmac storage into physical memory address, or have it be an instance setting

    const entrypoint = if (exec_mode == .direct) 
        memory_.dread(0x0000, endianness) else
        memory_.dread(0xC000, endianness);
    var system = Self.init(&memory_, &vmemory_, &interrupts_, entrypoint);

    while (true) {
        const byte = system.vmemory.read(system.ireference);
        std.debug.print("{} : {}\n", .{ system.ireference, byte });

        system.step(&system.ireference);
        // TODO: check interrupts here
        // TODO: update terminal here
    }
}

const StorePage = @import("mem/pages/store.zig").StorePage(Page);

fn physical_memory(allocator: std.mem.Allocator, context: anytype) ![]Page {
    var source = try allocator.alloc(Page, pages);
    source[0] = try empty_page(allocator); _ = context.bridge(0); // boot
    source[1] = try empty_page(allocator); // dmac

    for (2..256) |page_address|
        source[page_address] = try empty_page(allocator);
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

fn virtual_memory(allocator: std.mem.Allocator, source: *Memory(Page), context: anytype) ![]Region {
    const bridge = try allocator.create(Bridge);
    bridge.* = context.bridge(1); // 1 = dmac page

    const kfixed = try allocator.create(LinearRegion);
    kfixed.* = LinearRegion {
        .source = source,
        .size_pages = kfixed_size,
        .offset_pages = 0 };
    const kvariable = try allocator.create(MapRegion);
    kvariable.* = MapRegion {
        .source = source,
        .size_pages = kvariable_size,
        .map_region = kfixed.region(),
        .map_offset = 0,
        .bridge = bridge };
    const userland = try allocator.create(MapRegion);
    userland.* = MapRegion {
        .source = source,
        .size_pages = userland_size,
        .map_region = kvariable.region_unprivileged(),
        .map_offset = 0,
        .bridge = bridge };

    const interfaces = try allocator.alloc(Region, 3);
    interfaces[0] = userland.region();
    interfaces[1] = kfixed.region();
    interfaces[2] = kvariable.region();
    return interfaces;
}

fn is_kmode(self: *const Self) bool {
    return self.ireference >= (userland_size * page_bytes);
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
};

fn step(self: *Self, address: *Address) void {
    const byte = self.vmemory.read(address.*);
    const instruction = Instruction.decode(byte);
    _ = instruction;

    // run, branch
    address.* += 1;
}
