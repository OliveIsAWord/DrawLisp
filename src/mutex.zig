const std = @import("std");
const Lock = std.Thread.Mutex;

pub fn Mutex(comptime T: type) type {
    return struct {
        locker: Lock = .{},
        inner: T,

        const Self = @This();

        pub fn lock(self: *Self) *T {
            self.locker.lock();
            return &self.inner;
        }

        pub fn tryLock(self: *Self) ?*T {
            return if (self.locker.tryLock()) &self.inner else null;
        }

        pub fn unlock(self: *Self) void {
            self.locker.unlock();
        }
    };
}
