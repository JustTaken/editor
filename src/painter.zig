const std = @import("std");

const Allocator = std.mem.Allocator;
const EnumSet = std.EnumSet;
const Map = std.AutoArrayHashMap;
const ArrayList = std.ArrayList;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const Program = @import("opengl/shader.zig").Program;
const Shader = @import("opengl/shader.zig").Shader;
const Texture = @import("opengl/texture.zig").Texture;
const Buffer = @import("opengl/buffer.zig").Buffer;
const Mesh = @import("opengl/mesh.zig").Mesh;
const State = @import("opengl/mesh.zig").State;

const Matrix = @import("math.zig").Matrix;

const Key = @import("input.zig").Key;

const FreeType = @import("font.zig").FreeType;
const Char = @import("font.zig").Char;

const IDENTITY = Matrix(4).identity();

const VELOCITY: f32 = 3.0;

pub const Painter = struct {
    instanceTransforms: Buffer([2]f32),
    instanceTransformIndices: Buffer(u32),

    charTransforms: Buffer([2]f32),
    charTransformIndices: Buffer(u32),

    solidTransforms: Buffer(Matrix(4)),
    solidTransformIndices: Buffer(u32),

    programTexture: Program,
    programNoTexture: Program,

    matrixUniforms: Buffer(Matrix(4)),
    matrixUniformArray: [2]Matrix(4),

    scaleUniforms: Buffer(f32),
    scaleUniformArray: [3]f32,

    changes: [2]bool,

    text: TextPainter,

    width: u32,
    height: u32,

    near: f32,
    far: f32,

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
        const textureLocation = try self.programTexture.uniformLocation("textureSampler1");

        vertexShader.deinit();
        fragmentShader.deinit();

        const rawVertexShader = try Shader.fromPath(.vertex, "assets/rawVertex.glsl", config.allocator);
        const rawFragmentShader = try Shader.fromPath(.fragment, "assets/rawFrag.glsl", config.allocator);

        self.programNoTexture = try Program.new(rawVertexShader, rawFragmentShader, config.allocator);

        rawVertexShader.deinit();
        rawFragmentShader.deinit();

        self.instanceTransforms = Buffer([2]f32).new(.shader_storage_buffer, config.instanceMax, null);
        self.instanceTransformIndices = Buffer(u32).new(.shader_storage_buffer, config.instanceMax, null);

        self.charTransforms = Buffer([2]f32).new(.shader_storage_buffer, config.instanceMax, null);
        self.charTransformIndices = Buffer(u32).new(.shader_storage_buffer, config.instanceMax, null);

        self.solidTransforms = Buffer(Matrix(4)).new(.shader_storage_buffer, 1, null);
        self.solidTransformIndices = Buffer(u32).new(.shader_storage_buffer, 1, null);

        self.scaleUniformArray[0] = @floatFromInt(config.size / 2);
        self.scaleUniformArray[1] = config.scale;
        self.scaleUniforms = Buffer(f32).new(.uniform_buffer, 2, &self.scaleUniformArray);

        self.matrixUniformArray = .{ IDENTITY.translate(.{self.scaleUniformArray[0], -self.scaleUniformArray[0], -1}), IDENTITY.ortographic(0, @floatFromInt(config.width), 0, @floatFromInt(config.height), config.near, config.far) };
        self.matrixUniforms = Buffer(Matrix(4)).new(.uniform_buffer, 2, &self.matrixUniformArray);
        self.changes = .{false} ** 2;

        self.matrixUniforms.bind(0);
        self.scaleUniforms.bind(2);

        self.text = try TextPainter.new(
            config.size,
            config.width,
            config.height,
            config.scale,
            config.glyphMax,
            config.charKindMax,
            textureLocation,
            &self.instanceTransforms,
            &self.instanceTransformIndices,
            &self.charTransforms,
            &self.charTransformIndices,
            &self.solidTransforms,
            &self.solidTransformIndices,
            config.allocator,
        );

        return self;
    }

    pub fn keyListen(ptr: *anyopaque, keys: *const EnumSet(Key), controlActive: bool, altActive: bool) void {
        const self: *Painter = @ptrCast(@alignCast(ptr));

        if (keys.contains(.ArrowLeft)) {
            self.matrixUniformArray[0] = self.matrixUniformArray[0].translate(.{ -VELOCITY, 0, 0 });
            self.changes[0] = true;
        }

        if (keys.contains(.ArrowRight)) {
            self.matrixUniformArray[0] = self.matrixUniformArray[0].translate(.{ VELOCITY, 0, 0 });
            self.changes[0] = true;
        }

        if (keys.contains(.ArrowUp)) {
            self.matrixUniformArray[0] = self.matrixUniformArray[0].translate(.{ 0, VELOCITY, 0 });
            self.changes[0] = true;
        }

        if (keys.contains(.ArrowDown)) {
            self.matrixUniformArray[0] = self.matrixUniformArray[0].translate(.{ 0, -VELOCITY, 0 });
            self.changes[0] = true;
        }

        self.text.listen(keys, controlActive, altActive);
    }

    pub fn resizeListen(ptr: *anyopaque, width: u32, height: u32) void {
        const self: *Painter = @ptrCast(@alignCast(ptr));

        if (width == self.width and height == self.height) return;
        self.width = width;
        self.height = height;

        self.matrixUniformArray[1] = IDENTITY.ortographic(0, @floatFromInt(width), 0, @floatFromInt(height), self.near, self.far);
        self.changes[1] = true;

        self.text.resize(width, height) catch @panic("Failed to resize");
    }

    pub fn hasChange(self: *Painter) bool {
        var flag = false;
        var start: u32 = 0;
        var count: u32 = 0;

        while (start + count < self.matrixUniformArray.len) {
            if (!self.changes[start + count]) {
                if (count > 0) {
                    flag = true;
                    self.matrixUniforms.pushData(@intCast(start), self.matrixUniformArray[start .. start + count]);
                }

                start += count + 1;
                count = 0;

                continue;
            }

            self.changes[start + count] = false;
            count += 1;
        }

        if (count > 0) {
            self.matrixUniforms.pushData(@intCast(start), self.matrixUniformArray[start .. start + count]);
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
        self.instanceTransformIndices.deinit();
        self.instanceTransforms.deinit();
        self.matrixUniforms.deinit();
        self.scaleUniforms.deinit();
        self.charTransforms.deinit();
        self.charTransformIndices.deinit();
        self.solidTransforms.deinit();
        self.solidTransformIndices.deinit();
        self.programTexture.deinit();
        self.programNoTexture.deinit();
    }
};

const Lines = struct {
    cursorX: u32,
    cursorY: u32,
    cursorOffset: u32,

    buffer: ArrayList(u8),
    // buffer: []u8,
    // newChars: []u8,

    // additions: []Add,
    // removes: []Remove,
    // rows: ArrayList(Row),

    // allocator: FixedBufferAllocator,

    // const Add = struct {
    //     lineOffset: u16,
    //     charOffset: u16,
    //     len: u16,
    // };

    // const Remove = struct {
    //     lineOffset: u16,
    //     len: u16,
    // };

    // const Row = struct {
    //     offset: u16,
    //     additionPos: u16,
    //     additionLen: u16,
    //     removePos: u16,
    //     removeLen: u16,

        // fn new(allocator: Allocator) error{OutOfMemory}!Row {
        //     return .{
        //         .offset = @intCast(offset),
        //         .additionPos = 0,
        //         .additionLen = 0,
        //         .removePos = 0,
        //         .removeLen = 0,
        //     };
        // }
    // };

    fn new(allocator: Allocator) error{OutOfMemory}!Lines {
        var self: Lines = undefined;

        self.cursorX = 0;
        self.cursorY = 0;
        self.cursorOffset = 0;

        self.buffer = try ArrayList(u8).initCapacity(allocator, 100);

        return self;

    }

    fn insertChar(self: *Lines, char: u8) error{OutOfMemory}!void {
        if (self.cursorY > self.rows.items.len) return error.OutOfMemory;
        if (self.cursorX >= 50) return error.OutOfMemory;
        if (self.cursorY == self.rows.items.len) try self.rows.append(self.allocator.alloc(u8, 50));

        self.rows.items[self.cursorOffset] = char;
    }
};

const TextPainter = struct {
    font: FreeType,
    chars: Map(u32, CharSet),
    rectangle: Mesh,

    instanceTransforms: Buffer([2]f32).Slice,
    instanceTransformIndices: Buffer(u32).Slice,
    instanceTransformIndicesArray: []u32,

    charTransforms: Buffer([2]f32).Slice,
    charTransformIndices: Buffer(u32).Slice,
    charTransformIndicesArray: []u32,

    solidTransforms: Buffer(Matrix(4)).Slice,
    solidTransformIndices: Buffer(u32).Slice,
    solidTransformIndicesArray: []u32,

    textureIndiceChanges: ArrayList(Change),
    solidIndiceChanges: ArrayList(Change),

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
        instanceTransforms: *Buffer([2]f32),
        instanceTransformIndices: *Buffer(u32),
        charTransforms: *Buffer([2]f32),
        charTransformIndices: *Buffer(u32),
        solidTransforms: *Buffer(Matrix(4)),
        solidTransformIndices: *Buffer(u32),
        allocator: Allocator,
    ) error{ Init, Read, OutOfMemory }!TextPainter {
        var self: TextPainter = undefined;

        self.scale = scale;

        const overSize = size + 2;

        self.instanceTransforms = try instanceTransforms.getSlice(instanceMax);
        self.instanceTransformIndices = try instanceTransformIndices.getSlice(instanceMax);
        self.instanceTransformIndicesArray = try allocator.alloc(u32, instanceMax);
        @memset(self.instanceTransformIndicesArray, 0);

        self.charTransforms = try charTransforms.getSlice(textureMax + 1);
        self.charTransformIndices = try charTransformIndices.getSlice(instanceMax);
        self.charTransformIndicesArray = try allocator.alloc(u32, instanceMax);
        @memset(self.charTransformIndicesArray, 0);

        self.solidTransforms = try solidTransforms.getSlice(1);
        self.solidTransformIndices = try solidTransformIndices.getSlice(1);
        self.solidTransformIndicesArray = try allocator.alloc(u32, 1);
        @memset(self.solidTransformIndicesArray, 0);

        self.texture = Texture.new(overSize, overSize, textureMax, .r8, .red, .unsigned_byte, .@"2d_array", null);

        self.textureIndiceChanges = try ArrayList(Change).initCapacity(allocator, 5);
        self.solidIndiceChanges = try ArrayList(Change).initCapacity(allocator, 2);

        self.textureSize = @intCast(overSize);
        self.textureLocation = textureLocation;
        self.instanceMax = instanceMax;
        self.textureMax = textureMax;

        try self.resize(width, height);

        self.cursorX = 0;
        self.cursorY = 0;
        self.instanceCount = 0;
        self.textureCount = 0;

        self.font = try FreeType.new("assets/font.ttf", size);
        self.chars = Map(u32, CharSet).init(allocator);

        try self.chars.ensureTotalCapacity(textureMax * 2);

        try self.initCursor();

        self.rectangle = try Mesh.new("assets/plane.obj", allocator);

        self.instanceTransforms.bind(0);
        self.instanceTransformIndices.bind(1);

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

            self.charTransforms.pushData(self.textureCount, &.{.{ deltaX, -deltaY }});
        }
    }

    fn insertChar(self: *TextPainter, set: *CharSet) error{Max, OutOfMemory}!void {
        if (self.instanceCount >= self.instanceMax) {
            std.log.err("Maximun number of instances", .{});
            return error.Max;
        }

        if (set.textureId) |id| try self.insertChangeForTexture(self.instanceCount, id, self.cursorX, self.cursorY);

        self.instanceCount += 1;
        self.cursorX += 1;

        try self.updateCursor();
    }

    fn insertChangeForTexture(self: *TextPainter, indice: u32, textureId: u32, x: u32, y: u32) error{OutOfMemory}!void {
        const instanceValue = @as(u32, 0xFFFF) >> @as(u5, @intCast(16 * (indice % 2)));
        self.instanceTransformIndicesArray[indice / 2] &= ~instanceValue;

        const charValue = @as(u32, 0xFF) >> @as(u5, @intCast(8 * (indice % 4)));
        self.charTransformIndicesArray[indice / 4] &= ~charValue;

        const offset = self.offsetOf(x, y);

        self.instanceTransformIndicesArray[indice / 2] |= offset << @as(u5, @intCast(16 * (indice % 2)));
        self.charTransformIndicesArray[indice / 4] |= textureId << @as(u5, @intCast(8 * (indice % 4)));

        if (self.textureIndiceChanges.items.len > 0) {
            const change = &self.textureIndiceChanges.items[self.textureIndiceChanges.items.len - 1];

            if (change.offset + change.count == indice) {
                change.count += 1;

                return;
            }
        }

        try self.textureIndiceChanges.append(.{
            .offset = indice,
            .count = 1,
        });
    }

    fn insertChangeForSolid(self: *TextPainter, indice: u32, scaleId: u32, x: u32, y: u32) error{OutOfMemory}!void {
        const instanceValue = @as(u32, 0xFFFF) >> @as(u5, @intCast(16 * (indice % 2)));
        self.instanceTransformIndicesArray[indice / 2] &= ~instanceValue;

        const solidValue = @as(u32, 0xFF) >> @as(u5, @intCast(8 * (indice % 4)));
        self.solidTransformIndicesArray[indice / 4] &= ~solidValue;

        const offset = self.offsetOf(x, y);

        self.instanceTransformIndicesArray[indice / 2] |= offset << @as(u5, @intCast(16 * (indice % 2)));
        self.solidTransformIndicesArray[indice / 4] |= scaleId << @as(u5, @intCast(8 * (indice % 4)));

        if (self.solidIndiceChanges.items.len > 0) {
            const change = &self.solidIndiceChanges.items[self.solidIndiceChanges.items.len - 1];

            if (change.offset + change.count == indice) {
                change.count += 1;

                return;
            }
        }

        try self.solidIndiceChanges.append(.{
            .offset = indice,
            .count = 1,
        });
    }

    fn initCursor(self: *TextPainter) error{OutOfMemory}!void {
        defer self.instanceCount += 1;

        const heightScale = @as(f32, @floatFromInt(self.font.height)) / @as(f32, @floatFromInt(self.textureSize));
        const widthScale = @as(f32, @floatFromInt(self.font.width)) / @as(f32, @floatFromInt(self.textureSize));

        self.solidTransforms.pushData(0, &.{IDENTITY.scale(.{widthScale, heightScale, 1, 1}).translate(.{-@as(f32, @floatFromInt(self.font.width)) / 2.0, 0, 0})});//IDENTITY.scale(.{

        try self.updateCursor();
    }

    fn updateCursor(self: *TextPainter) error{OutOfMemory}!void {
        const cursorExcededRight = self.cursorX > self.rowChars;
        const cursorExcededBottom = self.cursorY > self.rowChars;

        if (cursorExcededRight) {}
        if (cursorExcededBottom) {}

        try self.insertChangeForSolid(0, 0, self.cursorX, self.cursorY);
    }

    fn offsetOf(self: *TextPainter, x: usize, y: usize) u32 {
        return @intCast((y * self.rowChars) + x);
    }

    pub fn drawChars(self: *TextPainter) void {
        if (self.instanceCount == 0) return;

        self.charTransforms.bind(2);
        self.charTransformIndices.bind(3);

        self.texture.bind(self.textureLocation, 0);

        self.rectangle.draw(1, self.instanceCount - 1);

        self.texture.unbind(0);
    }

    pub fn drawCursors(self: *TextPainter) void {
        self.solidTransforms.bind(2);
        self.solidTransformIndices.bind(3);

        self.rectangle.draw(0, 1);
    }

    fn resize(self: *TextPainter, width: u32, height: u32) error{OutOfMemory}!void {
        const rowChars: f32 = @floatFromInt(width / self.font.width);
        const colChars: f32 = @floatFromInt(height / self.font.height);

        self.rowChars = @intFromFloat(rowChars / self.scale);
        self.colChars = @intFromFloat(colChars / self.scale);

        if (self.rowChars * self.colChars > self.instanceMax) {
            std.log.err("Failed to resize text window, required glyph slot count: {}, given: {}", .{self.rowChars * self.colChars, self.instanceMax});

            return error.OutOfMemory;
        }

        for (0..self.rowChars) |j| {
            for (0..self.colChars) |i| {
                const offset = self.offsetOf(j, i);

                const xPos: f32 = @floatFromInt(self.font.width * j);
                const yPos: f32 = @floatFromInt(self.font.height * i);

                self.instanceTransforms.pushData(@intCast(offset), &.{.{ xPos, -yPos }});
            }
        }

        self.width = width;
        self.height = height;
    }

    fn hasChange(self: *TextPainter) bool {
        defer self.textureIndiceChanges.clearRetainingCapacity();
        defer self.solidIndiceChanges.clearRetainingCapacity();

        for (self.textureIndiceChanges.items) |change| {
            const instanceTransformOffset = change.offset / 2;
            const instanceTransformCount = change.count / 2;

            const charTransformOffset = change.offset / 4;
            const charTransformCount = change.count / 4;

            self.instanceTransformIndices.pushData(instanceTransformOffset, self.instanceTransformIndicesArray[instanceTransformOffset..instanceTransformOffset + instanceTransformCount + 1]);
            self.charTransformIndices.pushData(charTransformOffset, self.charTransformIndicesArray[charTransformOffset..charTransformOffset + charTransformCount + 1]);
        }

        for (self.solidIndiceChanges.items) |change| {
            const instanceTransformOffset = change.offset / 2;
            const instanceTransformCount = change.count / 2;

            const solidTransformOffset = change.offset / 4;
            const solidTransformCount = change.count / 4;

            self.instanceTransformIndices.pushData(instanceTransformOffset, self.instanceTransformIndicesArray[instanceTransformOffset..instanceTransformOffset + instanceTransformCount + 1]);
            self.solidTransformIndices.pushData(solidTransformOffset, self.solidTransformIndicesArray[solidTransformOffset..solidTransformOffset + solidTransformCount + 1]);
        }

        return self.textureIndiceChanges.items.len > 0 or self.solidIndiceChanges.items.len > 0;
    }

    fn deinit(self: *const TextPainter) void {
        self.texture.deinit();
        self.rectangle.deinit();
    }
};
