const std = @import("std");
const Board = @import("Board.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    try stdout.print("Meow!\n", .{});

    var rows = [_]usize{ 3, 2, 5, 3, 4, 1, 4, 4 };
    var columns = [_]usize{ 1, 4, 2, 7, 0, 4, 4, 4 };
    var board_data = [_]Board.Tile{.unknown} ** 64;
    //board_data[2 * 8 + 7] = .wall;
    // board_data[6 * 8 + 7] = .wall;
    // board_data[7 * 8 + 6] = .wall;
    board_data[5 * 8 + 1] = .treasure;
    board_data[2 * 8 + 2] = .monster;
    board_data[1 * 8 + 7] = .monster;
    board_data[3 * 8 + 7] = .monster;
    board_data[5 * 8 + 7] = .monster;
    board_data[7 * 8 + 7] = .monster;
    var board = Board{
        .width = 8,
        .height = 8,
        .rows = &rows,
        .columns = &columns,
        .board = &board_data,
    };
    try board.write(stdout);
    try stdout.writeByte('\n');
    try bw.flush();
    std.debug.print("{any}\n", .{board.isInvalid(alloc)});
}
