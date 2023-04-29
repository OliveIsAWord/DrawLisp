const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const print = std.debug.print;

const SymbolTable = @import("SymbolTable.zig");
const Value = @import("value.zig").Value;
const lexer = @import("lexer.zig");
const parse = @import("parser.zig").parse;
const Evaluator = @import("Evaluator.zig");
const Gc = @import("Gc.zig");
const RuntimeWriter = @import("RuntimeWriter.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const stdin = std.io.getStdIn().reader();
    const stdout_file = std.io.getStdOut().writer();
    var stdout_bw = std.io.bufferedWriter(stdout_file);
    defer stdout_bw.flush() catch {};
    const stdout = RuntimeWriter.fromBufferedWriter(&stdout_bw);
    try stdout_bw.flush();
    const stderr_file = std.io.getStdErr().writer();
    var stderr_bw = std.io.bufferedWriter(stderr_file);
    defer stderr_bw.flush() catch {};
    const stderr = RuntimeWriter.fromBufferedWriter(&stderr_bw);

    var symbol_table = SymbolTable.init(alloc, alloc);
    defer symbol_table.deinit();
    var gc = Gc.init(alloc, alloc);
    defer gc.deinit();
    var evaluator: Evaluator = try Evaluator.init(alloc, &gc, &symbol_table, stdout);
    defer evaluator.deinit();
    var buffer = std.ArrayList(u8).init(alloc);
    defer buffer.deinit();
    while (true) {
        defer gc.sweep();
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
        const input = std.mem.trimLeft(u8, buffer.items, &std.ascii.whitespace);
        if (input.len == 0) continue;
        if (input[0] == ';') {
            const command = std.mem.trimLeft(u8, input[1..], &std.ascii.whitespace);
            if (command.len == 0) return;
            _ = .{command};
            continue;
        }
        var token_iter = lexer.TokenIterator.init(input);
        const ast = switch (try parse(&token_iter, alloc, &gc, &symbol_table)) {
            .value => |v| v,
            .parse_error => |e| {
                std.debug.print("Parsing error: {}\n", .{e});
                continue;
            },
        };
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
        try yielded_value.print(stdout, symbol_table);
        try stdout.writeByte('\n');
        try stdout_bw.flush();
        for (evaluator.map.items) |variable| try gc.mark(variable.value);
    }
}
