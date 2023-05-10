const std = @import("std");
const math = std.math;
pub const c = @cImport({
    @cInclude("SDL.h");
});

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
    };
}

const Window = struct {
    window_handle: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
};

window: ?Window = null,

const Self = @This();

pub fn createWindow(self: *Self, width: c_int, height: c_int) Result(void) {
    if (c.SDL_InitSubSystem(c.SDL_INIT_VIDEO) != 0) return .{ .err = getError() };
    const error_or_void = self.getNewWindow(width, height).map(void, kCombinator(Window, {}));
    switch (self.clear()) {
        .ok => {},
        else => |e| return e,
    }
    return error_or_void;
}

pub fn hasWindow(self: Self) bool {
    return self.window != null;
}

pub fn clear(self: *Self) Result(void) {
    if (self.window) |window| {
        switch (self.setColor(255, 255, 255)) {
            .ok => {},
            else => |e| return e,
        }
        if (c.SDL_RenderClear(window.renderer) != 0) return .{ .err = getError() };
        switch (self.setColor(0, 0, 0)) {
            .ok => {},
            else => |e| return e,
        }
    }
    return .{ .ok = {} };
}

pub fn pixel(self: Self, x: c_int, y: c_int) Result(void) {
    if (self.window) |window| {
        if (c.SDL_RenderDrawPoint(window.renderer, x, y) != 0) return .{ .err = getError() };
    }
    return .{ .ok = {} };
}

pub fn render(self: *Self) void {
    if (self.window) |window| c.SDL_RenderPresent(window.renderer);
}

pub fn destroyWindow(self: *Self) void {
    const window = self.window orelse return;
    c.SDL_DestroyWindow(window.window_handle);
    c.SDL_DestroyRenderer(window.renderer);
    c.SDL_QuitSubSystem(c.SDL_INIT_VIDEO);
    c.SDL_Quit();
}

pub fn deinit(self: *Self) void {
    self.destroyWindow();
    self.* = undefined;
}

fn kCombinator(comptime T: type, x: anytype) fn (T) @TypeOf(x) {
    return struct {
        fn f(_: T) @TypeOf(x) {
            return x;
        }
    }.f;
}

fn unreachableFn(_: anytype) noreturn {
    unreachable;
}

fn getError() []const u8 {
    return std.mem.span(c.SDL_GetError());
}

fn getWindowOrDefault(self: *Self) Result(Window) {
    return if (self.window) |w| .{ .ok = w } else self.getNewWindow(100, 100);
}

fn getNewWindow(self: *Self, width: c_int, height: c_int) Result(Window) {
    if (self.hasWindow()) self.destroyWindow();
    var window_handle = c.SDL_CreateWindow(
        "meow lisp :3",
        c.SDL_WINDOWPOS_UNDEFINED,
        c.SDL_WINDOWPOS_UNDEFINED,
        width,
        height,
        0,
    ) orelse return .{ .err = getError() };
    var is_error = true;
    defer if (is_error) c.SDL_DestroyWindow(window_handle);
    var renderer = c.SDL_CreateRenderer(window_handle, -1, 0) orelse return .{ .err = getError() };
    const window = .{ .window_handle = window_handle, .renderer = renderer };
    self.window = window;
    is_error = false;
    return .{ .ok = window };
}

fn setColor(self: *Self, r: u8, g: u8, b: u8) Result(void) {
    if (self.window) |window|
        if (c.SDL_SetRenderDrawColor(window.renderer, r, g, b, 255) != 0)
            return .{ .err = getError() };

    return .{ .ok = {} };
}
