
const Instructino = @import("Instruction.zig");

const Byte = @This();

instruction: Instruction,
is: packed struct {
    misaligned_guard: bool,
    padding: bool
}
