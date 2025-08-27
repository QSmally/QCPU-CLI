
// QCPU Compilation Unit
//
//  A complete assemble/linking pipeline looks like:
//  - allocate/read file                -> buffer
//  - tokenisation                      -> tokens
//  - abstract syntax tree              -> nodes
//  - static analysis                   -> symbols
//  - exchange imports
//  - semantic analysis                 -> sections
//  - liveness
//  - reference tree elimination
//  - link sections                     -> blocks

const std = @import("std");
const AsmAst = @import("AsmAst.zig");
const AsmLiveness = @import("AsmLiveness.zig");
const AsmSemanticAir = @import("AsmSemanticAir.zig");
const AsmTokeniser = @import("AsmTokeniser.zig");
const Error = @import("Error.zig");
const Source = @import("Source.zig");
const Linker = @import("Linker.zig");

const Qcu = @This();

const stderr = std.io
    .getStdErr()
    .writer();

allocator: std.mem.Allocator,
cwd: std.fs.Dir,
files: FileList,
link_list: FileList,
options: Options,
work_queue: JobQueue,
errors: ErrorList,
linker: Linker,

/// Each run of QCPU-CLI contains exactly one Qcu. From a list of input files,
/// it performs tokenisation, AstGen, and lastly, both passes of semantic
/// analysis. Filepaths and cwd are borrowed until deinit.
pub fn init(
    allocator: std.mem.Allocator,
    cwd: std.fs.Dir,
    file_paths: []const []const u8,
    options: Options
) !*Qcu {
    const qcu = try allocator.create(Qcu);
    errdefer allocator.destroy(qcu);

    qcu.* = .{
        .allocator = allocator,
        .cwd = cwd,
        .files = .empty,
        .link_list = .empty,
        .options = options,
        .work_queue = .init(allocator, {}),
        .errors = .empty,
        .linker = .init(allocator, options) };
    errdefer qcu.deinit();

    try qcu.files.ensureUnusedCapacity(allocator, file_paths.len);
    for (file_paths) |file_path|
        qcu.files.appendAssumeCapacity(try File.init_work(qcu, cwd, file_path));
    try qcu.work_queue.add(.{ .link_generate = qcu });

    return qcu;
}

pub fn deinit(self: *Qcu) void {
    for (self.files.items) |file|
        file.deinit();
    self.files.deinit(self.allocator);
    self.link_list.deinit(self.allocator);
    self.work_queue.deinit();
    for (self.errors.items) |lerr|
        self.allocator.free(lerr.err.message);
    self.errors.deinit(self.allocator);
    self.linker.deinit();
    self.allocator.destroy(self);
}

pub const Options = struct {
    dload: bool = false,
    dtokens: bool = false,
    dast: bool = false,
    dair: bool = false,
    dlinker: bool = false,
    noliveness: bool = false,
    noelimination: bool = false,
    noautoalign: bool = false,
    nolinkwarnings: bool = false,
    rootsection: []const u8 = "root"
};

pub const File = struct {

    allocator: std.mem.Allocator,
    qcu: *Qcu,
    pwd: std.fs.Dir,
    file_name: []const u8,
    real_path: []const u8,
    buffer: [:0]const u8,
    sha256: [Sha256.digest_length]u8,

    source: ?Source = null,
    ast: ?AsmAst = null,
    sema: ?AsmSemanticAir = null,

    pub fn init_work(qcu: *Qcu, cwd: std.fs.Dir, file_path: []const u8) !*File {
        const file = try File.init(qcu, cwd, ".", file_path);
        errdefer file.deinit();

        try qcu.work_queue.ensureUnusedCapacity(3);
        qcu.work_queue.add(.{ .static_analysis = file }) catch unreachable;
        qcu.work_queue.add(.{ .semantic_analysis = file }) catch unreachable;

        if (!qcu.options.noliveness)
            qcu.work_queue.add(.{ .liveness = file }) catch unreachable;
        return file;
    }

    fn init_from(self: *Qcu.File, file_path: []const u8) !*File {
        const base_name = std.fs.path.dirname(self.real_path) orelse ".";
        return try File.init(self.qcu, self.pwd, base_name, file_path);
    }

    pub fn init(qcu: *Qcu, cwd: std.fs.Dir, from_path: []const u8, file_path: []const u8) !*File {
        const base_name = std.fs.path.dirname(file_path) orelse ".";
        var pwd = try cwd.openDir(base_name, .{});
        errdefer pwd.close();

        const file_name = std.fs.path.basename(file_path);
        const real_path = try std.fs.path.resolve(qcu.allocator, &.{ from_path, base_name, file_name });
        errdefer qcu.allocator.free(real_path);

        const file = try qcu.allocator.create(File);
        errdefer qcu.allocator.destroy(file);

        file.* = .{
            .allocator = qcu.allocator,
            .qcu = qcu,
            .pwd = pwd,
            .file_name = file_name,
            .real_path = real_path,
            .buffer = undefined,
            .sha256 = undefined };
        file.buffer = try file.get_source();
        file.sha256 = file.get_hash_source();

        if (qcu.options.dload)
            try stderr.print("File load '{s}' ({}) ({s})\n", .{
                file_path,
                std.fmt.fmtIntSizeBin(file.buffer.len),
                std.fmt.bytesToHex(file.sha256, .lower) });
        return file;
    }

    pub fn deinit(self: *File) void {
        if (self.source) |*source| {
            source.deinit();
            self.source = null;
        }
        if (self.ast) |*ast| {
            self.allocator.free(ast.nodes);
            self.ast = null;
        }
        if (self.sema) |*sema| {
            sema.deinit();
            self.sema = null;
        }

        self.pwd.close();
        self.allocator.free(self.real_path);
        self.allocator.free(self.buffer);
        self.allocator.destroy(self);
    }

    fn dump(self: *File, tag: []const u8, thing: anytype) !void {
        try stderr.print("{s} ({s}):\n", .{ tag, self.real_path });
        try thing.dump(stderr);
    }

    // From SemanticAir (and Liveness)

    /// From this file's parent directory, resolves a file path and - if
    /// necessary - adds a static analysis job to the Qcu's work queue.
    pub fn resolve(self: *File, file_path: []const u8) !*?AsmSemanticAir {
        try self.qcu.work_queue.ensureUnusedCapacity(3);
        try self.qcu.files.ensureUnusedCapacity(self.qcu.allocator, 1);
        const file = try File.init_from(self, file_path);
        errdefer file.deinit();

        // fixme: is this really the best way of knowing that two files are the same?
        // what if it's a copy in a different location so @symbols paths don't match up anymore?
        for (self.qcu.files.items) |existing_file| {
            if (!std.mem.eql(u8, &existing_file.sha256, &file.sha256))
                continue;
            file.deinit();
            return &existing_file.sema;
        }

        self.qcu.work_queue.add(.{ .static_analysis = file }) catch unreachable;
        self.qcu.work_queue.add(.{ .semantic_analysis = file }) catch unreachable;
        if (!self.qcu.options.noliveness)
            self.qcu.work_queue.add(.{ .liveness = file }) catch unreachable;
        self.qcu.files.appendAssumeCapacity(file);
        return &file.sema;
    }

    pub fn add_error(self: *File, err_data: Error) !void {
        try self.qcu.errors.append(self.allocator, .{
            .err = err_data,
            .file = self });
    }

    // Assemble passes

    /// Tokenisation, AstGen and first-pass semantic analysis.
    pub fn static_analysis(self: *File) !void {
        std.debug.assert(self.source == null);
        std.debug.assert(self.ast == null);
        std.debug.assert(self.sema == null);

        var tokeniser = AsmTokeniser.init(self.buffer);
        self.source = try Source.init(self.allocator, &tokeniser);
        if (self.qcu.options.dtokens) try self.dump("Tokens", &self.source.?);

        self.ast = try AsmAst.init(self.allocator, self.source.?);
        defer self.ast.?.allocator.free(self.ast.?.errors); // not nodes or error messages
        if (self.qcu.options.dast) try self.dump("AST", &self.ast.?);

        if (self.ast.?.errors.len > 0) {
            try self.qcu.errors.ensureUnusedCapacity(self.allocator, self.ast.?.errors.len);
            for (self.ast.?.errors) |err|
                self.qcu.errors.appendAssumeCapacity(.{ .err = err, .file = self });
            return error.AbstractSyntaxTree;
        }

        std.debug.assert(self.qcu.errors.items.len == 0);

        self.sema = try AsmSemanticAir.init(self, self.source.?, self.ast.?.nodes);
        std.debug.assert(self.sema.?.errors.items.len == 0);
        try self.qcu.verify_errorless_or(error.StaticAnalysis);
        std.debug.assert(self.qcu.errors.items.len == 0);
    }

    /// Second-pass semantic analysis. Illegal to call when any related files
    /// haven't done a static analysis pass prior to calling this routine.
    pub fn semantic_analysis(self: *File) !void {
        std.debug.assert(self.source != null);
        std.debug.assert(self.ast != null);
        std.debug.assert(self.sema != null);
        std.debug.assert(self.sema.?.sections.count() == 0);

        try self.sema.?.semantic_analyse();
        if (self.qcu.options.dair) try self.dump("AIR", &self.sema.?);

        std.debug.assert(self.sema.?.errors.items.len == 0);
        try self.qcu.verify_errorless_or(error.SemanticAnalysis);
        std.debug.assert(self.qcu.errors.items.len == 0);

        // imports aren't added to the link list as they're not being
        // semantically analysed
        try self.qcu.linker.append(self);
    }

    /// Liveness pass. Illegal to call when both passes of semantic analysis
    /// haven't been performed.
    pub fn liveness(self: *File) !void {
        std.debug.assert(self.source != null);
        std.debug.assert(self.sema != null);

        var liveness_pass = try AsmLiveness.init(
            self,
            self.source.?,
            &self.sema.?.symbols,
            &self.sema.?.sections);
        defer liveness_pass.deinit();

        std.debug.assert(liveness_pass.errors.items.len == 0);
        try self.qcu.verify_errorless_or(error.Liveness);
        std.debug.assert(self.qcu.errors.items.len == 0);
    }

    /// Memory returned is owned by caller.
    fn get_source(self: *File) ![:0]const u8 {
        var file = try self.pwd.openFile(self.file_name, .{});
        defer file.close();
        const stat = try file.stat();

        if (stat.size > std.math.maxInt(u32))
            return error.FileTooBig;
        const buffer = try self.allocator.allocSentinel(u8, stat.size, 0);
        errdefer self.allocator.free(buffer);

        if (try file.readAll(buffer) != stat.size)
            return error.UnexpectedEndOfFile;
        return buffer;
    }

    const Sha256 = std.crypto.hash.sha2.Sha256;

    fn get_hash_source(self: *File) [Sha256.digest_length]u8 {
        var result = Sha256.init(.{});
        result.update(self.buffer);
        return result.finalResult();
    }
};

fn verify_errorless_or(self: *Qcu, throw_error: anyerror) !void {
    if (self.errors.items.len > 0)
        return throw_error;
}

pub const LocatableError = struct {

    err: Error,
    file: *const File,

    pub fn write(self: *const LocatableError, writer: anytype) !void {
        try self.err.write(self.file.real_path, self.file.source.?.buffer, writer);
    }
};

pub const JobType = union(enum) {

    /// buffer -> symbols
    /// - tokenisation
    /// - astgen
    /// - first pass semantic analysis
    static_analysis: *File,
    /// buffer + symbols -> sections
    /// - second pass semantic analysis
    semantic_analysis: *File,
    liveness: *File,
    /// sections + sections -> sections
    link_generate: *Qcu,

    /// Jobs higher in the list are performed earlier and at the same time as
    /// each other.
    pub fn before(_: void, self: JobType, other: JobType) std.math.Order {
        const me = @intFromEnum(self);
        const you = @intFromEnum(other);
        return std.math.order(me, you);
    }

    comptime {
        std.debug.assert(before({}, .{ .static_analysis = undefined }, .{ .semantic_analysis = undefined }) == .lt);
    }

    pub fn execute(self: JobType) !void {
        return switch (self) {
            .static_analysis => |file| try file.static_analysis(),
            .semantic_analysis => |file| try file.semantic_analysis(),
            .liveness => |file| try file.liveness(),
            .link_generate => |qcu| {
                std.debug.assert(qcu.errors.items.len == 0);
                try qcu.linker.generate();
                try qcu.verify_errorless_or(error.Linker);

                if (qcu.options.dlinker) {
                    _ = try stderr.writeAll("Linker:\n");
                    try qcu.linker.dump(stderr);
                }
            }
        };
    }
};

const FileList = std.ArrayListUnmanaged(*File);
const JobQueue = std.PriorityQueue(JobType, void, JobType.before);
const SymbolMap = std.StringHashMapUnmanaged(*AsmSemanticAir.Symbol.Locatable);
const SectionMap = std.StringArrayHashMapUnmanaged(*AsmSemanticAir.Section);
const ErrorList = std.ArrayListUnmanaged(LocatableError);

// Tests

const options_ = @import("options");

const qcu_options = Options { .nolinkwarnings = true };

const JobTypeTag = @typeInfo(JobType).@"union".tag_type.?;

fn testUnwrapTag(comptime T: type, union_: ?T) ?@typeInfo(T).@"union".tag_type.? {
    return if (union_) |the_union|
        std.meta.activeTag(the_union) else
        null;
}

fn testJob(qcu: *Qcu, job: JobType) !void {
    const tag = @tagName(std.meta.activeTag(job));
    if (options_.dump)
        std.debug.print("job: {s}\n", .{ tag });
    job.execute() catch |err| {
        std.debug.print("failed on job {s} with {}\n", .{ tag, err });
        for (qcu.errors.items) |the_err|
            try the_err.write(stderr);
        return err;
    };
}

test "work queue dependency order" {
    const cwd = std.fs.cwd(); // QCPU-CLI/
    const files = &[_][]const u8 { "Tests/root.s", "Tests/sample.s", "Tests/Library.s" };
    const qcu = try Qcu.init(std.testing.allocator, cwd, files, qcu_options);
    defer qcu.deinit();

    try std.testing.expectEqual(@as(?JobTypeTag, .static_analysis), testUnwrapTag(JobType, qcu.work_queue.removeOrNull()));
    try std.testing.expectEqual(@as(?JobTypeTag, .static_analysis), testUnwrapTag(JobType, qcu.work_queue.removeOrNull()));
    try std.testing.expectEqual(@as(?JobTypeTag, .static_analysis), testUnwrapTag(JobType, qcu.work_queue.removeOrNull()));
    try std.testing.expectEqual(@as(?JobTypeTag, .semantic_analysis), testUnwrapTag(JobType, qcu.work_queue.removeOrNull()));
    try std.testing.expectEqual(@as(?JobTypeTag, .semantic_analysis), testUnwrapTag(JobType, qcu.work_queue.removeOrNull()));
    try std.testing.expectEqual(@as(?JobTypeTag, .semantic_analysis), testUnwrapTag(JobType, qcu.work_queue.removeOrNull()));
    try std.testing.expectEqual(@as(?JobTypeTag, .liveness), testUnwrapTag(JobType, qcu.work_queue.removeOrNull()));
    try std.testing.expectEqual(@as(?JobTypeTag, .liveness), testUnwrapTag(JobType, qcu.work_queue.removeOrNull()));
    try std.testing.expectEqual(@as(?JobTypeTag, .liveness), testUnwrapTag(JobType, qcu.work_queue.removeOrNull()));
    try std.testing.expectEqual(@as(?JobTypeTag, .link_generate), testUnwrapTag(JobType, qcu.work_queue.removeOrNull()));
    try std.testing.expectEqual(@as(?JobTypeTag, null), testUnwrapTag(JobType, qcu.work_queue.removeOrNull()));
}

test "full fledge" {
    const cwd = std.fs.cwd(); // QCPU-CLI/
    const files = &[_][]const u8 { "Tests/root.s", "Tests/sample.s" };
    const qcu = try Qcu.init(std.testing.allocator, cwd, files, qcu_options);
    defer qcu.deinit();

    const jobs = [_]JobTypeTag {
        .static_analysis,
        .static_analysis,
        .static_analysis,
        .semantic_analysis,
        .semantic_analysis,
        .semantic_analysis,
        .liveness,
        .liveness,
        .liveness,
        .link_generate };
    var i: usize = 0;

    while (qcu.work_queue.removeOrNull()) |job| {
        try std.testing.expectEqual(jobs[i], std.meta.activeTag(job));
        try testJob(qcu, job);
        i += 1;
    }

    try std.testing.expectEqual(@as(usize, 0), qcu.work_queue.count());
}
