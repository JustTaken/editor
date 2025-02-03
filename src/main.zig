const std = @import("std");

const Window = @import("window.zig").Window;

pub fn main() !void {
    const buffer = try std.heap.page_allocator.alloc(u8, 1 * std.mem.page_size);
    defer std.heap.page_allocator.free(buffer);

    var fixedAllocator = std.heap.FixedBufferAllocator.init(buffer);
    var window: Window = undefined;

    try window.init(800, 600, fixedAllocator.allocator());
    defer window.deinit();


    while (window.running) {
        window.clear();
        try window.draw();
    }
    // try OpenGL.init();
}
