const std = @import("std");
const math = @import("math.zig");
const lib = @import("root.zig");
const FreeType = @import("font.zig").FreeType;

const Matrix = math.Matrix;
const Vec = math.Vec;

const Window = lib.Window;
const ShaderProgram = lib.ShaderProgram;

pub fn main() !void {
    const buffer = try std.heap.page_allocator.alloc(u8, 4 * std.mem.page_size); // This is not all the allocations that happens, openGl do its own allocations, wayland do its own allocations and freetype do is own as well, but every other allocation in this program is made using this buffer
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

    var font = try FreeType.new("assets/font.ttf", 32);
    const aChar = try font.findChar('a');
    var aCharTexture = shader.newTexture(aChar.width, aChar.height, 1, .red, aChar.buffer);
    defer aCharTexture.deinit();

    const samplerLocation = try shader.uniformLocation("textureSampler1");

    var rectangle = try shader.newMesh("assets/plane.obj");
    defer rectangle.deinit();

    var identity = Matrix(4).identity();

    var uniform = try shader.newBuffer(Matrix(4), 3, .uniform_buffer, .dynamic_draw, .{
        identity.scale(.{200, 200, 1, 1}),
        identity.translate(.{ 0.0, 0.0, -1.0 }),
        identity.ortographic(0.0, 1280.0, 0.0, 720.0, 0.2, 10.0),
    });
    defer uniform.deinit();

    const UNIFORM_LOC = 0;

    const MODEL: u32 = 0;
    const VIEW: u32 = 1;
    const PROJECTION: u32 = 2;

    uniform.bind(UNIFORM_LOC);

    const instanceTransforms = try shader.newBuffer(Matrix(4), 4, .shader_storage_buffer, .dynamic_draw, .{
        identity, identity.translate(.{1, 1, 0}), identity.translate(.{-1, 1, 0}), identity.translate(.{1, -1, 0}),
    });
    defer instanceTransforms.deinit();

    const INSTANCE_LOC = 0;

    instanceTransforms.bind(INSTANCE_LOC);

    var instanceCount: u32 = 0;

    while (window.running) {
        const time = std.time.milliTimestamp();

        var viewChange = false;
        var modelChange = false;
        if (window.input.get(.ArrowLeft, time)) {
            uniform.data[VIEW] = uniform.data[VIEW].translate(.{ velocity, 0, 0 });
            viewChange = true;
        } if (window.input.get(.ArrowRight, time)) {
            uniform.data[VIEW] = uniform.data[VIEW].translate(.{ -velocity, 0, 0 });
            viewChange = true;
        } if (window.input.get(.ArrowDown, time)) {
            uniform.data[VIEW] = uniform.data[VIEW].translate(.{ 0, velocity, 0 });
            viewChange = true;
        } if (window.input.get(.ArrowUp, time)) {
            uniform.data[VIEW] = uniform.data[VIEW].translate(.{ 0, -velocity, 0 });
            viewChange = true;
        } if (window.input.get(.Plus, time)) {
            uniform.data[MODEL] = uniform.data[MODEL].scale(.{1.2, 1.2, 1, 1});
            modelChange = true;
        } if (window.input.get(.Minus, time)) {
            uniform.data[MODEL] = uniform.data[MODEL].scale(.{0.8, 0.8, 1, 1});
            modelChange = true;
        } if (window.input.get(.LowerS, time)) {
            if (instanceCount < 4) instanceCount += 1;
        } if (window.input.get(.LowerD, time)) {
            if (instanceCount > 0) instanceCount -= 1;
        }

        if (viewChange) uniform.pushData(VIEW, 1);
        if (modelChange) uniform.pushData(MODEL, 1);

        if (window.renderer.width != width or window.renderer.height != height) {
            width = window.renderer.width;
            height = window.renderer.height;

            uniform.data[PROJECTION] = identity.ortographic(0, @floatFromInt(width), 0.0, @floatFromInt(height), 0.2, 10.0);
            uniform.pushData(PROJECTION, 1);
        }

        shader.start();

        aCharTexture.bind(samplerLocation, 0);

        rectangle.draw(0, instanceCount);

        aCharTexture.unbind(0);

        shader.end();

        try window.update();
    }
}
