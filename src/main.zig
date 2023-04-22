const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const print = std.debug.print;

const SymbolTable = @import("SymbolTable.zig");
const Value = @import("value.zig").Value;
const lexer = @import("lexer.zig");
const parse = @import("parser.zig").parse;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    
    //const stdin = std.io.getStdIn().reader();
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    defer bw.flush() catch {};
    const stdout = bw.writer();
    
    // var symbol_table = SymbolTable.init(alloc, alloc);
    // var buffer = std.ArrayList(u8).init(alloc);
    // while (true) {
    //     try stdout.writeByte("> ");
    //     try stdin.readUntilDelimiterArrayList(&buffer, '\n', std.math.maxInt(usize));
    //     var token_iter = lexer.TokenIterator.init(buffer.items);
    // }

    //const src: []const u8 = "(2 . 1 . (4 . 3))";
    const src: []const u8 = "(+ 3 (- (+ 4) 3))";
    var iter = lexer.TokenIterator.init(src);
    var symbol_table = SymbolTable.init(alloc, alloc);
    defer symbol_table.deinit();
    const ast = switch (try parse(&iter, alloc, alloc, &symbol_table)) {
        .value => |v| v,
        .parse_error => |e| {
            std.debug.print("Parsing error: {}", .{e});
            return;
        },
    };
    defer ast.deinit(alloc);
    if (!iter.assertEof()) {
        std.debug.print("Parse warning: expected eof\n", .{});
    }
    try ast.print(stdout, symbol_table);
    try stdout.writeByte('\n');
    try bw.flush();
    //_ = ast;
}
