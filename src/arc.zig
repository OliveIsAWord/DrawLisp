const std = @import("std");
const Allocator = std.mem.Allocator;
const AllocError = Allocator.Error;

pub fn ArcUnmanaged(comptime T: type) type {
    const ArcInner = struct {
        ref_count: usize,
        value: T,
    };

    return struct {
        const Self = @This();
        inner: *ArcInner,

        pub fn init(value: T, alloc: Allocator) AllocError!Self {
            var inner = try alloc.create(ArcInner);
            inner.* = .{ .ref_count = 1, .value = value };
            return Self{ .inner = inner };
        }

        pub fn get(self: Self) *T {
            return &self.inner.value;
        }

        pub fn refCount(self: Self) usize {
            return self.inner.ref_count;
        }

        pub fn clone(self: Self) AllocError!Self {
            self.inner.ref_count = std.math.add(usize, self.inner.ref_count, 1) catch return AllocError.OutOfMemory;
            return self;
        }

        pub fn drop(self: *Self, alloc: Allocator) void {
            self.inner.ref_count -= 1;
            if (self.inner.ref_count == 0) {
                alloc.destroy(self.inner);
            }
            self.* = undefined;
        }
    };
}

test "one ref" {
    const alloc = std.testing.allocator;
    var x = try ArcUnmanaged(i32).init(413, alloc);
    defer x.drop(alloc);
    try std.testing.expectEqual(x.refCount(), 1);
    try std.testing.expectEqual(x.get().*, 413);
}

test "two ref" {
    const alloc = std.testing.allocator;
    var x = try ArcUnmanaged(i32).init(413, alloc);
    var y = try x.clone();
    try std.testing.expectEqual(x.refCount(), 2);
    try std.testing.expectEqual(y.refCount(), 2);
    x.drop(alloc);
    try std.testing.expectEqual(y.refCount(), 1);
    try std.testing.expectEqual(y.get().*, 413);
    y.drop(alloc);
}
