const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Arc = @import("arc.zig").ArcUnmanaged;
const lexer = @import("lexer.zig");
const TokenIterator = lexer.TokenIterator;
const LexError = lexer.LexError;
const Value = @import("value.zig").Value;
const SymbolTable = @import("SymbolTable.zig");

pub const Span = struct { start: u32, len: u32 };

pub const ParseError = struct {
    kind: union(enum) {
        lex_error: LexError,
        integer_literal_overflow,
        unexpected_paren_close,
        unexpected_eof,
        dot_outside_parens,
        repeated_dot,
        expected_value_after_dot,
        quote_without_atom,
        todo: []const u8,
    },
    span: Span,
};

pub const ParseOutput = union(enum) {
    value: Value,
    parse_error: ParseError,
};

fn todo(message: []const u8, span: Span) ParseOutput {
    return .{ .parse_error = .{ .kind = .{ .todo = message }, .span = span } };
}

pub fn parse(
    tokens: *TokenIterator,
    parser_alloc: Allocator,
    value_alloc: Allocator,
    symbols: *SymbolTable,
) !ParseOutput {
    const Item = struct { value: Value, dotty: bool, quoty: usize };
    const quote_symbol = try symbols.getOrPut("quote");
    var sexpr_stack = std.ArrayList(Item).init(parser_alloc);
    var quoty: usize = 0;
    var is_error = true;
    // the world if `defer` could capture a function's return value: 👩‍❤️‍💋‍👩
    defer {
        if (is_error) {
            for (sexpr_stack.items) |item| item.value.deinit(value_alloc);
        }
        sexpr_stack.deinit();
    }
    while (true) {
        //defer std.debug.print("\n", .{});
        //std.debug.print("stack: {any}\n", .{sexpr_stack.items});
        const token_start = tokens.byte_index;
        const token = tokens.next();
        const span = .{
            .start = token_start,
            .len = @intCast(u32, token.span.len),
        };
        const token_value = switch (token.value) {
            .token => |t| t,
            .lex_error => |e| return .{ .parse_error = .{
                .kind = .{ .lex_error = e },
                .span = span,
            } },
        };
        const unquoted_value: Value = switch (token_value) {
            .paren_open => {
                try sexpr_stack.append(.{ .value = .nil, .dotty = false, .quoty = quoty });
                quoty = 0;
                continue;
            },
            .paren_close => blk: {
                const item = sexpr_stack.popOrNull() orelse return .{ .parse_error = .{
                    .kind = .unexpected_paren_close,
                    .span = span,
                } };
                var is_error_inner = true;
                defer if (is_error_inner) item.value.deinit(value_alloc);
                if (quoty > 0) {
                    return .{ .parse_error = .{ .kind = .quote_without_atom, .span = span } };
                }
                quoty = item.quoty;
                if (item.dotty) return .{ .parse_error = .{
                    .kind = .expected_value_after_dot,
                    .span = span,
                } };
                is_error_inner = false;
                break :blk item.value;
            },
            .quote => {
                quoty += 1;
                continue;
            },
            .dot => {
                if (quoty > 0) {
                    return .{ .parse_error = .{ .kind = .quote_without_atom, .span = span } };
                }
                if (sexpr_stack.items.len == 0) {
                    return .{ .parse_error = .{ .kind = .dot_outside_parens, .span = span } };
                }
                const last_dotty: *bool = &sexpr_stack.items[sexpr_stack.items.len - 1].dotty;
                if (last_dotty.*) {
                    return .{ .parse_error = .{ .kind = .repeated_dot, .span = span } };
                }
                last_dotty.* = true;
                continue;
            },
            .integer_literal => blk: {
                const int = std.fmt.parseInt(i64, token.span, 10) catch |e| switch (e) {
                    std.fmt.ParseIntError.InvalidCharacter => unreachable,
                    std.fmt.ParseIntError.Overflow => return .{ .parse_error = .{
                        .kind = .integer_literal_overflow,
                        .span = span,
                    } },
                };
                break :blk .{ .int = int };
            },
            .boolean_literal => blk: {
                assert(token.span.len == 2);
                assert(token.span[0] == '#');
                const boolean = switch (token.span[1]) {
                    't' => true,
                    'f' => false,
                    else => unreachable,
                };
                break :blk .{ .bool = boolean };
            },
            .identifier => blk: {
                const index = try symbols.getOrPut(token.span);
                break :blk .{ .symbol = index };
            },
            .eof => return .{ .parse_error = .{
                .kind = .unexpected_eof,
                .span = span,
            } },
        };
        var value = unquoted_value;
        while (quoty > 0) : (quoty -= 1) {
            const arg_inner: Value.Cons = .{ .car = value, .cdr = .nil };
            const arg = try Arc(Value.Cons).init(arg_inner, value_alloc);
            const cons_inner: Value.Cons = .{
                .car = .{ .symbol = quote_symbol },
                .cdr = .{ .cons = arg },
            };
            const cons = try Arc(Value.Cons).init(cons_inner, value_alloc);
            value = .{ .cons = cons };
        }
        //std.debug.print("value: {any}\n", .{value});
        if (sexpr_stack.items.len == 0) {
            is_error = false;
            return .{ .value = value };
        }
        const last_item: *Item = &sexpr_stack.items[sexpr_stack.items.len - 1];
        const last_list: *Value = &last_item.value;
        const dotty = last_item.dotty;
        last_item.dotty = false;
        var last_elem = last_list;
        while (last_elem.* == .cons) last_elem = &last_elem.cons.get().cdr;
        // std.debug.print("last_list: {any}\n", .{last_list});
        // std.debug.print("last_elem: {any}\n", .{last_elem});
        // std.debug.print("dotty: {}\n", .{dotty});
        if (dotty) {
            switch (last_elem.*) {
                .nil => last_elem.* = value,
                else => {
                    const cons_inner = .{ .car = last_list.*, .cdr = value };
                    const cons = try Arc(Value.Cons).init(cons_inner, value_alloc);
                    last_list.* = .{ .cons = cons };
                },
            }
        } else {
            const cons_inner = .{ .car = value, .cdr = .nil };
            const cons = try Arc(Value.Cons).init(cons_inner, value_alloc);
            switch (last_elem.*) {
                .nil => {
                    last_elem.* = .{ .cons = cons };
                },
                else => {
                    const big_cons_inner = .{ .car = last_list.*, .cdr = .{ .cons = cons } };
                    const big_cons = try Arc(Value.Cons).init(big_cons_inner, value_alloc);
                    last_list.* = .{ .cons = big_cons };
                },
            }
        }
    }
}
