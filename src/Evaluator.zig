const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const AllocError = Allocator.Error;

const SymbolTable = @import("SymbolTable.zig");
const Type = @import("value.zig").Type;
const Value = @import("value.zig").Value;
const Gc = @import("Gc.zig");
const RuntimeWriter = @import("RuntimeWriter.zig");

map: Map,
gc: *Gc,
visit_stack: std.ArrayListUnmanaged(Value) = .{},
writer: RuntimeWriter,
symbol_table: *SymbolTable,

pub const Variable = struct { symbol: i32, value: Value };
pub const Map = std.ArrayList(Variable);

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

fn GetArgsOutput(comptime num_args: comptime_int) type {
    return union(enum) {
        args: [num_args]Value,
        eval_error: EvalError,
    };
}

fn GetArgsPartialOutput(comptime num_args: comptime_int) type {
    return union(enum) {
        args: struct { first: [num_args]Value, rest: ?Value.Cons },
        eval_error: EvalError,
    };
}

fn getArgsNoEvalPartial(
    comptime num_args: comptime_int,
    list_: ?Value.Cons,
) GetArgsPartialOutput(num_args) {
    var list = list_;
    var args: [num_args]Value = undefined;
    for (args) |*arg| {
        const cons = list orelse return .{ .eval_error = .not_enough_args };
        arg.* = cons.car;
        list = switch (cons.cdr.toListPartial()) {
            .list => |c| c,
            .bad => return .{ .eval_error = .{ .malformed_list = cons.cdr } },
        };
    }
    return .{ .args = .{ .first = args, .rest = list } };
}

fn getArgsNoEval(comptime num_args: comptime_int, list: ?Value.Cons) GetArgsOutput(num_args) {
    return switch (getArgsNoEvalPartial(num_args, list)) {
        .args => |out| if (out.rest) |_| .{
            .eval_error = .{ .todo = "extra args" },
        } else .{ .args = out.first },
        .eval_error => |e| .{ .eval_error = e },
    };
}

fn getArgs(
    comptime num_args: comptime_int,
    self: *Self,
    list: ?Value.Cons,
) !GetArgsOutput(num_args) {
    var args = switch (getArgsNoEval(num_args, list)) {
        .args => |a| a,
        .eval_error => |e| return .{ .eval_error = e },
    };
    for (args) |*arg| {
        switch (try self.eval(arg.*)) {
            .value => |v| arg.* = v,
            .eval_error => |e| return .{ .eval_error = e },
        }
    }
    return .{ .args = args };
}

const primitive_impls = struct {
    fn quote(_: *Self, list_: ?Value.Cons) !EvalOutput {
        const cons = list_ orelse return .{ .value = .nil };
        switch (cons.cdr.toListPartial()) {
            .list => |v| if (v) |_| return .{ .eval_error = .{ .extra_args = cons.cdr } },
            .bad => return .{ .eval_error = .{ .malformed_list = cons.cdr } },
        }
        return .{ .value = cons.car };
    }
    fn atom(self: *Self, list: ?Value.Cons) !EvalOutput {
        const cons = list orelse return .{ .value = .nil };
        switch (cons.cdr.toListPartial()) {
            .list => |v| if (v) |_| return .{ .eval_error = .{ .extra_args = cons.cdr } },
            .bad => return .{ .eval_error = .{ .malformed_list = cons.cdr } },
        }
        const arg = switch (try self.eval(cons.car)) {
            .value => |v| v,
            else => |e| return e,
        };
        return .{ .value = .{ .bool = arg != .cons } };
    }
    fn eq(self: *Self, list: ?Value.Cons) !EvalOutput {
        const args = switch (try getArgs(2, self, list)) {
            .args => |a| a,
            .eval_error => |e| return .{ .eval_error = e },
        };
        const x = args[0];
        const y = args[1];
        return .{ .value = .{ .bool = x.eq(y) } };
    }
    fn car(self: *Self, list: ?Value.Cons) !EvalOutput {
        const args = switch (try getArgs(1, self, list)) {
            .args => |a| a,
            .eval_error => |e| return .{ .eval_error = e },
        };
        const x = switch (args[0]) {
            .cons => |c| c,
            else => |v| return .{ .eval_error = .{ .expected_type = .{
                .expected = TypeMask.new(&.{.cons}),
                .found = v,
            } } },
        };
        return .{ .value = x.car };
    }
    fn cdr(self: *Self, list: ?Value.Cons) !EvalOutput {
        const args = switch (try getArgs(1, self, list)) {
            .args => |a| a,
            .eval_error => |e| return .{ .eval_error = e },
        };
        const x = switch (args[0]) {
            .cons => |c| c,
            else => |v| return .{ .eval_error = .{ .expected_type = .{
                .expected = TypeMask.new(&.{.cons}),
                .found = v,
            } } },
        };
        return .{ .value = x.cdr };
    }
    fn create_cons(self: *Self, list: ?Value.Cons) !EvalOutput {
        const args = switch (try getArgs(2, self, list)) {
            .args => |a| a,
            .eval_error => |e| return .{ .eval_error = e },
        };
        const cons_inner = .{ .car = args[0], .cdr = args[1] };
        const cons = try self.gc.create_cons(cons_inner);
        return .{ .value = .{ .cons = cons } };
    }
    fn begin(self: *Self, list_: ?Value.Cons) !EvalOutput {
        const old_len = self.map.items.len;
        defer self.map.shrinkRetainingCapacity(old_len);
        var list = list_;
        var yielded_value: Value = .nil;
        while (list) |cons| {
            list = switch (cons.cdr.toListPartial()) {
                .list => |meow| meow,
                .bad => |b| return .{ .eval_error = .{ .malformed_list = b } },
            };
            yielded_value = switch (try self.eval(cons.car)) {
                .value => |v| v,
                else => |e| return e,
            };
        }
        return .{ .value = yielded_value };
    }
    fn create_lambda(self: *Self, list: ?Value.Cons) !EvalOutput {
        const out = switch (getArgsNoEvalPartial(1, list)) {
            .args => |a| a,
            .eval_error => |e| return .{ .eval_error = e },
        };
        const cons_args = out.first[0];
        var args = std.ArrayListUnmanaged(i32){};
        var is_error = true;
        defer if (is_error) args.deinit(self.gc.value_alloc);
        switch (cons_args) {
            .nil => {},
            .symbol => |symbol| try args.append(self.gc.value_alloc, symbol),
            .cons => |cons| {
                var arg_list: ?Value.Cons = cons.*;
                while (arg_list) |pair| {
                    switch (pair.car) {
                        .symbol => |symbol| try args.append(self.gc.value_alloc, symbol),
                        else => |v| return .{ .eval_error = .{ .expected_type = .{
                            .expected = TypeMask.new(&.{.symbol}),
                            .found = v,
                        } } },
                    }
                    arg_list = switch (pair.cdr.toListPartial()) {
                        .list => |x| x,
                        .bad => |b| return .{ .eval_error = .{ .malformed_list = b } },
                    };
                }
            },
            else => |v| return .{ .eval_error = .{ .expected_type = .{
                .expected = TypeMask.new(&.{ .cons, .symbol }),
                .found = v,
            } } },
        }
        var body = out.rest orelse return .{ .eval_error = .not_enough_args };
        try self.visit_stack.append(self.map.allocator, .{ .cons = &body });
        var binds = std.ArrayList(Variable).init(self.gc.value_alloc);
        defer binds.deinit();
        // TODO: binding any variables in lambda.args is redundant
        // e.g. (lambda x (lambda x x))
        // should we keep track of a set of symbols not to bind?
        while (self.visit_stack.popOrNull()) |visit| {
            switch (visit) {
                .nil, .int, .bool, .primitive_function => {},
                .symbol => |symbol| if (self.getVar(symbol)) |current_value| {
                    try binds.append(.{ .symbol = symbol, .value = current_value });
                },
                .cons => |pair| {
                    try self.visit_stack.append(self.map.allocator, pair.car);
                    try self.visit_stack.append(self.map.allocator, pair.cdr);
                },
                .lambda => |lambda| {
                    try self.visit_stack.append(self.map.allocator, lambda.body);
                },
            }
        }
        const runnable_body: Value = if (body.cdr == .nil) body.car else blk: {
            const cons_body = try self.gc.create_cons(body);
            const cons_inner = .{
                .car = .{ .primitive_function = begin },
                .cdr = .{ .cons = cons_body },
            };
            const cons = try self.gc.create_cons(cons_inner);
            break :blk .{ .cons = cons };
        };
        var lambda_inner = Value.Lambda{
            .args = args,
            .binds = binds.toOwnedSlice(),
            .body = runnable_body,
        };
        defer if (is_error) lambda_inner.deinit(self.gc.value_alloc);
        const lambda = try self.gc.create_lambda(lambda_inner);
        is_error = false;
        return .{ .value = .{ .lambda = lambda } };
    }
    // fn define(self: *Self, list: ?Value.Cons) !EvalOutput {

    // }
    fn add(self: *Self, list_: ?Value.Cons) !EvalOutput {
        var sum: i64 = 0;
        var list = list_;
        while (list) |cons| {
            list = switch (cons.cdr.toListPartial()) {
                .list => |meow| meow,
                .bad => |b| return .{ .eval_error = .{ .malformed_list = b } },
            };
            const arg = switch (try self.eval(cons.car)) {
                .value => |v| v,
                else => |e| return e,
            };
            sum +%= switch (arg) {
                .int => |i| i,
                else => |v| return .{ .eval_error = .{ .expected_type = .{
                    .expected = TypeMask.new(&.{.int}),
                    .found = v,
                } } },
            };
        }
        return .{ .value = .{ .int = sum } };
    }
    fn print(self: *Self, list: ?Value.Cons) !EvalOutput {
        const args = switch (try getArgs(1, self, list)) {
            .args => |a| a,
            .eval_error => |e| return .{ .eval_error = e },
        };
        const arg = args[0];
        try self.print_value(arg);
        return .{ .value = arg };
    }
    fn todo(_: *Self, _: ?Value.Cons) !EvalOutput {
        return .{ .eval_error = .{ .todo = "unimplemented function" } };
    }
};

pub const PrimitiveImpl = *const fn (*Self, ?Value.Cons) anyerror!EvalOutput;
const PrimitiveEntry = struct {
    name: []const u8,
    impl: PrimitiveImpl,
};
pub const primitive_functions = [_]PrimitiveEntry{
    .{ .name = "quote", .impl = primitive_impls.quote },
    .{ .name = "atom?", .impl = primitive_impls.atom },
    .{ .name = "nil?", .impl = primitive_impls.todo },
    .{ .name = "cons?", .impl = primitive_impls.todo },
    .{ .name = "int?", .impl = primitive_impls.todo },
    .{ .name = "bool?", .impl = primitive_impls.todo },
    .{ .name = "symbol?", .impl = primitive_impls.todo },
    .{ .name = "primitive?", .impl = primitive_impls.todo },
    .{ .name = "lambda?", .impl = primitive_impls.todo },
    .{ .name = "function?", .impl = primitive_impls.todo },
    .{ .name = "eq?", .impl = primitive_impls.eq },
    .{ .name = "car", .impl = primitive_impls.car },
    .{ .name = "cdr", .impl = primitive_impls.cdr },
    .{ .name = "cons", .impl = primitive_impls.create_cons },
    .{ .name = "cond", .impl = primitive_impls.todo },
    .{ .name = "define", .impl = primitive_impls.todo },
    .{ .name = "begin", .impl = primitive_impls.begin },
    .{ .name = "lambda", .impl = primitive_impls.create_lambda },
    .{ .name = "+", .impl = primitive_impls.add },
    .{ .name = "print", .impl = primitive_impls.print },
};

pub const EvalError = union(enum) {
    variable_not_found: i32,
    cannot_call: Value,
    malformed_list: Value,
    expected_type: struct { expected: TypeMask, found: Value },
    extra_args: Value,
    not_enough_args,
    todo: []const u8,

    pub fn print(self: @This(), writer: RuntimeWriter, symbols: SymbolTable) !void {
        return switch (self) {
            .variable_not_found => |s| writer.print(
                "variable `{s}` not defined",
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
                try writer.writeAll("malformed list at `");
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
            .extra_args => |v| {
                try writer.writeAll("extra args `");
                try v.print(writer, symbols);
                try writer.writeByte('`');
            },
            .not_enough_args => try writer.writeAll("not enough args"),
            .todo => |msg| try writer.print("TODO \"{s}\"", .{msg}),
        };
    }
};

pub const EvalOutput = union(enum) {
    value: Value,
    eval_error: EvalError,

    fn is_error(self: @This()) bool {
        return self == .eval_error;
    }
};

pub fn init(
    evaluator_alloc: Allocator,
    gc: *Gc,
    symbol_table: *SymbolTable,
    writer: RuntimeWriter,
) AllocError!Self {
    const len = primitive_functions.len;
    try symbol_table.ensureUnusedCapacity(len);
    var map = try Map.initCapacity(evaluator_alloc, len);
    errdefer map.deinit();
    for (primitive_functions) |entry| {
        const identifier = entry.name;
        const value = .{ .primitive_function = entry.impl };
        const symbol = try symbol_table.put(identifier);
        map.appendAssumeCapacity(.{ .symbol = symbol, .value = value });
    }
    return .{ .map = map, .gc = gc, .writer = writer, .symbol_table = symbol_table };
}

fn getVar(self: Self, symbol: i32) ?Value {
    const items = self.map.items;
    var i = items.len - 1;
    while (true) {
        const entry = items[i];
        if (entry.symbol == symbol) return entry.value;
        if (i == 0) return null else i -= 1;
    }
}

fn print_value(self: Self, value: Value) anyerror!void {
    try value.print(self.writer, self.symbol_table.*);
    try self.writer.writeByte('\n');
}

pub fn eval(self: *Self, value: Value) !EvalOutput {
    switch (value) {
        .nil, .bool, .int, .primitive_function, .lambda => return .{ .value = value },
        .symbol => |s| if (self.getVar(s)) |v| return .{ .value = v } else {
            return .{ .eval_error = .{ .variable_not_found = s } };
        },
        .cons => |pair| {
            const function_out = try self.eval(pair.car);
            if (function_out.is_error()) return function_out;
            const function = function_out.value;
            switch (function) {
                .primitive_function => |f| {
                    const args = pair.cdr.toListPartial();
                    switch (args) {
                        .list => |list| return f(self, list),
                        .bad => |v| return .{ .eval_error = .{ .malformed_list = v } },
                    }
                },
                .lambda => |lambda| {
                    const old_len = self.map.items.len;
                    defer self.map.shrinkRetainingCapacity(old_len);
                    try self.map.ensureUnusedCapacity(lambda.binds.len + lambda.args.items.len);
                    self.map.appendSliceAssumeCapacity(lambda.binds);
                    var arg_list: Value = pair.cdr;
                    for (lambda.args.items) |arg_symbol| {
                        const args = arg_list.toListPartial();
                        switch (args) {
                            .list => |list| if (list) |cons| {
                                const arg_value = switch (try self.eval(cons.car)) {
                                    .value => |v| v,
                                    else => |e| return e,
                                };
                                self.map.appendAssumeCapacity(.{
                                    .symbol = arg_symbol,
                                    .value = arg_value,
                                });
                                arg_list = cons.cdr;
                            } else return .{ .eval_error = .not_enough_args },
                            .bad => |v| return .{ .eval_error = .{ .malformed_list = v } },
                        }
                    }
                    switch (arg_list) {
                        .nil => {},
                        .cons => return .{ .eval_error = .{ .extra_args = arg_list } },
                        else => return .{ .eval_error = .{ .malformed_list = arg_list } },
                    }
                    return self.eval(lambda.body);
                },
                else => return .{ .eval_error = .{ .cannot_call = function } },
            }
        },
    }
}

pub fn deinit(self: *Self) void {
    self.visit_stack.deinit(self.map.allocator);
    self.map.deinit();
    self.* = undefined;
}
