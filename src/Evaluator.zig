const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const AllocError = Allocator.Error;
const Thread = std.Thread;
const math = std.math;
const nanoTimestamp = std.time.nanoTimestamp;

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const SymbolTable = @import("SymbolTable.zig");
const Type = @import("value.zig").Type;
const Value = @import("value.zig").Value;
const Gc = @import("Gc.zig");
const RuntimeWriter = @import("RuntimeWriter.zig");
const canvas_runner = @import("canvas_runner.zig");
const CanvasMessage = canvas_runner.Message;
const Queue = @import("mpmc_queue.zig").MPMCQueueUnmanaged;
const Color = @import("Color.zig");
const Rng = @import("Rng.zig");

map: Map,
gc: *Gc,
visit_stack: std.ArrayListUnmanaged(Value) = .{},
writer: RuntimeWriter,
symbol_table: *SymbolTable,
draw_queue: *Queue(CanvasMessage),
draw_error_queue: *Queue([]const u8),
draw_thread: Thread,
recursion_limit: usize = 500,
stacktrace: std.ArrayListUnmanaged(*Value.Cons) = .{},
types_to_symbols: [max_type_tag]i32,
start_time: i128,
rng: Rng = Rng.init(0),

const max_type_tag = blk: {
    var max = 0;
    for (@typeInfo(Type).Enum.fields) |field| max = @max(max, field.value);
    break :blk max + 1;
};

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
        const BackingInt = std.meta.Int(.unsigned, len + 1);
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

fn GetCintArgsOutput(comptime num_args: comptime_int) type {
    return union(enum) {
        args: [num_args]c_int,
        eval_error: EvalError,
    };
}

fn GetVarArgsOutput(comptime num_args: comptime_int) type {
    return union(enum) {
        args: struct { buffer: [num_args]Value, len: usize },
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
        .args => |out| if (out.rest) |arg_cons| .{
            .eval_error = .{ .extra_args = arg_cons },
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

fn getVarArgsNoEval(
    comptime min_args: comptime_int,
    comptime max_args: comptime_int,
    list_: ?Value.Cons,
) GetVarArgsOutput(max_args) {
    comptime std.debug.assert(min_args <= max_args);
    var list = list_;
    var args: [max_args]Value = undefined;
    var len: usize = 0;
    for (args) |*arg| {
        const cons = list orelse break;
        arg.* = cons.car;
        list = switch (cons.cdr.toListPartial()) {
            .list => |c| c,
            .bad => return .{ .eval_error = .{ .malformed_list = cons.cdr } },
        };
        len += 1;
    }
    if (len < min_args) return .{ .eval_error = .not_enough_args };
    return .{ .args = .{ .buffer = args, .len = len } };
}

fn getVarArgs(
    comptime min_args: comptime_int,
    comptime max_args: comptime_int,
    self: *Self,
    list: ?Value.Cons,
) !GetVarArgsOutput(max_args) {
    var out = switch (getVarArgsNoEval(min_args, max_args, list)) {
        .args => |a| a,
        .eval_error => |e| return .{ .eval_error = e },
    };
    for (out.buffer[0..out.len]) |*arg| {
        switch (try self.eval(arg.*)) {
            .value => |v| arg.* = v,
            .eval_error => |e| return .{ .eval_error = e },
        }
    }
    return .{ .args = out };
}

fn getCintArgs(
    comptime num_args: comptime_int,
    self: *Self,
    list: ?Value.Cons,
) !GetCintArgsOutput(num_args) {
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
    var ints: [num_args]c_int = undefined;
    for (args) |arg, i| {
        switch (arg) {
            .int => |v| if (cast_cint(v)) |cint| {
                ints[i] = cint;
            } else return .{
                .eval_error = .{ .out_of_cint_range = v },
            },
            else => return .{ .eval_error = .{ .expected_type = .{
                .expected = TypeMask.new(&.{.int}),
                .found = arg,
            } } },
        }
    }
    return .{ .args = ints };
}

fn is_type(comptime types: anytype) PrimitiveImpl {
    return struct {
        fn f(self: *Self, list: ?Value.Cons) !EvalOutput {
            const arg = switch (try getArgs(1, self, list)) {
                .args => |a| a[0],
                .eval_error => |e| return .{ .eval_error = e },
            };
            const arg_is_type = inline for (types) |type_| {
                if (arg == type_) break true;
            } else false;
            return .{ .value = .{ .bool = arg_is_type } };
        }
    }.f;
}

fn set_cons_field(comptime field: []const u8) fn (self: *Self, list: ?Value.Cons) anyerror!EvalOutput {
    return struct {
        fn f(self: *Self, list: ?Value.Cons) !EvalOutput {
            const args = switch (try getArgs(2, self, list)) {
                .args => |a| a,
                .eval_error => |e| return .{ .eval_error = e },
            };
            const cons = switch (args[0]) {
                .cons => |c| c,
                else => |e| return .{ .eval_error = .{ .expected_type = .{
                    .expected = TypeMask.new(&.{.cons}),
                    .found = e,
                } } },
            };
            @field(cons, field) = args[1];
            return .{ .value = .nil };
        }
    }.f;
}

const RangeParameters = struct { start: i64, end: i64, step: i64 };
const GetRangeParametersOut = union(enum) {
    parameters: RangeParameters,
    eval_error: EvalError,
};
fn getRangeParameters(self: *Self, list: ?Value.Cons) !GetRangeParametersOut {
    var buffer: [3]i64 = undefined;
    var len: usize = undefined;
    switch (try getVarArgs(1, 3, self, list)) {
        .args => |out| {
            len = out.len;
            for (out.buffer[0..len]) |v, i| switch (v) {
                .int => |n| buffer[i] = n,
                else => return .{ .eval_error = .{ .expected_type = .{
                    .expected = TypeMask.new(&.{.int}),
                    .found = v,
                } } },
            };
        },
        .eval_error => |e| return .{ .eval_error = e },
    }
    const range: RangeParameters = switch (len) {
        1 => if (buffer[0] < 0) .{
            .start = buffer[0],
            .end = 0,
            .step = 1,
        } else .{
            .start = 0,
            .end = buffer[0],
            .step = 1,
        },
        2 => .{
            .start = buffer[0],
            .end = buffer[1],
            .step = math.sign(buffer[1] -| buffer[0]),
        },
        3 => .{ .start = buffer[0], .end = buffer[1], .step = buffer[2] },
        else => unreachable,
    };
    return .{ .parameters = range };
}

fn todo(_: *Self, _: ?Value.Cons) !EvalOutput {
    return .{ .eval_error = .{ .todo = "unimplemented function" } };
}

fn checkedWrappingDiv(dividend: i64, divisor: i64) ?i64 {
    const min_int: i64 = math.minInt(i64);
    if (divisor == 0) return null;
    if (dividend == min_int and divisor == -1) return min_int;
    return @divFloor(dividend, divisor);
}

// @divFloor(a, b) * b + @mod(a, b) == a
// @mod(a, b) == a - @divFloor(a, b) * b
fn checkedWrappingMod(dividend: i64, divisor: i64) ?i64 {
    const quotient = checkedWrappingDiv(dividend, divisor) orelse return null;
    return dividend -% quotient *% divisor;
}

// /// Fallibly casts any integer type to a non-negative `c_int`
// fn cast_cint_nonn(int: anytype) ?c_int {
//     const i = cast_cint(int) orelse return null;
//     return if (i >= 0) i else null;
// }

/// Fallibly casts any integer type to a `c_int`
fn cast_cint(int: anytype) ?c_int {
    return math.cast(c_int, int);
}

fn saturatingCast(comptime Int: type, value: anytype) Int {
    const min = math.minInt(Int);
    const max = math.maxInt(Int);
    return if (value < min)
        min
    else if (value > max)
        max
    else
        @intCast(Int, value);
}

const lexical_settings = .{
    .{ ":clear-color", "set_clear_color" },
    .{ ":fill-color", "set_fill_color" },
    .{ ":stroke-color", "set_stroke_color" },
};

const primitive_impls = struct {
    fn quote(_: *Self, list: ?Value.Cons) !EvalOutput {
        return switch (getArgsNoEval(1, list)) {
            .args => |a| .{ .value = a[0] },
            .eval_error => |e| .{ .eval_error = e },
        };
    }
    fn eval(self: *Self, list: ?Value.Cons) !EvalOutput {
        const args = switch (try getArgs(1, self, list)) {
            .args => |a| a,
            .eval_error => |e| return .{ .eval_error = e },
        };
        return self.eval(args[0]);
    }
    fn apply(self: *Self, list: ?Value.Cons) !EvalOutput {
        const args = switch (try getArgs(2, self, list)) {
            .args => |a| a,
            .eval_error => |e| return .{ .eval_error = e },
        };
        const func = args[0];
        const arg_list = args[1];
        // Eagerly catch this error before we evaluate anything, just for fun
        if (arg_list != .nil and arg_list != .cons) return .{ .eval_error = .{ .expected_type = .{
            .expected = TypeMask.new(&.{ .nil, .cons }),
            .found = arg_list,
        } } };
        const func_call = .{ .cons = try self.gc.create_cons(.{ .car = func, .cdr = arg_list }) };
        return self.eval(func_call);
    }
    fn @"while"(self: *Self, list: ?Value.Cons) !EvalOutput {
        const func = switch (getArgsNoEvalPartial(2, list)) {
            .args => |a| a.first[0],
            .eval_error => |e| return .{ .eval_error = e },
        };
        const body = .{ .cons = try self.gc.create_cons(.{
            .car = .{ .primitive = begin },
            .cdr = list.?.cdr,
        }) };
        while (true) {
            const old_len = self.map.items.len;
            defer self.destroyScope(old_len);
            switch (try self.eval(func)) {
                .value => |v| switch (v) {
                    .bool => |b| if (!b) return .{ .value = .nil },
                    else => return .{ .eval_error = .{ .expected_type = .{
                        .expected = TypeMask.new(&.{.bool}),
                        .found = v,
                    } } },
                },
                else => |e| return e,
            }
            switch (try self.eval(body)) {
                .value => {},
                else => |e| return e,
            }
        }
    }
    fn @"type-of"(self: *Self, list: ?Value.Cons) !EvalOutput {
        const args = switch (try getArgs(1, self, list)) {
            .args => |a| a,
            .eval_error => |e| return .{ .eval_error = e },
        };
        const symbol = self.types_to_symbols[@enumToInt(args[0])];
        return .{ .value = .{ .symbol = symbol } };
    }
    const @"atom?" = is_type(.{ .nil, .int, .bool, .symbol, .primitive, .lambda, .color });
    const @"nil?" = is_type(.{.nil});
    const @"cons?" = is_type(.{.cons});
    const @"int?" = is_type(.{.int});
    const @"bool?" = is_type(.{.bool});
    const @"symbol?" = is_type(.{.symbol});
    const @"primitive?" = is_type(.{.primitive});
    const @"lambda?" = is_type(.{.lambda});
    const @"function?" = is_type(.{ .primitive, .lambda });
    const @"color?" = is_type(.{.color});
    fn @"eq?"(self: *Self, list: ?Value.Cons) !EvalOutput {
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
    const @"set-car!" = set_cons_field("car");
    const @"set-cdr!" = set_cons_field("cdr");
    fn @" cons"(self: *Self, list: ?Value.Cons) !EvalOutput {
        const args = switch (try getArgs(2, self, list)) {
            .args => |a| a,
            .eval_error => |e| return .{ .eval_error = e },
        };
        const cons_inner = .{ .car = args[0], .cdr = args[1] };
        const cons = try self.gc.create_cons(cons_inner);
        return .{ .value = .{ .cons = cons } };
    }
    fn map(self: *Self, list: ?Value.Cons) !EvalOutput {
        const out = switch (try getArgs(2, self, list)) {
            .args => |a| a,
            .eval_error => |e| return .{ .eval_error = e },
        };
        const op = out[0];
        if (op != .lambda and op != .primitive)
            return .{ .eval_error = .{ .cannot_call = op } };
        var cur_list = out[1];
        if (cur_list != .nil and cur_list != .cons) {
            return .{ .eval_error = .{ .expected_type = .{
                .expected = TypeMask.new(&.{ .nil, .cons }),
                .found = cur_list,
            } } };
        }
        var out_list: Value = .nil;
        var nil_ptr: *Value = undefined;
        while (true) {
            const element = switch (cur_list.toListPartial()) {
                .list => |list2| if (list2) |cons| blk: {
                    cur_list = cons.cdr;
                    break :blk cons.car;
                } else break,
                .bad => |b| return .{ .eval_error = .{ .malformed_list = b } },
            };
            var local_cons1 = .{ .car = element, .cdr = .nil };
            var local_cons2 = .{ .car = op, .cdr = .{ .cons = try self.gc.create_cons(local_cons1) } };
            const op_call = .{ .cons = try self.gc.create_cons(local_cons2) };
            const out_element = switch (try self.eval(op_call)) {
                .value => |v| v,
                else => |e| return e,
            };
            const new_cons = try self.gc.create_cons(.{ .car = out_element, .cdr = .nil });
            if (out_list == .nil)
                out_list = .{ .cons = new_cons }
            else
                nil_ptr.* = .{ .cons = new_cons };
            nil_ptr = &new_cons.cdr;
        }
        return .{ .value = out_list };
    }

    fn filter(self: *Self, list: ?Value.Cons) !EvalOutput {
        const out = switch (try getArgs(2, self, list)) {
            .args => |a| a,
            .eval_error => |e| return .{ .eval_error = e },
        };
        const op = out[0];
        if (op != .lambda and op != .primitive)
            return .{ .eval_error = .{ .cannot_call = op } };
        var cur_list = out[1];
        if (cur_list != .nil and cur_list != .cons) {
            return .{ .eval_error = .{ .expected_type = .{
                .expected = TypeMask.new(&.{ .nil, .cons }),
                .found = cur_list,
            } } };
        }
        var out_list: Value = .nil;
        var nil_ptr: *Value = undefined;
        while (true) {
            const element = switch (cur_list.toListPartial()) {
                .list => |list2| if (list2) |cons| blk: {
                    cur_list = cons.cdr;
                    break :blk cons.car;
                } else break,
                .bad => |b| return .{ .eval_error = .{ .malformed_list = b } },
            };
            var local_cons1 = .{ .car = element, .cdr = .nil };
            var local_cons2 = .{ .car = op, .cdr = .{ .cons = try self.gc.create_cons(local_cons1) } };
            const op_call = .{ .cons = try self.gc.create_cons(local_cons2) };
            const should_retain = switch (try self.eval(op_call)) {
                .value => |v| switch (v) {
                    .bool => |b| b,
                    else => |bad_type| return .{ .eval_error = .{ .expected_type = .{
                        .expected = TypeMask.new(&.{.bool}),
                        .found = bad_type,
                    } } },
                },
                else => |e| return e,
            };
            if (should_retain) {
                const new_cons = try self.gc.create_cons(.{ .car = element, .cdr = .nil });
                if (out_list == .nil)
                    out_list = .{ .cons = new_cons }
                else
                    nil_ptr.* = .{ .cons = new_cons };
                nil_ptr = &new_cons.cdr;
            }
        }
        return .{ .value = out_list };
    }
    fn fold(self: *Self, list: ?Value.Cons) !EvalOutput {
        const out = switch (try getArgs(3, self, list)) {
            .args => |a| a,
            .eval_error => |e| return .{ .eval_error = e },
        };
        const op = out[0];
        if (op != .lambda and op != .primitive)
            return .{ .eval_error = .{ .cannot_call = op } };
        var accumulator = out[1];
        var cur_list = out[2];
        if (cur_list != .nil and cur_list != .cons) {
            return .{ .eval_error = .{ .expected_type = .{
                .expected = TypeMask.new(&.{ .nil, .cons }),
                .found = cur_list,
            } } };
        }
        while (true) {
            const element = switch (cur_list.toListPartial()) {
                .list => |list2| if (list2) |cons| blk: {
                    cur_list = cons.cdr;
                    break :blk cons.car;
                } else break,
                .bad => |b| return .{ .eval_error = .{ .malformed_list = b } },
            };
            var local_cons1 = .{ .car = element, .cdr = .nil };
            var local_cons2 = .{ .car = accumulator, .cdr = .{ .cons = try self.gc.create_cons(local_cons1) } };
            var local_cons3 = .{ .car = op, .cdr = .{ .cons = try self.gc.create_cons(local_cons2) } };
            const op_call = .{ .cons = try self.gc.create_cons(local_cons3) };
            accumulator = switch (try self.eval(op_call)) {
                .value => |v| v,
                else => |e| return e,
            };
        }
        return .{ .value = accumulator };
    }
    fn range(self: *Self, list: ?Value.Cons) !EvalOutput {
        const parameters = switch (try getRangeParameters(self, list)) {
            .parameters => |p| p,
            .eval_error => |e| return .{ .eval_error = e },
        };
        var out_list: Value = .nil;
        if (parameters.start != parameters.end) {
            const s = math.sign(parameters.step);
            if (s == 0) return .{ .eval_error = .division_by_zero };
            var i = parameters.end;
            while (true) {
                i = math.sub(i64, i, parameters.step) catch break;
                if (math.sign(i +| s -| parameters.start) != s) break;
                const new_link = .{ .car = .{ .int = i }, .cdr = out_list };
                out_list = .{ .cons = try self.gc.create_cons(new_link) };
            }
        }
        return .{ .value = out_list };
    }
    fn cond(self: *Self, list_: ?Value.Cons) !EvalOutput {
        var list = list_;
        while (list) |cons| {
            const branch = switch (cons.car.toListPartial()) {
                .list => |v| v,
                .bad => |b| return .{ .eval_error = .{ .malformed_list = b } },
            };
            list = switch (cons.cdr.toListPartial()) {
                .list => |v| v,
                .bad => |b| return .{ .eval_error = .{ .malformed_list = b } },
            };
            const out = switch (getArgsNoEvalPartial(1, branch)) {
                .args => |a| a,
                .eval_error => |e| return .{ .eval_error = e },
            };
            const body = out.rest orelse return .{ .eval_error = .not_enough_args };
            const condition = switch (try self.eval(out.first[0])) {
                .value => |v| switch (v) {
                    .bool => |b| b,
                    else => |e| return .{ .eval_error = .{ .expected_type = .{
                        .expected = TypeMask.new(&.{.bool}),
                        .found = e,
                    } } },
                },
                else => |e| return e,
            };
            if (condition) return begin(self, body);
        }
        return .{ .value = .nil };
    }
    fn @"if"(self: *Self, list: ?Value.Cons) !EvalOutput {
        const out = switch (getArgsNoEvalPartial(2, list)) {
            .args => |a| a,
            .eval_error => |e| return .{ .eval_error = e },
        };
        const condition = out.first[0];
        const true_body = out.first[1];
        const false_body = if (out.rest) |cons| switch (cons.cdr) {
            .nil => cons.car,
            .cons => |c| return .{ .eval_error = .{ .extra_args = c.* } },
            else => |e| return .{ .eval_error = .{ .malformed_list = e } },
        } else .nil;
        const evaled_condition = switch (try self.eval(condition)) {
            .value => |v| v,
            else => |e| return e,
        };
        const body_to_eval = switch (evaled_condition) {
            .bool => |b| if (b) true_body else false_body,
            else => |v| return .{ .eval_error = .{ .expected_type = .{
                .expected = TypeMask.new(&.{.bool}),
                .found = v,
            } } },
        };
        return self.eval(body_to_eval);
    }
    fn begin(self: *Self, list_: ?Value.Cons) !EvalOutput {
        const old_len = self.map.items.len;
        defer self.destroyScope(old_len);
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
    fn @" lambda"(self: *Self, list: ?Value.Cons) !EvalOutput {
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
                .expected = TypeMask.new(&.{ .nil, .cons, .symbol }),
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
                .nil, .int, .bool, .primitive, .color => {},
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
                .car = .{ .primitive = begin },
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
    fn let(self: *Self, list: ?Value.Cons) !EvalOutput {
        const out = switch (getArgsNoEvalPartial(1, list)) {
            .args => |a| a,
            .eval_error => |e| return .{ .eval_error = e },
        };
        const symbol_to_define = out.first[0];
        const block = out.rest orelse return .{ .eval_error = .not_enough_args };
        switch (symbol_to_define) {
            .symbol => |symbol| {
                const init_value = switch (try begin(self, block)) {
                    .value => |v| v,
                    else => |e| return e,
                };
                inline for (lexical_settings) |setting| {
                    if (self.symbol_table.getOrNull(setting[0]) == symbol) {
                        if (init_value != .color) return .{ .eval_error = .{ .expected_type = .{
                            .expected = TypeMask.new(&.{.color}),
                            .found = init_value,
                        } } };
                        var message = @unionInit(CanvasMessage, setting[1], init_value.color);
                        self.draw_queue.push(message);
                        break;
                    }
                } else if (self.symbol_table.getByIndex(symbol)[0] == ':') {
                    return .{ .eval_error = .{ .unknown_lexical_setting = symbol } };
                }
                try self.map.append(.{ .symbol = symbol, .value = init_value });
                return .{ .value = init_value };
            },
            .cons => return .{ .eval_error = .{ .todo = "defining functions" } },
            else => |e| return .{ .eval_error = .{ .expected_type = .{
                .expected = TypeMask.new(&.{ .symbol, .cons }),
                .found = e,
            } } },
        }
    }
    fn @"+"(self: *Self, list_: ?Value.Cons) !EvalOutput {
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
    // We do a little code duplication :3
    fn @"*"(self: *Self, list_: ?Value.Cons) !EvalOutput {
        var product: i64 = 1;
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
            product *%= switch (arg) {
                .int => |i| i,
                else => |v| return .{ .eval_error = .{ .expected_type = .{
                    .expected = TypeMask.new(&.{.int}),
                    .found = v,
                } } },
            };
        }
        return .{ .value = .{ .int = product } };
    }
    fn @"-"(self: *Self, list: ?Value.Cons) !EvalOutput {
        var cons = list orelse return .{ .eval_error = .not_enough_args };
        var difference: i64 = switch (try self.eval(cons.car)) {
            .value => |v| switch (v) {
                .int => |i| i,
                else => |bad| return .{ .eval_error = .{ .expected_type = .{
                    .expected = TypeMask.new(&.{.int}),
                    .found = bad,
                } } },
            },
            else => |e| return e,
        };
        cons = switch (cons.cdr) {
            // `(- a)` => -a, wrapping negation
            .nil => return .{ .value = .{ .int = -%difference } },
            .cons => |c| c.*,
            else => |b| return .{ .eval_error = .{ .malformed_list = b } },
        };
        while (true) {
            const arg = switch (try self.eval(cons.car)) {
                .value => |v| v,
                else => |e| return e,
            };
            difference -%= switch (arg) {
                .int => |i| i,
                else => |v| return .{ .eval_error = .{ .expected_type = .{
                    .expected = TypeMask.new(&.{.int}),
                    .found = v,
                } } },
            };
            cons = switch (cons.cdr.toListPartial()) {
                .list => |meow| meow orelse break,
                .bad => |b| return .{ .eval_error = .{ .malformed_list = b } },
            };
        }
        return .{ .value = .{ .int = difference } };
    }
    fn @"/"(self: *Self, list: ?Value.Cons) !EvalOutput {
        var cons = list orelse return .{ .eval_error = .not_enough_args };
        var quotient: i64 = switch (try self.eval(cons.car)) {
            .value => |v| switch (v) {
                .int => |i| i,
                else => |bad| return .{ .eval_error = .{ .expected_type = .{
                    .expected = TypeMask.new(&.{.int}),
                    .found = bad,
                } } },
            },
            else => |e| return e,
        };
        cons = switch (cons.cdr) {
            // We do not support the reciprocal function `(/ a)`, since it's not useful for integers
            .nil => return .{ .eval_error = .not_enough_args },
            .cons => |c| c.*,
            else => |b| return .{ .eval_error = .{ .malformed_list = b } },
        };
        while (true) {
            const arg = switch (try self.eval(cons.car)) {
                .value => |v| switch (v) {
                    .int => |i| i,
                    else => |bad_type| return .{ .eval_error = .{ .expected_type = .{
                        .expected = TypeMask.new(&.{.int}),
                        .found = bad_type,
                    } } },
                },
                else => |e| return e,
            };
            quotient = checkedWrappingDiv(quotient, arg) orelse
                return .{ .eval_error = .division_by_zero };
            cons = switch (cons.cdr.toListPartial()) {
                .list => |meow| meow orelse break,
                .bad => |b| return .{ .eval_error = .{ .malformed_list = b } },
            };
        }
        return .{ .value = .{ .int = quotient } };
    }
    // More code duplication! >:3
    fn @"%"(self: *Self, list: ?Value.Cons) !EvalOutput {
        var cons = list orelse return .{ .eval_error = .not_enough_args };
        var quotient: i64 = switch (try self.eval(cons.car)) {
            .value => |v| switch (v) {
                .int => |i| i,
                else => |bad| return .{ .eval_error = .{ .expected_type = .{
                    .expected = TypeMask.new(&.{.int}),
                    .found = bad,
                } } },
            },
            else => |e| return e,
        };
        cons = switch (cons.cdr) {
            // We do not support the reciprocal function `(/ a)`, since it's not useful for integers
            .nil => return .{ .eval_error = .not_enough_args },
            .cons => |c| c.*,
            else => |b| return .{ .eval_error = .{ .malformed_list = b } },
        };
        while (true) {
            const arg = switch (try self.eval(cons.car)) {
                .value => |v| switch (v) {
                    .int => |i| i,
                    else => |bad_type| return .{ .eval_error = .{ .expected_type = .{
                        .expected = TypeMask.new(&.{.int}),
                        .found = bad_type,
                    } } },
                },
                else => |e| return e,
            };
            quotient = checkedWrappingMod(quotient, arg) orelse
                return .{ .eval_error = .division_by_zero };
            cons = switch (cons.cdr.toListPartial()) {
                .list => |meow| meow orelse break,
                .bad => |b| return .{ .eval_error = .{ .malformed_list = b } },
            };
        }
        return .{ .value = .{ .int = quotient } };
    }
    fn @"rand-int"(self: *Self, list: ?Value.Cons) !EvalOutput {
        const parameters = switch (try getRangeParameters(self, list)) {
            .parameters => |p| p,
            .eval_error => |e| return .{ .eval_error = e },
        };
        const start: i128 = parameters.start;
        const end: i128 = parameters.end;
        const step: i128 = parameters.step;
        const i = math.divCeil(i128, end - start, step) catch
            return .{ .eval_error = .division_by_zero };
        if (i <= 0) return .{ .eval_error = .division_by_zero };
        const u = @intCast(u64, i);
        const num_steps = self.rng.next() % u;
        return .{ .value = .{ .int = @intCast(i64, start + step * num_steps) } };
    }
    fn @"seed"(self: *Self, list: ?Value.Cons) !EvalOutput {
        const args = switch (try getArgs(1, self, list)) {
            .args => |a| a,
            .eval_error => |e| return .{ .eval_error = e },
        };
        const x = switch (args[0]) {
            .int => |i| i,
            else => |v| return .{ .eval_error = .{ .expected_type = .{
                .expected = TypeMask.new(&.{.int}),
                .found = v,
            } } },
        };
        self.rng = Rng.init(x);
        return .{ .value = .nil };
    }
    fn print(self: *Self, list: ?Value.Cons) !EvalOutput {
        const args = switch (try getArgs(1, self, list)) {
            .args => |a| a,
            .eval_error => |e| return .{ .eval_error = e },
        };
        const arg = args[0];
        try self.printValue(arg);
        return .{ .value = .nil };
    }
    fn @"time-ns"(self: *Self, list: ?Value.Cons) !EvalOutput {
        if (list) |args_cons| return .{ .eval_error = .{ .extra_args = args_cons } };
        const time = nanoTimestamp() - self.start_time;
        // This will overflow after about ~292.5 years. So much for Zig's claims of "robust" software...
        return .{ .value = .{ .int = @truncate(i64, time) } };
    }
    const @"set!" = todo;

    fn color(self: *Self, list: ?Value.Cons) !EvalOutput {
        const args = switch (try getVarArgs(1, 4, self, list)) {
            .args => |a| a,
            .eval_error => |e| return .{ .eval_error = e },
        };
        if (args.len == 2) return .{ .eval_error = .not_enough_args };
        var ints: [4]u8 = undefined;
        for (args.buffer[0..args.len]) |a, i| {
            switch (a) {
                .int => |v| ints[i] = saturatingCast(u8, v),
                else => return .{ .eval_error = .{ .expected_type = .{
                    .expected = TypeMask.new(&.{.int}),
                    .found = a,
                } } },
            }
        }
        if (args.len == 1) {
            ints[1] = ints[0];
            ints[2] = ints[0];
        }
        if (args.len < 4) ints[3] = 255;
        const meow_color = .{ .r = ints[0], .g = ints[1], .b = ints[2], .a = ints[3] };
        return .{ .value = .{ .color = meow_color } };
    }

    fn @"create-window"(self: *Self, list: ?Value.Cons) !EvalOutput {
        const dimensions: [2]c_int = if (list == null) .{ 500, 500 } else switch (try getCintArgs(2, self, list)) {
            .args => |a| a,
            .eval_error => |e| return .{ .eval_error = e },
        };
        const width = dimensions[0];
        const height = dimensions[1];
        self.draw_queue.push(.{ .create_window = .{ .width = width, .height = height } });
        return .{ .value = .nil };
    }

    fn @"resize-window"(self: *Self, list: ?Value.Cons) !EvalOutput {
        const dimensions: [2]c_int = if (list == null) .{ 500, 500 } else switch (try getCintArgs(2, self, list)) {
            .args => |a| a,
            .eval_error => |e| return .{ .eval_error = e },
        };
        const width = dimensions[0];
        const height = dimensions[1];
        self.draw_queue.push(.{ .resize_window = .{ .width = width, .height = height } });
        return .{ .value = .nil };
    }

    fn @"reposition-window"(self: *Self, list: ?Value.Cons) !EvalOutput {
        const dimensions: [2]c_int = switch (try getCintArgs(2, self, list)) {
            .args => |a| a,
            .eval_error => |e| return .{ .eval_error = e },
        };
        const x = dimensions[0];
        const y = dimensions[1];
        self.draw_queue.push(.{ .reposition_window = .{ .x = x, .y = y } });
        return .{ .value = .nil };
    }

    fn draw(self: *Self, list: ?Value.Cons) !EvalOutput {
        if (list) |args_cons| return .{ .eval_error = .{ .extra_args = args_cons } };
        self.draw_queue.push(.draw);
        return .{ .value = .nil };
    }

    fn clear(self: *Self, list: ?Value.Cons) !EvalOutput {
        if (list) |args_cons| return .{ .eval_error = .{ .extra_args = args_cons } };
        self.draw_queue.push(.clear);
        return .{ .value = .nil };
    }

    fn point(self: *Self, list: ?Value.Cons) !EvalOutput {
        const coordinates = switch (try getCintArgs(2, self, list)) {
            .args => |a| a,
            .eval_error => |e| return .{ .eval_error = e },
        };
        const x = coordinates[0];
        const y = coordinates[1];
        self.draw_queue.push(.{ .point = .{ .x = x, .y = y } });
        return .{ .value = .nil };
    }

    fn line(self: *Self, list: ?Value.Cons) !EvalOutput {
        const v = switch (try getCintArgs(4, self, list)) {
            .args => |a| a,
            .eval_error => |e| return .{ .eval_error = e },
        };
        self.draw_queue.push(.{ .line = .{ .x1 = v[0], .y1 = v[1], .x2 = v[2], .y2 = v[3] } });
        return .{ .value = .nil };
    }

    fn rect(self: *Self, list: ?Value.Cons) !EvalOutput {
        const v = switch (try getCintArgs(4, self, list)) {
            .args => |a| a,
            .eval_error => |e| return .{ .eval_error = e },
        };
        self.draw_queue.push(.{ .rect = .{ .x = v[0], .y = v[1], .w = v[2], .h = v[3] } });
        return .{ .value = .nil };
    }

    fn @"destroy-window"(self: *Self, list: ?Value.Cons) !EvalOutput {
        if (list) |args_cons| return .{ .eval_error = .{ .extra_args = args_cons } };
        self.draw_queue.push(.destroy_window);
        return .{ .value = .nil };
    }
};

pub const PrimitiveImpl = *const fn (*Self, ?Value.Cons) anyerror!EvalOutput;
const PrimitiveEntry = struct {
    name: []const u8,
    impl: PrimitiveImpl,
};
pub const primitives = blk: {
    const show_me_todos = false;
    var todo_list: []const u8 = &.{};
    const decls = @typeInfo(primitive_impls).Struct.decls;
    var funcs: [decls.len]PrimitiveEntry = undefined;
    for (decls) |decl, i| {
        const name = decl.name;
        const impl = @field(primitive_impls, name);
        const publish_name = if (name[0] == ' ') name[1..] else name;
        if (show_me_todos and impl == todo) {
            if (todo_list.len != 0) todo_list = todo_list ++ ", ";
            todo_list = todo_list ++ publish_name;
        }
        funcs[i] = .{ .name = publish_name, .impl = impl };
    }
    if (todo_list.len != 0) @compileError("todos: `" ++ todo_list ++ "`");
    break :blk funcs;
};

pub const EvalError = union(enum) {
    variable_not_found: i32,
    cannot_call: Value,
    malformed_list: Value,
    expected_type: struct { expected: TypeMask, found: Value },
    extra_args: Value.Cons,
    not_enough_args,
    division_by_zero,
    recursion_limit,
    unknown_lexical_setting: i32,
    //sdl_error: []const u8,
    out_of_cint_range: i64,
    todo: []const u8,

    pub fn print(this_error: @This(), self: Self, writer: RuntimeWriter) !void {
        const symbols = self.symbol_table.*;
        return switch (this_error) {
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
                var v1 = v;
                const temp_value = Value{ .cons = &v1 };
                try writer.writeAll("extra args `");
                try temp_value.print(writer, symbols);
                try writer.writeByte('`');
            },
            .not_enough_args => try writer.writeAll("not enough args"),
            .division_by_zero => try writer.writeAll("division by zero"),
            .recursion_limit => try writer.print(
                "recursion limit of {} exceeded",
                .{self.recursion_limit},
            ),
            .unknown_lexical_setting => |s| writer.print(
                "unknown lexical setting `{s}`",
                .{symbols.getByIndex(s)},
            ),
            .out_of_cint_range => |i| try writer.print(
                "integer {} out of range (must be between {} and {})",
                .{ i, math.minInt(c_int), math.maxInt(c_int) },
            ),
            //.sdl_error => |msg| try writer.print("SDL error \"{s}\"", .{msg}),
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
    fn toInterpreterOutput(self: @This()) InterpreterOutput {
        return switch (self) {
            .value => |v| .{ .return_value = v },
            .eval_error => |e| .{ .eval_error = e },
        };
    }
};

pub fn init(
    evaluator_alloc: Allocator,
    gc: *Gc,
    symbol_table: *SymbolTable,
    writer: RuntimeWriter,
) !Self {
    const all_types = @typeInfo(Type).Enum.fields;
    const len = primitives.len;
    try symbol_table.ensureUnusedCapacity(len + all_types.len);
    var map = try Map.initCapacity(evaluator_alloc, len);
    errdefer map.deinit();
    for (primitives) |entry| {
        const identifier = entry.name;
        const value = .{ .primitive = entry.impl };
        const symbol = try symbol_table.put(identifier);
        map.appendAssumeCapacity(.{ .symbol = symbol, .value = value });
    }
    var types_to_symbols: [max_type_tag]i32 = undefined;
    inline for (all_types) |field| {
        types_to_symbols[field.value] = try symbol_table.getOrPut(field.name);
    }
    var draw_queue = try Queue(CanvasMessage).init(evaluator_alloc, 4096);
    errdefer draw_queue.deinit(evaluator_alloc);
    var draw_error_queue = try Queue([]const u8).init(evaluator_alloc, 8);
    errdefer draw_error_queue.deinit(evaluator_alloc);
    var draw_queue_ptr = try evaluator_alloc.create(Queue(CanvasMessage));
    errdefer evaluator_alloc.destroy(draw_queue_ptr);
    var draw_error_queue_ptr = try evaluator_alloc.create(Queue([]const u8));
    errdefer evaluator_alloc.destroy(draw_error_queue_ptr);
    draw_queue_ptr.* = draw_queue;
    draw_error_queue_ptr.* = draw_error_queue;
    var draw_thread = try Thread.spawn(
        .{},
        canvas_runner.run,
        .{ draw_queue_ptr, draw_error_queue_ptr },
    );
    draw_thread.setName("draw") catch {};
    return .{
        .map = map,
        .gc = gc,
        .writer = writer,
        .symbol_table = symbol_table,
        .draw_queue = draw_queue_ptr,
        .draw_error_queue = draw_error_queue_ptr,
        .draw_thread = draw_thread,
        .types_to_symbols = types_to_symbols,
        .start_time = nanoTimestamp(),
    };
}

pub fn printVars(self: Self) !void {
    for (self.map.items) |variable| {
        try self.printValue(variable.value);
    }
}

fn getVar(self: Self, symbol: i32) ?Value {
    const items = self.map.items;
    var i = items.len;
    while (i != 0) {
        i -= 1;
        const entry = items[i];
        if (entry.symbol == symbol) return entry.value;
    }
    return null;
}

fn destroyScope(self: *Self, old_len: usize) void {
    inline for (lexical_settings) |setting| {
        const symbol = self.symbol_table.getOrNull(setting[0]);
        for (self.map.items[old_len..]) |binding| {
            if (binding.symbol == symbol) {
                var i = old_len;
                while (i > 0) {
                    i -= 1;
                    const old_variable = self.map.items[i];
                    if (old_variable.symbol == symbol) {
                        var message = @unionInit(CanvasMessage, setting[1], old_variable.value.color);
                        self.draw_queue.push(message);
                        break;
                    }
                } else std.debug.panic("could not find previous value of {s}", .{setting[0]});
                break;
            }
        }
    }
    self.map.shrinkRetainingCapacity(old_len);
}

fn printValue(self: Self, value: Value) anyerror!void {
    try value.print(self.writer, self.symbol_table.*);
    try self.writer.writeByte('\n');
}

fn printStacktrace(self: Self, writer: RuntimeWriter) !void {
    const printStacktraceSlice = struct {
        fn f(
            writer1: RuntimeWriter,
            self1: Self,
            lower: usize,
            upper: usize,
        ) !void {
            const stacktrace = self1.stacktrace.items;
            var i = upper;
            while (i > lower) {
                i -= 1;
                try writer1.print("{}: ", .{i});
                try self1.printValue(.{ .cons = stacktrace[i] });
            }
        }
    }.f;
    const max_latest_items = 5;
    const max_earliest_items = 3;
    const len = self.stacktrace.items.len;
    if (len < 2) return;
    if (len <= max_latest_items + max_earliest_items + 1) {
        try printStacktraceSlice(writer, self, 0, len);
    } else {
        try printStacktraceSlice(writer, self, len - max_latest_items, len);
        try writer.writeAll("...\n");
        try printStacktraceSlice(writer, self, 0, max_earliest_items);
    }
}

const EvalSettings = struct {
    top_level_parens_optional: bool,
};

const InterpreterOutput = union(enum) {
    parse_error: parser.ParseError,
    eval_error: EvalError,
    return_value: ?Value,
    pub fn println(this_output: @This(), self: Self, writer: RuntimeWriter) !void {
        const symbols = self.symbol_table.*;
        switch (this_output) {
            .parse_error => |e| {
                try writer.writeAll("Parse error: ");
                try e.print(writer);
                try writer.writeByte('\n');
            },
            .eval_error => |e| {
                try writer.writeAll("Eval error: ");
                try e.print(self, writer);
                try writer.writeByte('\n');
                try self.printStacktrace(writer);
            },
            .return_value => |v_| {
                std.debug.assert(self.stacktrace.items.len == 0);
                if (v_) |v| try v.print(writer, symbols) else return;
                try writer.writeByte('\n');
            },
        }
    }
};
pub fn evalSource(self: *Self, source: []const u8, settings: EvalSettings) !InterpreterOutput {
    self.stacktrace.clearRetainingCapacity();
    var token_iter = lexer.TokenIterator.init(source);
    const EvalFolder = union(enum) {
        last: ?Value,
        all: Value,
        fn from_setting(b: bool) @This() {
            return if (b) .{ .all = .nil } else .{ .last = null };
        }
        fn add_value(self2: *@This(), evaluator: *Self, value: Value) !?EvalError {
            switch (self2.*) {
                .last => |*last| last.* = switch (try evaluator.eval(value)) {
                    .value => |v| v,
                    .eval_error => |e| return e,
                },
                .all => |*list| {
                    const new_last_item = try evaluator.gc.create_cons(.{
                        .car = value,
                        .cdr = .nil,
                    });
                    var nil_ptr: *Value = list;
                    while (true) {
                        nil_ptr = switch (nil_ptr.*) {
                            .cons => |c| &c.cdr,
                            .nil => break,
                            else => unreachable,
                        };
                    }
                    nil_ptr.* = .{ .cons = new_last_item };
                },
            }
            return null;
        }
        fn finish(self2: @This(), evaluator: *Self) !InterpreterOutput {
            switch (self2) {
                .last => |last| return .{ .return_value = last },
                .all => |list| {
                    const cons = switch (list) {
                        .cons => |c| c,
                        .nil => return .{ .return_value = null },
                        else => unreachable,
                    };
                    if (cons.cdr == .nil) {
                        const eval_out = try evaluator.eval(cons.car);
                        return eval_out.toInterpreterOutput();
                    }
                    const eval_out = try evaluator.eval(list);
                    return eval_out.toInterpreterOutput();
                },
            }
        }
    };
    var eval_folder = EvalFolder.from_setting(settings.top_level_parens_optional);
    while (!token_iter.peek().is_eof_token()) {
        const parse_out = try parser.parse(
            &token_iter,
            self.map.allocator,
            self.gc,
            self.symbol_table,
        );
        const ast = switch (parse_out) {
            .value => |v| v,
            .parse_error => |e| return .{ .parse_error = e },
        };
        //std.debug.print("ast: {any}\n", .{ast});
        if (try eval_folder.add_value(self, ast)) |e| return .{ .eval_error = e };
    }
    const out = eval_folder.finish(self);
    // Give time for draw errors to propogate.
    std.time.sleep(std.time.ns_per_s / 60);
    self.flushDrawErrorQueue();
    return out;
}

pub fn flushDrawErrorQueue(self: *Self) void {
    while (self.draw_error_queue.popOrNull()) |msg| {
        std.debug.print("Renderer error: {s}\n", .{msg});
    }
}

pub fn eval(self: *Self, value: Value) anyerror!EvalOutput {
    self.flushDrawErrorQueue();
    switch (value) {
        .nil, .bool, .int, .primitive, .lambda, .color => return .{ .value = value },
        .symbol => |s| if (self.getVar(s)) |v| return .{ .value = v } else {
            return .{ .eval_error = .{ .variable_not_found = s } };
        },
        .cons => |pair| {
            if (self.stacktrace.items.len >= self.recursion_limit)
                return .{ .eval_error = .recursion_limit };
            try self.stacktrace.append(self.map.allocator, pair);
            var is_error = true;
            defer if (!is_error) {
                _ = self.stacktrace.pop();
            };
            const out = try self.eval_cons(pair);
            if (out == .value) is_error = false;
            return out;
        },
    }
}

fn eval_cons(self: *Self, pair: *Value.Cons) !EvalOutput {
    self.flushDrawErrorQueue();
    const function_out = try self.eval(pair.car);
    if (function_out.is_error()) return function_out;
    const function = function_out.value;
    switch (function) {
        .primitive => |f| {
            const args = pair.cdr.toListPartial();
            switch (args) {
                .list => |list| return f(self, list),
                .bad => |v| return .{ .eval_error = .{ .malformed_list = v } },
            }
        },
        .lambda => |lambda| {
            const old_len = self.map.items.len;
            defer self.destroyScope(old_len);
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
                .cons => |c| return .{ .eval_error = .{ .extra_args = c.* } },
                else => return .{ .eval_error = .{ .malformed_list = arg_list } },
            }
            return self.eval(lambda.body);
        },
        else => return .{ .eval_error = .{ .cannot_call = function } },
    }
    self.flushDrawErrorQueue();
}

pub fn deinit(self: *Self) void {
    self.visit_stack.deinit(self.map.allocator);
    self.map.deinit();
    self.flushDrawErrorQueue();
    self.draw_queue.push(.kill);
    self.draw_thread.join();
    std.debug.assert(self.draw_queue.empty());
    std.debug.assert(self.draw_error_queue.empty());
    self.draw_queue.deinit(self.map.allocator);
    self.draw_error_queue.deinit(self.map.allocator);
    self.map.allocator.destroy(self.draw_queue);
    self.map.allocator.destroy(self.draw_error_queue);
    self.stacktrace.deinit(self.map.allocator);
    self.* = undefined;
}
