
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

comptime {
    std.debug.assert(pages * page_bytes == std.math.pow(usize, 2, @bitSizeOf(Address)));
}

accumulator: Result = 0,
registers: [registers]Result = .{ 0 } ** registers,
memory: Memory(Page),
vmemory: Memory(Region), // TODO: wrap in interrupts to mark off kernel section from user mode

ireference: Address,

pub fn init(memory_: Memory(Page), vmemory_: Memory(Region), entrypoint: Address) Self {
    return .{
        .memory = memory_,
        .vmemory = vmemory_,
        .ireference = entrypoint };
}

pub fn main() !void {
    var source = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = source.deinit();

    var global = std.heap.ArenaAllocator.init(source.allocator());
    defer _ = global.deinit();

    var memory_ = Memory(Page).init(try physical_memory(global.allocator()));
    var vmemory_ = Memory(Region).init(try virtual_memory(global.allocator(), &memory_));
    const entrypoint = (userland_size * page_bytes) + (kfixed_size * MapRegion.stride);
    var system = Self.init(memory_, vmemory_, entrypoint);

    while (true) {
        const instruction = system.vmemory.read(system.ireference);
        std.debug.print("{} : {}\n", .{ system.ireference, instruction });
        // run, branch, check interrupts
        system.ireference += 1;
    }
}

const StorePage = @import("mem/pages/store.zig").StorePage(Page);

fn physical_memory(allocator: std.mem.Allocator) ![]Page {
    var source = try allocator.alloc(Page, pages);
    for (source) |*page| page.* = try empty_page(allocator);
    return source;
}

fn empty_page(allocator: std.mem.Allocator) !Page {
    const store_page = try allocator.create(StorePage);
    store_page.* = StorePage.init(0);
    return store_page.page();
}

const LinearRegion = @import("mem/regions/linear.zig").LinearRegion(Memory(Page));
const MapRegion = @import("mem/regions/map.zig").MapRegion(Memory(Page), BridgeTest);
const BridgeTest = @import("mem/test/bridge.zig");

const kfixed_size = 48;
const kvariable_size = 16;
const userland_size = 192;

fn virtual_memory(allocator: std.mem.Allocator, source: *Memory(Page)) ![]Region {
    // TODO: interrupt system
    const bridge = try allocator.create(BridgeTest);

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
