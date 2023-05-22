const std = @import("std");
const math = std.math;
pub const c = @cImport({
    @cInclude("SDL.h");
});

const Color = @import("Color.zig");

pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: []const u8,

        pub fn map(self: @This(), comptime U: type, f: fn (T) U) Result(U) {
            return switch (self) {
                .ok => |v| .{ .ok = f(v) },
                .err => |e| .{ .err = e },
            };
        }

        pub fn as_err(self: @This()) ?[]const u8 {
            return if (self == .err) self.err else null;
        }
    };
}

const Window = struct {
    window_handle: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
};

window: ?Window = null,
clear_color: Color = Color.magenta,
fill_color: Color = Color.magenta,
stroke_color: Color = Color.magenta,

const Self = @This();

pub fn createWindow(self: *Self, width: c_int, height: c_int, scale: ?c_int) Result(void) {
    if (c.SDL_InitSubSystem(c.SDL_INIT_VIDEO) != 0) return .{ .err = getError() };
    switch (self.getNewWindow(width, height, scale)) {
        .ok => {},
        .err => |e| return .{ .err = e },
    }
    return self.clear();
}

pub fn resizeWindow(self: *Self, width: c_int, height: c_int, scale: ?c_int) Result(void) {
    if (self.window) |window| {
        const times_scale = scale orelse getWindowScale(window);
        c.SDL_SetWindowSize(window.window_handle, width * times_scale, height * times_scale);
        if (self.setWindowScale(scale) == .err) return .{ .err = getError() };
        return self.clear();
    }
    return .{ .ok = {} };
}

pub fn repositionWindow(self: *Self, x: c_int, y: c_int) Result(void) {
    if (self.window) |window| {
        c.SDL_SetWindowPosition(window.window_handle, x, y);
    }
    return .{ .ok = {} };
}

pub fn hasWindow(self: Self) bool {
    return self.window != null;
}

pub fn clear(self: Self) Result(void) {
    if (self.window) |window| {
        const e = self.setColor(self.clear_color);
        if (e == .err) return e;
        if (c.SDL_RenderClear(window.renderer) != 0) return .{ .err = getError() };
    }
    return .{ .ok = {} };
}

pub fn point(self: Self, x: c_int, y: c_int) Result(void) {
    if (self.window) |window| {
        const e = self.setColor(self.stroke_color);
        if (e == .err) return e;
        if (c.SDL_RenderDrawPoint(window.renderer, x, y) != 0) return .{ .err = getError() };
    }
    return .{ .ok = {} };
}

pub fn line(self: Self, x1: c_int, y1: c_int, x2: c_int, y2: c_int) Result(void) {
    if (self.window) |window| {
        const e = self.setColor(self.stroke_color);
        if (e == .err) return e;
        if (c.SDL_RenderDrawLine(window.renderer, x1, y1, x2, y2) != 0) return .{ .err = getError() };
    }
    return .{ .ok = {} };
}

pub fn rect(self: Self, x: c_int, y: c_int, w: c_int, h: c_int) Result(void) {
    if (self.window) |window| {
        const sdl_rect = c.SDL_Rect{ .x = x, .y = y, .w = w, .h = h };
        {
            const e = self.setColor(self.fill_color);
            if (e == .err) return e;
        }
        if (c.SDL_RenderFillRect(window.renderer, &sdl_rect) != 0) return .{ .err = getError() };
        {
            const e = self.setColor(self.stroke_color);
            if (e == .err) return e;
        }
        if (c.SDL_RenderDrawRect(window.renderer, &sdl_rect) != 0) return .{ .err = getError() };
    }
    return .{ .ok = {} };
}

pub fn render(self: Self) void {
    if (self.window) |window| c.SDL_RenderPresent(window.renderer);
}

pub fn destroyWindow(self: *Self) void {
    const window = self.window orelse return;
    c.SDL_DestroyWindow(window.window_handle);
    c.SDL_DestroyRenderer(window.renderer);
    c.SDL_QuitSubSystem(c.SDL_INIT_VIDEO);
    c.SDL_Quit();
    self.window = null;
}

pub fn deinit(self: *Self) void {
    self.destroyWindow();
    self.* = undefined;
}

fn unreachableFn(_: anytype) noreturn {
    unreachable;
}

fn getError() []const u8 {
    return std.mem.span(c.SDL_GetError());
}

// fn getWindowOrDefault(self: *Self) Result(Window) {
//     return if (self.window) |w| .{ .ok = w } else self.getNewWindow(100, 100);
// }

fn getNewWindow(self: *Self, width: c_int, height: c_int, scale: ?c_int) Result(Window) {
    const times_scale = scale orelse 1;
    if (self.hasWindow()) self.destroyWindow();
    var window_handle = c.SDL_CreateWindow(
        "DrawLisp Canvas",
        c.SDL_WINDOWPOS_UNDEFINED,
        c.SDL_WINDOWPOS_UNDEFINED,
        width * times_scale,
        height * times_scale,
        0,
    ) orelse return .{ .err = getError() };
    var is_error = true;
    defer if (is_error) c.SDL_DestroyWindow(window_handle);
    // IDK if this can error, which is why I'm not providing this as a flag in SDL_CreateWindow
    c.SDL_SetWindowResizable(window_handle, 1);
    var renderer = c.SDL_CreateRenderer(
        window_handle,
        -1,
        c.SDL_RENDERER_PRESENTVSYNC,
    ) orelse return .{ .err = getError() };
    defer if (is_error) c.SDL_DestroyRenderer(renderer);
    if (c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND) != 0)
        return .{ .err = getError() };
    const window = .{ .window_handle = window_handle, .renderer = renderer };
    self.window = window;
    if (self.setWindowScale(scale) == .err) return .{ .err = getError() };
    is_error = false;
    return .{ .ok = window };
}

fn setColor(self: Self, color: Color) Result(void) {
    if (self.window) |window|
        if (c.SDL_SetRenderDrawColor(window.renderer, color.r, color.g, color.b, color.a) != 0)
            return .{ .err = getError() };
    return .{ .ok = {} };
}

fn setWindowScale(self: *Self, scale_: ?c_int) Result(void) {
    const scale = @intToFloat(f32, scale_ orelse return .{ .ok = {} });
    if (self.window) |window|
        if (c.SDL_RenderSetScale(window.renderer, scale, scale) != 0)
            return .{ .err = getError() };
    return .{ .ok = {} };
}

fn getWindowScale(window: Window) c_int {
    var x_scale: f32 = undefined;
    var y_scale: f32 = undefined;
    c.SDL_RenderGetScale(window.renderer, &x_scale, &y_scale);
    std.debug.assert(x_scale == y_scale);
    return @floatToInt(c_int, x_scale);
}
