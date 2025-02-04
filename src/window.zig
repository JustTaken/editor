const std = @import("std");

const renderer = @import("opengl/root.zig");
const display = @import("wayland/root.zig");

const Allocator = std.mem.Allocator;

const Renderer = renderer.OpenGL;
const Display = display.Wayland;

pub const Window = struct {
    display: Display,
    renderer: Renderer,

    pub fn init(
        self: *Window,
        width: u32,
        height: u32,
        allocator: Allocator,
    ) !void {
        self.display.resizeCallbackFn = Renderer.resize;
        self.display.resizeCallbackListener = &self.renderer;

        try self.display.init();

        try self.renderer.init(
            width,
            height,
            self.display.getHandle(),
            self.display.getSurface(),
            allocator,
        );

        self.display.running = true;
    }

    pub fn newShader(self: *Window, vertex: []const u8, fragment: []const u8) error{ Read, Compile, NotFound, OutOfMemory }!*renderer.Program {
        return try self.renderer.addShader(vertex, fragment);
    }

    pub fn clear(self: *Window) void {
        self.renderer.clear();
    }

    pub fn isRunning(self: *const Window) bool {
        return self.display.running;
    }

    pub fn update(self: *Window) !void {
        try self.renderer.render();
        try self.display.update();

        sleep(30);
    }

    pub fn deinit(self: *Window) void {
        self.renderer.deinit();
        self.display.deinit();
    }
};

fn sleep(ms: u32) void {
    std.time.sleep(ms * std.time.ns_per_ms);
}
