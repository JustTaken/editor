const std = @import("std");

const renderer = @import("opengl/root.zig");
const display = @import("wayland/root.zig");
const input = @import("input.zig");

const Input = input.Xkbcommon;
const Key = input.Key;

const Allocator = std.mem.Allocator;

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
        allocator: Allocator,
    ) !void {
        try self.display.init(self);

        try self.renderer.init(
            width,
            height,
            self.display.display,
            self.display.surface,
            allocator,
        );

        self.running = true;
    }

    pub fn newShader(self: *Window, vertex: []const u8, fragment: []const u8) error{ Read, Compile, NotFound, OutOfMemory }!*renderer.Program {
        return try self.renderer.addShader(vertex, fragment);
    }

    pub fn isKeyPressed(self: *const Window, key: Key) bool {
        return self.input.keys.contains(key);
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
