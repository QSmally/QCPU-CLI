
const builtin = @import("builtin");
const std = @import("std");
const Qcu = @import("Qcu.zig");
const Virtualiser = @import("Virtualiser.zig");

fn version(writer: anytype) !void {
    try writer.print("QCPU-CLI v{s} (Zig {s}) ({s}, {s})", .{
        "0.0.0",
        builtin.zig_version_string,
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch) });
    defer writer.print("\n", .{}) catch {};

    if (builtin.link_mode == .dynamic)
        try writer.print(" dynamically linked", .{});
    if (builtin.mode == .Debug)
        try writer.print(" in debug mode", .{});
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    var arguments = Arguments(std.process.ArgIterator).init_second(std.process.args());

    const run_files,
    var run_options = arguments.parse(Options, arena.allocator()) catch |err| {
        _ = switch (err) {
            error.InvalidCharacter => stderr.print("error: {s}: invalid numeric '{s}'\n", .{ arguments.current_option, arguments.current_value }),
            error.Overflow => stderr.print("error: {s}: {s} doesn't fit in type {s}\n", .{ arguments.current_option, arguments.current_value, arguments.current_type }),
            error.ArgumentExpected => stderr.print("error: {s}: expected option value\n", .{ arguments.current_option }),
            error.NotPowerOfTwo => stderr.print("error: {s}: numeric options must be powers of two ({s})\n", .{ arguments.current_option, arguments.current_value }),
            error.Zero => stderr.print("error: {s}: numeric options must be non-zero\n", .{ arguments.current_option }),
            error.SelectionNotFound => stderr.print("error: {s}: value '{s}' is invalid\n", .{ arguments.current_option, arguments.current_value }),
            error.OptionNotFound => stderr.print("error: {s}: unknown option\n", .{  arguments.current_value }),
            error.OutOfMemory => stderr.print("error: out of memory\n", .{})
        } catch return 255;
        return 1;
    };

    if (run_options.verbose) {
        run_options.doptions = true;    // dump options
        run_options.dload = true;       // dump file loads
        run_options.dtokens = true;     // dump tokens
        run_options.dast = true;        // dump abstract syntax tree
        run_options.dair = true;        // dump analysed intermediate representation
        run_options.dlinker = true;     // dump linker sections and symbols
    }

    if (run_options.l1 > run_options.page)
        return error.CachePageHierarchy;

    if (run_options.doptions)
        try stderr.print("{any}\n", .{ run_options });

    if (run_options.version) {
        try version(stdout);
        return 0;
    }

    if (run_files.len == 0) {
        try stderr.print("error: no input files; nothing to do\n", .{});
        return 1;
    }

    // fixme: deinit with gpa on error gives segfault/double panic
    const qcu = Qcu.init(arena.allocator(), std.fs.cwd(), run_files, unmerge(Qcu.Options, run_options)) catch |err| {
        try stderr.print("error: unhandled {}\n", .{ err });
        return 1;
    };

    while (qcu.work_queue.removeOrNull()) |job| {
        job.execute() catch {
            for (qcu.errors.items) |err|
                try err.write(stderr);
            if (!qcu.options.dnotrace)
                try qcu.linker.dump_last_block_trace(stderr);
            return 1;
        };
    }

    if (run_options.dry)
        return 0;

    post_assemble_task(gpa.allocator(), qcu, run_options) catch |err| {
        try stderr.print("{}\n", .{ err });
        return 1;
    };

    return 0;
}

fn post_assemble_task(allocator: std.mem.Allocator, qcu: *Qcu, run_options: Options) !void {
    // if (run_options.output) |file|
    //     try qcu.output_file(file);
    if (run_options.virtualise)
        try Virtualiser.begin(allocator, qcu, unmerge(Virtualiser.Options, run_options));
    // if (run_options.output == null and run_options.virtualise == null)
    //     qcu.output_file("binary");
}

const stdout = std.io
    .getStdOut()
    .writer();
const stderr = std.io
    .getStdErr()
    .writer();

const CliOptions = struct {
    version: bool = false,
    doptions: bool = false,
    verbose: bool = false,
    dry: bool = false,
    output: ?[]const u8 = null,
    virtualise: bool = false
};

const Options = blk: {
    const cli = @typeInfo(CliOptions).@"struct";
    const qcu = @typeInfo(Qcu.Options).@"struct";
    const virt = @typeInfo(Virtualiser.Options).@"struct";

    // Merging structs at compile-time? Hell yeah!
    break :blk @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = cli.fields ++ qcu.fields ++ virt.fields,
        .is_tuple = false,
        .decls = &.{} } });
};

fn unmerge(comptime T: type, self: Options) T {
    var specific_options: T = undefined;

    inline for (@typeInfo(T).@"struct".fields) |field|
        @field(specific_options, field.name) = @field(self, field.name);
    return specific_options;
}

fn Arguments(comptime T: type) type {
    return struct {

        const ArgumentsType = @This();

        iterator: T,

        current_option: []const u8 = undefined,
        current_type: []const u8 = undefined,
        current_value: []const u8 = undefined,

        pub fn init(iterator: T) ArgumentsType {
            return .{ .iterator = iterator };
        }

        pub fn init_second(iterator: T) ArgumentsType {
            var arguments = ArgumentsType.init(iterator);
            _ = arguments.iterator.skip();
            return arguments;
        }

        pub fn next(self: *ArgumentsType) ?[]const u8 {
            const slice: []const u8 = @ptrCast(self.iterator.next() orelse return null);
            self.current_value = slice;
            return slice;
        }

        const Error = error { ArgumentExpected };

        pub fn expect(self: *ArgumentsType) Error![]const u8 {
            return self.next() orelse error.ArgumentExpected;
        }

        fn parse(self: *ArgumentsType, comptime OptionsType: type, allocator: std.mem.Allocator) !struct {
            []const []const u8,
            OptionsType
        } {
            var run_files: std.ArrayListUnmanaged([]const u8) = .empty;
            var run_options = OptionsType {};

            arg: while (self.next()) |argument| {
                inline for (@typeInfo(OptionsType).@"struct".fields) |option| {
                    const name = "--" ++ option.name;
                    const Type = option.@"type";

                    self.current_option = name;
                    self.current_type = @typeName(Type);

                    if (std.mem.eql(u8, name, argument)) {
                        if (@typeInfo(Type) == .@"enum") {
                            const value = std.meta.stringToEnum(Type, try self.expect()) orelse return error.SelectionNotFound;
                            @field(run_options, option.name) = value;
                            continue :arg;
                        }

                        const value = switch (Type) {
                            bool => true,

                            u16, u24, u32, u64 => val: {
                                const inherit = 0;
                                const parsed_value = try std.fmt.parseInt(Type, try self.expect(), inherit);
                                if (parsed_value == 0) return error.Zero;
                                if (!std.math.isPowerOfTwo(parsed_value)) return error.NotPowerOfTwo;
                                break :val parsed_value;
                            },

                            []const u8,
                            ?[]const u8 => try self.expect(),

                            else => @compileError("bug: unsupported option type: " ++ @typeName(Type))
                        };

                        @field(run_options, option.name) = value;
                        continue :arg;
                    }
                }

                if (std.mem.startsWith(u8, argument, "--"))
                    return error.OptionNotFound;
                try run_files.append(allocator, argument);
            }

            return .{
                try run_files.toOwnedSlice(allocator),
                run_options };
        }
    };
}

// Tests

test "unmerge options" {
    const options = Options {
        .dload = false,
        .dair = true,
        .noliveness = true };
    const concrete_options = unmerge(Qcu.Options, options);

    try std.testing.expectEqual(options.dload, concrete_options.dload);
    try std.testing.expectEqual(options.dair, concrete_options.dair);
    try std.testing.expectEqual(options.noliveness, concrete_options.noliveness);
}

test "arguments iterator" {
    const foo = std.mem.splitScalar(u8, "foo bar roo", ' ');
    var iterator = Arguments(@TypeOf(foo)).init(foo);

    try std.testing.expectEqualSlices(u8, "foo", iterator.next() orelse "x");
    try std.testing.expectEqualSlices(u8, "bar", iterator.next() orelse "x");
    try std.testing.expectEqualSlices(u8, "roo", iterator.next() orelse "x");
    try std.testing.expectEqual(@as(?[]const u8, null), iterator.next());
}

const TestOptions = struct {
    foo: bool = false,
    bar: bool = false,
    roo: ?[]const u8 = null,
    doo: bool = false,
    loo: u16 = 0
};

test "arguments parser simple correctly" {
    const foo = std.mem.splitScalar(u8, "--foo --bar aaa", ' ');
    var iterator = Arguments(@TypeOf(foo)).init(foo);
    const positional, const tagged = try iterator.parse(TestOptions, std.testing.allocator);
    defer std.testing.allocator.free(positional);

    try std.testing.expectEqual(true, tagged.foo);
    try std.testing.expectEqual(true, tagged.bar);
    try std.testing.expectEqual(@as(?[]const u8, null), tagged.roo);
    try std.testing.expectEqual(false, tagged.doo);
    try std.testing.expectEqual(@as(u16, 0), tagged.loo);

    try std.testing.expect(positional.len == 1);
    try std.testing.expectEqualSlices(u8, "aaa", positional[0]);
}

test "arguments parser advanced correctly" {
    const foo = std.mem.splitScalar(u8, "--roo bbb --loo 5 aaa", ' ');
    var iterator = Arguments(@TypeOf(foo)).init(foo);
    const positional, const tagged = try iterator.parse(TestOptions, std.testing.allocator);
    defer std.testing.allocator.free(positional);

    try std.testing.expectEqual(false, tagged.foo);
    try std.testing.expectEqual(false, tagged.bar);
    try std.testing.expectEqualSlices(u8, "bbb", tagged.roo.?);
    try std.testing.expectEqual(false, tagged.doo);
    try std.testing.expectEqual(@as(u16, 5), tagged.loo);

    try std.testing.expect(positional.len == 1);
    try std.testing.expectEqualSlices(u8, "aaa", positional[0]);
}

test "arguments parser advanced incorrectly 1" {
    const foo = std.mem.splitScalar(u8, "--roo", ' ');
    var iterator = Arguments(@TypeOf(foo)).init(foo);
    const err = iterator.parse(TestOptions, std.testing.allocator);

    try std.testing.expectError(error.ArgumentExpected, err);
}

test "arguments parser advanced incorrectly 2" {
    const foo = std.mem.splitScalar(u8, "--loo 0xFFFFFF", ' ');
    var iterator = Arguments(@TypeOf(foo)).init(foo);
    const err = iterator.parse(TestOptions, std.testing.allocator);

    try std.testing.expectError(error.Overflow, err);
}

test "arguments parser advanced incorrectly 3" {
    const foo = std.mem.splitScalar(u8, "--aaa 0xFFFFFF", ' ');
    var iterator = Arguments(@TypeOf(foo)).init(foo);
    const err = iterator.parse(TestOptions, std.testing.allocator);

    try std.testing.expectError(error.OptionNotFound, err);
}
