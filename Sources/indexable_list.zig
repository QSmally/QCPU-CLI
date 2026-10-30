
const std = @import("std");

pub fn IndexableList(comptime T: type) type {
    return struct {

        const IndexableListType = @This();

        list: std.ArrayList(T),

        pub const empty = IndexableListType { .list = .empty };

        pub fn initCapacity(allocator: std.mem.Allocator, cap: usize) !IndexableListType {
            return .{ .list = try .initCapacity(allocator, cap) };
        }

        pub fn deinit(self: *IndexableListType, allocator: std.mem.Allocator) void {
            self.list.deinit(allocator);
        }

        pub fn ensureUnusedCapacity(self: *IndexableListType, allocator: std.mem.Allocator, cap: UnderlyingType) !void {
            std.debug.assert(self.list.items.len + cap < std.math.maxInt(UnderlyingType));
            try self.list.ensureUnusedCapacity(allocator, cap);
        }

        pub fn appendAssumeCapacity(self: *IndexableListType, item: T) void {
            self.list.appendAssumeCapacity(item);
        }

        pub fn append(self: *IndexableListType, allocator: std.mem.Allocator, item: T) !void {
            std.debug.assert(self.list.items.len + 1 < std.math.maxInt(UnderlyingType));
            try self.list.append(allocator, item);
        }

        pub const Index = enum(UnderlyingType) {

            root = 0,
            _,

            pub fn at(index: UnderlyingType) Index {
                return @fromBackingInt(index);
            }

            pub fn fromIndex(index: usize) Index {
                const typed_index: UnderlyingType = @intCast(index);
                return .at(typed_index);
            }

            pub fn addIndex(self: Index, index: usize) Index {
                const typed_index: Index = .fromIndex(index);
                return .at(self.raw() + typed_index.raw());
            }

            pub fn raw(self: Index) UnderlyingType {
                return @backingInt(self);
            }
        };

        pub fn get(self: *const IndexableListType, index: Index) T {
            return self.list.items[@backingInt(index)];
        }

        pub fn len(self: *const IndexableListType) UnderlyingType {
            return @intCast(self.list.items.len);
        }

        pub const Slice = struct {
            items: []const T,

            pub fn deinit(self: *const Slice, allocator: std.mem.Allocator) void {
                allocator.free(self.items);
            }

            pub fn get(self: *const Slice, index: Index) T {
                return self.items[@backingInt(index)];
            }
        };

        pub fn toOwnedSlice(self: *IndexableListType, allocator: std.mem.Allocator) !Slice {
            return .{ .items = try self.list.toOwnedSlice(allocator) };
        }
    };
}

pub const UnderlyingType = u32;

// Tests

test IndexableList {
    const Type = IndexableList(u32);
    const Type2 = IndexableList(void);

    comptime std.debug.assert(Type.Index != Type2.Index);
    comptime std.debug.assert(Type.Slice != Type2.Slice);

    var foo: Type = .empty;
    defer foo.deinit(std.testing.allocator);
    try std.testing.expectEqual(0, foo.len());

    try foo.append(std.testing.allocator, 5);
    try std.testing.expectEqual(1, foo.len());
    try std.testing.expectEqualSlices(u32, &.{ 5 }, foo.list.items);
    try std.testing.expectEqual(5, foo.get(.root));

    try foo.append(std.testing.allocator, 42);
    try std.testing.expectEqual(2, foo.len());
    try std.testing.expectEqualSlices(u32, &.{ 5, 42 }, foo.list.items);
    try std.testing.expectEqual(42, foo.get(.at(1)));

    const slice = try foo.toOwnedSlice(std.testing.allocator);
    defer slice.deinit(std.testing.allocator);

    try std.testing.expectEqual(42, slice.get(.at(1)));
}
