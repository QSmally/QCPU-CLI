
// QCPU Compilation Unit

const std = @import("std");
const AsmAst = @import("AsmAst.zig");
const Error = @import("Error.zig");
const Source = @import("Source.zig");

const Qcu = @This();

errors: ErrorList,

/// Each run of QCPU-CLI contains exactly one Qcu. From a list of input files,
/// it performs tokenisation, AstGen, and lastly, both passes of semantic
/// analysis.
pub fn init() Qcu {
    return .{ .errors = .empty };
}

pub const File = struct {

    allocator: std.mem.Allocator,
    qcu: *Qcu,
    pwd: std.fs.Dir,
    filename: []const u8,
    source: Source,
    nodes: []const AsmAst.Node,

    pub fn eql(self: *File, path: []const u8) !bool {
        _ = self;
        _ = path;
        return false;
    }

    pub fn resolve(self: *File, path: []const u8) ![]const u8 {
        _ = self;
        _ = path;
        return "0";
    }

    pub fn add_error(self: *File, err_data: Error) !void {
        try self.qcu.errors.append(self.allocator, .{
            .err = err_data,
            .filename = self.filename,
            .buffer = self.source.buffer });
    }
};

pub const LocatableError = struct {

    err: Error,
    filename: []const u8,
    buffer: []const u8
};

const ErrorList = std.ArrayListUnmanaged(LocatableError);

// Tests

// ...
