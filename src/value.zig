const std = @import("std");
const Allocator = std.mem.Allocator;

const SymbolTable = @import("SymbolTable.zig");

const pretty_print_lists = true;
const pretty_print_symbols = true;

pub const Value = union(enum) {
    const Self = @This();
    nil,
    cons: *Cons,
    int: i64,
    bool: bool,
    symbol: i32,

    pub fn deinit(self: Self, alloc: Allocator) void {
        switch (self) {
            .cons => |pair| {
                pair.car.deinit(alloc);
                pair.cdr.deinit(alloc);
                alloc.destroy(pair);
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
                try pair.car.format_internal(writer, false, maybe_symbols);
                const separator_or_null: ?[]const u8 = if (pretty_print_lists) switch (pair.cdr) {
                    .nil => null,
                    .cons => " ",
                    else => " . ",
                } else " . ";
                if (separator_or_null) |separator| {
                    try writer.writeAll(separator);
                    try pair.cdr.format_internal(writer, pretty_print_lists, maybe_symbols);
                }
                if (!am_in_cdr) try writer.writeAll(")");
            },
            .int => |i| try writer.print("{}", .{i}),
            .bool => |b| try writer.print("{s}", .{if (b) "#t" else "#f"}),
            .symbol => |index| if (maybe_symbols) |symbols| {
                try writer.print("{s}", .{symbols.getByIndex(index)});
            } else try writer.print("<{}>", .{index}),
        }
    }

    pub fn print(self: Self, writer: anytype, symbols: SymbolTable) !void {
        const maybe_symbols = if (pretty_print_symbols) symbols else null;
        return self.format_internal(writer, false, maybe_symbols);
    }

    pub fn format(self: Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return self.format_internal(writer, false, null);
    }

    pub const Cons = struct { car: Value, cdr: Value };
};
