
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
/// [file index] << 32 | [block index]
semantically_analysed: std.AutoHashMapUnmanaged(u64, void) = .empty,
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

    qcu.* = .{
        .allocator = allocator,
        .flags = run_flags,
        .options = options,
        .work_queue = .init(allocator, {}) };
    errdefer qcu.deinit();

    try qcu.files.ensureUnusedCapacity(allocator, file_paths.len);

    for (file_paths) |file_path|
        try File.add(qcu, cwd, file_path);
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
    index: AsmIr.Index,
    ast: ?AsmAst = null,
    ir: ?AsmIr = null,

    pub fn add(qcu: *Qcu, cwd: std.fs.Dir, file_path: []const u8) !void {
        const file = try qcu.allocator.create(AsmFile);
        errdefer qcu.allocator.destroy(file);

        try qcu.files.ensureUnusedCapacity(qcu.allocator, 1);
        try qcu.work_queue.ensureUnusedCapacity(1);

        const source_location = try SourceLocation.init(qcu.allocator, cwd, ".", file_path);
        errdefer source_location.deinit(qcu.allocator);

        file.* = .{
            .qcu = qcu,
            .source_location = source_location,
            .index = @intCast(qcu.files.items.len) };
        qcu.files.appendAssumeCapacity(.{ .@"asm" = file });
        qcu.work_queue.add(.{ .static_analysis = file }) catch unreachable;
    }

    pub fn deinit(self: *AsmFile) void {
        if (self.ast) |*ast| ast.deinit(self.qcu.allocator);
        if (self.ir) |*ir| ir.deinit(self.qcu.allocator);
        self.source_location.deinit(self.qcu.allocator);
        self.qcu.allocator.destroy(self);
    }

    fn dump(self: *AsmFile, tag: []const u8, thing: anytype) !void {
        try stderr.print("{s} ({s}):\n", .{ tag, self.source_location.real_path });
        try thing.dump(self.qcu.allocator, stderr);
    }

    fn create_semantic_analysis(self: *AsmFile, namespace: []const u8) AsmSemanticAir {
        return AsmSemanticAir.init(
            self.qcu.allocator,
            &self.source_location,
            &self.ast.?,
            &self.ir.?,
            namespace,
            .{ .vtable = semaTable, .context = self });
    }

    /// Any root section, noelimination or global noelimination section.
    fn activate_initable_sections(self: *AsmFile) !void {
        std.debug.assert(self.ir != null);
        const root_section = self.qcu.options.rootsection orelse "root";

        next: for (self.ir.?.blocks, 0..) |block, i| {
            activate: {
                if (self.qcu.options.noelimination)
                    break :activate;
                if (std.mem.eql(u8, block.name, root_section))
                    break :activate;
                switch (block.ty) {
                    .section => |section| if (section.is_noelimination)
                        break :activate else
                        continue :next,
                    .header => continue :next
                }
                comptime unreachable;
            }

            const block_index: AsmIr.Index = @intCast(i);
            try self.qcu.work_queue.add(.{ .semantic_analysis = .{ self, block_index } });
        }
    }

    fn block_id(self: *AsmFile, block: AsmIr.Index) u64 {
        const file_index: u64 = @intCast(self.index);
        const block_index: u64 = @intCast(block);
        return (file_index << 32) | block_index;
    }

    // Assemble passes

    /// Tokenisation, AstGen and IrGen (static analysis).
    pub fn static_analysis(self: *AsmFile) !void {
        std.debug.assert(self.ast == null);
        std.debug.assert(self.ir == null);

        self.ast = try AsmAst.init(
            self.qcu.allocator,
            &self.source_location,
            .{ .vtable = astTable, .context = self });
        if (self.qcu.options.dast)
            try self.dump("AST", &self.ast.?);
        if (self.qcu.errors.items.len > 0)
            return error.AbstractSyntaxTree;

        self.ir = try AsmIr.init(
            self.qcu.allocator,
            &self.source_location,
            &self.ast.?,
            .{ .vtable = irTable, .context = self });
        if (self.qcu.options.dir)
            try self.dump("IR", &self.ir.?);
        if (self.qcu.errors.items.len > 0)
            return error.StaticAnalysis;
        try self.activate_initable_sections();
    }

    pub fn link_script(self: *AsmFile) !void {
        var sema = self.create_semantic_analysis(self.source_location.qualified_namespace());
        defer sema.deinit();
        const link_info = try sema.analyse_link_script();
        _ = link_info;
        // TODO: add linkinfo to linker
    }

    /// Semantic analysis. Illegal to call when any related objects haven't yet
    /// performed static analysis prior to calling this. Semantic analysis
    /// only evaluates one block, which queues other analysis processes.
    pub fn semantic_analysis(self: *AsmFile, block: AsmIr.Index) !void {
        const the_block_id = self.block_id(block);
        if (self.qcu.semantically_analysed.contains(the_block_id)) return;

        var sema = self.create_semantic_analysis(self.source_location.qualified_namespace());
        defer sema.deinit();

        sema.analyse_block(block) catch |err| switch (err) {
            // error.AnalysisFail => std.debug.assert(self.qcu.errors.items.len > 0),
            else => |the_err| return the_err
        };

        if (self.qcu.options.dair)
            try self.dump("AIR", &sema);
        if (self.qcu.errors.items.len > 0)
            return error.SemanticAnalysis;
        try self.qcu.semantically_analysed.put(self.qcu.allocator, the_block_id, {});
        // TODO: own generated section and push to linker

        if (!self.qcu.options.noliveness) {
            try self.qcu.work_queue.add(.{ .liveness = .{ self, block } });
        }
    }

    /// Liveness pass. Illegal to call when the file isn't semantically
    /// analysed yet.
    pub fn liveness(self: *AsmFile, block: AsmIr.Index) !void {
        _ = self;
        _ = block;
        // TODO: liveness
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
        .file_context = file_context,
        .ensure_block_analysed = ensure_block_analysed
    };

    fn emit_error(context: *anyopaque, err: SourceLocation.Error) !void {
        const self: *AsmFile = @alignCast(@ptrCast(context));
        try self.qcu.errors.append(self.qcu.allocator, err);
    }

    fn flag(context: *anyopaque, name: []const u8) ?i32 {
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
        errdefer comptime unreachable;

        file.* = .{
            .qcu = self.qcu,
            .source_location = source_location,
            .index = @intCast(self.qcu.files.items.len) };

        const file_index: AsmIr.Index = @intCast(self.qcu.files.items.len);
        self.qcu.files.appendAssumeCapacity(.{ .@"asm" = file });
        self.qcu.work_queue.add(.{ .static_analysis = file }) catch unreachable;
        return file_index;
    }

    fn file_context(context: *anyopaque, index: AsmIr.Index, namespace: []const u8) AsmSemanticAir {
        const self: *AsmFile = @alignCast(@ptrCast(context));
        const other_file = self.qcu.files.items[index];
        std.debug.assert(other_file == .@"asm");
        return other_file.@"asm".create_semantic_analysis(namespace);
    }

    fn ensure_block_analysed(context: *anyopaque, index: AsmIr.Index, block_index: AsmIr.Index) !void {
        const self: *AsmFile = @alignCast(@ptrCast(context));
        const file = self.qcu.files.items[index];
        std.debug.assert(file == .@"asm");

        const job: Job = .{ .semantic_analysis = .{ file.@"asm", block_index } };
        try self.qcu.work_queue.add(job);
    }
};

const File = union(enum) {

    @"asm": *AsmFile,
    // bin: *BinFile,

    pub fn add(qcu: *Qcu, cwd: std.fs.Dir, file_path: []const u8) !void {
        const extension = std.fs.path.extension(file_path);

        if (std.mem.eql(u8, extension, ".s"))
            return try AsmFile.add(qcu, cwd, file_path);
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
    link_script: *AsmFile,
    semantic_analysis: struct { *AsmFile, AsmIr.Index },
    liveness: struct { *AsmFile, AsmIr.Index },
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
            .link_script => |file| try file.link_script(),
            .semantic_analysis => |t| try t[0].semantic_analysis(t[1]),
            .liveness => |t| try t[0].liveness(t[1]),
            .link => |qcu| try qcu.link()
        };
    }
};

pub const Options = struct {
    dast: bool = false,
    dir: bool = false,
    dair: bool = false,
    noliveness: bool = false,
    noelimination: bool = false,
    rootsection: ?[]const u8 = null
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
