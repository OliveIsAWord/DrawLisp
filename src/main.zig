const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const print = std.debug.print;

const Arc = @import("arc.zig").ArcUnmanaged;
const SymbolTable = @import("SymbolTable.zig");
const Value = @import("value.zig").Value;
const lexer = @import("lexer.zig");
const parse = @import("parser.zig").parse;
const Evaluator = @import("Evaluator.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const stdin = std.io.getStdIn().reader();
    const stdout_file = std.io.getStdOut().writer();
    var stdout_bw = std.io.bufferedWriter(stdout_file);
    defer stdout_bw.flush() catch {};
    const stdout = stdout_bw.writer();
    const stderr_file = std.io.getStdErr().writer();
    var stderr_bw = std.io.bufferedWriter(stderr_file);
    defer stderr_bw.flush() catch {};
    const stderr = stderr_bw.writer();

    var symbol_table = SymbolTable.init(alloc, alloc);
    defer symbol_table.deinit();
    var evaluator: Evaluator = try Evaluator.init(alloc, alloc, &symbol_table);
    defer evaluator.deinit();
    var buffer = std.ArrayList(u8).init(alloc);
    defer buffer.deinit();
    while (true) {
        try stdout.writeAll("> ");
        try stdout_bw.flush();
        stdin.readUntilDelimiterArrayList(&buffer, '\n', std.math.maxInt(usize)) catch |e| switch (e) {
            // TODO: Is this how you do Ctrl-C handling? Works on my machine :3
            error.EndOfStream => {
                stdout.writeAll("Bye.\n") catch {};
                stdout_bw.flush() catch {};
                stderr_bw.flush() catch {};
                return;
            },
            else => return e,
        };
        if (buffer.items[0] == ';') return;
        var token_iter = lexer.TokenIterator.init(buffer.items);
        const ast = switch (try parse(&token_iter, alloc, alloc, &symbol_table)) {
            .value => |v| v,
            .parse_error => |e| {
                std.debug.print("Parsing error: {}\n", .{e});
                continue;
            },
        };
        defer ast.deinit(alloc);
        if (!token_iter.assertEof()) {
            std.debug.print("Parse warning: expected eof\n", .{});
        }
        try stdout.writeAll("ast: ");
        try ast.print(stdout, symbol_table);
        try stdout.writeByte('\n');
        try stdout_bw.flush();
        const eval_output = try evaluator.eval(ast);
        const yielded_value = switch (eval_output) {
            .value => |v| v,
            .eval_error => |e| {
                try stderr.writeAll("Evaluation error: ");
                try e.print(stderr, symbol_table);
                try stderr.writeByte('\n');
                try stderr_bw.flush();
                continue;
            },
        };
        defer yielded_value.deinit(alloc);
        try yielded_value.print(stdout, symbol_table);
        try stdout.writeByte('\n');
        try stdout_bw.flush();
    }
}
