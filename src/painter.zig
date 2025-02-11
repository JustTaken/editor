const std = @import("std");

const Allocator = std.mem.Allocator;
const EnumSet = std.EnumSet;
const Map = std.AutoArrayHashMap;
const ArrayList = std.ArrayList;

const Program = @import("opengl/shader.zig").Program;
const Shader = @import("opengl/shader.zig").Shader;
const Texture = @import("opengl/texture.zig").Texture;
const Buffer = @import("opengl/buffer.zig").Buffer;
const Mesh = @import("opengl/mesh.zig").Mesh;

const Matrix = @import("math.zig").Matrix;

const Key = @import("input.zig").Key;

const FreeType = @import("font.zig").FreeType;
const Char = @import("font.zig").Char;

const IDENTITY = Matrix(4).identity();

const VELOCITY: f32 = 10.0;

pub const Painter = struct {
    indices: Buffer([2]u32),
    instances: Buffer(Matrix(4)),
    uniform: Buffer(Matrix(4)),
    programTexture: Program,
    programNoTexture: Program,

    matrices: [N]Matrix(4),
    changes: [N]bool,

    text: TextPainter,

    width: u32,
    height: u32,

    near: f32,
    far: f32,

    const N: u32 = 4;

    const Config = struct {
        width: u32,
        height: u32,
        size: u32,
        scale: f32,
        instanceMax: u32,
        near: f32,
        far: f32,
        glyphMax: u32,
        charKindMax: u32,
        allocator: Allocator,
    };

    pub fn new(config: Config) error{ Init, Compile, Read, NotFound, OutOfMemory }!Painter {
        var self: Painter = undefined;

        self.width = config.width;
        self.height = config.height;
        self.near = config.near;
        self.far = config.far;

        const vertexShader = try Shader.fromPath(.vertex, "assets/vertex.glsl", config.allocator);
        const fragmentShader = try Shader.fromPath(.fragment, "assets/fragment.glsl", config.allocator);

        self.programTexture = try Program.new(vertexShader, fragmentShader, config.allocator);

        fragmentShader.deinit();

        const rawFragmentShader = try Shader.fromPath(.fragment, "assets/rawFrag.glsl", config.allocator);

        self.programNoTexture = try Program.new(vertexShader, rawFragmentShader, config.allocator);

        vertexShader.deinit();
        rawFragmentShader.deinit();

        const textureLocation = try self.programTexture.uniformLocation("textureSampler1");

        self.instances = Buffer(Matrix(4)).new(.shader_storage_buffer, config.instanceMax, null);
        self.indices = Buffer([2]u32).new(.shader_storage_buffer, config.instanceMax, null);

        const fsize: f32 = @floatFromInt(config.size / 2);

        self.matrices = .{
            IDENTITY.scale(.{ fsize, fsize, 1, 1 }),
            IDENTITY.translate(.{ fsize, -fsize, -1 }),
            IDENTITY.scale(.{ config.scale, config.scale, 1, 1 }),
            IDENTITY.ortographic(0, @floatFromInt(config.width), 0, @floatFromInt(config.height), config.near, config.far),
        };

        self.uniform = Buffer(Matrix(4)).new(.uniform_buffer, N, &self.matrices);
        self.changes = .{false} ** N;

        self.uniform.bind(0);
        self.instances.bind(0);
        self.indices.bind(1);

        self.text = try TextPainter.new(
            config.size,
            config.width,
            config.height,
            config.scale,
            config.glyphMax,
            config.charKindMax,
            textureLocation,
            &self.instances,
            &self.indices,
            config.allocator,
        );

        return self;
    }

    pub fn keyListen(ptr: *anyopaque, keys: *const EnumSet(Key), controlActive: bool, altActive: bool) void {
        const self: *Painter = @ptrCast(@alignCast(ptr));

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

    pub fn resizeListen(ptr: *anyopaque, width: u32, height: u32) void {
        const self: *Painter = @ptrCast(@alignCast(ptr));

        if (width == self.width and height == self.height) return;
        self.width = width;
        self.height = height;

        self.matrices[3] = IDENTITY.ortographic(0, @floatFromInt(width), 0, @floatFromInt(height), self.near, self.far);
        self.changes[3] = true;

        self.text.resize(width, height);
    }

    pub fn hasChange(self: *Painter) bool {
        var flag = false;
        var start: u32 = 0;
        var count: u32 = 0;

        while (start + count < self.matrices.len) {
            if (!self.changes[start + count]) {
                if (count > 0) {
                    flag = true;
                    self.uniform.pushData(@intCast(start), self.matrices[start .. start + count]);
                }

                start += count + 1;
                count = 0;

                continue;
            }

            self.changes[start + count] = false;
            count += 1;
        }

        if (count > 0) {
            self.uniform.pushData(@intCast(start), self.matrices[start .. start + count]);
        }

        return self.text.hasChange() or flag or count > 0;
    }

    pub fn draw(self: *Painter) void {
        self.programTexture.start();
        self.text.drawChars();
        self.programTexture.end();

        self.programNoTexture.start();
        self.text.drawCursors();
        self.programNoTexture.end();
        
    }

    pub fn deinit(self: *const Painter) void {
        self.text.deinit();
        self.indices.deinit();
        self.instances.deinit();
        self.uniform.deinit();
        self.programTexture.deinit();
        self.programNoTexture.deinit();
    }
};

const TextPainter = struct {
    font: FreeType,
    chars: Map(u32, CharSet),
    rectangle: Mesh,

    charTransforms: Buffer(Matrix(4)),
    instances: Buffer(Matrix(4)).Slice,
    indices: Buffer([2]u32).Slice,

    indiceChanges: ArrayList(Change),
    indiceArray: [][2]u32,

    texture: Texture,
    textureCount: u16,
    textureMax: u32,
    textureLocation: u32,

    instanceCount: u32,
    instanceMax: u32,

    cursorTransform: Matrix(4),
    cursorX: u32,
    cursorY: u32,

    textureSize: u16,
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

    const Change = struct {
        offset: u32,
        count: u32,
    };

    fn new(
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
    ) error{ Init, Read, OutOfMemory }!TextPainter {
        var self: TextPainter = undefined;

        self.scale = scale;

        const overSize = size + 2;
        self.texture = Texture.new(overSize, overSize, textureMax, .r8, .red, .unsigned_byte, .@"2d_array", null);
        self.charTransforms = Buffer(Matrix(4)).new(.shader_storage_buffer, textureMax + 1, null);
        self.charTransforms.bind(2);

        self.resize(width, height);

        self.instances = try instances.getSlice(instanceMax);
        self.indices = try indices.getSlice(instanceMax);

        self.indiceChanges = try ArrayList(Change).initCapacity(allocator, 5);
        self.indiceArray = try allocator.alloc([2]u32, instanceMax);

        self.textureSize = @intCast(overSize);
        self.textureLocation = textureLocation;
        self.instanceMax = instanceMax;
        self.textureMax = textureMax;

        self.cursorX = 0;
        self.cursorY = 0;
        self.instanceCount = 0;
        self.textureCount = 0;

        self.rectangle = try Mesh.new("assets/plane.obj", allocator);
        self.font = try FreeType.new("assets/font.ttf", size);
        self.chars = Map(u32, CharSet).init(allocator);

        try self.chars.ensureTotalCapacity(textureMax * 2);

        try self.initCursor();

        return self;
    }

    fn listen(self: *TextPainter, keys: *const EnumSet(Key), controlActive: bool, altActive: bool) void {
        if (controlActive or altActive) self.processWithModifiers(keys, controlActive, altActive) else self.processKeys(keys);
    }

    fn processKeys(self: *TextPainter, keys: *const EnumSet(Key)) void {
        var iter = keys.iterator();

        while (iter.next()) |k| {
            const i: u32 = @intFromEnum(k);

            if (i > Key.NON_DISPLAYABLE) {
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

            self.insertChar(charSetEntry.value_ptr) catch |e| {
                std.log.err("Failed to add instance of: {}, to the screen, cause: {}", .{ k, e });
                break;
            };
        }
    }

    fn processCommand(self: *TextPainter, key: Key) void {
        switch (key) {
            .Enter => {
                self.cursorY += 1;
                self.cursorX = 0;
                self.updateCursor() catch return;
            },
            else => return,
        }
    }

    fn processWithModifiers(self: *TextPainter, keys: *const EnumSet(Key), controlActive: bool, altActive: bool) void {
        _ = self;
        _ = keys;
        _ = controlActive;
        _ = altActive;
    }

    fn newCharSet(self: *TextPainter, set: *CharSet, code: u32) error{ CharNotFound, Max }!void {
        set.textureId = null;

        if (self.textureCount >= self.textureMax) {
            std.log.err("Max number of chars", .{});

            return error.Max;
        }

        const char = try self.font.findChar(code);

        set.advance = @intCast(char.advance);
        set.bearing = char.bearing;

        if (char.buffer) |b| {
            defer self.textureCount += 1;

            set.textureId = self.textureCount;

            self.texture.pushData(char.width, char.height, self.textureCount, .red, .unsigned_byte, b);

            const deltaX: f32 = @floatFromInt(set.bearing[0]);
            const deltaY: f32 = @floatFromInt((self.textureSize - set.bearing[1]));

            self.charTransforms.pushData(self.textureCount, &.{IDENTITY.translate(.{ deltaX, -deltaY, 0 })});
        }
    }

    fn insertChar(self: *TextPainter, set: *CharSet) error{Max, OutOfMemory}!void {
        if (self.instanceCount >= self.instanceMax) {
            std.log.err("Maximun number of instances", .{});
            return error.Max;
        }

        if (set.textureId) |id| try self.appendChange(self.instanceCount, self.cursorX, self.cursorY, id);
        self.instanceCount += 1;
        self.cursorX += 1;
        try self.updateCursor();
    }

    fn appendChange(self: *TextPainter, indice: u32, x: u32, y: u32, textureId: u32) error{OutOfMemory}!void {
        const offset = self.offsetOf(x, y);

        self.indiceArray[indice] = .{ offset, textureId };

        if (self.indiceChanges.items.len > 0) {
            const change = &self.indiceChanges.items[self.indiceChanges.items.len - 1];

            if (change.offset + change.count == indice) {
                change.count += 1;

                return;
            }
        }

        try self.indiceChanges.append(.{
            .offset = indice,
            .count = 1,
        });
    }

    fn initCursor(self: *TextPainter) error{OutOfMemory}!void {
        defer self.instanceCount += 1;

        const heightScale = @as(f32, @floatFromInt(self.font.height)) / @as(f32, @floatFromInt(self.textureSize));
        const widthScale = @as(f32, @floatFromInt(self.font.width)) / @as(f32, @floatFromInt(self.textureSize));

        self.charTransforms.pushData(self.textureMax, &.{IDENTITY.scale(.{
            widthScale,
            heightScale,
            1,
            1,
        }).translate(.{
            -@as(f32, @floatFromInt(self.font.width)) / 2.0,
            0,
            0,
        })});

        try self.updateCursor();
    }

    fn updateCursor(self: *TextPainter) error{OutOfMemory}!void {
        const cursorExcededRight = self.cursorX > self.rowChars;
        const cursorExcededBottom = self.cursorY > self.rowChars;

        if (cursorExcededRight) {}

        if (cursorExcededBottom) {}

        try self.appendChange(0, self.cursorX, self.cursorY, self.textureMax);
    }

    fn offsetOf(self: *TextPainter, x: usize, y: usize) u32 {
        return @intCast((y * self.rowChars) + x);
    }

    pub fn drawChars(self: *TextPainter) void {
        if (self.instanceCount == 0) return;

        self.texture.bind(self.textureLocation, 0);
        self.rectangle.draw(1, self.instanceCount - 1);
    }

    pub fn drawCursors(self: *TextPainter) void {
        self.rectangle.draw(0, 1);
    }

    fn resize(self: *TextPainter, width: u32, height: u32) void {
        const rowChars: f32 = @floatFromInt(width / self.font.width);
        const colChars: f32 = @floatFromInt(height / self.font.height);

        self.rowChars = @intFromFloat(rowChars / self.scale);
        self.colChars = @intFromFloat(colChars / self.scale);

        if (self.rowChars * self.colChars > self.instanceMax) @panic("Increase the maximum number of instances");

        for (0..self.rowChars) |j| {
            for (0..self.colChars) |i| {
                const offset = self.offsetOf(j, i);

                const xPos: f32 = @floatFromInt(self.font.width * j);
                const yPos: f32 = @floatFromInt(self.font.height * i);

                self.instances.pushData(@intCast(offset), &.{IDENTITY.translate(.{ xPos, -yPos, 0 })});
            }
        }

        self.width = width;
        self.height = height;
    }

    fn hasChange(self: *TextPainter) bool {
        defer self.indiceChanges.clearRetainingCapacity();

        for (self.indiceChanges.items) |change| {
            self.indices.pushData(change.offset, self.indiceArray[change.offset..change.offset + change.count]);
        }

        return self.indiceChanges.items.len > 0;
    }

    fn deinit(self: *const TextPainter) void {
        self.texture.deinit();
        self.rectangle.deinit();
    }
};
