const std = @import("std");
const math = @import("math.zig");
const lib = @import("root.zig");
const FreeType = @import("font.zig").FreeType;

const Matrix = math.Matrix;
const Vec = math.Vec;

const Window = lib.Window;
const ShaderProgram = lib.ShaderProgram;

pub fn main() !void {
    const buffer = try std.heap.page_allocator.alloc(u8, 4 * std.mem.page_size);
    defer std.heap.page_allocator.free(buffer);

    var fixedAllocator = std.heap.FixedBufferAllocator.init(buffer);
    var window: Window = undefined;

    var width: u32 = 800;
    var height: u32 = 600;

    const velocity = 10.0;

    try window.init(width, height);
    defer window.deinit();

    var shader = try ShaderProgram.new("assets/vertex.glsl", "assets/fragment.glsl", fixedAllocator.allocator());
    defer shader.deinit();

    const textureSamplerLocation = try shader.uniformLocation("textureSampler1");

    var font = try FreeType.new("assets/font.ttf");
    const aChar = try font.findChar('a');
    var aCharTexture = shader.newTexture(aChar.width, aChar.height, 1, .red, aChar.buffer);
    defer aCharTexture.deinit();

    var rectangle = try shader.newMesh("assets/plane.obj");
    defer rectangle.deinit();

    var identity = Matrix(4).identity();

    var uniform = try shader.newBuffer(Matrix(4), 3, .uniform_buffer, .dynamic_draw, .{
        identity.scale(.{200.0, 400.0, 1.0, 1.0}),
        identity.translate(.{0.0, 0.0, -1.0}),
        identity.ortographic(0.0, 1280.0, 0.0, 720.0, 0.2, 10.0),
    });
    defer uniform.deinit();

    uniform.bind(0);

    const instanceTransforms = try shader.newBuffer(Matrix(4), 1, .shader_storage_buffer, .dynamic_draw, .{
        identity,
    });
    defer instanceTransforms.deinit();

    instanceTransforms.bind(0);

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

        shader.start();

        aCharTexture.bind(textureSamplerLocation, 0);

        rectangle.draw(0, 1);

        aCharTexture.unbind(0);

        shader.end();

        try window.update();
    }
}
