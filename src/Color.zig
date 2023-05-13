r: u8,
g: u8,
b: u8,
a: u8 = 255,

const Self = @This();

pub const white = Self{ .r = 255, .g = 255, .b = 255 };
pub const black = Self{ .r = 0, .g = 0, .b = 0 };
pub const magenta = Self{ .r = 255, .g = 0, .b = 255 };
