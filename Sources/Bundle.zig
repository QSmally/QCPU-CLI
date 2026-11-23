
// Bundle

const std = @import("std");
const Section = @import("Section.zig");
const Qcu = @import("Qcu.zig");
const SourceFile = @import("SourceFile.zig");
const AsmSemanticAir = @import("AsmSemanticAir.zig");

const Bundle = @This();

io: std.Io,
allocator: std.mem.Allocator,
options: Qcu.Options,
stderr: *std.Io.Writer,

units: std.ArrayList(*Qcu) = .empty,
// virt_boot: VirtBootDevice,

const log = std.log.scoped(.Bundle);

pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Qcu.Options,
    stderr: *std.Io.Writer
) Bundle {
    return .{
        .io = io,
        .allocator = allocator,
        .options = options,
        .stderr = stderr };
}

pub fn deinit(self: *Bundle) void {
    for (self.units.items) |qcu|
        qcu.deinit();
    self.units.deinit(self.allocator);
}

pub fn processUnit(self: *Bundle, pwd: std.Io.Dir, root_file_path: []const u8) !void {
    log.debug("create unit {s}", .{ root_file_path });

    const qcu = Qcu.init(
        self.io,
        self.allocator,
        pwd,
        root_file_path,
        self.options,
        self.stderr
    ) catch |err| switch (err) {
        error.FileNotFound => {
            try self.stderr.print("error: {s}: file not found", .{ root_file_path });
            return error.Break;
        },
        else => |the_err| return the_err
    };

    try self.units.append(self.allocator, qcu);

    qcu.work() catch |err| {
        for (qcu.errors.items) |the_err|
            try the_err.write(self.stderr);
        return err;
    };

    // switch (qcu.linker.virt) {
    //     .none => {},
    //     .boot => {},
    //     .memory => {}
    // }
}

// const virt_boot_address = 0x0000;

// pub fn getVirtDevice(self: *const Bundle, physical_address: u16) !VirtDevice {
//     return switch (physical_address) {
//         virt_boot_address...(virt_boot_address + VirtBootDevice.bytes - 1) => self.virt_boot,
//         // 0x0400...(0x0400 + VirtUartDevice.bytes - 1) => self.virt_uart0
//         0x0400...0xFFFF => error.DeviceNotFound
//     };
// }

pub fn dumpSectionTraceNear(
    self: *const Bundle,
    note: Section.Note,
    writer: *std.Io.Writer
) !void {
    if (self.findSectionNear(note.address)) |nearest_section| {
        const range = Section.Range {
            .min = note.address -| 10,
            .max = @min(nearest_section.bytes(), note.address + 10) };
        return try nearest_section.dumpTraceRange(range, note, writer);
    }

    try writer.print(
        \\@section unknown
        \\... unknown section mapped near physical address 0x{X:0>4}
        \\... {s}
        \\
    , .{ note.address, note.message });
}

pub fn findSectionNear(self: *const Bundle, physical_address: u32) ?*const Section {
    var nearest_section: ?*const Section = null;

    for (self.units.items) |qcu| {
        for (qcu.linker.linked_sections.list.items) |*section| {
            if (physical_address < section.origin or physical_address > section.origin + section.bytes())
                continue;
            nearest_section = section;
        }
    }

    return nearest_section;
}
