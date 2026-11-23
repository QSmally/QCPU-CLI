
const std = @import("std");
const term = @import("term.zig");
const Section = @import("Section.zig");
const Bundle = @import("Bundle.zig");

const Virtualiser = @This();

bundle: *const Bundle,
options: Options,
start_timestamp: std.Io.Timestamp,

running: std.atomic.Value(bool) = .init(true),
step: std.Io.Semaphore = .{},
total_cycles: u128 = 0,
incr_ip: bool = true,
drs: std.EnumArray(Section.Register.DataRegister, u16) = .initFill(0),
ars: std.EnumArray(Section.Register.AddressRegister, u16) = .initFill(0),
csrs: Csrs = .{},
stats: Statistics = .{}, // TODO: timeline instead of stat counters
l1i: AssociativeCache(8, 32, u16, Section.MachineInstr) = .init(.bkpt),
l1d: AssociativeCache(16, 8, u16, u16) = .init(0),

fn init(bundle: *const Bundle, options: Options) Virtualiser {
    return .{
        .bundle = bundle,
        .options = options,
        .start_timestamp = .now(bundle.io, .real) };
}

pub fn begin(bundle: *const Bundle, options: Options) !void {
    var virtualiser = Virtualiser.init(bundle, options);
    errdefer virtualiser.dumpInterestingTrace() catch {};

    const original_termio = try term.enableRaw(bundle.stderr);
    defer term.move(bundle.stderr, 0, 0) catch {};
    defer term.clear(bundle.stderr) catch {};
    defer term.restore(bundle.stderr, original_termio) catch {};

    try virtualiser.run();
}

fn run(self: *Virtualiser) !void {
    self.start_timestamp = .now(self.bundle.io, .real);
    errdefer self.running.store(false, .release);

    var stdin_task = try self.bundle.io.concurrent(readInputLoop, .{ self });
    errdefer stdin_task.cancel(self.bundle.io) catch {};

    try self.runLoop();
    try stdin_task.await(self.bundle.io);
}

pub const Options = struct {
    step: bool = false,
    maxcycles: u32 = 4096,
    batch: u32 = 16
};

const Csrs = struct {
    k: bool = false
};

const Statistics = struct {
    l1i_miss: u128 = 0,
    l1d_miss: u128 = 0
};

fn readInputLoop(self: *Virtualiser) !void {
    const stdin: std.Io.File = .stdin();
    var stdin_buffer: [16]u8 = undefined;
    var stdin_reader = stdin.reader(self.bundle.io, &stdin_buffer);

    defer self.running.store(false, .release);

    while (self.running.load(.unordered)) switch (try stdin_reader.interface.takeByte()) {
        ' ' => self.step.post(self.bundle.io),
        'q' => return error.Quit,
        0 => return,
        else => {}
    };
}

fn runLoop(self: *Virtualiser) !void {
    while (self.running.load(.unordered)) {
        if (self.options.step or self.total_cycles % self.options.batch == 0) {
            try self.renderTerminal();
        }

        if (self.total_cycles >= self.options.maxcycles) {
            return error.MaxCyclesExceeded;
        }

        if (self.options.step) {
            try self.step.wait(self.bundle.io);
        }

        self.total_cycles += 1;
        self.incr_ip = true;

        self.singleStep() catch |err| switch (err) {
            // error.Interrupt => {},
            else => |the_err| return the_err
        };

        if (self.incr_ip) {
            const old_ip = self.ars.get(.ip);
            self.ars.set(.ip, old_ip + 2);
        }

        if (self.ars.get(.ip) & 1 > 0) {
            self.activateInterrupt(.instr_align);
        }
    }
}

fn singleStep(self: *Virtualiser) !void {
    const ip = self.ars.get(.ip);
    const instr = self.fetchInstruction(ip);

    switch (instr) {
        .bkpt => return error.Breakpoint,
        else => return error.InstructionNotSupported
    }
}

fn AssociativeCache(
    comptime lines: usize,
    comptime line: usize,
    comptime AddressType: type,
    comptime ContentType: type
) type {
    return struct {

        const CacheType = @This();

        content: [lines][line]ContentType,
        age: [lines]usize,
        valid: [lines]bool,
        address: [lines]AddressType,

        const alignment: std.mem.Alignment = if (@typeInfo(ContentType) != .@"int")
            ContentType.alignment else
            .of(ContentType);

        const bits = @ctz(line) + @ctz(alignment.toByteUnits());
        const offset_field = std.math.pow(AddressType, 2, bits) - 1;
        const line_field = ~offset_field;

        comptime {
            std.debug.assert(std.math.isPowerOfTwo(lines));
            std.debug.assert(std.math.isPowerOfTwo(line));
        }

        pub fn init(splat: ContentType) CacheType {
            return .{
                .content = @splat(@splat(splat)),
                .age = @splat(0),
                .valid = @splat(false),
                .address = @splat(0) };
        }

        fn lineOf(self: *const CacheType, address: AddressType) ?usize {
            const addr = address & line_field;

            for (&self.address, 0..) |compare_address, index| {
                if (addr == compare_address and self.valid[index])
                    return index;
            }

            return null;
        }

        fn poke(self: *CacheType, line_index: usize) void {
            for (&self.age, 0..) |age, index| {
                if (age < self.age[line_index])
                    self.age[index] += 1;
            }

            self.age[line_index] = 0;
        }

        fn lru(self: *const CacheType) usize {
            for (&self.valid, 0..) |is_valid, index| {
                if (!is_valid) return index;
            }

            var oldest_age_index: usize = 0;

            for (&self.age, 0..) |age, index| {
                if (age > self.age[oldest_age_index])
                    oldest_age_index = index;
            }

            return oldest_age_index;
        }

        pub fn fetch(self: *CacheType, upper: anytype, context: anytype, address: AddressType) ContentType {
            std.debug.assert(alignment.check(address));

            const page = address & line_field;
            const offset = address & offset_field;
            var line_index: ?usize = null;

            for (&self.address, 0..) |compare_address, index| {
                if (page == compare_address and self.valid[index])
                    line_index = index;
            }

            if (line_index) |index| {
                self.poke(index);
                return self.content[index][offset];
            }

            const replacement = self.lru();
            const new_content = upper(context, page, self.content[replacement]);

            return switch (new_content.mode) {
                .cache => blk: {
                    self.content[replacement] = new_content.result;
                    self.valid[replacement] = true;
                    self.address[replacement] = page;
                    self.poke(replacement);
                    break :blk self.content[replacement][offset];
                },
                .no_cache => new_content.result[offset]
            };
        }
    };
}

fn MemoryResult(comptime T: type) type {
    return struct {
        mode: enum { cache, no_cache },
        result: T
    };
}

fn fetchInstruction(self: *Virtualiser, address: u16) Section.MachineInstr {
    return self.l1i.fetch(loadInstructionMemory, self, address);
}

fn loadInstructionMemory(self: *Virtualiser, address: u16, spill: anytype) MemoryResult(@TypeOf(spill)) {
    self.stats.l1i_miss += 1;
    const physical_address = self.physicalAddressOf(address);
    const len = @typeInfo(@TypeOf(spill)).@"array".len;
    _ = physical_address;
    _ = len;
    return .{ .mode = .cache, .result = @splat(.bkpt) };
}

fn fetchDataByte(self: *Virtualiser, address: u16) u16 {
    const data = self.l1d.fetch(loadDataMemory, self, address & ~1);
    const byte = if (address & 1 == 0)
        (data & 0x00FF) else
        (data >> 8);
    return if (byte & 0x0080 == 0)
        byte else
        (byte | 0xFF00);
}

fn fetchDataWord(self: *Virtualiser, address: u16) u16 {
    std.debug.assert(address & 1 == 0);
    return self.l1d.fetch(loadDataMemory, self, address);
}

fn loadDataMemory(self: *Virtualiser, address: u16, spill: anytype) MemoryResult(@TypeOf(spill)) {
    self.stats.l1d_miss += 1;
    const physical_address = self.physicalAddressOf(address);
    const len = @typeInfo(@TypeOf(spill)).@"array".len;
    _ = physical_address;
    _ = len;
    return .{ .mode = .no_cache, .result = @splat(0) };
}

fn physicalAddressOf(self: *const Virtualiser, address: u16) u16 {
    _ = self;
    return address;
}

const Interrupt = enum {
    instr_align,        // ip align != 2
    instr_reserved,     // instr invalid encoding
    memory_align,       // memory load/store word align != 2
    memory_fault        // physical memory unmapped
};

fn activateInterrupt(self: *Virtualiser, int: Interrupt) void {
    _ = self;
    _ = int;
}

fn renderTerminal(self: *const Virtualiser) !void {
    _ = self;
}

fn dumpInterestingTrace(self: *const Virtualiser) !void {
    const duration = self.start_timestamp.untilNow(self.bundle.io, .real);

    try self.bundle.stderr.print("a crash occurred. ran {} cycles in {f}\n", .{ self.total_cycles, duration });

    try self.bundle.stderr.writeAll("\nData Registers\n");
    try self.dumpRegisters(self.drs);

    try self.bundle.stderr.writeAll("Address Registers\n");
    try self.dumpRegisters(self.ars);

    try self.bundle.stderr.writeAll("Control & Status Registers\n");
    try self.dumpStruct(self.csrs);

    const note = Section.Note {
        .address = self.physicalAddressOf(self.ars.get(.ip)),
        .message = "problem occurred here" };
    try self.bundle.stderr.writeAll("\n");
    try self.bundle.dumpSectionTraceNear(note, self.bundle.stderr);

    try self.bundle.stderr.writeAll("\nStatistics\n");
    try self.dumpStruct(self.stats);
}

fn dumpRegisters(self: *const Virtualiser, domain: anytype) !void {
    for (std.meta.tags(@TypeOf(domain).Key)[1..]) |reg| {
        try self.bundle.stderr.print("  {0s}: 0x{1X:0>4} 0b{1b:0>16} {1}\n", .{ @tagName(reg), domain.get(reg) });
    }
}

fn dumpStruct(self: *const Virtualiser, ty: anytype) !void {
    const type_info = @typeInfo(@TypeOf(ty)).@"struct";
    inline for (type_info.field_names, type_info.field_types) |name, Ty| switch (Ty) {
        bool => try self.bundle.stderr.print("  {s: <4}: {}\n", .{ name, @as(u1, if (@field(ty, name)) 1 else 0) }),
        u8, u16, u32, u128 => try self.bundle.stderr.print("  {s: <4}: {}\n", .{ name, @field(ty, name) }),
        else => comptime unreachable
    };
}
