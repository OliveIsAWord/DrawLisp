const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const AllocError = Allocator.Error;

const SymbolTable = @import("SymbolTable.zig");
const Type = @import("value.zig").Type;
const Value = @import("value.zig").Value;

map: Map,
value_alloc: Allocator,

const Map = std.AutoHashMap(i32, Value);

fn MaskFromEnum(comptime T: type) type {
    return struct {
        inner: BackingInt,

        const len = @typeInfo(T).Enum.fields.len;
        const field_list = blk: {
            var fields: [len][]const u8 = undefined;
            for (@typeInfo(T).Enum.fields) |field, i| {
                fields[i] = field.name;
            }
            break :blk fields;
        };
        const BackingInt = std.meta.Int(.unsigned, len);
        const WidthInt = std.math.Log2Int(BackingInt);

        fn new(types: []const T) @This() {
            const one: BackingInt = 1;
            var inner: BackingInt = 0;
            for (types) |t| {
                const index = for (field_list) |f, i| {
                    if (std.mem.eql(u8, f, @tagName(t))) break @intCast(WidthInt, i);
                } else unreachable;
                inner |= one << index;
            }
            return .{ .inner = inner };
        }
        fn print(self: @This(), writer: anytype) !void {
            var add_comma = false;
            const one: BackingInt = 1;
            var i: WidthInt = 0;
            while (i < len) : (i += 1) if (self.inner & (one << i) != 0) {
                if (add_comma) try writer.writeAll(", ") else add_comma = true;
                try writer.writeAll(field_list[i]);
            };
        }
    };
}
const TypeMask = MaskFromEnum(Type);

const primitive_impls = struct {
    fn add(list_: ?Value.Cons, _: Allocator) !EvalOutput {
        var sum: i64 = 0;
        var list = list_;
        while (list) |cons| {
            list = switch (cons.cdr.toListPartial()) {
                .list => |meow| meow,
                .bad => |b| return .{ .eval_error = .{ .malformed_list = b } },
            };
            sum += switch (cons.car) {
                .int => |i| i,
                else => |v| return .{ .eval_error = .{ .expected_type = .{
                    .expected = TypeMask.new(&.{.int}),
                    .found = v,
                } } },
            };
        }
        return .{ .value = .{ .int = sum } };
    }
};

pub const PrimitiveImpl = *const fn (?Value.Cons, Allocator) anyerror!EvalOutput;
const PrimitiveEntry = struct {
    name: []const u8,
    impl: PrimitiveImpl,
};
pub const primitive_functions = [_]PrimitiveEntry{
    .{ .name = "+", .impl = primitive_impls.add },
};

pub const EvalError = union(enum) {
    evaluated_symbol: i32,
    cannot_call: Value,
    malformed_list: Value,
    expected_type: struct { expected: TypeMask, found: Value },

    pub fn print(self: @This(), writer: anytype, symbols: SymbolTable) !void {
        return switch (self) {
            .evaluated_symbol => |s| writer.print(
                "could not evaluate symbol `{s}`",
                .{symbols.getByIndex(s)},
            ),
            .cannot_call => |v| {
                try writer.writeAll("cannot evaluate `");
                try v.print(writer, symbols);
                try writer.print(
                    "` as a function (because it is of type {s})",
                    .{@tagName(v.getType())},
                );
            },
            .malformed_list => |v| {
                try writer.writeAll("malformed list `");
                try v.print(writer, symbols);
                try writer.writeByte('`');
            },
            .expected_type => |meow| {
                try writer.writeAll("expected ");
                try meow.expected.print(writer);
                try writer.writeAll("; found `");
                try meow.found.print(writer, symbols);
                try writer.writeByte('`');
            },
        };
    }
};

pub const EvalOutput = union(enum) {
    value: Value,
    eval_error: EvalError,

    fn is_error(self: @This()) bool {
        return switch (self) {
            .value => false,
            .eval_error => true,
        };
    }
};

pub fn init(
    evaluator_alloc: Allocator,
    value_alloc: Allocator,
    symbol_table: *SymbolTable,
) AllocError!Self {
    var map = Map.init(evaluator_alloc);
    inline for (primitive_functions) |entry| {
        const identifier = entry.name;
        const value = .{ .primitive_function = entry.impl };
        const symbol = try symbol_table.put(identifier);
        try map.put(symbol, value);
    }
    return .{ .map = map, .value_alloc = value_alloc };
}

pub fn eval(self: *Self, value: Value) !EvalOutput {
    _ = .{ self, value };
    const yielded_value: Value = switch (value) {
        .nil, .bool, .int => value,
        .symbol => |s| if (self.map.get(s)) |v| v else {
            return .{ .eval_error = .{ .evaluated_symbol = s } };
        },
        .cons => |pair| {
            const function_out = try self.eval(pair.get().car);
            if (function_out.is_error()) return function_out;
            const function = function_out.value;
            const f = switch (function) {
                .primitive_function => |f| f,
                else => return .{ .eval_error = .{ .cannot_call = function } },
            };
            const args = pair.get().cdr.toListPartial();
            switch (args) {
                .list => |list| return f(list, self.value_alloc),
                .bad => |v| return .{ .eval_error = .{ .malformed_list = v } },
            }
        },
        .primitive_function => unreachable,
    };
    return .{ .value = yielded_value };
}

pub fn deinit(self: *Self) void {
    var iter = self.map.iterator();
    while (iter.next()) |entry| {
        entry.value_ptr.deinit(self.value_alloc);
    }
    self.map.deinit();
    self.* = undefined;
}
