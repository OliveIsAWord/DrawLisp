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

const cli_ = .{ .interactive = .{} };
const stdlib_source = @embedFile("std.lisp");

const StartupError = error{
    BadStdlib,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const stdin = std.io.getStdIn().reader();
    const stdout_file = std.io.getStdOut().writer();
    var stdout_bw = std.io.bufferedWriter(stdout_file);
    defer stdout_bw.flush() catch {};
    const stdout = RuntimeWriter.fromBufferedWriter(&stdout_bw);
    const stderr_file = std.io.getStdErr().writer();
    var stderr_bw = std.io.bufferedWriter(stderr_file);
    defer stderr_bw.flush() catch {};
    const stderr = RuntimeWriter.fromBufferedWriter(&stderr_bw);

    try stdout.writeAll("DrawLisp v0.0.1a\n");
    try stdout_bw.flush();

    var symbol_table = SymbolTable.init(alloc, alloc);
    defer symbol_table.deinit();
    var gc = Gc.init(alloc, alloc);
    defer gc.deinitAndSweep();
    var evaluator: Evaluator = try Evaluator.init(alloc, &gc, &symbol_table, stdout);
    defer evaluator.deinit();
    {
        errdefer gc.sweep();
        const stdlib_eval_out = try evaluator.evalSource(
            stdlib_source,
            .{ .top_level_parens_optional = false },
        );
        if (stdlib_eval_out != .return_value) {
            stderr.writeAll("Error while compiling standard library\n") catch {};
            stdlib_eval_out.println(evaluator, stderr) catch {};
            stderr_bw.flush() catch {};
            return StartupError.BadStdlib;
        }
    }
    var buffer = SourceBuffer.init(alloc);
    defer buffer.deinit();
    var skip_prompt = false;
    while (true) {
        defer evaluator.flushDrawErrorQueue();
        defer {
            for (evaluator.map.items) |variable| {
                gc.mark(variable.value) catch {
                    std.debug.print("Ran out of memory during garbage collection.", .{});
                    break;
                };
            } else gc.sweep();
        }
        if (!skip_prompt and buffer.outstanding_parens == 0) {
            try stdout.writeAll("> ");
            try stdout_bw.flush();
        }
        skip_prompt = false;
        const input = switch (buffer.readExpressions(stdin)) {
            .ok => |source| std.mem.trimLeft(u8, source, &std.ascii.whitespace),
            .incomplete => continue,
            .unexpected_paren_close => {
                std.debug.print("Parsing error: Unexpected paren close\n", .{});
                skip_prompt = true;
                continue;
            },
            .read_error => |e| switch (e) {
                // TODO: Is this how you do Ctrl-C handling? Works on my machine :3
                error.EndOfStream => {
                    stdout.writeAll("\nBye.\n") catch {};
                    stdout_bw.flush() catch {};
                    stderr_bw.flush() catch {};
                    return;
                },
                else => return e,
            },
        };
        if (input.len == 0) continue;
        if (input[0] == ';') {
            const command = std.mem.trimLeft(u8, input[1..], &std.ascii.whitespace);
            if (command.len == 0) {
                stdout.writeAll("Bye.\n") catch {};
                return;
            }
            continue;
        }
        const eval_output = try evaluator.evalSource(
            input,
            .{ .top_level_parens_optional = true },
        );
        try eval_output.println(evaluator, stdout);
        try stdout_bw.flush();
    }
}

const SourceBufferOutput = union(enum) {
    ok: []const u8,
    incomplete,
    unexpected_paren_close,
    read_error: anyerror,
};

const SourceBuffer = struct {
    buffer: std.ArrayList(u8),
    outstanding_parens: usize = 0,

    const Self = @This();

    fn init(alloc: Allocator) Self {
        return .{ .buffer = std.ArrayList(u8).init(alloc) };
    }

    fn readExpressions(self: *Self, reader: anytype) SourceBufferOutput {
        if (self.outstanding_parens == 0) self.buffer.clearRetainingCapacity();
        while (true) {
            var byte = reader.readByte() catch |e| return .{ .read_error = e };
            if (byte == '(') {
                self.outstanding_parens += 1;
            } else if (byte == ')') {
                if (self.outstanding_parens == 0) return .unexpected_paren_close;
                self.outstanding_parens -= 1;
            } else if (byte == '\n') break;
            self.buffer.append(byte) catch |e| return .{ .read_error = e };
        }
        return if (self.outstanding_parens == 0) .{ .ok = self.buffer.items } else .incomplete;
    }

    fn deinit(self: *Self) void {
        self.buffer.deinit();
        self.* = undefined;
    }
};
