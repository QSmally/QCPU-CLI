
// QCPU Compilation Unit
//
//  A complete assemble/linking pipeline:
//
//  - Allocate/read file                -> buffer
//  - Tokenisation                      -> tokens
//  - Abstract Syntax Tree              -> AST nodes
//      - recursive descent parser
//  - Intermediate Representation gen   -> IR blocks, symbols, imports
//  - Semantic Analysis                 -> AIR blocks
//      - <3 of the assembler
//      - lazy evaluation
//      - compute expression tree
//  - Liveness
//      - point out stupid assembly
//  - Linker                            -> sections
//      - section layouts
//      - lazy address resolution
//      - word gen

const std = @import("std");
const indexable_list = @import("indexable_list.zig");
const SourceFile = @import("SourceFile.zig");
const Error = @import("Error.zig");
const AsmAst = @import("AsmAst.zig");
const AsmIr = @import("AsmIr.zig");
const AsmSemanticAir = @import("AsmSemanticAir.zig");
const AsmLiveness = @import("AsmLiveness.zig");
const Linker = @import("Linker.zig");

const Qcu = @This();

io: std.Io,
allocator: std.mem.Allocator,
options: Options,
stderr: *std.Io.Writer,
linker: Linker,
work_queue: std.PriorityQueue(Job, void, Job.before) = .empty,
files: File.List = .empty,
errors: std.ArrayListUnmanaged(Error) = .empty,
semantically_analysed: std.AutoHashMapUnmanaged(u64, void) = .empty,

const log = std.log.scoped(.Qcu);

// Each module contains exactly one Compilation Unit, responsible for static
// analysis, semantic analysis, liveness and linking. It forms one memory
// layout. Its output can be combined with other Compilation Units to form a
// memory layout consisting of multiple independent binaries.
pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    pwd: std.Io.Dir,
    root_file_path: []const u8,
    options: Options,
    stderr: *std.Io.Writer
) !*Qcu {
    const qcu = try allocator.create(Qcu);

    qcu.* = .{
        .io = io,
        .allocator = allocator,
        .options = options,
        .stderr = stderr,
        .linker = .init(allocator) };
    errdefer qcu.deinit();

    try File.add(qcu, pwd, root_file_path);
    try qcu.work_queue.push(allocator, .{ .link = qcu });

    return qcu;
}

pub fn deinit(self: *Qcu) void {
    self.work_queue.deinit(self.allocator);
    for (self.files.list.items) |file|
        file.deinit();
    self.files.deinit(self.allocator);
    for (self.errors.items) |err|
        err.deinit(self.allocator);
    self.errors.deinit(self.allocator);
    self.semantically_analysed.deinit(self.allocator);
    // Self-destruct
    self.allocator.destroy(self);
}

pub const Options = struct {
    dast: bool = false,
    dir: bool = false,
    dair: bool = false,
    dlinker: bool = false,
    noliveness: bool = false,
    noelimination: bool = false,
    rootsection: []const u8 = "root"
};

pub const File = struct {

    qcu: *Qcu,
    index: List.Index,
    source_file: SourceFile,

    ast: ?AsmAst = null,
    ir: ?AsmIr = null,

    pub const List = indexable_list.IndexableList(*File);

    pub fn add(qcu: *Qcu, pwd: std.Io.Dir, file_path: []const u8) !void {
        const file = try qcu.allocator.create(File);
        errdefer qcu.allocator.destroy(file);

        try qcu.files.ensureUnusedCapacity(qcu.allocator, 1);
        try qcu.work_queue.ensureUnusedCapacity(qcu.allocator, 1);

        const source_file = try SourceFile.init(qcu.io, qcu.allocator, pwd, ".", file_path);
        errdefer source_file.deinit(qcu.allocator);

        const file_type = source_file.fileType();

        log.debug("add file {s} (file type {s})", .{ source_file.real_path, @tagName(file_type) });

        file.* = .{
            .qcu = qcu,
            .source_file = source_file,
            .index = .at(qcu.files.len()) };

        const job: Job = switch (file_type) {
            .assembly => .{ .static_analysis = file },
            .unknown => return error.FileTypeNotSupported
        };

        qcu.work_queue.push(qcu.allocator, job) catch unreachable;
        qcu.files.appendAssumeCapacity(file);
    }

    pub fn deinit(self: *File) void {
        if (self.ir) |*ir| ir.deinit(self.qcu.allocator);
        if (self.ast) |*ast| ast.deinit(self.qcu.allocator);
        self.source_file.deinit(self.qcu.allocator);
        // Self-destruct
        self.qcu.allocator.destroy(self);
    }

    fn dump(self: *const File, tag: []const u8, thing: anytype) !void {
        defer self.qcu.stderr.flush() catch {};
        try self.qcu.stderr.print("{s} ({s}):\n", .{ tag, self.source_file.real_path });
        try thing.dump(self.qcu.allocator, self.qcu.stderr);
    }

    // Tokenisation, AstGen, and IrGen (per-file static analysis).
    pub fn staticAnalysis(self: *File) !void {
        std.debug.assert(self.ast == null);
        std.debug.assert(self.ir == null);

        log.debug("static analysis {s}", .{ self.source_file.fileName() });

        self.ast = try AsmAst.init(
            self.qcu.allocator,
            &self.source_file,
            .{ .vtable = astTable, .context = self });

        if (self.qcu.options.dast)
            try self.dump("AST", &self.ast.?);
        if (self.qcu.errors.items.len > 0)
            return error.Break;

        self.ir = try AsmIr.init(
            self.qcu.allocator,
            &self.source_file,
            &self.ast.?,
            .{ .vtable = irTable, .context = self });

        if (self.qcu.options.dir)
            try self.dump("IR", &self.ir.?);
        if (self.qcu.errors.items.len > 0)
            return error.Break;

        const root_section = self.qcu.options.rootsection;

        for (self.ir.?.blocks.items, 0..) |block, index| {
            const evaluate = switch (block.ty) {
                .section => |section|
                    section.is_noelimination or
                    self.qcu.options.noelimination or
                    std.mem.eql(u8, block.name, root_section),
                .header => false
            };

            log.debug("block[{}] {s}{s}", .{
                index,
                block.name,
                if (evaluate) " EVALUATE" else "" });

            if (evaluate) {
                const block_index: AsmIr.Block.List.Index = .at(@intCast(index));
                try self.qcu.work_queue.push(self.qcu.allocator, .{ .semantic_analysis = .{ self, block_index } });
            }
        }
    }

    // Semantic analysis is the heart of the QCPU 2 assembler. Illegal to call
    // when any related files haven't performed static analysis prior to
    // calling this. Semantic analysis only evaluates one block, which queues
    // other semantic analysis processes. This is done lazily; only the root
    // section as well as noelimination sections are initially evaluated.
    pub fn semanticAnalysis(self: *File, block_index: AsmIr.Block.List.Index) !void {
        std.debug.assert(self.ast != null);
        std.debug.assert(self.ir != null);

        const block_id = self.blockId(block_index);
        if (self.qcu.semantically_analysed.contains(block_id)) return;
        try self.qcu.semantically_analysed.put(self.qcu.allocator, block_id, {});

        log.debug("semantic analysis {}", .{ block_index.raw() });

        const namespace = self.source_file.qualifiedNamespace();
        var sema = self.createSemanticAnalyser(namespace);
        defer sema.deinit();

        try sema.analyseBlock(block_index);

        std.debug.assert(sema.output == .owned);

        if (self.qcu.options.dair)
            try self.dump("AIR", &sema);
        if (self.qcu.errors.items.len > 0)
            return error.Break;

        const linker_index = try self.qcu.linker.provisionSection(sema.output.owned);

        if (!self.qcu.options.noliveness) {
            try self.qcu.work_queue.push(self.qcu.allocator, .{ .liveness = .{ self, linker_index } });
        }
    }

    fn blockId(self: *const File, block_index: AsmIr.Block.List.Index) u64 {
        const file_untyped_index: u64 = @intCast(self.index.raw());
        const block_untyped_index: u64 = @intCast(block_index.raw());
        return (file_untyped_index << 32) | block_untyped_index;
    }

    fn createSemanticAnalyser(self: *File, namespace: []const u8) AsmSemanticAir {
        return AsmSemanticAir.init(
            self.qcu.allocator,
            self.index,
            &self.source_file,
            &self.ast.?,
            &self.ir.?,
            namespace,
            .{ .vtable = semaTable, .context = self });
    }

    pub fn liveness(self: *File, section_index: Linker.SectionList.Index) !void {
        log.debug("liveness {}", .{ section_index.raw() });
        const section = self.qcu.linker.link_list.get(section_index);
        const instance = AsmLiveness.init(self.qcu.allocator, .{ .vtable = livenessTable, .context = self });

        try instance.analyseSection(section);

        if (self.qcu.errors.items.len > 0)
            return error.Break;
    }

    const astTable = AsmAst.Bridge.VTable {
        .emitError = emitError
    };

    const irTable = AsmIr.Bridge.VTable {
        .emitError = emitError,
        .import = import
    };

    const semaTable = AsmSemanticAir.Bridge.VTable {
        .emitError = emitError,
        .createScope = createScope,
        .ensureBlockAnalysed = ensureBlockAnalysed
    };

    const livenessTable = AsmLiveness.Bridge.VTable {
        .emitError = emitError
    };

    fn emitError(context: *anyopaque, err: Error) !void {
        const self: *File = @alignCast(@ptrCast(context));
        try self.qcu.errors.append(self.qcu.allocator, err);
    }

    fn import(context: *anyopaque, file_path: []const u8) !List.Index {
        const self: *File = @alignCast(@ptrCast(context));
        try self.qcu.work_queue.ensureUnusedCapacity(self.qcu.allocator, 1);
        try self.qcu.files.ensureUnusedCapacity(self.qcu.allocator, 1);

        // TODO: Lazily read into buffer, but keep stat call for eql
        const source_file = try self.source_file.initFrom(self.qcu.io, self.qcu.allocator, file_path);
        errdefer source_file.deinit(self.qcu.allocator);

        for (self.qcu.files.list.items, 0..) |existing_file, file_index| {
            if (!source_file.eql(&existing_file.source_file))
                continue;
            if (self.source_file.eql(&existing_file.source_file))
                return error.CircularImport;

            errdefer comptime unreachable;
            source_file.deinit(self.qcu.allocator);
            return .at(@intCast(file_index));
        }

        const file = try self.qcu.allocator.create(File);
        errdefer self.qcu.allocator.destroy(file);

        const index: File.List.Index = .at(@intCast(self.qcu.files.list.items.len));
        const file_type = source_file.fileType();

        log.debug("resolve file {s} (file type {s})", .{ source_file.real_path, @tagName(file_type) });

        file.* = .{
            .qcu = self.qcu,
            .source_file = source_file,
            .index = index };

        const job: Job = switch (file_type) {
            .assembly => .{ .static_analysis = file },
            .unknown => return error.FileTypeNotSupported
        };

        self.qcu.work_queue.push(self.qcu.allocator, job) catch unreachable;
        self.qcu.files.appendAssumeCapacity(file);
        return index;
    }

    fn createScope(context: *anyopaque, file_index: File.List.Index, namespace: []const u8) AsmSemanticAir {
        const self: *File = @alignCast(@ptrCast(context));
        const other_file = self.qcu.files.get(file_index);
        std.debug.assert(other_file.ir != null);
        return other_file.createSemanticAnalyser(namespace);
    }

    fn ensureBlockAnalysed(
        context: *anyopaque,
        file_index: File.List.Index,
        block_index: AsmIr.Block.List.Index
    ) !void {
        const self: *File = @alignCast(@ptrCast(context));
        log.debug("ensureBlockAnalysed {} {}", .{ file_index.raw(), block_index.raw() });
        const other_file = self.qcu.files.get(file_index);
        std.debug.assert(other_file.ir != null);
        try self.qcu.work_queue.push(self.qcu.allocator, .{ .semantic_analysis = .{ other_file, block_index } });
    }
};

const Job = union(enum) {

    static_analysis: *File,
    semantic_analysis: struct { *File, AsmIr.Block.List.Index },
    liveness: struct { *File, Linker.SectionList.Index },
    link: *Qcu,

    pub fn before(_: void, self: Job, other: Job) std.math.Order {
        const me = @backingInt(self);
        const you = @backingInt(other);
        return std.math.order(me, you);
    }

    pub fn execute(self: Job) !void {
        return switch (self) {
            .static_analysis => |file| try file.staticAnalysis(),
            .semantic_analysis => |obj| try obj[0].semanticAnalysis(obj[1]),
            .liveness => |obj| try obj[0].liveness(obj[1]),
            .link => |qcu| try qcu.linker.performLink()
        };
    }
};

pub fn work(self: *Qcu) !void {
    while (self.work_queue.pop()) |job|
        try job.execute();
}
