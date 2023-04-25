const std = @import("std");
const Allocator = std.mem.Allocator;
const AllocError = Allocator.Error;

const Value = @import("value.zig").Value;
const Cons = Value.Cons;

const Self = @This();

value_alloc: Allocator,
gc_alloc: Allocator,
all_allocations: std.ArrayListUnmanaged(*Cons) = .{},
to_mark: std.ArrayListUnmanaged(*Cons) = .{},

pub fn init(value_alloc: Allocator, gc_alloc: Allocator) Self {
    return .{ .value_alloc = value_alloc, .gc_alloc = gc_alloc };
}

pub fn create(self: *Self, value: Cons) AllocError!*Cons {
    var ptr = try self.value_alloc.create(Cons);
    errdefer self.value_alloc.destroy(ptr);
    try self.all_allocations.append(self.gc_alloc, ptr);
    ptr.* = value;
    return ptr;
}

pub fn mark(self: *Self, value: Value) AllocError!void {
    try self.mark_push(value);
    while (self.to_mark.popOrNull()) |cons| {
        if (cons.marked) continue;
        cons.marked = true;
        try self.mark_push(cons.car);
        try self.mark_push(cons.cdr);
    }
}

fn mark_push(self: *Self, value: Value) AllocError!void {
    switch (value) {
        .cons => |cons| try self.to_mark.append(self.gc_alloc, cons),
        else => {},
    }
}

/// MORBIUS
pub fn sweep(self: *Self) void {
    var items = self.all_allocations.items;
    var retain_index: usize = 0;
    for (items) |ptr| {
        if (ptr.marked) {
            ptr.marked = false;
            items[retain_index] = ptr;
            retain_index += 1;
        } else {
            self.value_alloc.destroy(ptr);
        }
    }
    self.all_allocations.shrinkRetainingCapacity(retain_index);
}

pub fn deinit(self: *Self) void {
    self.all_allocations.deinit(self.gc_alloc);
    self.to_mark.deinit(self.gc_alloc);
    self.* = undefined;
}
