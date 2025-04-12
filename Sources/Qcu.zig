
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
//  - link sections

const std = @import("std");
const AsmAst = @import("AsmAst.zig");
const AsmLiveness = @import("AsmLiveness.zig");
const AsmSemanticAir = @import("AsmSemanticAir.zig");
const AsmTokeniser = @import("AsmTokeniser.zig");
const Error = @import("Error.zig");
const Source = @import("Source.zig");

const Qcu = @This();

allocator: std.mem.Allocator,
cwd: std.fs.Dir,
files: []*File,
options: Options,
work_queue: JobQueue,
errors: ErrorList,

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
        .files = undefined, // populated later
        .options = options,
        .work_queue = .init(allocator, {}),
        .errors = .empty };
    var files = try std
        .ArrayList(*File)
        .initCapacity(allocator, file_paths.len);
    errdefer {
        for (files.items) |file|
            file.deinit();
        files.deinit();
        qcu.work_queue.deinit();
    }

    for (file_paths) |file_path|
        files.appendAssumeCapacity(try File.add_work(qcu, cwd, file_path));
    qcu.files = try files.toOwnedSlice();
    try qcu.work_queue.add(.{ .link = qcu });
    return qcu;
}

pub fn deinit(self: *Qcu) void {
    for (self.files) |file|
        file.deinit();
    self.allocator.free(self.files);
    self.work_queue.deinit();
    for (self.errors.items) |lerr|
        self.allocator.free(lerr.err.message);
    self.errors.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub const Options = struct {
    noliveness: bool = false
};

pub const File = struct {

    allocator: std.mem.Allocator,
    qcu: *Qcu,
    pwd: std.fs.Dir,
    file_path: []const u8,

    source: ?Source = null,
    ast: ?AsmAst = null,
    sema: ?AsmSemanticAir = null,

    pub fn add_work(qcu: *Qcu, cwd: std.fs.Dir, file_path: []const u8) InitError!*File {
        const extension = std.fs.path.extension(file_path);
        if (!std.mem.eql(u8, extension, ".s")) // fixme: more file types
            return error.FileTypeNotSupported;
        const base_name = std.fs.path.dirname(file_path) orelse ".";
        var pwd = try cwd.openDir(base_name, .{});
        errdefer pwd.close();

        const file = try qcu.allocator.create(File);
        errdefer qcu.allocator.destroy(file);

        file.* = .{
            .allocator = qcu.allocator,
            .qcu = qcu,
            .pwd = pwd,
            .file_path = file_path };
        // fixme: based on file type, add jobs to queue
        try qcu.work_queue.ensureUnusedCapacity(2);
        qcu.work_queue.add(.{ .static_analysis = file }) catch unreachable;
        qcu.work_queue.add(.{ .semantic_analysis = file }) catch unreachable;
        return file;
    }

    pub fn deinit(self: *File) void {
        if (self.source) |*source| {
            self.allocator.free(source.buffer);
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
        self.allocator.destroy(self);
    }

    // From SemanticAir (and Liveness)

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
            .file = self });
    }

    // Assemble passes

    pub const InitError = error {
        FileTypeNotSupported
    } ||
        std.mem.Allocator.Error ||
        std.fs.Dir.OpenError;

    pub const FileError = error {
        UnexpectedEndOfFile
    } ||
        std.mem.Allocator.Error ||
        std.fs.File.OpenError ||
        std.fs.File.StatError ||
        std.fs.File.ReadError;

    pub const AssembleError = error {
        AbstractSyntaxTree,
        StaticAnalysis,
        SemanticAnalysis,
        Liveness
    } || FileError;

    /// Tokenisation, AstGen and first-pass semantic analysis.
    pub fn static_analysis(self: *File) AssembleError!void {
        var tokeniser = AsmTokeniser.init(try self.get_source());
        self.source = try Source.init(self.allocator, &tokeniser);
        self.ast = try AsmAst.init(self.allocator, self.source.?);
        defer self.ast.?.allocator.free(self.ast.?.errors); // not nodes or error messages

        if (self.ast.?.errors.len > 0) {
            try self.qcu.errors.ensureUnusedCapacity(self.allocator, self.ast.?.errors.len);
            for (self.ast.?.errors) |err|
                self.qcu.errors.appendAssumeCapacity(.{ .err = err, .file = self });
            return error.AbstractSyntaxTree;
        }

        std.debug.assert(self.qcu.errors.items.len == 0);

        self.sema = try AsmSemanticAir.init(self, self.source.?, self.ast.?.nodes);
        try self.verify_errorless_or(error.StaticAnalysis);
        std.debug.assert(self.qcu.errors.items.len == 0);
        std.debug.assert(self.sema.?.errors.items.len == 0);
    }

    /// Second-pass semantic analysis and liveness. Illegal to call when any
    /// related files haven't done a static analysis pass prior to calling this
    /// routine.
    pub fn semantic_analysis(self: *File) AssembleError!void {
        try self.sema.?.semantic_analyse();
        try self.verify_errorless_or(error.SemanticAnalysis);
        std.debug.assert(self.qcu.errors.items.len == 0);
        std.debug.assert(self.sema.?.errors.items.len == 0);

        if (!self.qcu.options.noliveness) {
            var liveness = try AsmLiveness.init(
                self,
                self.source.?,
                &self.sema.?.symbols,
                &self.sema.?.sections);
            defer liveness.deinit();

            try self.verify_errorless_or(error.Liveness);
            std.debug.assert(self.qcu.errors.items.len == 0);
            std.debug.assert(liveness.errors.items.len == 0);
        }
    }

    /// Memory returned is owned by caller.
    fn get_source(self: *File) FileError![:0]const u8 {
        const file_name = std.fs.path.basename(self.file_path);
        var file = try self.pwd.openFile(file_name, .{});
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

    fn verify_errorless_or(self: *File, throw_error: AssembleError) AssembleError!void {
        if (self.qcu.errors.items.len > 0)
            return throw_error;
    }
};

pub const LocatableError = struct {

    err: Error,
    file: *const File,

    pub fn write(self: *const LocatableError, writer: anytype) !void {
        try self.err.write(self.file.file_path, self.file.source.?.buffer, writer);
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
    /// - liveness
    semantic_analysis: *File,
    /// sections + sections -> sections
    link: *Qcu,

    pub fn before(_: void, self: JobType, other: JobType) std.math.Order {
        const me = @intFromEnum(self);
        const you = @intFromEnum(other);
        return std.math.order(me, you);
    }

    pub fn execute(self: JobType) !void {
        return switch (self) {
            .static_analysis => |file| try file.static_analysis(),
            .semantic_analysis => |file| try file.semantic_analysis(),
            .link => |qcu| try qcu.link_sema_units()
        };
    }
};

const JobQueue = std.PriorityQueue(JobType, void, JobType.before);
const SymbolMap = std.StringHashMapUnmanaged(*AsmSemanticAir.Symbol.Locatable);
const SectionMap = std.StringArrayHashMapUnmanaged(*AsmSemanticAir.Section);
const ErrorList = std.ArrayListUnmanaged(LocatableError);

fn link_sema_units(self: *Qcu) !void {
    // fixme: add linker
    _ = self;
}

// Tests

const stderr = std.io
    .getStdErr()
    .writer();

const JobTypeTag = @typeInfo(JobType).@"union".tag_type.?;

fn testUnwrapTag(comptime T: type, union_: ?T) ?@typeInfo(T).@"union".tag_type.? {
    return if (union_) |the_union|
        std.meta.activeTag(the_union) else
        null;
}

fn testJob(qcu: *Qcu, job: JobType) !void {
    job.execute() catch |err| {
        std.debug.print("failed on job {s} with {}\n", .{ @tagName(std.meta.activeTag(job)), err });
        for (qcu.errors.items) |the_err|
            try the_err.write(stderr);
        return err;
    };
}

test "work queue dependency order" {
    const cwd = std.fs.cwd(); // QCPU-CLI/
    const files = &[_][]const u8 { "Tests/sample.s", "Tests/Library.s" };
    const options = Options {};
    const qcu = try Qcu.init(std.testing.allocator, cwd, files, options);
    defer qcu.deinit();

    try std.testing.expectEqual(@as(?JobTypeTag, .static_analysis), testUnwrapTag(JobType, qcu.work_queue.removeOrNull()));
    try std.testing.expectEqual(@as(?JobTypeTag, .static_analysis), testUnwrapTag(JobType, qcu.work_queue.removeOrNull()));
    try std.testing.expectEqual(@as(?JobTypeTag, .semantic_analysis), testUnwrapTag(JobType, qcu.work_queue.removeOrNull()));
    try std.testing.expectEqual(@as(?JobTypeTag, .semantic_analysis), testUnwrapTag(JobType, qcu.work_queue.removeOrNull()));
    try std.testing.expectEqual(@as(?JobTypeTag, .link), testUnwrapTag(JobType, qcu.work_queue.removeOrNull()));
    try std.testing.expectEqual(@as(?JobTypeTag, null), testUnwrapTag(JobType, qcu.work_queue.removeOrNull()));
}

test "full fledge" {
    const cwd = std.fs.cwd(); // QCPU-CLI/
    const files = &[_][]const u8 { "Tests/sample.s" };
    const options = Options {};
    const qcu = try Qcu.init(std.testing.allocator, cwd, files, options);
    defer qcu.deinit();

    while (qcu.work_queue.removeOrNull()) |job|
        try testJob(qcu, job);
}
