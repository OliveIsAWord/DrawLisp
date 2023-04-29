const std = @import("std");

data: []const u8,

const Self = @This();

pub fn format(self: Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    return writer.print("{s}", .{self.data});
}
