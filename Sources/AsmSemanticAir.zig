
// Semantic Analysed Intermediate Representation

const std = @import("std");
const SourceLocation = @import("SourceLocation.zig");
const AsmAst = @import("AsmAst.zig");
const AsmIr = @import("AsmIr.zig");
const Token = @import("Token.zig");
const Instruction = @import("Instruction.zig");
const Section = @import("Section.zig");

const AsmSemanticAir = @This();

allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
source_location: *const SourceLocation,
tree: *const AsmAst,
ir: *const AsmIr,
bridge: Bridge,

sections: Section.Map = .empty,
current_section: ?*Section = null,
/// Semantic Analysis unit which instantiated and manages this unit.
parent: ?*AsmSemanticAir = null,

/// Borrows the Abstract Syntax Tree and Intermediate Representation, and
/// initialises a Semantic Analysis unit in its context. A specific
/// `analyse_block` call must be done in order to add an analysed section.
pub fn init(
    allocator: std.mem.Allocator,
    source_location: *const SourceLocation,
    tree: *const AsmAst,
    ir: *const AsmIr,
    bridge: Bridge
) AsmSemanticAir {
    return .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .source_location = source_location,
        .tree = tree,
        .ir = ir,
        .bridge = bridge };
}

pub fn deinit(self: *AsmSemanticAir) void {
    self.arena.deinit();
}

pub fn dump(self: *AsmSemanticAir, _: std.mem.Allocator, writer: anytype) !void {
    _ = self;
    _ = writer;
}

pub const Bridge = struct {

    const AllocatorError = std.mem.Allocator.Error;

    pub const VTable = struct {
        emit_error: *const fn (*anyopaque, SourceLocation.Error) AllocatorError!void,
        file_evaluation_context: *const fn (*anyopaque, AsmIr.Index) AllocatorError!?*AsmSemanticAir,
        ensure_block_analysis: *const fn (*anyopaque, AsmIr.Index, AsmIr.Index) AllocatorError!void
    };

    vtable: VTable,
    context: *anyopaque,

    fn emit_error(self: *Bridge, err: SourceLocation.Error) !void {
        try self.vtable.emit_error(self.context, err);
    }

    fn file_evaluation_context(self: *Bridge, file_path: []const u8) !?*AsmSemanticAir {
        return try self.vtable.file_evaluation_context(self.context, file_path);
    }

    fn ensure_block_analysis(self: *Bridge, index: AsmIr.Index, block_index: AsmIr.Index) !void {
        try self.vtable.ensure_block_analysis(self.context, index, block_index);
    }
};

pub const Error = error {
    Expected,
    NoteCalledFromHere,
    NoteDefinedHere,
    Note
};

fn add_error(
    self: *AsmSemanticAir,
    token: Token,
    comptime err: Error,
    comptime format: []const u8,
    arguments: anytype
) !void {
    @branchHint(.cold);

    const message = try std.fmt.allocPrint(self.allocator, format, arguments);
    errdefer self.allocator.free(message);

    const is_note = switch (err) {
        error.NoteCalledFromHere,
        error.NoteDefinedHere,
        error.Note => true,
        else => false
    };

    try self.bridge.emit_error(.{
        .err = err,
        .token = token,
        .source_location = self.source_location,
        .is_note = is_note,
        .is_preview = err != error.Note,
        .message = message });
}

const ParseError = std.mem.Allocator.Error;

pub fn analyse_block(self: *AsmSemanticAir, block: AsmIr.Index) ParseError!void {
    const section = self.ir.blocks[block];
    std.log.debug("analyse_block({s}, {s}({}))", .{ self.source_location.file_name, section.name, block });
    // try self.bridge.ensure_block_analysis(0, 2);
}

// Tests

const build_options = @import("options");

const TestBridge = struct {

    allocator: std.mem.Allocator,
    errors: std.ArrayListUnmanaged(SourceLocation.Error) = .empty,

    pub fn deinit(self: *TestBridge) void {
        for (self.errors.items) |err|
            self.allocator.free(err.message);
        self.errors.deinit(self.allocator);
    }

    const semaTable = Bridge.VTable {
        .emit_error = emit_error,
        .file_evaluation_context = file_evaluation_context,
        .ensure_block_analysis = ensure_block_analysis
    };

    fn emit_error(context: *anyopaque, err: SourceLocation.Error) !void {
        const self: *TestBridge = @alignCast(@ptrCast(context));
        try self.errors.append(self.allocator, err);
    }

    fn file_evaluation_context(context: *anyopaque, index: AsmIr.Index) !?*AsmSemanticAir {
        _ = context;
        _ = index;
        return null;
    }

    fn ensure_block_analysis(context: *anyopaque, index: AsmIr.Index, block_index: AsmIr.Index) !void {
        _ = context;
        _ = index;
        _ = block_index;
    }

    pub fn bridge(self: *TestBridge) Bridge {
        return .{ .vtable = semaTable, .context = self };
    }
};
