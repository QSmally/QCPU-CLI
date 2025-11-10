
// QCPU Compilation Unit
//
//  A complete assemble/linking pipeline looks like:
//  - allocate/read file                -> buffer
//  - tokenisation                      -> tokens
//  - abstract syntax tree              -> nodes
//    - recursive descent parser
//  - static analysis                   -> symbols
//    - prepare symbols
//    - exchange imports
//  - semantic analysis                 -> sections
//    - <3 of the assembler
//  - liveness
//  - link sections                     -> blocks
//    - reference tree elimination
//    - block and byte generation
//    - address resolution

const std = @import("std");
const SourceLocation = @import("SourceLocation.zig");
const AsmAst = @import("AsmAst.zig");
const AsmSemanticAir = @import("AsmSemanticAir.zig");

const Qcu = @This();

allocator: std.mem.Allocator,
files: FileList,
flags: FlagMap,
options: Options,
work_queue: JobQueue,
errors: ErrorList,
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
        .files = .empty,
        .flags = run_flags,
        .options = options,
        .work_queue = .init(allocator, {}),
        .errors = .empty };
    errdefer qcu.deinit();

    try qcu.files.ensureUnusedCapacity(allocator, file_paths.len);

    for (file_paths) |file_path|
        qcu.files.appendAssumeCapacity(try File.init(qcu, cwd, file_path));
    try qcu.work_queue.add(.{ .link = qcu });

    return qcu;
}

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
    sema: AsmSemanticAir = undefined,

    pub fn init(qcu: *Qcu, cwd: std.fs.Dir, file_path: []const u8) !*AsmFile {
        const file = try qcu.allocator.create(AsmFile);
        errdefer qcu.allocator.destroy(file);

        file.* = .{
            .qcu = qcu,
            .source_location = try SourceLocation.init(qcu.allocator, cwd, ".", file_path) };
        errdefer file.deinit();

        try qcu.work_queue.ensureUnusedCapacity(3);
        qcu.work_queue.add(.{ .static_analysis = file }) catch unreachable;
        qcu.work_queue.add(.{ .semantic_analysis = file }) catch unreachable;

        if (qcu.options.noliveness)
            qcu.work_queue.add(.{ .liveness = file }) catch unreachable;
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

    /// Tokenisation, AstGen and static analysis.
    pub fn static_analysis(self: *AsmFile) !void {
        self.ast = try AsmAst.init(
            self.qcu.allocator,
            &self.source_location,
            .{ .vtable = astTable, .context = self });
        if (self.qcu.options.dast)
            try self.dump("AST", &self.ast);
        if (self.qcu.errors.items.len > 0)
            return error.AbstractSyntaxTree;

        self.sema = AsmSemanticAir.init(
            self.qcu.allocator,
            &self.source_location,
            self.ast.tokens,
            self.ast.nodes,
            .{ .vtable = semaTable, .context = self });
        try self.sema.static_analysis();
        if (self.qcu.errors.items.len > 0)
            return error.StaticAnalysis;
    }

    /// Semantic analysis. Illegal to call when any related objects haven't yet
    /// performed static analysis prior to calling this.
    pub fn semantic_analysis(self: *AsmFile) !void {
        std.debug.assert(self.sema.sections.count() == 0);

        try self.sema.semantic_analysis();
        if (self.qcu.options.dair)
            try self.dump("AIR", &self.sema);
        if (self.qcu.errors.items.len > 0)
            return error.SemanticAnalysis;

        // try self.qcu.linker.append(.{
        //     .source_location = self.source_location,
        //     .sema = self.sema.? });
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

    const semaTable = AsmSemanticAir.Bridge.VTable {
        .emit_error = emit_error,
        .resolve = resolve
    };

    fn emit_error(context: *anyopaque, err: SourceLocation.Error) !void {
        const self: *AsmFile = @alignCast(@ptrCast(context));
        try self.qcu.errors.append(self.qcu.allocator, err);
    }

    fn resolve(context: *anyopaque, file_path: []const u8) !?*AsmSemanticAir {
        const self: *AsmFile = @alignCast(@ptrCast(context));
        _ = self;
        _ = file_path;
        return null;
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

    pub fn deinit(self: File) void {
        switch (self) {
            inline else => |file| file.deinit()
        }
    }
};

const Job = union(enum) {

    static_analysis: *AsmFile,
    semantic_analysis: *AsmFile,
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
            .semantic_analysis => |file| try file.semantic_analysis(),
            .liveness => |file| try file.liveness(),
            .link => |qcu| try qcu.link()
        };
    }
};

pub const Options = struct {
    dast: bool = false,
    dair: bool = false,
    noliveness: bool = false
};

const FileList = std.ArrayListUnmanaged(File);
const FlagMap = *const std.StringArrayHashMapUnmanaged([]const u8);
const JobQueue = std.PriorityQueue(Job, void, Job.before);
const ErrorList = std.ArrayListUnmanaged(SourceLocation.Error);

const stderr = std.io.getStdErr().writer();

pub fn work(self: *Qcu) !void {
    while (self.work_queue.removeOrNull()) |job|
        try job.execute();
}

fn link(self: *Qcu) !void {
    _ = self;
}
