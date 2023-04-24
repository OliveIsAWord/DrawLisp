const std = @import("std");
const math = std.math;
const mem = std.mem;
const Allocator = mem.Allocator;
const AllocError = Allocator.Error;

const Self = @This();
const Table = std.StringArrayHashMap(i32);

/// DO NOT ACCESS THIS FIELD OR YOU WILL BE FIRED
table: Table,
symbol_alloc: Allocator,

pub fn init(table_alloc: Allocator, symbol_alloc: Allocator) Self {
    return .{ .table = Table.init(table_alloc), .symbol_alloc = symbol_alloc };
}

pub fn deinit(self: *Self) void {
    for (self.table.unmanaged.entries.items(.key)) |symbol| self.symbol_alloc.free(symbol);
    self.table.deinit();
}

pub fn getByIndex(self: *const Self, index: i32) []const u8 {
    return self.table.unmanaged.entries.get(@intCast(usize, index)).key;
}

pub fn getOrPut(self: *Self, symbol: []const u8) AllocError!i32 {
    return self.table.get(symbol) orelse {
        if (self.table.count() >= math.maxInt(i32)) return AllocError.OutOfMemory;
        const owned_symbol: []u8 = try self.symbol_alloc.alloc(u8, symbol.len);
        mem.copy(u8, owned_symbol, symbol);
        try self.table.put(owned_symbol, @intCast(i32, self.table.count()));
        return self.table.get(symbol).?;
    };
}
