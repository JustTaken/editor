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

    // const smileTexture = try shader.newTexture("textureSampler2", "assets/awesomeface.png");
    // defer smileTexture.deinit();

    // const modelMatrix = try shader.newUniform("modelMatrix", .MatrixF32, 4);
    // const viewMatrix = try shader.newUniform("viewMatrix", .MatrixF32, 4);
    // const projectionMatrix = try shader.newUniform("projectionMatrix", .MatrixF32, 4);

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
        2,
    );

    defer rectangle.deinit();

    var matrices = [_]Matrix(4){
        Matrix(4).scale(.{200.0, 400.0, 1.0, 1.0}),
        Matrix(4).translate(.{0.0, 0.0, -1.0}),
        Matrix(4).ortographic(0.0, 1280.0, 0.0, 720.0, 0.2, 10.0),
    };

    var uniform = try shader.newUniformBlock("Matrix", Matrix(4), &matrices);
    defer uniform.deinit();

    try rectangle.addTexture(texture);
    // try rectangle.addTexture(smileTexture);

    const velocity = 10.0;

    _ = try rectangle.addInstance();

    while (window.running) {
        shader.draw(&.{rectangle});

        if (window.isKeyPressed(.ArrowLeft)) {
            addUniform(uniform, &matrices, velocity, 1, 0, 3);
        } else if (window.isKeyPressed(.ArrowRight)) {
            addUniform(uniform, &matrices, -velocity, 1, 0, 3);
        }

        try window.update();
    }
}

fn addUniform(uniform: anytype, matrices: []Matrix(4), value: f32, index: u32, row: u32, col: u32) void {
    const T = Matrix(4);
    matrices[index].data[row][col] += value;
    // std.debug.print("offset: {}\n", .{@sizeOf(T) * index + 4 * @sizeOf(Matrix(4).inner()) * row + col * @sizeOf(Matrix(4).inner())});
    uniform.pushData(T.inner(), &.{matrices[index].data[row][col]}, T.size() * T.size() * index + T.size() * row + col);
}
