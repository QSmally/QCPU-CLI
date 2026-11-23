
const std = @import("std");

pub fn Fields(comptime T: type, comptime list: []const []const u8) type {
    const type_info = @typeInfo(T).@"struct";

    var field_names: []const [:0]const u8 = &.{};
    var field_types: []const type = &.{};
    var field_attrs: []const std.lang.Type.Struct.FieldAttributes = &.{};

    for (type_info.field_names, type_info.field_types, type_info.field_attrs) |name, Ty, attr| {
        var include_field = false;

        for (list) |omitting_name| {
            if (std.mem.eql(u8, name, omitting_name))
                include_field = true;
        }

        if (include_field) {
            field_names = field_names ++ .{ name };
            field_types = field_types ++ .{ Ty };
            field_attrs = field_attrs ++ .{ attr };
        }
    }

    return @Struct(
        .auto,
        null,
        field_names,
        field_types,
        field_attrs);
}

pub fn Merge(comptime list: []const type) type {
    var field_names: []const [:0]const u8 = &.{};
    var field_types: []const type = &.{};
    var field_attrs: []const std.lang.Type.Struct.FieldAttributes = &.{};

    for (list) |T| {
        const type_info = @typeInfo(T).@"struct";

        // Merging structs at compile-time? Hell yeah!
        for (type_info.field_names, type_info.field_types, type_info.field_attrs) |name, Ty, attr| {
            field_names = field_names ++ .{ name };
            field_types = field_types ++ .{ Ty };
            field_attrs = field_attrs ++ .{ attr };
        }
    }

    return @Struct(
        .auto,
        null,
        field_names,
        field_types,
        field_attrs);
}

pub fn unmerge(comptime T: type, global_options: anytype) T {
    var concrete_options: T = undefined;

    inline for (@typeInfo(T).@"struct".field_names) |name|
        @field(concrete_options, name) = @field(global_options, name);
    return concrete_options;
}

pub fn popCount(comptime T: type, options: anytype) T {
    var count: T = 0;

    inline for (@typeInfo(@TypeOf(options)).@"struct".field_names) |name| {
        if (@field(options, name))
            count += 1;
    }

    return count;
}

pub fn enumSelect(comptime T: type, options: anytype) T {
    std.debug.assert(popCount(usize, options) == 1);

    inline for (@typeInfo(@TypeOf(options)).@"struct".field_names) |name| {
        if (@field(options, name))
            return std.meta.stringToEnum(T, name).?;
    }

    unreachable;
}

// Tests

const Foo = struct {
    a: bool = false,
    b: bool = false,
    c: bool = false
};

const Bar = struct {
    a: bool = false,
    b: bool = false
};

test "unmerge options" {
    const options = Foo { .a = true };
    const concrete_options = unmerge(Bar, options);

    try std.testing.expectEqual(options.a, concrete_options.a);
    try std.testing.expectEqual(options.b, concrete_options.b);
}

test "popCount" {
    try std.testing.expectEqual(popCount(u32, Foo {}), 0);
    try std.testing.expectEqual(popCount(u32, Foo { .a = true }), 1);
    try std.testing.expectEqual(popCount(u32, Foo { .b = true }), 1);
    try std.testing.expectEqual(popCount(u32, Foo { .b = true, .c = true }), 2);
    try std.testing.expectEqual(popCount(u32, Foo { .a = true, .b = true, .c = true }), 3);
}

const FooEnum = enum {
    a,
    b,
    c
};

test "enumSelect" {
    try std.testing.expectEqual(enumSelect(FooEnum, Foo { .a = true }), .a);
    try std.testing.expectEqual(enumSelect(FooEnum, Foo { .b = true }), .b);
}
