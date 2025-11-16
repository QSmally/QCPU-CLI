
// QCPU Compilation Unit
//
//  A complete assemble/linking pipeline looks like:
//  - allocate/read file                -> buffer
//  - tokenisation                      -> tokens
//  - abstract syntax tree              -> nodes
//      - recursive descent parser
//  - intermediate representation gen   -> ir blocks, symbols, imports
//  - semantic analysis                 -> air blocks
//      - <3 of the assembler
//      - lazy evaluation
//  - liveness
//      - point out stupid assembly
//  - link sections                     -> sections
//      - byte layout
//      - byte gen
//      - address resolution

const std = @import("std");
const SourceLocation = @import("SourceLocation.zig");
const AsmAst = @import("AsmAst.zig");
const AsmIr = @import("AsmIr.zig");
const AsmSemanticAir = @import("AsmSemanticAir.zig");

const Qcu = @This();

allocator: std.mem.Allocator,
flags: FlagMap,
options: Options,
files: std.ArrayListUnmanaged(File) = .empty,
work_queue: std.PriorityQueue(Job, void, Job.before),
/// [file index] << 16 | [block index]
semantically_analysed: std.AutoHashMapUnmanaged(u32, void) = .empty,
/// [file index]
liveness_analysed: std.AutoHashMapUnmanaged(u32, void) = .empty,
errors: std.ArrayListUnmanaged(SourceLocation.Error) = .empty,
// linker: Linker,

/// Each run of QCPU-CLI contains exactly one Compilation Unit, responsible for
/// static analysis, semantic analysis, liveness and linking. It forms one
/// virtual memory layout.
pub fn init(
    allocator: std.mem.Allocator,
    cwd: std.fs.Dir,
    file_paths: []const []const u8,
    run_flags: FlagMap,
    options: Options
) !*Qcu {
    const qcu = try allocator.create(Qcu);
    errdefer allocator.destroy(qcu);

    qcu.* = .{
        .allocator = allocator,
        .flags = run_flags,
        .options = options,
        .work_queue = .init(allocator, {}) };
    errdefer qcu.deinit();

    try qcu.files.ensureUnusedCapacity(allocator, file_paths.len);

    for (file_paths) |file_path|
        qcu.files.appendAssumeCapacity(try File.init(qcu, cwd, file_path));
    try qcu.work_queue.add(.{ .link = qcu });

    return qcu;
}

const FlagMap = *const std.StringArrayHashMapUnmanaged([]const u8);

pub fn deinit(self: *Qcu) void {
    for (self.files.items) |file|
        file.deinit();
    self.files.deinit(self.allocator);
    self.work_queue.deinit();
    for (self.errors.items) |err|
        err.deinit(self.allocator);
    self.errors.deinit(self.allocator);
    self.allocator.destroy(self);
}

const AsmFile = struct {

    qcu: *Qcu,
    source_location: SourceLocation,
    ast: AsmAst = undefined,
    ir: AsmIr = undefined,
    sema: AsmSemanticAir = undefined,

    pub fn init(qcu: *Qcu, cwd: std.fs.Dir, file_path: []const u8) !*AsmFile {
        const file = try qcu.allocator.create(AsmFile);
        errdefer qcu.allocator.destroy(file);

        const source_location = try SourceLocation.init(qcu.allocator, cwd, ".", file_path);
        errdefer source_location.deinit(qcu.allocator);

        file.qcu = qcu;
        file.source_location = source_location;
        try qcu.work_queue.add(.{ .static_analysis = file });
        return file;
    }

    pub fn deinit(self: *AsmFile) void {
        self.source_location.deinit(self.qcu.allocator);
        self.qcu.allocator.destroy(self);
    }

    fn dump(self: *AsmFile, tag: []const u8, thing: anytype) !void {
        try stderr.print("{s} ({s}):\n", .{ tag, self.source_location.real_path });
        try thing.dump(self.qcu.allocator, stderr);
    }

    // Assemble passes

    /// Tokenisation, AstGen and IrGen (static analysis).
    pub fn static_analysis(self: *AsmFile) !void {
        self.ast = try AsmAst.init(
            self.qcu.allocator,
            &self.source_location,
            .{ .vtable = astTable, .context = self });
        if (self.qcu.options.dast)
            try self.dump("AST", &self.ast);
        if (self.qcu.errors.items.len > 0)
            return error.AbstractSyntaxTree;

        self.ir = try AsmIr.init(
            self.qcu.allocator,
            &self.source_location,
            &self.ast,
            .{ .vtable = irTable, .context = self });
        if (self.qcu.options.dir)
            try self.dump("IR", &self.ir);
        if (self.qcu.errors.items.len > 0)
            return error.StaticAnalysis;

        self.sema = AsmSemanticAir.init(
            self.qcu.allocator,
            &self.source_location,
            &self.ast,
            &self.ir,
            .{ .vtable = semaTable, .context = self });
        // if (root_section or noelimination) {
        //     try qcu.work_queue.add(.{ .semantic_analysis = file });

        //     if (qcu.options.noliveness)
        //         qcu.work_queue.add(.{ .liveness = file }) catch unreachable;
        // }
    }

    /// Semantic analysis. Illegal to call when any related objects haven't yet
    /// performed static analysis prior to calling this. Semantic analysis
    /// only evaluates one block, which queues other analysis processes.
    pub fn semantic_analysis(self: *AsmFile, block: AsmIr.Index) !void {
        try self.sema.analyse_block(block);

        if (self.qcu.options.dair)
            try self.dump("AIR", &self.sema);
        if (self.qcu.errors.items.len > 0)
            return error.SemanticAnalysis;
    }

    /// Liveness pass. Illegal to call when the file isn't semantically
    /// analysed yet.
    pub fn liveness(self: *AsmFile) !void {
        _ = self;
    }

    // Interfaces

    const astTable = AsmAst.Bridge.VTable {
        .emit_error = emit_error
    };

    const irTable = AsmIr.Bridge.VTable {
        .emit_error = emit_error,
        .flag = flag,
        .import = import
    };

    const semaTable = AsmSemanticAir.Bridge.VTable {
        .emit_error = emit_error,
        .file_evaluation_context = file_evaluation_context,
        .ensure_block_analysis = ensure_block_analysis
    };

    fn emit_error(context: *anyopaque, err: SourceLocation.Error) !void {
        const self: *AsmFile = @alignCast(@ptrCast(context));
        try self.qcu.errors.append(self.qcu.allocator, err);
    }

    fn flag(context: *anyopaque, name: []const u8) ?isize {
        const self: *AsmFile = @alignCast(@ptrCast(context));
        _ = self;
        _ = name;
        return null;
    }

    fn import(context: *anyopaque, file_path: []const u8) !AsmIr.Index {
        const self: *AsmFile = @alignCast(@ptrCast(context));
        try self.qcu.work_queue.ensureUnusedCapacity(1);
        try self.qcu.files.ensureUnusedCapacity(self.qcu.allocator, 1);

        const source_location = try self.source_location.init_from(self.qcu.allocator, file_path);
        errdefer source_location.deinit(self.qcu.allocator);

        for (self.qcu.files.items, 0..) |existing_file, file_index| {
            if (!source_location.eql(existing_file.source_location()))
                continue;
            if (self.source_location.eql(existing_file.source_location()))
                return error.SelfImport;
            source_location.deinit(self.qcu.allocator);
            errdefer comptime unreachable;
            return @intCast(file_index);
        }

        const extension = std.fs.path.extension(file_path);

        if (!std.mem.eql(u8, extension, ".s"))
            return error.SemanticsNotSupported;

        const file = try self.qcu.allocator.create(AsmFile);
        errdefer self.qcu.allocator.destroy(file);

        file.qcu = self.qcu;
        file.source_location = source_location;

        errdefer comptime unreachable;
        const file_index: AsmIr.Index = @intCast(self.qcu.files.items.len);
        self.qcu.work_queue.add(.{ .static_analysis = file }) catch unreachable;
        self.qcu.files.appendAssumeCapacity(.{ .@"asm" = file });

        return file_index;
    }

    fn file_evaluation_context(context: *anyopaque, index: AsmIr.Index) !?*AsmSemanticAir {
        const self: *AsmFile = @alignCast(@ptrCast(context));
        _ = self;
        _ = index;
        return null;
    }

    fn ensure_block_analysis(context: *anyopaque, index: AsmIr.Index, block_index: AsmIr.Index) !void {
        const self: *AsmFile = @alignCast(@ptrCast(context));
        _ = self;
        _ = index;
        _ = block_index;
    }
};

const File = union(enum) {

    @"asm": *AsmFile,
    // bin: *BinFile,

    pub fn init(qcu: *Qcu, cwd: std.fs.Dir, file_path: []const u8) !File {
        const extension = std.fs.path.extension(file_path);

        if (std.mem.eql(u8, extension, ".s"))
            return .{ .@"asm" = try AsmFile.init(qcu, cwd, file_path) };
        return error.FileTypeNotSupported;
    }

    pub fn source_location(self: File) *const SourceLocation {
        return switch (self) {
            inline else => |file| &file.source_location
        };
    }

    pub fn deinit(self: File) void {
        switch (self) {
            inline else => |file| file.deinit()
        }
    }
};

const Job = union(enum) {

    static_analysis: *AsmFile,
    semantic_analysis: struct { *AsmFile, u32 },
    liveness: *AsmFile,
    link: *Qcu,

    pub fn before(_: void, self: Job, other: Job) std.math.Order {
        const me = @intFromEnum(self);
        const you = @intFromEnum(other);
        return std.math.order(me, you);
    }

    comptime {
        std.debug.assert(before({}, .{ .static_analysis = undefined }, .{ .semantic_analysis = undefined }) == .lt);
    }

    pub fn execute(self: Job) !void {
        return switch (self) {
            .static_analysis => |file| try file.static_analysis(),
            .semantic_analysis => |t| try t[0].semantic_analysis(t[1]),
            .liveness => |file| try file.liveness(),
            .link => |qcu| try qcu.link()
        };
    }
};

pub const Options = struct {
    dast: bool = false,
    dir: bool = false,
    dair: bool = false,
    noliveness: bool = false
};

const stderr = std.io.getStdErr().writer();

pub fn work(self: *Qcu) !void {
    while (self.work_queue.removeOrNull()) |job|
        try job.execute();
}

fn link(self: *Qcu) !void {
    _ = self;

    // try self.qcu.linker.append(.{
    //     .source_location = self.source_location,
    //     .sema = self.sema.? });
}
