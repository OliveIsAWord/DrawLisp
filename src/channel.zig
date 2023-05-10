const std = @import("std");
const Allocator = std.mem.Allocator;
const AllocError = Allocator.Error;
const Atomic = std.atomic.Atomic;
const Futex = std.Thread.Futex;

pub fn Channel(comptime T: type) type {
    return struct {
        buffer: []T,
        start: u32 = 0,
        len: u32 = 0,

        const Self = @This();

        pub fn init(alloc: Allocator, len: usize) AllocError!Self {
            var buffer = try alloc.alloc(T, len);
            if (buffer.len > std.math.maxInt(u32)) {
                std.debug.panic("length {} too large", .{buffer.len});
            }
            return .{ .buffer = buffer };
        }

        pub fn put(self: *Self, value: T) void {
            Futex.wait(&self.len, self.buffer.len);
            self.putUnchecked(value);
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            alloc.free(self.buffer);
            self.* = undefined;
        }
    };
}

pub fn wrappingAdd(x: u32, y: u32, len: usize) u32 {}
