const std = @import("std");

const renderer = @import("opengl/root.zig");
const display = @import("wayland.zig");
const input = @import("input.zig");

const Input = input.Xkbcommon;

const Renderer = renderer.OpenGL;
const Display = display.Wayland;

pub const Window = struct {
    display: Display,
    renderer: Renderer,

    input: Input,

    running: bool,

    pub fn init(
        self: *Window,
        width: u32,
        height: u32,
    ) !void {

        self.input = Input.new();
        try self.display.init(self);

        try self.renderer.init(
            width,
            height,
            self.display.display,
            self.display.surface,
        );

        self.display.newListener(&self.renderer, Renderer.resizeListener);

        self.running = true;
    }

    pub fn commit(self: *Window) error{ InvalidDisplay, InvalidSurface, ContextLost, SwapBuffers }!void {
        try self.renderer.render();
        self.display.surface.commit();
    }

    pub fn getEvents(self: *Window) error{Fail}!void {
        if (self.display.display.roundtrip() != .SUCCESS) return error.Fail;

        self.input.tick();

        sleep(30);
    }

    pub fn deinit(self: *Window) void {
        self.input.deinit();
        self.renderer.deinit();
        self.display.deinit();
    }
};

pub fn sleep(ms: u32) void {
    std.time.sleep(ms * std.time.ns_per_ms);
}
