const std = @import("std");
const Allocator = std.mem.Allocator;

const SymbolTable = @import("SymbolTable.zig");
const Evaluator = @import("Evaluator.zig");
const RuntimeWriter = @import("RuntimeWriter.zig");
const Color = @import("Color.zig");

const pretty_print_lists = true;
const pretty_print_symbols = true;
const quote_before_symbols = false;

// TODO: Using `std.meta.Tag` gives a circular dependency error because of `Value.getType`
pub const Type = enum {
    nil,
    cons,
    int,
    bool,
    symbol,
    primitive,
    lambda,
    color,
};

pub const Value = union(Type) {
    const Self = @This();
    pub const Cons = struct {
        marked: bool = false,
        car: Value,
        cdr: Value,
    };
    pub const Lambda = struct {
        marked: bool = false,
        args: std.ArrayListUnmanaged(i32),
        binds: []Evaluator.Variable,
        body: Value,
        pub fn deinit(self: *@This(), alloc: Allocator) void {
            self.args.deinit(alloc);
            alloc.free(self.binds);
            self.* = undefined;
        }
    };
    nil,
    cons: *Cons,
    int: i64,
    bool: bool,
    symbol: i32,
    primitive: Evaluator.PrimitiveImpl,
    lambda: *Lambda,
    color: Color,

    pub fn toListPartial(self: Self) union(enum) { list: ?Cons, bad: Value } {
        const list = switch (self) {
            .cons => |c| c.*,
            .nil => null,
            else => return .{ .bad = self },
        };
        return .{ .list = list };
    }

    pub fn getType(self: Self) Type {
        return self;
    }

    pub fn eq(x: Self, y: Self) bool {
        if (x == .nil and y == .nil) return true;
        if (x == .int and y == .int) return x.int == y.int;
        if (x == .bool and y == .bool) return x.bool == y.bool;
        if (x == .symbol and y == .symbol) return x.symbol == y.symbol;
        if (x == .primitive and y == .primitive)
            return x.primitive == y.primitive;
        return false;
    }

    fn print_symbol(symbol: i32, writer: RuntimeWriter, maybe_symbols: ?SymbolTable) !void {
        if (maybe_symbols) |symbols| {
            if (quote_before_symbols) writer.writeByte('\'');
            try writer.writeAll(symbols.getByIndex(symbol));
        } else try writer.print("<{}>", .{symbol});
    }

    fn format_internal(
        self: Self,
        writer: RuntimeWriter,
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
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .symbol => |index| try Self.print_symbol(index, writer, maybe_symbols),
            .primitive => |func| {
                const this_addr = @ptrToInt(func);
                const name = for (Evaluator.primitives) |entry| {
                    if (this_addr == @ptrToInt(entry.impl)) break entry.name;
                } else return writer.writeAll("<private fn>");
                try writer.print("<fn {s}>", .{name});
            },
            .lambda => |lambda| {
                try writer.writeAll("<lambda");
                for (lambda.args.items) |symbol| {
                    try writer.writeByte(' ');
                    try Self.print_symbol(symbol, writer, maybe_symbols);
                }
                try writer.writeAll(": ");
                try lambda.body.format_internal(writer, false, maybe_symbols);
                try writer.writeAll(">");
            },
            .color => |color| {
                try writer.print("<color #{x:0>2}{x:0>2}{x:0>2}", .{ color.r, color.g, color.b });
                if (color.a < 255) try writer.print("{x:0>2}", .{color.a});
                try writer.writeAll(">");
            },
        }
    }

    pub fn print(self: Self, writer: RuntimeWriter, symbols: SymbolTable) !void {
        const maybe_symbols = if (pretty_print_symbols) symbols else null;
        return self.format_internal(writer, false, maybe_symbols);
    }
};
