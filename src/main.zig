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

    var width: u32 = 800;
    var height: u32 = 600;

    try window.init(width, height, fixedAllocator.allocator());
    defer window.deinit();

    const shader = try window.renderer.newProgram("assets/vertex.glsl", "assets/fragment.glsl");
    defer shader.deinit();

    const texture = try shader.newTexture("textureSampler1", "assets/container.jpg");
    defer texture.deinit();

    const smileTexture = try shader.newTexture("textureSampler2", "assets/awesomeface.png");
    defer smileTexture.deinit();

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

    var identity = Matrix(4).identity();

    var uniform = try shader.newUniformBlock("Matrix", Matrix(4), 3, .{
        identity.scale(.{200.0, 400.0, 1.0, 1.0}),
        identity.translate(.{0.0, 0.0, -1.0}),
        identity.ortographic(0.0, 1280.0, 0.0, 720.0, 0.2, 10.0),
    });
    defer uniform.deinit();

    const velocity = 10.0;

    const instance = try rectangle.addInstances(1);
    _ = instance;

    while (window.running) {
        if (window.input.keys.contains(.ArrowLeft)) {
            uniform.data[1] = uniform.data[1].translate(.{velocity, 0.0, 0.0});
            uniform.pushData(1, 1);
        } else if (window.input.keys.contains(.ArrowRight)) {
            uniform.data[1] = uniform.data[1].translate(.{-velocity, 0.0, 0.0});
            uniform.pushData(1, 1);
        } else if (window.input.keys.contains(.ArrowDown)) {
            uniform.data[0] = uniform.data[0].rotate(math.rad(-5), Vec(3).init(.{1.0, 0.0, 0.0}));
            uniform.pushData(0, 1);
        } else if (window.input.keys.contains(.ArrowUp)) {
            uniform.data[0] = uniform.data[0].rotate(math.rad(5), Vec(3).init(.{1.0, 0.0, 0.0}));
            uniform.pushData(0, 1);
        }

        if (window.renderer.width != width or window.renderer.height != height) {
            width = window.renderer.width;
            height = window.renderer.height;

            uniform.data[2] = identity.ortographic(0, @floatFromInt(width), 0.0, @floatFromInt(height), 0.2, 10.0);
            uniform.pushData(2, 1);
        }

        shader.draw(&.{rectangle});

        try window.update();
    }
}
