const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const mem = std.mem;
const print = std.debug.print;

pub const Token = enum {
    const Self = @This();
    paren_open,
    paren_close,
    quote,
    dot,
    integer_literal,
    string_literal,
    color_literal,
    identifier,
    eof,
};

fn is_one_of(comptime chars: anytype) fn (anytype) bool {
    return struct {
        fn f(c: anytype) bool {
            inline for (chars) |char| {
                if (c == char) return true;
            }
            return false;
        }
    }.f;
}

const is_whitespace = is_one_of(std.ascii.whitespace);

fn is_delimiter(c: u8) bool {
    return is_whitespace(c) or is_one_of(.{ 0, '(', ')', '"', ';', '.' })(c);
}

fn is_digit(c: u8) bool {
    return '0' <= c and c <= '9';
}

fn is_hex(c: u8) bool {
    return is_digit(c) or ('A' <= c and c <= 'F') or ('a' <= c and c <= 'f');
}

fn eat_whitespace(src_: []const u8) []const u8 {
    var src = src_;
    while (true) {
        while (src.len > 0 and is_whitespace(src[0])) src = src[1..];
        if (src.len > 0 and src[0] == ';') {
            while (src.len > 0 and src[0] != '\n' and src[0] != '\r') src = src[1..];
            continue;
        }
        return src;
    }
}

pub const LexOutput = struct {
    const Self = @This();
    pub const Value = union(enum) {
        /// A valid token.
        token: Token,
        /// A token error in the source code.
        lex_error: LexError,
    };
    /// The token or error the lexer produced.
    value: Value,
    /// The substring representing the token or error location,
    span: []const u8,
    /// The remaining source code after the token or error.
    rest: []const u8,

    pub fn is_eof_token(self: Self) bool {
        return switch (self.value) {
            .token => |t| t == .eof,
            .lex_error => false,
        };
    }
};

pub const LexError = union(enum) {
    const Self = @This();
    generic,
    unexpected_eof,
    invalid_integer_literal,
    unclosed_string_literal,
    invalid_string_escape,
    invalid_color_literal,

    pub fn print(self: Self, writer: anytype) !void {
        const str = switch (self) {
            .generic => "unknown",
            .unexpected_eof => "unexpected eof",
            .invalid_integer_literal => "invalid integer literal",
            .unclosed_string_literal => "unclosed string literal",
            .invalid_string_escape => "invalid string escape",
            .invalid_color_literal => "invalid color literal",
        };
        try writer.writeAll(str);
    }
};

fn lex_exact(comptime token: Token, comptime match: []const u8) fn ([]const u8) ?LexOutput {
    return struct {
        fn f(src: []const u8) ?LexOutput {
            return if (src.len >= match.len and mem.eql(u8, match, src[0..match.len])) .{
                .value = .{ .token = token },
                .span = src[0..match.len],
                .rest = src[match.len..],
            } else null;
        }
    }.f;
}

/// Lexers assume that the input stream is non-empty
const lexers = struct {
    const lex_paren_open = lex_exact(.paren_open, "(");
    const lex_paren_close = lex_exact(.paren_close, ")");
    const lex_quote = lex_exact(.quote, "'");
    const lex_dot = lex_exact(.dot, ".");
    fn lex_string_literal(src: []const u8) ?LexOutput {
        if (src[0] != '"') return null;
        var i: usize = 1;
        while (i < src.len) : (i += 1) {
            const c = src[i];
            if (c == '\n' or c == '\r') break;
            if (c == '"') return .{
                .value = .{ .token = .string_literal },
                .span = src[0 .. i + 1],
                .rest = src[i + 1 ..],
            };
            if (c == '\\') {
                i += 1;
                if (i >= src.len) break;
                const invalid_string_escape_error = .{
                    .value = .{ .lex_error = .invalid_string_escape },
                    .span = src[0 .. i + 1],
                    .rest = src[i + 1 ..],
                };
                switch (src[i]) {
                    '0', 'n', 'r', 't', '"', '\\' => {},
                    'x' => if (i + 2 >= src.len or !is_hex(src[i + 1]) or !is_hex(src[i + 2]))
                        return invalid_string_escape_error,
                    else => return invalid_string_escape_error,
                }
            }
        }
        return .{
            .value = .{ .lex_error = .unclosed_string_literal },
            .span = src[0..i],
            .rest = src[i..],
        };
    }
    fn lex_color_literal(src: []const u8) ?LexOutput {
        if (src[0] != '#') return null;
        const rest = src[1..];
        var i: usize = 0;
        var is_error = false;
        while (i < rest.len) : (i += 1) {
            const c = rest[i];
            if (is_delimiter(c)) break;
            if (!is_hex(c)) is_error = true;
        }
        const value: LexOutput.Value = if (i == 6 or i == 8) .{ .token = .color_literal } else .{ .lex_error = .invalid_color_literal };
        return .{
            .value = value,
            .span = src[0 .. i + 1],
            .rest = src[i + 1 ..],
        };
    }
    fn lex_integer_literal(src: []const u8) ?LexOutput {
        const minus_offset = @boolToInt(src[0] == '-');
        var i: usize = minus_offset;
        var is_first_digit = true;
        while (i < src.len) {
            defer is_first_digit = false;
            const c = src[i];
            if (is_digit(c) or c == '_') {
                i += 1;
            } else if (is_delimiter(c)) {
                break;
            } else if (is_first_digit) {
                return null;
            } else {
                return .{
                    .value = .{ .lex_error = .invalid_integer_literal },
                    .span = src[0 .. i + 1],
                    .rest = src[i + 1 ..],
                };
            }
        }
        if (i == minus_offset) return null;
        return .{
            .value = .{ .token = .integer_literal },
            .span = src[0..i],
            .rest = src[i..],
        };
    }
    fn lex_ident(src: []const u8) ?LexOutput {
        var i: usize = 0;
        while (i < src.len and !is_delimiter(src[i])) i += 1;
        if (i == 0) return null;
        return .{
            .value = .{ .token = .identifier },
            .span = src[0..i],
            .rest = src[i..],
        };
    }
    fn lex_error(in: []const u8) ?LexOutput {
        return .{
            .value = .{ .lex_error = .generic },
            .span = in[0..1],
            .rest = in[1..],
        };
    }
};

pub fn lex(src_: []const u8) LexOutput {
    const src = eat_whitespace(src_);
    if (src.len == 0) return .{
        .value = .{ .token = .eof },
        .span = src,
        .rest = src,
    };
    inline for (@typeInfo(lexers).Struct.decls) |func_decl| {
        //std.debug.print("lexing with {s}\n", .{func_decl.name});
        const func = @field(lexers, func_decl.name);
        if (func(src)) |output| return output;
    }
    unreachable;
}

fn ptr_dist(smaller: anytype, larger: anytype) u32 {
    return @intCast(u32, @ptrToInt(larger) - @ptrToInt(smaller));
}

pub const TokenIterator = struct {
    const Self = @This();
    original_src: []const u8,
    src: []const u8,
    byte_index: u32 = 0,
    peeked: ?LexOutput = null,
    pub fn init(src: []const u8) Self {
        return .{ .original_src = src, .src = src };
    }
    pub fn next(self: *Self) LexOutput {
        if (self.peeked) |peeked| {
            const out = peeked; // TODO: is this necessary?
            self.peeked = null;
            return out;
        }
        const out = lex(self.src);
        //print("\"{s}\" => {any}\n", .{ out.span, out.value });
        self.byte_index += ptr_dist(self.src.ptr, out.rest.ptr);
        self.src = out.rest;
        return out;
    }
    pub fn peek(self: *Self) LexOutput {
        if (self.peeked) |peeked| return peeked;
        const peeked = self.next();
        self.peeked = peeked;
        return peeked;
    }
};
