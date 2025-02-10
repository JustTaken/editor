const std = @import("std");
const math = @import("math.zig");
const font = @import("font.zig");
const lib = @import("root.zig");
const input = @import("input.zig");

const ArrayList = std.ArrayList;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const Allocator = std.mem.Allocator;
const EnumSet = std.EnumSet;
const Map = std.AutoArrayHashMap;

const Matrix = math.Matrix;

const Window = lib.Window;
const Program = lib.Program;
const Shader = lib.Shader;
const Buffer = lib.Buffer;
const Texture = lib.Texture;
const Mesh = lib.Mesh;

const Key = input.Key;

const FreeType = font.FreeType;
const Char = font.Char;

const IDENTITY = Matrix(4).identity();

const VELOCITY: f32 = 10.0;

const WIDTH: f32 = 800;
const HEIGHT: f32 = 600;
const NEAR: f32 = 1;
const FAR: f32 = 10;
const SIZE: u16 = 32;
const SCALE: f32 = 1.33;

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

    const samplerLocation = try withTextureProgram.uniformLocation("textureSampler1");
    var global = try Global.new(WIDTH, HEIGHT, SIZE, SCALE, INSTANCE_MAX, samplerLocation, allocator);
    defer global.deinit();

    window.display.newListener(&global, Global.resizeListen);
    window.input.newListener(&global, Global.keyListen);

    try window.commit();
    while (window.running) {
        window.getEvents() catch break;

        if (!global.hasChange()) continue;

        withTextureProgram.start();
        global.text.drawChars();
        withTextureProgram.end();

        nonTextureProgram.start();
        global.text.drawCursors();
        nonTextureProgram.end();

        window.commit() catch break;
    }
}

const Global = struct {
    indices: Buffer([2]u32),
    instances: Buffer(Matrix(4)),
    uniform: Buffer(Matrix(4)),

    matrices: [N]Matrix(4),
    changes: [N]bool,

    text: TextBuffer,

    width: u32,
    height: u32,

    const N: u32 = 4;

    fn new(
        width: u32,
        height: u32,
        size: u32,
        scale: f32,
        instanceMax: u32,
        samplerLocation: u32,
        allocator: Allocator,
    ) error{Init, Read, OutOfMemory}!Global {
        var self: Global = undefined;

        self.width = width;
        self.height = height;

        self.instances = Buffer(Matrix(4)).new(.shader_storage_buffer, instanceMax, null);
        self.indices = Buffer([2]u32).new(.shader_storage_buffer, instanceMax, null);

        const fsize: f32 = @floatFromInt(size / 2);

        self.matrices = .{
            IDENTITY.scale(.{ fsize, fsize, 1, 1 }),
            IDENTITY.translate(.{ fsize, -fsize, -1 }),
            IDENTITY.scale(.{ scale, scale, 1, 1 }),
            IDENTITY.ortographic(0, @floatFromInt(width), 0, @floatFromInt(height), NEAR, FAR),
        };

        self.uniform = Buffer(Matrix(4)).new(.uniform_buffer, N, &self.matrices);
        self.changes = .{false} ** N;

        self.uniform.bind(0);
        self.instances.bind(0);
        self.indices.bind(1);

        self.text = try TextBuffer.new(
            size,
            width,
            height,
            scale,
            GLYPH_MAX,
            CHAR_COUNT,
            samplerLocation,
            &self.instances,
            &self.indices,
            allocator,
        );

        return self;
    }

    fn keyListen(ptr: *anyopaque, keys: *const EnumSet(Key), controlActive: bool, altActive: bool) void {
        const self: *Global = @ptrCast(@alignCast(ptr));

        if (keys.contains(.ArrowLeft)) {
            self.matrices[1] = self.matrices[1].translate(.{ -VELOCITY, 0, 0 });
            self.changes[1] = true;
        }

        if (keys.contains(.ArrowRight)) {
            self.matrices[1] = self.matrices[1].translate(.{ VELOCITY, 0, 0 });
            self.changes[1] = true;
        }

        if (keys.contains(.ArrowUp)) {
            self.matrices[1] = self.matrices[1].translate(.{ 0, VELOCITY, 0 });
            self.changes[1] = true;
        }

        if (keys.contains(.ArrowDown)) {
            self.matrices[1] = self.matrices[1].translate(.{ 0, -VELOCITY, 0 });
            self.changes[1] = true;
        }

        self.text.listen(keys, controlActive, altActive);
    }

    fn resizeListen(ptr: *anyopaque, width: u32, height: u32) void {
        const self: *Global = @ptrCast(@alignCast(ptr));

        if (width == self.width and height == self.height) return;
        self.width = width;
        self.height = height;

        self.matrices[3] = IDENTITY.ortographic(0, @floatFromInt(width), 0, @floatFromInt(height), NEAR, FAR);
        self.changes[3] = true;

        self.text.resize(width, height);
    }

    fn hasChange(self: *Global) bool {
        var flag = false;
        var start: u32 = 0;
        var count: u32 = 0;

        while (start + count < self.matrices.len) {

            if (!self.changes[start + count]) {
                if (count > 0) {
                    flag = true;
                    self.uniform.pushData(@intCast(start), self.matrices[start..start + count]);
                }

                start += count + 1;
                count = 0;

                continue;
            }

            self.changes[start + count] = false;
            count += 1;
        }

        if (count > 0) {
            self.uniform.pushData(@intCast(start), self.matrices[start..start + count]);
        }

        return self.text.hasChange() or flag or count > 0;
    }

    fn deinit(self: *const Global) void {
        self.text.deinit();
        self.indices.deinit();
        self.instances.deinit();
        self.uniform.deinit();
    }
};

pub const TextBuffer = struct {
    font: FreeType,
    chars: Map(u32, CharSet),
    rectangle: Mesh,

    charTransforms: Buffer(Matrix(4)),
    instances: Buffer(Matrix(4)).Slice,
    indices: Buffer([2]u32).Slice,

    texture: Texture,

    instanceCount: u32,
    instanceMax: u32,

    textureLocation: u32,

    cursorTransform: Matrix(4),

    cursorX: u32,
    cursorY: u32,
    // cursorIndex: u32,

    textureCount: u16,
    textureMax: u32,
    size: u16,

    change: bool,

    width: u32,
    height: u32,

    scale: f32,
    rowChars: u32,
    colChars: u32,

    const CharSet = struct {
        textureId: ?u16,
        advance: u16,
        bearing: [2]i32,
    };

    pub fn new(
        size: u32,
        width: u32,
        height: u32,
        scale: f32,
        instanceMax: u32,
        textureMax: u32,
        textureLocation: u32,
        instances: *Buffer(Matrix(4)),
        indices: *Buffer([2]u32),
        allocator: Allocator,
    ) error{ Init, Read, OutOfMemory }!TextBuffer {
        var self: TextBuffer = undefined;

        self.scale = scale;

        const overSize = size + 2;
        self.texture = Texture.new(overSize, overSize, textureMax, .r8, .red, .unsigned_byte, .@"2d_array", null);
        self.charTransforms = Buffer(Matrix(4)).new(.shader_storage_buffer, textureMax, null);

        self.charTransforms.bind(2);

        self.resize(width, height);

        self.instances = try instances.getSlice(instanceMax);
        self.indices = try indices.getSlice(instanceMax);

        self.size = @intCast(overSize);
        self.textureLocation = textureLocation;
        self.instanceMax = instanceMax;
        self.textureMax = textureMax;

        self.cursorX = 0;
        self.cursorY = 0;
        self.instanceCount = 0;
        self.textureCount = 0;
        // self.cursorIndex = 0;
        self.change = true;

        self.rectangle = try Mesh.new("assets/plane.obj", allocator);
        self.font = try FreeType.new("assets/font.ttf", size);
        self.chars = Map(u32, CharSet).init(allocator);

        try self.chars.ensureTotalCapacity(textureMax * 2);

        self.initCursor();

        return self;
    }

    fn processKeys(self: *TextBuffer, keys: *const EnumSet(Key)) void {
        var iter = keys.iterator();

        while (iter.next()) |k| {
            const i: u32 = @intFromEnum(k);

            if (i > input.NO_DISPLAY_START) {
                self.processCommand(k);
                continue;
            }

            const charSetEntry = self.chars.getOrPut(i) catch |e| {
                std.log.err("Failed to register char of key: {}, code: {}, err: {}", .{ k, i, e });
                continue;
            };

            if (!charSetEntry.found_existing) self.newCharSet(charSetEntry.value_ptr, i) catch |e| {
                std.log.err("Failed to construct char bitmap for: {}, code: {}, {}", .{ k, i, e });
                continue;
            };

            self.addInstance(charSetEntry.value_ptr) catch |e| {
                std.log.err("Failed to add instance of: {}, to the screen, cause: {}", .{ k, e });
                break;
            };
        }
    }

    fn processCommand(self: *TextBuffer, key: Key) void {
        switch (key) {
            .Enter => {
                self.cursorY += 1;
                self.cursorX = 0;
                self.updateCursor();
            },
            else => return,
        }
    }

    fn processWithModifiers(self: *TextBuffer, keys: *const EnumSet(Key), controlActive: bool, altActive: bool) void {
        _ = self;
        _ = keys;
        _ = controlActive;
        _ = altActive;
    }

    fn newCharSet(self: *TextBuffer, set: *CharSet, code: u32) error{ CharNotFound, Max }!void {
        set.textureId = null;

        if (self.textureCount >= self.textureMax) {
            std.log.err("Max number of chars", .{});

            return error.Max;
        }

        const index = self.textureCount;

        const char = try self.font.findChar(code);

        set.advance = @intCast(char.advance);
        set.bearing = char.bearing;

        if (char.buffer) |b| {
            self.textureCount += 1;
            set.textureId = index;

            self.texture.pushData(char.width, char.height, index, .red, .unsigned_byte, b);

            const deltaX: f32 = @floatFromInt(set.bearing[0]);
            const deltaY: f32 = @floatFromInt((self.size - set.bearing[1]));

            self.charTransforms.pushData(index, &.{IDENTITY.translate(.{ deltaX, -deltaY, 0 })});
        }
    }

    fn addInstance(self: *TextBuffer, set: *CharSet) error{Max}!void {
        if (self.instanceCount >= self.instanceMax) {
            std.log.err("Maximun number of instances", .{});
            return error.Max;
        }

        if (set.textureId) |id| {

            self.instanceCount += 1;
            self.indices.pushData(self.instanceCount, &.{.{(self.cursorY * self.rowChars) + self.cursorX, id}});
        }

        self.cursorX += 1;
        self.updateCursor();
    }

    pub fn listen(self: *TextBuffer, keys: *const EnumSet(Key), controlActive: bool, altActive: bool) void {
        if (controlActive or altActive) self.processWithModifiers(keys, controlActive, altActive) else self.processKeys(keys);
    }

    fn initCursor(self: *TextBuffer) void {
        self.textureCount += 1;
        self.instanceCount += 1;

        const heightScale = @as(f32, @floatFromInt(self.font.height)) / @as(f32, @floatFromInt(self.size));
        const widthScale = @as(f32, @floatFromInt(self.font.width)) / @as(f32, @floatFromInt(self.size));

        self.cursorTransform = IDENTITY.scale(.{widthScale, heightScale, 1, 1}).translate(.{-@as(f32, @floatFromInt(self.font.width)) / 2.0, 0, 0 });
        self.charTransforms.pushData(0, &.{self.cursorTransform});

        self.updateCursor();
    }

    fn updateCursor(self: *TextBuffer) void {
        self.change = true;
        self.indices.pushData(0, &.{.{(self.cursorY * self.rowChars) +  self.cursorX, 0}});
    }

    pub fn drawChars(self: *TextBuffer) void {
        if (self.instanceCount == 0) return;

        self.texture.bind(self.textureLocation, 0);
        self.rectangle.draw(1, self.instanceCount);
    }

    pub fn drawCursors(self: *TextBuffer) void {
        self.rectangle.draw(0, 1);
    }

    pub fn resize(self: *TextBuffer, width: u32, height: u32) void {
        const rowChars: f32 = @floatFromInt(width / self.font.width);
        const colChars: f32 = @floatFromInt(height / self.font.height);

        self.rowChars = @intFromFloat(rowChars / self.scale);
        self.colChars = @intFromFloat(colChars / self.scale);

        if (self.rowChars * self.colChars > self.instanceMax) @panic("Increase the maximum number of instances");

        for (0..self.rowChars) |j| {
            for (0..self.colChars) |i| {
                const offset = (i * self.rowChars) + j;
                const xPos: f32 = @floatFromInt(self.font.width * j);
                const yPos: f32 = @floatFromInt(self.font.height * i);

                self.instances.pushData(@intCast(offset), &.{IDENTITY.translate(.{ xPos, -yPos, 0 })});
            }
        }

        self.width = width;
        self.height = height;
    }

    pub fn hasChange(self: *TextBuffer) bool {
        defer self.change = false;
        return self.change;
    }

    pub fn deinit(self: *const TextBuffer) void {
        self.texture.deinit();
        self.rectangle.deinit();
    }
};
