
// Compilation

const std = @import("std");
const indexable_list = @import("indexable_list.zig");
const instruction = @import("instruction.zig");
const Qcu = @import("Qcu.zig");
const SourceFile = @import("SourceFile.zig");
const AsmSemanticAir = @import("AsmSemanticAir.zig");

const Compilation = @This();

allocator: std.mem.Allocator,
units: std.ArrayList(*Qcu) = .empty,

const log = std.log.scoped(.Compilation);

pub fn init(allocator: std.mem.Allocator) Compilation {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Compilation) void {
    for (self.units.items) |qcu|
        qcu.deinit();
    self.units.deinit(self.allocator);
}

pub const Section = struct {

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

        const len: usize = if (range.max) |max| max else self.origin + self.bytes();

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
                if (global_address >= the_note.address and global_address + mir.op.bytes() < the_note.address)
                    try writer.print("  <-- {s}", .{ the_note.message });
            }
        }

        if (len != self.origin + self.bytes()) {
            try writer.writeAll("... (omitted)\n");
        }
    }

    pub fn dumpTrace(self: *const Section, writer: *std.Io.Writer) !void {
        try self.dumpTraceRange(.{ .min = 0, .max = null }, null, writer);
    }
};

pub const Mir = struct {

    token: SourceFile.Token,
    op: Operation,

    binary: u32 = 0,
    address: u32 = 0,

    pub const List = indexable_list.IndexableList(Mir);

    pub const Operation = union(enum) {

        instruction: instruction.MachineInstr,
        padding: u32,
        data: struct { bytes: u32, value: instruction.LinkerAddress },
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

                        if (@hasField(Ty, "rd") and @TypeOf(operands.rd) == instruction.Register.AddressRegister) {
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
                                instruction.Register.DataRegister,
                                instruction.Register.AddressRegister,
                                instruction.Flag => try writer.print(" {s}", .{ @tagName(operand) }),
                                instruction.LinkerAddress => if (operand.dynamic) |dynamic| {
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
                                instruction.LinkerIndex => if (operand.address.dynamic) |dynamic| {
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
            .data => try writer.print("0x{X} ({})", .{ self.address, self.address }),
            .ascii => |ascii| {
                if (ascii.sentinel) |sentinel|
                    try writer.print("\"{s}\" {}", .{ ascii.text, sentinel }) else
                    try writer.print("\"{s}\"", .{ ascii.text });
            }
        }
    }
};

pub fn addTransferOwnership(self: *Compilation, qcu: *Qcu) !void {
    log.debug("add unit {s}", .{ qcu.name() });
    try self.units.append(self.allocator, qcu);
}

pub fn work(self: *const Compilation, stderr: *std.Io.Writer) !void {
    for (self.units.items, 0..) |qcu, len| {
        qcu.work() catch |err| {
            for (qcu.errors.items) |the_err|
                try the_err.write(stderr);
            return err;
        };

        const physical_origin = qcu.linker.physical_origin;
        const total_bytes = qcu.linker.resolveTotalBytes();

        for (self.units.items[0..len]) |comparison_qcu| {
            if (
                physical_origin < comparison_qcu.linker.physical_origin and
                physical_origin + total_bytes <= comparison_qcu.linker.physical_origin
            ) continue;

            if (physical_origin >= comparison_qcu.linker.physical_origin + comparison_qcu.linker.resolveTotalBytes())
                continue;

            return error.PhysicalAddressOverlap;
        }
    }
}

pub fn dumpSectionTraceNear(
    self: *const Compilation,
    note: Section.Note,
    writer: *std.Io.Writer
) !void {
    if (self.findSectionNear(note.address)) |nearest_section| {
        const address_near: i32 = @intCast(note.address);
        const range = Section.Range {
            .min = @max(0, address_near - 10),
            .max = @min(nearest_section.bytes(), address_near + 10) };
        return try self.dumpSectionTraceRange(nearest_section, range, note, writer);
    }

    try writer.print(
        \\@section unknown
        \\... unknown section mapped near address 0x{X:0>4}
        \\... {s}
        \\
    , .{ note.address, note.message });
}

pub fn findSectionNear(self: *const Compilation, address: u32) ?*const Section {
    var nearest_section: ?*const Section = null;

    for (self.units) |linker| {
        for (linker.linked_sections.list.items) |*section| {
            if (address < section.origin or address > section.origin + section.bytes())
                continue;
            nearest_section = section;
        }
    }

    return nearest_section;
}
