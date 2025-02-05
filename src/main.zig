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

    const modelMatrix = try shader.newUniform("modelMatrix", .MatrixF32, 4);
    const viewMatrix = try shader.newUniform("viewMatrix", .MatrixF32, 4);
    const projectionMatrix = try shader.newUniform("projectionMatrix", .MatrixF32, 4);

    const rectangle = try shader.newMesh(
        VertexData,
        &.{
            .{ .position = Vec(3).init(.{ 1.0, -1.0, 0.0 }), .color = Vec(3).init(.{ 0.0, 1.0, 0.0 }), .texture = Vec(2).init(.{ 1.0, 1.0 }) },
            .{ .position = Vec(3).init(.{ 1.0, 1.0, 0.0 }), .color = Vec(3).init(.{ 1.0, 0.0, 0.0 }), .texture = Vec(2).init(.{ 1.0, 0.0 }) },
            .{ .position = Vec(3).init(.{ -1.0, 1.0, 0.0 }), .color = Vec(3).init(.{ 1.0, 0.0, 1.0 }), .texture = Vec(2).init(.{ 0.0, 0.0 }) },
            .{ .position = Vec(3).init(.{ -1.0, -1.0, 0.0 }), .color = Vec(3).init(.{ 0.0, 0.0, 1.0 }), .texture = Vec(2).init(.{ 0.0, 1.0 }) },
        },
        &.{
            0, 1, 3,
            1, 2, 3,
        },
    );
    defer rectangle.deinit();

    try rectangle.addTexture(texture);
    try rectangle.addTexture(smileTexture);

    modelMatrix.pushData(Matrix(4).scale(.{400.0, 400.0, 1.0, 1.0}));
    viewMatrix.pushData(Matrix(4).translate(.{0.0, 0.0, -1.0}));
    projectionMatrix.pushData(Matrix(4).ortographic(0.0, 1280.0, 0.0, 720.0, 0.2, 10.0));

    _ = try rectangle.addInstance();

    while (window.isRunning()) {
        window.clear();

        shader.draw(&.{rectangle});

        try window.update();
    }
}
