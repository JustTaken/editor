const std = @import("std");
const Window = @import("window.zig").Window;

pub const error_handling = .log;

const VertexData = struct {
    position: [3]f32,
    color: [3]f32,
    texture: [2]f32,
};

const transformMatrix: [4][4]f32 = .{
    .{ 1.0, 0.0, 0.0, 0.0},
    .{ 0.0, 1.0, 0.0, 0.0},
    .{ 0.0, 0.0, 1.0, 0.0},
    .{ 0.0, 0.0, 0.0, 1.0},
};

pub fn main() !void {
    const buffer = try std.heap.page_allocator.alloc(u8, 1 * std.mem.page_size);
    defer std.heap.page_allocator.free(buffer);

    var fixedAllocator = std.heap.FixedBufferAllocator.init(buffer);
    var window: Window = undefined;

    try window.init(800, 600, fixedAllocator.allocator());
    defer window.deinit();

    const shader = try window.newShader("assets/vertex.glsl", "assets/fragment.glsl");
    defer shader.deinit();

    const texture = try shader.newTexture("textureSampler1", "assets/container.jpg");
    defer texture.deinit();

    const transformUniform = try shader.newUniform("myTransformMatrix", .mat4);

    const rectangle = try shader.newMesh(
        VertexData,
        &.{
            .{ .position = .{ 0.5, 0.5, 0.0 }, .color = .{ 1.0, 0.0, 0.0 }, .texture = .{ 2.2, 0.0 } },
            .{ .position = .{ 0.5, -0.5, 0.0 }, .color = .{ 0.0, 1.0, 0.0 }, .texture = .{ 2.2, 2.2 } },
            .{ .position = .{ -0.5, -0.5, 0.0 }, .color = .{ 0.0, 0.0, 1.0 }, .texture = .{ 0.0, 2.2 } },
            .{ .position = .{ -0.5, 0.5, 0.0 }, .color = .{ 1.0, 0.0, 1.0 }, .texture = .{ 0.0, 0.0 } },
        },
        &.{
            0, 1, 3,
            1, 2, 3,
        },
    );
    defer rectangle.deinit();

    try rectangle.addTexture(texture);

    shader.start();

    transformUniform.update(.mat4, transformMatrix);

    rectangle.configure();

    shader.end();

    while (window.running) {
        window.clear();

        shader.start();

        rectangle.draw();

        shader.end();

        try window.update();
    }
}
