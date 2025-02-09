const std = @import("std");
const math = @import("math.zig");
const lib = @import("root.zig");
const input = @import("input.zig");
const text = @import("textBuffer.zig");

const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const Matrix = math.Matrix;

const Window = lib.Window;
const ShaderProgram = lib.ShaderProgram;
const TextBuffer = text.TextBuffer;
const Buffer = lib.Buffer;

const EnumSet = std.EnumSet;
const Key = input.Key;

const IDENTITY = Matrix(4).identity();

const UNIFORM_MATRICES_LOC = 0;
const VELOCITY: f32 = 10.0;

const WIDTH: f32 = 800;
const HEIGHT: f32 = 600;
const NEAR: f32 = 1;
const FAR: f32 = 10;
const SIZE: u16 = 32;

pub fn main() !void {
    const buffer = try std.heap.page_allocator.alloc(u8, 4 * std.mem.page_size);
    defer std.heap.page_allocator.free(buffer);

    var fixedAllocator = FixedBufferAllocator.init(buffer);
    var window: Window = undefined;

    try window.init(WIDTH, HEIGHT);
    defer window.deinit();

    var shader = try ShaderProgram.new(
        "assets/vertex.glsl",
        "assets/fragment.glsl",
        fixedAllocator.allocator(),
    );
    defer shader.deinit();

    var global = Global.new(WIDTH, HEIGHT, SIZE, 0);
    defer global.deinit();

    window.display.newListener(&global, Global.resizeListen);
    window.input.newListener(&global, Global.keyListen);

    const samplerLocation = try shader.uniformLocation("textureSampler1");

    var charWriter = try TextBuffer.new(SIZE, 128, 32, samplerLocation, fixedAllocator.allocator());
    defer charWriter.deinit();

    window.input.newListener(&charWriter, TextBuffer.listen);

    while (window.running) {
        defer window.update();

        shader.start();

        charWriter.draw();

        shader.end();
    }
}

const Global = struct {
    model: Matrix(4),
    view: Matrix(4),

    uniform: Buffer(Matrix(4)),
    uniformLoc: u32,

    fn new(width: u32, height: u32, size: u32, loc: u32) Global {
        var self: Global = undefined;

        const fsize: f32 = @floatFromInt(size);
        self.model = IDENTITY.scale(.{ fsize, fsize, 1, 1 });
        self.view = IDENTITY.translate(.{ fsize, -fsize, -1 });
        self.uniform = Buffer(Matrix(4)).new(.uniform_buffer, 3, &.{
            self.model,
            self.view,
            IDENTITY.ortographic(0, @floatFromInt(width), 0, @floatFromInt(height), 0.2, 10),
        });

        self.uniformLoc = loc;
        self.uniform.bind(loc);

        return self;
    }

    fn keyListen(ptr: *anyopaque, keys: *EnumSet(Key), controlActive: bool, altActive: bool) void {
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
            2,
            &.{
                IDENTITY.ortographic(0, @floatFromInt(width), 0, @floatFromInt(height), 0.2, 10),
            },
        );
    }

    fn deinit(self: *const Global) void {
        self.uniform.deinit();
    }
};
