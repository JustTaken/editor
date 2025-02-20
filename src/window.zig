const std = @import("std");

const Allocator = std.mem.Allocator;

const Input = @import("input.zig").Xkbcommon;
const Renderer = @import("opengl/root.zig").OpenGL;
const Display = @import("wayland.zig").Wayland;
const Painter = @import("painter.zig").Painter;

const NEAR: f32 = 1;
const FAR: f32 = 10;
const SIZE: u16 = 32;
const SCALE: f32 = 1.0;

const CHAR_COUNT: u32 = 92;
const INSTANCE_MAX: u32 = 1024 * 8;

pub const Window = struct {
    /// Wayland abstraction fr creating a surface and a seat, the later is for handling
    /// keyboard and mouse input. This is responsible for sending resize events for every
    /// componenet that is registred in the resize event.
    display: Display,

    /// Setup opengl for beeing able to create a shader element when passing a
    /// shader file, for example "assets/vertex.glsl" and "assets/fragment.glsl"
    renderer: Renderer,

    /// Manage and draw ui elements every time one of its elements
    /// changes.
    painter: Painter,

    /// Take input from keyboard and send for every one
    /// registered every time it ticks the associated repeat or delay.
    input: Input,

    running: bool,

    pub fn init(
        self: *Window,
        width: u32,
        height: u32,
        allocator: Allocator,
    ) !void {
        self.input = Input.new();

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
            .scale = SCALE,
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

    /// Needs to be called every frame so it can round trip the wayland componenet
    /// and receives updatess from the compositor.
    /// Parallel to that this function performs the drawing of the next frame if the painter
    /// componenet says it has changed, otherwise it just updates the input handler timer.
    pub fn draw(self: *Window) error{Fail}!void {
        defer sleep(30);
        const time = std.time.Instant.now() catch return error.Fail;

        if (self.display.display.roundtrip() != .SUCCESS) return error.Fail;

        self.input.tick();

        if (!self.painter.hasChange()) return;

        self.painter.draw();

        self.commit() catch return error.Fail;

        const end = std.time.Instant.now() catch return error.Fail; 
        const elapsed = end.since(time);
        _ = elapsed;

        // std.log.info("time: {} ns -> {} ms", .{elapsed, elapsed / std.time.ns_per_ms});
    }

    /// Meat to be a wayland wrapper around the commit action and prior to the commit it performs the
    /// renderer necessary work to commit the next changes
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
