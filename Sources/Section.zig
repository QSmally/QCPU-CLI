
const std = @import("std");
const SourceLocation = @import("SourceLocation.zig");
const Instruction = @import("Instruction.zig");

const Section = @This();

token: SourceLocation.Token,
/// Grows with the use of @align(op) to ensure the correct padding is
/// calculated ahead-of-time.
alignment: std.mem.Alignment = .@"1",
/// A boolean to indicate whether this section is allowed to be removed by
/// dead tree elimination.
is_invincible: bool = false,
/// A boolean to indicate whether this section block warrants to be the
/// first in the series. Illegal to have multiple entrypoints in the same
/// section series.
is_entrypoint: bool = false,
/// Opaque list of instructions.
content: Instruction.List = .empty,
/// A section with the same name, made with @section or @barrier.
next: ?*Section = null,

pub const Map = std.StringArrayHashMapUnmanaged(*Section);
