const std = @import("std");
const Allocator = std.mem.Allocator;
const RawImage = @import("RawImage.zig");
const Rgb = @import("Rgb.zig");
const math = std.math;
const Order = math.Order;

pub fn QuadTree(comptime T: type) type {
    return union(enum) {
        const Self = @This();
        leaf: T,
        branch: [4]*Self,

        pub fn deinit(self: *Self, alloc: Allocator) void {
            switch (self.*) {
                .leaf => {},
                .branch => |bs| {
                    for (bs) |b| {
                        b.deinit(alloc);
                        alloc.destroy(b);
                    }
                },
            }
            self.* = undefined;
        }
    };
}

const QuadTreeImage = struct {
    const Self = @This();
    width: usize = 0,
    height: usize = 0,
    tree: QuadTree(Rgb) = .{ .leaf = undefined },

    pub fn writeToImage(self: *Self, alloc: Allocator) !RawImage {
        var image = try RawImage.init(alloc, self.width, self.height);
        errdefer image.deinit(alloc);
        var pixels = image.pixelsMut();
        const SubImage = struct {
            x: usize,
            y: usize,
            w: usize,
            h: usize,
            tree: QuadTree(Rgb),
        };
        var list = std.ArrayList(SubImage).init(alloc);
        defer list.deinit();
        try list.append(.{ .x = 0, .y = 0, .w = self.width, .h = self.height, .tree = self.tree });
        while (list.popOrNull()) |sub_image| {
            //std.debug.print("meow {any}\n", .{sub_image});
            switch (sub_image.tree) {
                .leaf => |color| {
                    var y: usize = 0;
                    while (y < sub_image.h) : (y += 1) {
                        var x: usize = 0;
                        while (x < sub_image.w) : (x += 1) {
                            pixels[(y + sub_image.y) * image.width + x + sub_image.x] = color;
                        }
                    }
                },
                .branch => |branches| {
                    const w1 = sub_image.w / 2;
                    const h1 = sub_image.h / 2;
                    const w2 = sub_image.w - w1;
                    const h2 = sub_image.h - h1;
                    try list.append(.{ .x = sub_image.x, .y = sub_image.y, .w = w1, .h = h1, .tree = branches[0].* });
                    try list.append(.{ .x = sub_image.x + w1, .y = sub_image.y, .w = w2, .h = h1, .tree = branches[1].* });
                    try list.append(.{ .x = sub_image.x, .y = sub_image.y + h1, .w = w1, .h = h2, .tree = branches[2].* });
                    try list.append(.{ .x = sub_image.x + w1, .y = sub_image.y + h1, .w = w2, .h = h2, .tree = branches[3].* });
                },
            }
        }
        return image;
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        self.tree.deinit(alloc);
        self.* = undefined;
    }
};

fn calculateEnergy(image: *const RawImage, average_color: Rgb) ?f64 {
    if (image.numPixels() == 0) {
        return null;
    }
    var sum_differences: f64 = 0.0;
    for (image.pixels()) |pixel| {
        const dist = pixel.distance(average_color);
        sum_differences += dist;
    }
    //const num_pixels = @intToFloat(f64, image.numPixels());
    //return sum_differences / num_pixels;
    return sum_differences;
}

fn quadrisectImage(alloc: Allocator, image: *const RawImage) ![4]RawImage {
    const w = image.width;
    const h = image.height;
    const half_w_1 = w / 2;
    const half_h_1 = h / 2;
    const half_w_2 = w - half_w_1;
    const half_h_2 = h - half_h_1;

    return .{
        try image.crop(alloc, 0, 0, half_w_1, half_h_1),
        try image.crop(alloc, half_w_1, 0, half_w_2, half_h_1),
        try image.crop(alloc, 0, half_h_1, half_w_1, half_h_2),
        try image.crop(alloc, half_w_1, half_h_1, half_w_2, half_h_2),
    };
}

pub fn readFromImage(alloc: Allocator, image: *const RawImage) !QuadTreeImage {
    const full_average = image.get_average() orelse return .{};
    // TODO: removing this type annotation causes a memory leak
    var qt_image: QuadTreeImage = .{
        .width = image.width,
        .height = image.height,
        .tree = .{ .leaf = full_average },
    };
    const QueueEntry = struct {
        const Self = @This();
        energy: f64,
        leaf_ptr: *QuadTree(Rgb),
        sub_image: RawImage,

        fn init(sub_image: RawImage, leaf_ptr: *QuadTree(Rgb)) ?Self {
            const energy = calculateEnergy(&sub_image, leaf_ptr.leaf) orelse return null;
            return .{ .energy = energy, .leaf_ptr = leaf_ptr, .sub_image = sub_image };
        }
        fn deinit(self: *Self, alloc2: Allocator) void {
            //std.debug.print("deiniting {any}\n", .{self.*});
            self.sub_image.deinit(alloc2);
            self.* = undefined;
        }
        fn cmp(_: void, a: Self, b: Self) Order {
            return math.order(b.energy, a.energy);
        }
    };
    var queue = std.PriorityQueue(QueueEntry, void, QueueEntry.cmp).init(alloc, {});
    defer {
        for (queue.items[0..queue.len]) |item| {
            var item_ = item;
            item_.deinit(alloc);
        }
        queue.deinit();
    }
    const image_clone = try image.crop(alloc, 0, 0, image.width, image.height);
    try queue.add(QueueEntry.init(image_clone, &qt_image.tree).?);
    const quality = 0.9997;
    var x: usize = 0;
    while (blk: {
        const num_pixels = @intToFloat(f64, image.numPixels());
        const max_energy = 1 - quality;
        var total_energy: f64 = 0.0;
        for (queue.items) |entry| {
            total_energy += entry.energy;
            if (total_energy / num_pixels >= max_energy) break :blk true;
        }
        break :blk false;
    }) : (x += 1) {
        var entry = queue.remove();
        defer entry.deinit(alloc);
        const sub_images = try quadrisectImage(alloc, &entry.sub_image);
        var branches: [4]*QuadTree(Rgb) = .{
            try alloc.create(QuadTree(Rgb)),
            try alloc.create(QuadTree(Rgb)),
            try alloc.create(QuadTree(Rgb)),
            try alloc.create(QuadTree(Rgb)),
        };
        branches[0].* = .{ .leaf = sub_images[0].get_average() orelse undefined };
        branches[1].* = .{ .leaf = sub_images[1].get_average() orelse undefined };
        branches[2].* = .{ .leaf = sub_images[2].get_average() orelse undefined };
        branches[3].* = .{ .leaf = sub_images[3].get_average() orelse undefined };
        //std.debug.print("bitch {}\n", .{ qt_image });
        entry.leaf_ptr.* = .{ .branch = branches };
        //std.debug.print("bitch {}\n", .{ qt_image });
        for (sub_images) |sub_image, i| {
            if (QueueEntry.init(sub_image, entry.leaf_ptr.branch[i])) |new_entry| try queue.add(new_entry);
        }
    }
    std.debug.print("Ran in {} iterations\n", .{x});
    return qt_image;
}

test {
    const image = RawImage{ .width = 1, .height = 1, .data = undefined };
    _ = try readFromImage(std.testing.allocator, &image);
}
