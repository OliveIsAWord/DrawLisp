const std = @import("std");
const Allocator = std.mem.Allocator;
const AllocError = Allocator.Error;

const Value = @import("value.zig").Value;
const Cons = Value.Cons;
const Lambda = Value.Lambda;

const Self = @This();

value_alloc: Allocator,
gc_alloc: Allocator,
all_allocations: std.ArrayListUnmanaged(AllocValue) = .{},
to_mark: std.ArrayListUnmanaged(AllocValue) = .{},

const AllocValue = union(enum) {
    cons: *Cons,
    lambda: *Lambda,
    fn from(value: Value) ?@This() {
        return switch (value) {
            .cons => |c| .{ .cons = c },
            .lambda => |f| .{ .lambda = f },
            else => null,
        };
    }
    fn markedMut(self: @This()) *bool {
        return switch (self) {
            .cons => |c| &c.marked,
            .lambda => |f| &f.marked,
        };
    }
    fn replaceMarked(self: @This(), marked: bool) bool {
        var ptr = self.markedMut();
        const prev_value = ptr.*;
        ptr.* = marked;
        return prev_value;
    }
    fn deinit(self: @This(), alloc: Allocator) void {
        return switch (self) {
            .cons => |c| alloc.destroy(c),
            .lambda => |f| {
                f.deinit(alloc);
                alloc.destroy(f);
            },
        };
    }
};

pub fn init(value_alloc: Allocator, gc_alloc: Allocator) Self {
    return .{ .value_alloc = value_alloc, .gc_alloc = gc_alloc };
}

pub fn create_cons(self: *Self, value: Cons) AllocError!*Cons {
    var ptr = try self.value_alloc.create(Cons);
    {
        errdefer self.value_alloc.destroy(ptr);
        try self.all_allocations.append(self.gc_alloc, .{ .cons = ptr });
    }
    ptr.* = value;
    return ptr;
}

pub fn create_lambda(self: *Self, value: Lambda) AllocError!*Lambda {
    var ptr = try self.value_alloc.create(Lambda);
    {
        errdefer self.value_alloc.destroy(ptr);
        try self.all_allocations.append(self.gc_alloc, .{ .lambda = ptr });
    }
    ptr.* = value;
    return ptr;
}

pub fn mark(self: *Self, value: Value) AllocError!void {
    try self.mark_push(value);
    while (self.to_mark.popOrNull()) |v| switch (v) {
        .cons => |cons| {
            if (cons.marked) continue;
            cons.marked = true;
            try self.mark_push(cons.car);
            try self.mark_push(cons.cdr);
        },
        .lambda => |lambda| {
            if (lambda.marked) continue;
            lambda.marked = true;
            for (lambda.binds) |bind| try self.mark_push(bind.value);
            try self.mark_push(lambda.body);
        },
    };
}

fn mark_push(self: *Self, value: Value) AllocError!void {
    if (AllocValue.from(value)) |v| try self.to_mark.append(self.gc_alloc, v);
}

/// MORBIUS
pub fn sweep(self: *Self) void {
    var items = self.all_allocations.items;
    var retain_index: usize = 0;
    for (items) |a| {
        // std.debug.print("{} is {}\n", .{ a, a.markedMut() });
        if (a.replaceMarked(false)) {
            items[retain_index] = a;
            retain_index += 1;
        } else a.deinit(self.value_alloc);
    }
    self.all_allocations.shrinkRetainingCapacity(retain_index);
}

pub fn deinit(self: *Self) void {
    self.all_allocations.deinit(self.gc_alloc);
    self.to_mark.deinit(self.gc_alloc);
    self.* = undefined;
}

pub fn deinitAndSweep(self: *Self) void {
    for (self.all_allocations.items) |a| {
        a.deinit(self.value_alloc);
    }
    self.deinit();
}
