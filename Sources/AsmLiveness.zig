
const std = @import("std");
const SourceFile = @import("SourceFile.zig");
const Error = @import("Error.zig");
const AsmSemanticAir = @import("AsmSemanticAir.zig");

const AsmLiveness = @This();

allocator: std.mem.Allocator,
bridge: Bridge,

pub fn init(allocator: std.mem.Allocator, bridge: Bridge) AsmLiveness {
    return .{ .allocator = allocator, .bridge = bridge };
}

pub const Bridge = struct {

    const AllocatorError = std.mem.Allocator.Error;

    vtable: VTable,
    context: *anyopaque,

    pub const VTable = struct {
        emitError: *const fn (*anyopaque, Error) AllocatorError!void
    };

    fn emitError(self: *const Bridge, err: Error) !void {
        return try self.vtable.emitError(self.context, err);
    }
};

pub const LivenessError = error {
    UncoordinatedPadding,
    UncoordinatedData,
    UnreachableBody,
    UndefinedControlFlow,
    NoteDivertedHere,
    NotePaddingHere,
    NoteDefinedHere,
    Note
};

fn addError(
    self: *const AsmLiveness,
    comptime err: LivenessError,
    token: SourceFile.Token
) !void {
    @branchHint(.cold);

    const format = switch (err) {
        error.UncoordinatedPadding => .{ "execution flow spills into padding", .{} },
        error.UncoordinatedData => .{ "execution flow spills into non-executable body", .{} },
        error.UnreachableBody => .{ "unreachable instruction '{s}'", .{ token.slice() } },
        error.UndefinedControlFlow => .{ "execution flow reaches end of section", .{} },
        error.NoteDivertedHere => .{ "control flow diverted here", .{} },
        error.NotePaddingHere => .{ "padding is generated here", .{} },
        error.NoteDefinedHere => .{ "{s} defined here", .{ token.inner_token.tag.fmt() } },
        error.Note => @compileError("use self.addNote() instead")
    };

    const message = try self.allocator.print(format[0], format[1]);
    errdefer self.allocator.free(message);

    try self.bridge.emitError(.{
        .err = err,
        .token = token.inner_token,
        .source_file = token.source_file,
        .is_note = switch (err) {
            error.NoteDivertedHere,
            error.NotePaddingHere,
            error.NoteDefinedHere,
            error.Note => true,
            else => false
        },
        .is_preview = err != error.Note,
        .message = message });
}

fn addNote(self: *const AsmLiveness, token: SourceFile.Token, message: []const u8) !void {
    const message_copy = try self.allocator.dupe(u8, message);
    errdefer self.allocator.free(message_copy);

    try self.bridge.emitError(.{
        .err = error.Note,
        .token = token.inner_token,
        .source_file = token.source_file,
        .is_note = true,
        .is_preview = false,
        .message = message_copy });
}

const Section = AsmSemanticAir.Section;
const Air = AsmSemanticAir.Air;

pub fn analyseSection(self: *const AsmLiveness, section: Section) !void {
    var previous_air: ?Air = null;

    for (section.content.list.items) |air| {
        if (air.op == .padding) {
            if (previous_air) |the_previous_air|
                try self.passUncoordinatedPadding(air, the_previous_air);
            continue;
        }

        defer previous_air = air;

        if (previous_air) |the_previous_air| {
            try self.passUnreachableBody(air, the_previous_air);
            try self.passUncoordinatedData(air, the_previous_air);
        } else {
            try self.passUnreachableSection(section, air);
        }
    }

    try self.passUndefinedControlFlow(previous_air);
}

fn passUncoordinatedPadding(self: *const AsmLiveness, air: Air, previous_air: Air) !void {
    std.debug.assert(air.op == .padding);
    if (!previous_air.isJump() and previous_air.op == .instruction) {
        try self.addError(error.UncoordinatedPadding, previous_air.token);
        try self.addError(error.NotePaddingHere, air.token);
    }
}

fn passUnreachableBody(self: *const AsmLiveness, air: Air, previous_air: Air) !void {
    const condition = previous_air.isJump() or
        (previous_air.op == .data and air.op != .data) or
        previous_air.op == .ascii;
    if (!air.is_labeled and condition) {
        try self.addError(error.UnreachableBody, air.token);
        try self.addError(error.NoteDivertedHere, previous_air.token);
    }
}

fn passUncoordinatedData(self: *const AsmLiveness, air: Air, previous_air: Air) !void {
    if (air.op != .instruction and
        previous_air.op == .instruction and
        !previous_air.isJump()
    ) {
        try self.addError(error.UncoordinatedData, previous_air.token);
        try self.addError(error.NoteDefinedHere, air.token);
    }
}

fn passUnreachableSection(self: *const AsmLiveness, section: Section, air: Air) !void {
    if (!air.is_labeled) {
        try self.addError(error.UnreachableBody, air.token);
        try self.addError(error.NoteDefinedHere, section.token);
        try self.addNote(air.token, "use a discarding label if this section is an entrypoint");
    }
}

fn passUndefinedControlFlow(self: *const AsmLiveness, previous_air: ?Air) !void {
    const air = previous_air orelse return;
    if (air.op == .instruction and !air.isJump()) {
        try self.addError(error.UndefinedControlFlow, air.token);
    }
}
