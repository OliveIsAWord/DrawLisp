const std = @import("std");
const Allocator = std.mem.Allocator;

const SymbolTable = @import("SymbolTable.zig");
const Evaluator = @import("Evaluator.zig");
const Arc = @import("arc.zig").ArcUnmanaged;

const pretty_print_lists = true;
const pretty_print_symbols = true;

pub const Type = enum {
    nil,
    cons,
    int,
    bool,
    symbol,
    primitive_function,
};

pub const Value = union(Type) {
    const Self = @This();
    pub const Cons = struct {
        car: Value,
        cdr: Value,
        pub fn deinit(self: @This(), alloc: Allocator) void {
            self.car.deinit(alloc);
            self.cdr.deinit(alloc);
        }
    };
    nil,
    cons: Arc(Cons),
    int: i64,
    bool: bool,
    symbol: i32,
    primitive_function: Evaluator.PrimitiveImpl,

    pub fn toListPartial(self: Self) union(enum) { list: ?Cons, bad: Value } {
        const list = switch (self) {
            .cons => |c| c.get().*,
            .nil => null,
            else => return .{ .bad = self },
        };
        return .{ .list = list };
    }

    pub fn getType(self: Self) Type {
        return @intToEnum(Type, @enumToInt(self));
    }

    pub fn deinit(self_: Self, alloc: Allocator) void {
        var self = self_;
        switch (self) {
            .cons => |*pair| {
                pair.get().deinit(alloc);
                pair.drop(alloc);
            },
            else => {},
        }
    }

    fn format_internal(
        self: Self,
        writer: anytype,
        am_in_cdr: bool,
        maybe_symbols: ?SymbolTable,
    ) !void {
        switch (self) {
            .nil => if (!am_in_cdr) try writer.writeAll("()"),
            .cons => |pair| {
                if (!am_in_cdr) try writer.writeAll("(");
                try pair.get().car.format_internal(writer, false, maybe_symbols);
                const separator_or_null: ?[]const u8 = if (pretty_print_lists) switch (pair.get().cdr) {
                    .nil => null,
                    .cons => " ",
                    else => " . ",
                } else " . ";
                if (separator_or_null) |separator| {
                    try writer.writeAll(separator);
                    try pair.get().cdr.format_internal(writer, pretty_print_lists, maybe_symbols);
                }
                if (!am_in_cdr) try writer.writeAll(")");
            },
            .int => |i| try writer.print("{}", .{i}),
            .bool => |b| try writer.writeAll(if (b) "#t" else "#f"),
            .symbol => |index| if (maybe_symbols) |symbols| {
                try writer.print("{s}", .{symbols.getByIndex(index)});
            } else try writer.print("<{}>", .{index}),
            .primitive_function => |func| {
                const this_addr = @ptrToInt(func);
                const name = for (Evaluator.primitive_functions) |entry| {
                    if (this_addr == @ptrToInt(entry.impl)) break entry.name;
                } else unreachable;
                try writer.print("<fn {s}>", .{name});
            },
        }
    }

    pub fn print(self: Self, writer: anytype, symbols: SymbolTable) !void {
        const maybe_symbols = if (pretty_print_symbols) symbols else null;
        return self.format_internal(writer, false, maybe_symbols);
    }

    pub fn format(self: Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return self.format_internal(writer, false, null);
    }
};
