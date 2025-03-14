const std = @import("std");

const Allocator = std.mem.Allocator;

const Input = @import("input.zig").Xkbcommon;
const Renderer = @import("opengl/root.zig").OpenGL;
const Display = @import("wayland.zig").Wayland;
const Painter = @import("painter.zig").Painter;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const NEAR: f32 = 0;
const FAR: f32 = 10;
const SIZE: u16 = 24;
const SCALE: f32 = 1.0;

const CHAR_COUNT: u32 = 92;
const INSTANCE_MAX: u32 = 1024 * 8;

pub const Window = struct {
    display: Display,
    renderer: Renderer,
    painter: Painter,
    input: Input,

    running: bool,

    pub fn init(
        self: *Window,
        width: u32,
        height: u32,
        allocator: *FixedBufferAllocator,
    ) !void {
        self.input = try Input.new(allocator.allocator());

        try self.display.init(self);

        try self.renderer.init(
            width,
            height,
            self.display.display,
            self.display.surface,
        );

        try self.painter.init(.{
            .width = width,
            .height = height,
            .size = SIZE,
            .instanceMax = INSTANCE_MAX,
            .charKindMax = CHAR_COUNT,
            .near = NEAR,
            .far = FAR,
            .allocator = allocator,
        });

        self.display.newListener(&self.renderer, Renderer.resizeListener);
        self.display.newListener(&self.painter, Painter.resizeListen);
        self.input.newListener(&self.painter, Painter.keyListen);

        self.running = true;

        try self.commit();
    }

    pub fn draw(self: *Window) error{Fail}!void {
        defer sleep(60);
        const time = std.time.Instant.now() catch return error.Fail;

        if (self.display.display.roundtrip() != .SUCCESS) return error.Fail;

        self.input.tick();

        if (!self.painter.hasChange()) return;

        self.painter.draw();

        self.commit() catch return error.Fail;

        const end = std.time.Instant.now() catch return error.Fail;
        const elapsed = end.since(time);

        std.log.info("time: {} ns -> {} ms", .{elapsed, elapsed / std.time.ns_per_ms});
    }

    fn commit(self: *Window) error{ InvalidDisplay, InvalidSurface, ContextLost, SwapBuffers }!void {
        try self.renderer.render();
        self.display.surface.commit();
    }

    pub fn deinit(self: *Window) void {
        self.painter.deinit();
        self.input.deinit();
        self.renderer.deinit();
        self.display.deinit();
    }
};

pub fn sleep(ms: u32) void {
    std.time.sleep(ms * std.time.ns_per_ms);
}
