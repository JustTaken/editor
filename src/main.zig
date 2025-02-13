const std = @import("std");

const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const Window = @import("window.zig").Window;
const Painter = @import("painter.zig").Painter;

const WIDTH: f32 = 800;
const HEIGHT: f32 = 600;
const NEAR: f32 = 1;
const FAR: f32 = 10;
const SIZE: u16 = 16;
const SCALE: f32 = 1.5;

const CHAR_COUNT: u32 = 64;
const GLYPH_MAX: u32 = 1024 * 4;
const INSTANCE_MAX: u32 = GLYPH_MAX + 1;

pub fn main() !void {
    const buffer = try std.heap.page_allocator.alloc(u8, 16 * std.mem.page_size);
    defer std.heap.page_allocator.free(buffer);

    var fixedAllocator = FixedBufferAllocator.init(buffer);
    const allocator = fixedAllocator.allocator();
    var window: Window = undefined;

    try window.init(WIDTH, HEIGHT);
    defer window.deinit();

    var painter = try Painter.new(.{
        .width = WIDTH,
        .height = HEIGHT,
        .size = SIZE,
        .scale = SCALE,
        .instanceMax = INSTANCE_MAX,
        .glyphMax = GLYPH_MAX,
        .charKindMax = CHAR_COUNT,
        .near = NEAR,
        .far = FAR,
        .allocator = allocator,
    });

    defer painter.deinit();

    window.display.newListener(&painter, Painter.resizeListen);
    window.input.newListener(&painter, Painter.keyListen);

    try window.commit();

    var frame: u32 = 0;
    while (window.running) {
        window.getEvents() catch break;

        if (!painter.hasChange()) continue;

        frame += 1;
        std.log.info("Drawing: {}", .{frame});
        painter.draw();

        window.commit() catch break;
    }
}

