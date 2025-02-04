const std = @import("std");
const math = @import("math.zig");

const Matrix = math.Matrix;
const Vec = math.Vec;

const Window = @import("window.zig").Window;

pub const error_handling = .log;

const VertexData = struct {
    position: Vec(3),
    color: Vec(3),
    texture: Vec(2),
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

    const smileTexture = try shader.newTexture("textureSampler2", "assets/awesomeface.png");
    defer smileTexture.deinit();

    const transformUniform = try shader.newUniform("myTransformMatrix", .MatrixF32, 4);

    const rectangle = try shader.newMesh(
        VertexData,
        &.{
            .{ .position = Vec(3).init(.{ 0.5, 0.5, 0.0 }), .color = Vec(3).init(.{ 1.0, 0.0, 0.0 }), .texture = Vec(2).init(.{ 1.0, 0.0 }) },
            .{ .position = Vec(3).init(.{ 0.5, -0.5, 0.0 }), .color = Vec(3).init(.{ 0.0, 1.0, 0.0 }), .texture = Vec(2).init(.{ 1.0, 1.0 }) },
            .{ .position = Vec(3).init(.{ -0.5, -0.5, 0.0 }), .color = Vec(3).init(.{ 0.0, 0.0, 1.0 }), .texture = Vec(2).init(.{ 0.0, 1.0 }) },
            .{ .position = Vec(3).init(.{ -0.5, 0.5, 0.0 }), .color = Vec(3).init(.{ 1.0, 0.0, 1.0 }), .texture = Vec(2).init(.{ 0.0, 0.0 }) },
        },
        &.{
            0, 1, 3,
            1, 2, 3,
        },
    );
    defer rectangle.deinit();

    try rectangle.addTexture(texture);
    try rectangle.addTexture(smileTexture);

    shader.start();

    transformUniform.update(Matrix(4).rotate(math.rad(90), Vec(3).init(.{0.0, 0.0, 0.1})));

    rectangle.configure();

    shader.end();

    while (window.isRunning()) {
        window.clear();

        shader.start();

        rectangle.draw();

        shader.end();

        try window.update();
    }
}
