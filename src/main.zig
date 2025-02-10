const std = @import("std");
const math = @import("math.zig");
const lib = @import("root.zig");
const input = @import("input.zig");
const text = @import("textBuffer.zig");

const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const Matrix = math.Matrix;

const Window = lib.Window;
const Program = lib.Program;
const Shader = lib.Shader;
const TextBuffer = text.TextBuffer;
const Buffer = lib.Buffer;

const EnumSet = std.EnumSet;
const Key = input.Key;

const IDENTITY = Matrix(4).identity();

const VELOCITY: f32 = 10.0;

const WIDTH: f32 = 800;
const HEIGHT: f32 = 600;
const NEAR: f32 = 1;
const FAR: f32 = 10;
const SIZE: u16 = 32;

const CHAR_COUNT: u32 = 64;
const GLYPH_MAX: u32 = 1024;
const INSTANCE_MAX: u32 = GLYPH_MAX + 1;

pub fn main() !void {
    const buffer = try std.heap.page_allocator.alloc(u8, 4 * std.mem.page_size);
    defer std.heap.page_allocator.free(buffer);

    var fixedAllocator = FixedBufferAllocator.init(buffer);
    const allocator = fixedAllocator.allocator();
    var window: Window = undefined;

    try window.init(WIDTH, HEIGHT);
    defer window.deinit();

    const vertexShader = try Shader.fromPath(.vertex, "assets/vertex.glsl", allocator);
    const fragmentShader = try Shader.fromPath(.fragment, "assets/fragment.glsl", allocator);

    var withTextureProgram = try Program.new(vertexShader, fragmentShader, allocator);
    defer withTextureProgram.deinit();

    fragmentShader.deinit();

    const rawFragmentShader = try Shader.fromPath(.fragment, "assets/rawFrag.glsl", allocator);

    var nonTextureProgram = try Program.new(vertexShader, rawFragmentShader, allocator);
    defer nonTextureProgram.deinit();

    vertexShader.deinit();
    rawFragmentShader.deinit();

    var global = Global.new(WIDTH, HEIGHT, SIZE, 0.8, INSTANCE_MAX);
    defer global.deinit();

    window.display.newListener(&global, Global.resizeListen);
    window.input.newListener(&global, Global.keyListen);

    const samplerLocation = try withTextureProgram.uniformLocation("textureSampler1");

    var charWriter = try TextBuffer.new(
        SIZE,
        GLYPH_MAX,
        CHAR_COUNT,
        samplerLocation,
        &global.instances,
        &global.textureIndices,
        allocator,
    );
    defer charWriter.deinit();

    window.input.newListener(&charWriter, TextBuffer.listen);

    while (window.running) {
        defer window.update();

        withTextureProgram.start();
        charWriter.drawChars();
        withTextureProgram.end();

        nonTextureProgram.start();
        charWriter.drawCursors();
        nonTextureProgram.end();
    }
}

const Global = struct {
    model: Matrix(4),
    view: Matrix(4),
    scale: Matrix(4),

    instances: Buffer(Matrix(4)),
    textureIndices: Buffer(u32),
    uniform: Buffer(Matrix(4)),

    fn new(
        width: u32,
        height: u32,
        size: u32,
        scale: f32,
        instanceMax: u32,
    ) Global {
        var self: Global = undefined;

        self.instances = Buffer(Matrix(4)).new(.shader_storage_buffer, instanceMax, null);
        self.textureIndices = Buffer(u32).new(.shader_storage_buffer, instanceMax, null);

        const fsize: f32 = @floatFromInt(size / 2);

        self.model = IDENTITY.scale(.{ fsize, fsize, 1, 1 });
        self.view = IDENTITY.translate(.{ fsize, -fsize, -1 });
        self.scale = IDENTITY.scale(.{ scale, scale, 1, 1 });

        self.uniform = Buffer(Matrix(4)).new(.uniform_buffer, 4, &.{
            self.model,
            self.view,
            self.scale,
            IDENTITY.ortographic(0, @floatFromInt(width), 0, @floatFromInt(height), NEAR, FAR),
        });

        self.uniform.bind(0);
        self.instances.bind(0);
        self.textureIndices.bind(1);

        return self;
    }

    fn keyListen(ptr: *anyopaque, keys: *const EnumSet(Key), controlActive: bool, altActive: bool) void {
        const self: *Global = @ptrCast(@alignCast(ptr));

        _ = controlActive;
        _ = altActive;

        if (keys.contains(.ArrowLeft)) {
            self.view = self.view.translate(.{ -VELOCITY, 0, 0 });
            self.uniform.pushData(1, &.{self.view});
        }

        if (keys.contains(.ArrowRight)) {
            self.view = self.view.translate(.{ VELOCITY, 0, 0 });
            self.uniform.pushData(1, &.{self.view});
        }

        if (keys.contains(.ArrowUp)) {
            self.view = self.view.translate(.{ 0, VELOCITY, 0 });
            self.uniform.pushData(1, &.{self.view});
        }

        if (keys.contains(.ArrowDown)) {
            self.view = self.view.translate(.{ 0, -VELOCITY, 0 });
            self.uniform.pushData(1, &.{self.view});
        }
    }

    fn resizeListen(ptr: *anyopaque, width: u32, height: u32) void {
        const self: *Global = @ptrCast(@alignCast(ptr));

        self.uniform.pushData(
            3,
            &.{
                IDENTITY.ortographic(0, @floatFromInt(width), 0, @floatFromInt(height), NEAR, FAR),
            },
        );
    }

    fn deinit(self: *const Global) void {
        self.textureIndices.deinit();
        self.instances.deinit();
        self.uniform.deinit();
    }
};
