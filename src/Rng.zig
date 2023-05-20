//! An implementation of the xoshiro256** generator.

state: [4]u64,

const Self = @This();

pub fn init(seed: i64) Self {
    const SplitMix64 = struct {
        state: u64,
        fn next(self: *@This()) u64 {
            self.state +%= 0x9E3779B97f4A7C15;
            var result = self.state;
            result = (result ^ (result >> 30)) *% 0xBF58476D1CE4E5B9;
            result = (result ^ (result >> 27)) *% 0x94D049BB133111EB;
            return result ^ (result >> 31);
        }
    };

    var gen = SplitMix64{ .state = @bitCast(u64, seed) };
    var self: Self = .{ .state = undefined };
    for (self.state) |*v| {
        v.* = gen.next();
    }
    return self;
}

pub fn next(self: *Self) u64 {
    var s = &self.state;
    const result = rotl(s[1] *% 5, 7) *% 9;
    const t = s[1] << 17;

    s[2] ^= s[0];
    s[3] ^= s[1];
    s[1] ^= s[2];
    s[0] ^= s[3];

    s[2] ^= t;

    s[3] = rotl(s[3], 45);

    return result;
}

fn rotl(x: u64, comptime k: comptime_int) u64 {
    return (x << k) | (x >> (64 - k));
}
