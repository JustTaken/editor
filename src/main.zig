const std = @import("std");

const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const Window = @import("window.zig").Window;

const WIDTH: f32 = 800;
const HEIGHT: f32 = 600;

pub fn main() !void {
    const buffer = try std.heap.page_allocator.alloc(u8, 32 * std.mem.page_size);
    defer std.heap.page_allocator.free(buffer);

    var fixedAllocator = FixedBufferAllocator.init(buffer);
    const allocator = fixedAllocator.allocator();

    var window: Window = undefined;

    try window.init(WIDTH, HEIGHT, allocator);
    defer window.deinit();

    while (window.running) {
        try window.draw();
    }
}

