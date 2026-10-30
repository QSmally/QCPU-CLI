
const builtin = @import("builtin");
const std = @import("std");
const Qcu = @import("Qcu.zig");

const version_str = "0.1.0";

fn version(writer: *std.Io.Writer) !void {
    try writer.print("QCPU-CLI v{s}\n", .{ version_str });
}

fn help(writer: *std.Io.Writer) !void {
    try writer.print(
        \\
        \\    QCPU CLI
        \\    qcpu [option ...] file ...
        \\
        \\
    , .{});

    inline for (&[_] struct { []const u8, type } {
        .{ "general options", CliOptions },
        .{ "compilation unit options", Qcu.Options }
    }) |category| {
        try writer.print("{s}\n", .{ category[0] });

        const properties = @typeInfo(category[1]).@"struct";

        inline for (
            properties.field_names,
            properties.field_types,
            properties.field_attrs
        ) |name, Type, attrs| {
            const fancy_type = switch (Type) {
                []const u8 => "string (default " ++ attrs.defaultValue(Type).? ++ ")",
                ?[]const u8 => "string",
                bool => "",
                u32 => "number (default " ++ std.fmt.comptimePrint("{}", attrs.defaultValue(Type).?) ++ ")",
                ?u32 => "number",
                else => @typeName(Type)
            };

            try writer.print("    --{s} {s}\n", .{ name, fancy_type });
        }

        try writer.print("\n", .{});
    }

    try version(writer);
}

fn doEverything(
    io: std.Io,
    arena: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    parser: *ArgumentsParser
) !void {
    const run_files,
    var run_options = try parser.parse(Options, arena);

    if (run_options.verbose) {
        run_options.doptions = true;
        run_options.dast = true;
        run_options.dir = true;
        run_options.dair = true;
        run_options.dlinker = true;
    }

    if (run_options.doptions)
        try stderr.print("{any}\n", .{ run_options });

    if (run_options.version)
        return try version(stdout);

    if (run_options.help)
        return try help(stderr);

    if (run_files.len == 0)
        return error.Nothing;

    for (run_files) |root_file_path| {
        const qcu = try Qcu.init(
            io,
            arena,
            std.Io.Dir.cwd(),
            root_file_path,
            unmerge(Qcu.Options, run_options),
            stderr);
        defer qcu.deinit();

        qcu.work() catch |err| {
            for (qcu.errors.items) |the_err|
                try the_err.write(stderr);
            return err;
        };
    }
}

const ArgumentsParser = Arguments(std.process.Args.Iterator);

const stdout_file = std.Io.File.stdout();
const stderr_file = std.Io.File.stderr();
var stdout_buffer: [4096]u8 = undefined;
var stderr_buffer: [4096]u8 = undefined;

pub fn main(init: std.process.Init) u8 {
    var stdout = stdout_file.writer(init.io, &stdout_buffer);
    defer stdout.flush() catch {};

    var stderr = stderr_file.writer(init.io, &stderr_buffer);
    defer stderr.flush() catch {};

    const args = init.minimal.args.iterate();
    var parser = ArgumentsParser.initSkipFirst(args);

    doEverything(
        init.io,
        init.arena.allocator(),
        &stdout.interface,
        &stderr.interface,
        &parser
    ) catch |err| {
        switch (err) {
            error.ArgumentExpected => stderr.interface.print("error: {s}: expected option value\n", .{ parser.current_value }) catch {},
            error.OptionNotFound => stderr.interface.print("error: {s}: unknown option\n", .{ parser.current_value }) catch {},
            error.Nothing => stderr.interface.print("error: nothing to do\n", .{}) catch {},
            error.Break => {},
            else => |the_err| stderr.interface.print("{}\n", .{ the_err }) catch {}
        }
        return 1;
    };

    return 0;
}

const CliOptions = struct {
    // run modes
    version: bool = false,
    help: bool = false,
    docs: ?[]const u8 = null,
    // run options
    doptions: bool = false,
    verbose: bool = false,
    // output modes
    binary: bool = false,
    verilog: bool = false,
    virtualise: bool = false
};

const Options = blk: {
    const cli = @typeInfo(CliOptions).@"struct";
    const qcu = @typeInfo(Qcu.Options).@"struct";
    // const virt = @typeInfo(Virtualiser.Options).@"struct";

    // Merging structs at compile-time? Hell yeah!
    break :blk @Struct(
       .auto,
       null,
       cli.field_names ++ qcu.field_names,
       cli.field_types ++ qcu.field_types,
       cli.field_attrs ++ qcu.field_attrs);
};

fn unmerge(comptime T: type, self: Options) T {
    var specific_options: T = undefined;

    inline for (@typeInfo(T).@"struct".field_names) |name|
        @field(specific_options, name) = @field(self, name);
    return specific_options;
}

fn Arguments(comptime T: type) type {
    return struct {

        const ArgumentsType = @This();

        iterator: T,

        current_option: []const u8 = undefined,
        current_type: []const u8 = undefined,
        current_value: []const u8 = undefined,

        pub fn initSkipFirst(iterator: T) ArgumentsType {
            var parser = ArgumentsType { .iterator = iterator };
            _ = parser.iterator.skip();
            return parser;
        }

        pub fn parse(self: *ArgumentsType, comptime OptionsType: type, allocator: std.mem.Allocator) !struct {
            []const []const u8,
            OptionsType
        } {
            var run_files: std.ArrayListUnmanaged([]const u8) = .empty;
            var run_options = OptionsType {};

            args: while (self.next()) |argument| {
                const properties = @typeInfo(OptionsType).@"struct";

                inline for (properties.field_names, properties.field_types) |name, Type| {
                    const option_name = "--" ++ name;

                    self.current_option = option_name;
                    self.current_type = @typeName(Type);

                    if (std.mem.eql(u8, option_name, argument)) {
                        const value = switch (Type) {
                            bool => true,

                            u32, ?u32 => value: {
                                const UnderlyingType = if (@typeInfo(Type) == .optional)
                                    @typeInfo(Type).@"optional".child else
                                    Type;
                                const inherit = 0;
                                const parsed_value = try std.fmt.parseInt(UnderlyingType, try self.expect(), inherit);
                                if (parsed_value == 0)
                                    return error.Zero;
                                break :value parsed_value;
                            },

                            []const u8, ?[]const u8 => try self.expect(),

                            else => @compileError("bug: unsupported option type: " ++ @typeName(Type))
                        };

                        @field(run_options, name) = value;
                        continue :args;
                    }
                }

                if (std.mem.startsWith(u8, argument, "--"))
                    return error.OptionNotFound;

                try run_files.append(allocator, argument);
            }

            return .{ try run_files.toOwnedSlice(allocator), run_options };
        }

        pub fn next(self: *ArgumentsType) ?[]const u8 {
            const slice: []const u8 = @ptrCast(self.iterator.next() orelse return null);
            self.current_value = slice;
            return slice;
        }

        pub const Error = error {
            ArgumentExpected
        };

        pub fn expect(self: *ArgumentsType) Error![]const u8 {
            return self.next() orelse error.ArgumentExpected;
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
    var iterator = Arguments(@TypeOf(foo)) { .iterator = foo };

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
    loo: u32 = 0
};

test "arguments parser simple correctly" {
    const foo = std.mem.splitScalar(u8, "--foo --bar aaa", ' ');
    var iterator = Arguments(@TypeOf(foo)) { .iterator = foo };
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
    var iterator = Arguments(@TypeOf(foo)) { .iterator = foo };
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
    var iterator = Arguments(@TypeOf(foo)) { .iterator = foo };
    const err = iterator.parse(TestOptions, std.testing.allocator);

    try std.testing.expectError(error.ArgumentExpected, err);
}

test "arguments parser advanced incorrectly 2" {
    const foo = std.mem.splitScalar(u8, "--loo 0x100000000", ' ');
    var iterator = Arguments(@TypeOf(foo)) { .iterator = foo };
    const err = iterator.parse(TestOptions, std.testing.allocator);

    try std.testing.expectError(error.Overflow, err);
}

test "arguments parser advanced incorrectly 3" {
    const foo = std.mem.splitScalar(u8, "--aaa 0xFFFFFF", ' ');
    var iterator = Arguments(@TypeOf(foo)) { .iterator = foo };
    const err = iterator.parse(TestOptions, std.testing.allocator);

    try std.testing.expectError(error.OptionNotFound, err);
}
