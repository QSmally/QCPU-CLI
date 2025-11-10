
// Semantic Analysed Intermediate Representation

const std = @import("std");
const SourceLocation = @import("SourceLocation.zig");
const AsmAst = @import("AsmAst.zig");
const Token = @import("Token.zig");
const Instruction = @import("Instruction.zig");
const Section = @import("Section.zig");

const AsmSemanticAir = @This();

allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
source_location: *const SourceLocation,
/// Borrowed from AsmAst.
tokens: []const Token,
/// Borrowed from AsmAst.
nodes: []const AsmAst.Node,
sections: Section.Map,
current_section: ?*Section,
/// Semantic Analysis unit which instantiated and manages this unit.
parent: ?*AsmSemanticAir,
/// Emitting reference.
bridge: Bridge,

/// Borrows a list of tokens and nodes (from an Abstract Syntax Tree) and
/// initialises a Semantic Analysis unit in its context.
pub fn init(
    allocator: std.mem.Allocator,
    source_location: *const SourceLocation,
    tokens: []const Token,
    nodes: []const AsmAst.Node,
    bridge: Bridge
) AsmSemanticAir {
    return .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .source_location = source_location,
        .tokens = tokens,
        .nodes = nodes,
        .sections = .empty,
        .current_section = null,
        .parent = null,
        .bridge = bridge };
}

pub fn deinit(self: *AsmSemanticAir) void {
    self.arena.deinit();
}

pub fn dump(self: *AsmSemanticAir, _: std.mem.Allocator, writer: anytype) !void {
    _ = self;
    _ = writer;
}

const Symbol = struct {

    token: SourceLocation.Token,
    name: []const u8,
    the_type: union(enum) {
        file
    }
};

pub const Bridge = struct {

    const AllocatorError = std.mem.Allocator.Error;
    const OpenError = std.fs.File.OpenError;

    pub const VTable = struct {
        emit_error: *const fn (*anyopaque, SourceLocation.Error) AllocatorError!void,
        resolve: *const fn (*anyopaque, []const u8) (AllocatorError || OpenError)!?*AsmSemanticAir
    };

    vtable: VTable,
    context: *anyopaque,

    fn emit_error(self: *Bridge, err: SourceLocation.Error) !void {
        try self.vtable.emit_error(self.context, err);
    }

    fn resolve(self: *Bridge, file_path: []const u8) !?*AsmSemanticAir {
        try self.vtable.resolve(self.context, file_path);
    }
};

pub const SemanticError = error {
    Expected
};

fn add_error(
    self: *AsmSemanticAir,
    token: SourceLocation.Token,
    comptime err: SemanticError,
    comptime format: []const u8,
    arguments: anytype
) !void {
    @branchHint(.cold);

    const message = try std.fmt.allocPrint(self.allocator, format, arguments);
    errdefer self.allocator.free(message);

    try self.bridge.emit_error(.{
        .err = err,
        .token = token.inner_token,
        .source_location = token.source_location,
        .is_note = false,
        .is_preview = true,
        .message = message });
}

pub const SemanticNote = error {
    NoteDefinedHere,
    NoteCalledFromHere
};

fn add_note(
    self: *AsmSemanticAir,
    token: SourceLocation.Token,
    comptime err: SemanticNote,
    comptime format: []const u8,
    arguments: anytype
) !void {
    @branchHint(.cold);

    const message = try std.fmt.allocPrint(self.allocator, format, arguments);
    errdefer self.allocator.free(message);

    const is_preview = switch (err) {
        else => true
    };

    try self.bridge.emit_error(.{
        .err = err,
        .token = token.inner_token,
        .source_location = token.source_location,
        .is_note = true,
        .is_preview = is_preview,
        .message = message });
}

pub const Error = SemanticError || SemanticNote;

inline fn astgen_assert(ok: bool) void {
    if (!ok) astgen_failure();
}

inline fn astgen_failure() noreturn {
    @panic("AstGen failed to comply to AsmSemanticAir assumption");
}

const ParseError = std.mem.Allocator.Error;

pub fn static_analysis(self: *AsmSemanticAir) ParseError!void {
    _ = self;
}

pub fn semantic_analysis(self: *AsmSemanticAir) ParseError!void {
    _ = self;
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
        .resolve = resolve
    };

    fn emit_error(context: *anyopaque, err: SourceLocation.Error) !void {
        const self: *TestBridge = @alignCast(@ptrCast(context));
        try self.errors.append(self.allocator, err);
    }

    fn resolve(context: *anyopaque, file_path: []const u8) !?*AsmSemanticAir {
        _ = context;
        _ = file_path;
        return null;
    }

    pub fn bridge(self: *TestBridge) Bridge {
        return .{ .vtable = semaTable, .context = self };
    }
};
