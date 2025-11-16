
const builtin = @import("builtin");
const std = @import("std");
const Qcu = @import("Qcu.zig");

const version_str = "0.1.0";

fn version(writer: anytype) !void {
    try writer.print("QCPU-CLI v{s} (Zig {s}) ({s}, {s})", .{
        version_str,
        builtin.zig_version_string,
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch) });
    defer writer.print("\n", .{}) catch {};

    if (builtin.link_mode == .dynamic)
        try writer.print(" dynamically linked", .{});
    if (builtin.mode == .Debug)
        try writer.print(" in debug mode", .{});
}

fn help(raw_writer: anytype) !void {
    var buffer = std.io.bufferedWriter(raw_writer);
    defer buffer.flush() catch {};
    var writer = buffer.writer();

    try writer.writeAll(
        \\
        \\    QCPU CLI
        \\    qcpu [option ...] [--flag key[ value] ...] file ...
        \\
        \\
    );

    inline for (&[_]struct { []const u8, type } {
        .{ "general options", CliOptions },
        .{ "compilation unit options", Qcu.Options },
        // .{ "virtualiser options", Virtualiser.Options }
    }) |category| {
        try writer.print("{s}\n", .{ category[0] });

        inline for (@typeInfo(category[1]).@"struct".fields) |field| {
            const fancy_type = switch (field.@"type") {
                []const u8 => "string (default " ++ field.defaultValue().? ++ ")",
                ?[]const u8 => "string (default none)",
                bool => "",
                u3, u16, u32, u64 => @typeName(field.@"type") ++ " (default " ++ std.fmt.comptimePrint("{}", .{ field.defaultValue().? }) ++ ")",
                ?u3, ?u16, ?u32, ?u64 => @typeName(field.@"type") ++ " (default none)",
                else => @typeName(field.@"type")
            };

            try writer.print("    --{s} {s}\n", .{ field.name, fancy_type });
        }

        try writer.writeAll("\n");
    }

    try version(writer);
}

var gpa = std.heap.GeneralPurposeAllocator(.{}) {};

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    var arguments = Arguments(std.process.ArgIterator).init_second(std.process.args());

    const run_files,
    const run_flags,
    var run_options = arguments.parse(Options, arena.allocator()) catch |err| {
         switch (err) {
            // error.InvalidCharacter => try stderr.print("error: {s}: invalid numeric '{s}'\n", .{ arguments.current_option, arguments.current_value }),
            // error.Overflow => try stderr.print("error: {s}: {s} doesn't fit in type {s}\n", .{ arguments.current_option, arguments.current_value, arguments.current_type }),
            error.ArgumentExpected => try stderr.print("error: {s}: expected option value\n", .{ arguments.current_option }),
            // error.NotPowerOfTwo => try stderr.print("error: {s}: numeric options must be powers of two ({s})\n", .{ arguments.current_option, arguments.current_value }),
            // error.Zero => try stderr.print("error: {s}: numeric options must be non-zero\n", .{ arguments.current_option }),
            // error.SelectionNotFound => try stderr.print("error: {s}: value '{s}' is invalid\n", .{ arguments.current_option, arguments.current_value }),
            error.OptionNotFound => try stderr.print("error: {s}: unknown option\n", .{  arguments.current_value }),
            error.OutOfMemory => try stderr.print("error: out of memory\n", .{})
        }
        return 1;
    };

    if (run_options.verbose) {
        run_options.doptions = true;    // dump options
        run_options.dast = true;        // dump abstract syntax tree
        run_options.dir = true;         // dump intermediate representation
        run_options.dair = true;        // dump analysed intermediate representation
        // run_options.dlinker = true;     // dump linker sections and symbols
    }

    if (run_options.doptions)
        try stderr.print("{any}\n", .{ run_options });

    // if (run_options.l1 > run_options.page) {
    //     try stderr.print("error: --l1: larger than page size\n", .{});
    //     return 1;
    // }

    if (run_options.version) {
        try version(stdout);
        return 0;
    }

    if (run_options.help) {
        try help(stdout);
        return 0;
    }

    if (run_files.len == 0) {
        try stderr.print("error: no input files; nothing to do\n", .{});
        return 1;
    }

    const qcu = Qcu.init(
        gpa.allocator(),
        std.fs.cwd(),
        run_files,
        &run_flags,
        unmerge(Qcu.Options, run_options)
    ) catch |err| {
        try stderr.print("{}\n", .{ err });
        return 1;
    };

    qcu.work() catch |err| switch (err) {
        error.OutOfMemory => {
            try stderr.print("{}\n", .{ err });
            return 1;
        },

        else => {
            for (qcu.errors.items) |the_err|
                try the_err.write(stderr);
            // if (!qcu.options.dnotrace)
            //     try qcu.linker.dump_last_block_trace(stderr);
            return 1;
        }
    };

    return task(gpa.allocator(), qcu, run_options) catch |err| exit: {
        try stderr.print("{}\n", .{ err });
        break :exit 1;
    };
}

fn task(allocator: std.mem.Allocator, qcu: *Qcu, run_options: Options) !u8 {
    // if (run_options.output) |file_name|
    //     try qcu.output_binary(file_name);
    // if (run_options.virtualise)
    //     try Virtualiser.begin(allocator, qcu, unmerge(Virtualiser.Options, run_options));
    _ = allocator;
    _ = qcu;
    _ = run_options;
    return 0;
}

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

const CliOptions = struct {
    version: bool = false,
    help: bool = false,
    doptions: bool = false,
    verbose: bool = false,
    docs: ?[]const u8 = null,
    output: ?[]const u8 = null,
    virtualise: bool = false
};

const Options = blk: {
    const cli = @typeInfo(CliOptions).@"struct";
    const qcu = @typeInfo(Qcu.Options).@"struct";
    // const virt = @typeInfo(Virtualiser.Options).@"struct";

    // Merging structs at compile-time? Hell yeah!
    break :blk @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = cli.fields ++ qcu.fields,
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
            std.StringArrayHashMapUnmanaged([]const u8),
            OptionsType
        } {
            var run_files: std.ArrayListUnmanaged([]const u8) = .empty;
            var run_flags: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
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

                            u3, u16, u32, u64,
                            ?u3, ?u16, ?u32, ?u64 => val: {
                                const UnderlyingType = if (@typeInfo(Type) == .optional)
                                    @typeInfo(Type).@"optional".child else
                                    Type;
                                const inherit = 0;
                                const parsed_value = try std.fmt.parseInt(UnderlyingType, try self.expect(), inherit);
                                if (parsed_value == 0)
                                    return error.Zero;
                                if (std.math.isPowerOfTwo(@bitSizeOf(UnderlyingType)) and !std.math.isPowerOfTwo(parsed_value))
                                    return error.NotPowerOfTwo;
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

                if (std.mem.eql(u8, argument, "--flag")) {
                    self.current_option = "--flag";
                    const key = try self.expect();
                    const value = try self.expect();
                    try run_flags.put(allocator, key, value);
                    continue;
                }

                if (std.mem.startsWith(u8, argument, "--"))
                    return error.OptionNotFound;
                try run_files.append(allocator, argument);
            }

            return .{
                try run_files.toOwnedSlice(allocator),
                run_flags,
                run_options };
        }
    };
}

// Tests

test "unmerge options" {
    const options = Options {
        .version = true,
        .help = true };
    const concrete_options = unmerge(CliOptions, options);

    try std.testing.expectEqual(options.version, concrete_options.version);
    try std.testing.expectEqual(options.help, concrete_options.help);
    try std.testing.expectEqual(options.virtualise, concrete_options.virtualise);
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
    const foo = std.mem.splitScalar(u8, "--roo bbb --loo 8 aaa", ' ');
    var iterator = Arguments(@TypeOf(foo)).init(foo);
    const positional, const tagged = try iterator.parse(TestOptions, std.testing.allocator);
    defer std.testing.allocator.free(positional);

    try std.testing.expectEqual(false, tagged.foo);
    try std.testing.expectEqual(false, tagged.bar);
    try std.testing.expectEqualSlices(u8, "bbb", tagged.roo.?);
    try std.testing.expectEqual(false, tagged.doo);
    try std.testing.expectEqual(@as(u16, 8), tagged.loo);

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
