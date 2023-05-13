const std = @import("std");
const sleep_nanoseconds = std.time.sleep;

const Queue = @import("mpmc_queue.zig").MPMCQueueUnmanaged;
const Canvas = @import("Canvas.zig");
pub const Result = Canvas.Result;
const c = Canvas.c;
const Color = @import("Color.zig");

pub const Message = union(enum) {
    create_window: struct { width: c_int, height: c_int },
    set_clear_color: Color,
    set_fill_color: Color,
    set_stroke_color: Color,
    clear,
    draw,
    point: struct { x: c_int, y: c_int },
    line: struct { x1: c_int, y1: c_int, x2: c_int, y2: c_int },
    rect: struct { x: c_int, y: c_int, w: c_int, h: c_int },
    destroy_window,
    kill,
};

const one_billion: u64 = 1_000_000_000;

fn pass_error(queue: *Queue([]const u8), value: Result(void)) void {
    switch (value) {
        .ok => {},
        .err => |msg| queue.push(msg),
    }
}

pub fn run(event_queue: *Queue(Message), error_queue: *Queue([]const u8)) void {
    var canvas: Canvas = .{};
    defer canvas.deinit();
    while (true) {
        while (true) {
            {
                var sdl_event: c.SDL_Event = undefined;
                while (c.SDL_PollEvent(&sdl_event) != 0) {
                    switch (sdl_event.type) {
                        c.SDL_QUIT => canvas.destroyWindow(),
                        else => {},
                    }
                }
            }
            // If there are no messages and we have no window, block
            const message = event_queue.popOrNull() orelse
                if (canvas.hasWindow()) break else event_queue.pop();
            switch (message) {
                .create_window => |dimensions| {
                    const width = dimensions.width;
                    const height = dimensions.height;
                    pass_error(error_queue, canvas.createWindow(width, height));
                },
                .set_clear_color => |color| canvas.clear_color = color,
                .set_fill_color => |color| canvas.fill_color = color,
                .set_stroke_color => |color| canvas.stroke_color = color,
                .draw => canvas.render(),
                .clear => pass_error(error_queue, canvas.clear()),
                .point => |coordinates| {
                    const x = coordinates.x;
                    const y = coordinates.y;
                    pass_error(error_queue, canvas.point(x, y));
                },
                .line => |v| pass_error(error_queue, canvas.line(v.x1, v.y1, v.x2, v.y2)),
                .rect => |v| pass_error(error_queue, canvas.rect(v.x, v.y, v.w, v.h)),
                .destroy_window => canvas.destroyWindow(),
                .kill => return,
            }
        }
        canvas.render();
    }
}
