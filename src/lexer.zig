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
    return is_whitespace(c) or is_one_of(.{ '\x00', '(', ')', '"', ';', '.' })(c);
}

fn is_digit(c: u8) bool {
    return '0' <= c and c <= '9';
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
    invalid_boolean_literal: u8,

    pub fn print(self: Self, writer: anytype) !void {
        const static_str = switch (self) {
            .generic => "unknown",
            .unexpected_eof => "unexpected eof",
            .invalid_boolean_literal => |c| blk: {
                try writer.print("invalid boolean literal `{c}`", .{c});
                break :blk null;
            },
        };
        if (static_str) |str| try writer.writeAll(str);
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
    fn lex_integer_literal(src: []const u8) ?LexOutput {
        const minus_offset = @boolToInt(src[0] == '-');
        var i: usize = minus_offset;
        while (i < src.len and is_digit(src[i])) i += 1;
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
