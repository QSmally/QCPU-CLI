
const std = @import("std");
const Linker = @import("Linker.zig");

const indent: [12]u8 = @splat(' ');

pub fn output(linker: *const Linker, writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\// QCPU 2 boot memory
        \\//
        \\// The 'boot' module is a XIP non-volatile memory starting at address 0. It is
        \\// executed when QCPU 2 starts up. It is 10 bit, contains 1024 bytes, and
        \\// therefore holds a maximum of 512 instructions.
        \\
        \\module boot (
        \\    input [9:1] addr,
        \\    output [15:0] instr
        \\);
        \\    logic [15:0] instr_c;
        \\
        \\    always_comb begin
        \\        case (addr)
        \\
    );

    for (linker.linked_sections.list.items) |*section| {
        try writer.print("{s}// @section {s} ({} bytes)\n", .{
            indent,
            section.identifier,
            section.bytes() });

        for (section.content.list.items, 0..) |mir, index| {
            const address = section.origin + section.localAddressOf(.fromIndex(index));

            switch (mir.op) {
                .instruction => {
                    try writer.print("{s}'h{X:0>4} : instr_c = 16'b{b:0>16}; // ", .{ indent, address >> 1, mir.binary });
                    try mir.render(writer);
                    try writer.writeByte('\n');
                },
                .padding => {},
                .data => {}, // TODO
                .ascii => {} // TODO
            }
        }
    }

    try writer.writeAll(
        \\            default : instr_c = 'h0000;
        \\        endcase
        \\    end
        \\
        \\    assign instr = instr_c;
        \\endmodule
        \\
    );
}
