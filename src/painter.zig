const std = @import("std");

const Allocator = std.mem.Allocator;
const EnumSet = std.EnumSet;
const Map = std.AutoArrayHashMap;
const ArrayList = std.ArrayList;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const List = std.DoublyLinkedList;

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

const VELOCITY: f32 = 3.0;

pub const Painter = struct {
    font: FreeType,
    chars: Map(u32, CharSet),
    rectangle: Mesh,

    lines: Lines,

    instanceTransforms: Buffer([2]f32),
    instanceTransformIndices: Buffer(u32),
    instanceTransformIndicesArray: []u32,

    charTransforms: Buffer([2]f32),
    charTransformIndices: Buffer(u32),
    charTransformIndicesArray: []u32,
    // charIndiceChanges: ArrayList(Change),

    solidTransforms: Buffer(Matrix(4)),
    solidTransformIndices: Buffer(u32),
    solidTransformIndicesArray: []u32,
    // solidIndiceChanges: ArrayList(Change),

    programTexture: Program,
    programNoTexture: Program,

    matrixUniforms: Buffer(Matrix(4)),
    matrixUniformArray: [2]Matrix(4),

    scaleUniforms: Buffer(f32),
    scaleUniformArray: [3]f32,

    changes: [2]bool,

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

    scale: f32,
    rowChars: u32,
    colChars: u32,
    charMax: u32,
    totalChars: u32,

    width: u32,
    height: u32,

    near: f32,
    far: f32,

    allocator: FixedBufferAllocator,

    const Config = struct {
        width: u32,
        height: u32,
        size: u32,
        scale: f32,
        instanceMax: u32,
        near: f32,
        far: f32,
        charKindMax: u32,
        allocator: Allocator,
    };

    pub fn init(self: *Painter, config: Config) error{ Init, Compile, Read, NotFound, OutOfMemory }!void {
        self.allocator = FixedBufferAllocator.init(try config.allocator.alloc(u8, std.mem.page_size * 20));

        self.width = config.width;
        self.height = config.height;
        self.near = config.near;
        self.far = config.far;
        self.scale = config.scale;
        const allocator = self.allocator.allocator();

        const vertexShader = try Shader.fromPath(.vertex, "assets/vertex.glsl", allocator);
        const fragmentShader = try Shader.fromPath(.fragment, "assets/fragment.glsl", allocator);

        self.programTexture = try Program.new(vertexShader, fragmentShader, allocator);
        const textureLocation = try self.programTexture.uniformLocation("textureSampler1");

        vertexShader.deinit();
        fragmentShader.deinit();

        const rawVertexShader = try Shader.fromPath(.vertex, "assets/rawVertex.glsl", allocator);
        const rawFragmentShader = try Shader.fromPath(.fragment, "assets/rawFrag.glsl", allocator);

        self.programNoTexture = try Program.new(rawVertexShader, rawFragmentShader, allocator);

        rawVertexShader.deinit();
        rawFragmentShader.deinit();

        self.rectangle = try Mesh.new("assets/plane.obj", allocator);
        self.font = try FreeType.new("assets/font.ttf", config.size);
        self.chars = Map(u32, CharSet).init(allocator);
        try self.chars.ensureTotalCapacity(config.charKindMax * 2);

        self.instanceTransforms = Buffer([2]f32).new(.shader_storage_buffer, config.instanceMax, null);
        self.instanceTransformIndices = Buffer(u32).new(.shader_storage_buffer, config.instanceMax / 2, null);
        self.instanceTransformIndicesArray = try allocator.alloc(u32, config.instanceMax / 2);
        @memset(self.instanceTransformIndicesArray, 0);

        self.charTransforms = Buffer([2]f32).new(.shader_storage_buffer, config.instanceMax, null);
        self.charTransformIndices = Buffer(u32).new(.shader_storage_buffer, config.instanceMax / 4, null);
        self.charTransformIndicesArray = try allocator.alloc(u32, config.instanceMax / 4);
        @memset(self.charTransformIndicesArray, 0);

        self.solidTransforms = Buffer(Matrix(4)).new(.shader_storage_buffer, 1, null);
        self.solidTransformIndices = Buffer(u32).new(.shader_storage_buffer, 1, null);
        self.solidTransformIndicesArray = try allocator.alloc(u32, 1);
        @memset(self.solidTransformIndicesArray, 0);

        self.scaleUniformArray[0] = @floatFromInt(config.size / 2);
        self.scaleUniformArray[1] = config.scale;
        self.scaleUniforms = Buffer(f32).new(.uniform_buffer, 2, &self.scaleUniformArray);

        self.matrixUniformArray = .{ IDENTITY.translate(.{self.scaleUniformArray[0], -self.scaleUniformArray[0], -1}), IDENTITY.ortographic(0, @floatFromInt(config.width), 0, @floatFromInt(config.height), config.near, config.far) };
        self.matrixUniforms = Buffer(Matrix(4)).new(.uniform_buffer, 2, &self.matrixUniformArray);
        self.changes = .{false} ** 2;

        const overSize = config.size + 2;
        self.texture = Texture.new(overSize, overSize, config.charKindMax, .r8, .red, .unsigned_byte, .@"2d_array", null);

        // self.charIndiceChanges = try ArrayList(Change).initCapacity(allocator, 5);
        // self.solidIndiceChanges = try ArrayList(Change).initCapacity(allocator, 2);

        self.textureSize = @intCast(overSize);
        self.textureLocation = textureLocation;
        self.instanceMax = config.instanceMax;
        self.textureMax = config.charKindMax;

        resize(self, config.width, config.height);

        self.instanceCount = 0;
        self.textureCount = 0;
        self.cursorX = 0;
        self.cursorY = 0;
        self.totalChars = 0;

        self.lines = try Lines.new(self.rowChars, self.colChars, self.allocator.allocator());
        try self.initCursor();

        self.instanceTransforms.bind(0);
        self.instanceTransformIndices.bind(1);

        self.matrixUniforms.bind(0);
        self.scaleUniforms.bind(2);
    }

    pub fn processCommand(self: *Painter, key: Key) void {
        switch (key) {
            .ArrowLeft => {
                self.matrixUniformArray[0] = self.matrixUniformArray[0].translate(.{ -VELOCITY, 0, 0 });
                self.changes[0] = true;
            },
            .ArrowRight => {
                self.matrixUniformArray[0] = self.matrixUniformArray[0].translate(.{ VELOCITY, 0, 0 });
                self.changes[0] = true;
            },
            .ArrowUp => {
                self.matrixUniformArray[0] = self.matrixUniformArray[0].translate(.{ 0, VELOCITY, 0 });
                self.changes[0] = true;
            },
            .ArrowDown => {
                self.matrixUniformArray[0] = self.matrixUniformArray[0].translate(.{ 0, -VELOCITY, 0 });
                self.changes[0] = true;
            },
            .Enter => {
                self.lines.newLine() catch return;
            },
            else => {},
        }
    }

    pub fn keyListen(ptr: *anyopaque, keys: *const EnumSet(Key), controlActive: bool, altActive: bool) void {
        const self: *Painter = @ptrCast(@alignCast(ptr));

        if (controlActive or altActive) self.processWithModifiers(keys, controlActive, altActive) else self.processKeys(keys);
    }

    fn processKeys(self: *Painter, keys: *const EnumSet(Key)) void {
        var iter = keys.iterator();

        while (iter.next()) |k| {
            const i: u32 = @intFromEnum(k);

            if (i > Key.NON_DISPLAYABLE) {
                self.processCommand(k);
                continue;
            }

            self.lines.insertChar(@intCast(i)) catch |e| {
                std.log.err("Failed to insert {} into the buffer: {}", .{k, e});
                continue;
            };

            // const charSetEntry = self.chars.getOrPut(i) catch |e| {
            //     std.log.err("Failed to register char of key: {}, code: {}, err: {}", .{ k, i, e });
            //     continue;
            // };

            // if (!charSetEntry.found_existing) self.newCharSet(charSetEntry.value_ptr, i) catch |e| {
            //     std.log.err("Failed to construct char bitmap for: {}, code: {}, {}", .{ k, i, e });
            //     continue;
            // };

            // self.insertChar(charSetEntry.value_ptr) catch |e| {
            //     std.log.err("Failed to add instance of: {}, to the screen, cause: {}", .{ k, e });
            //     break;
            // };
        }
    }

    fn resize(self: *Painter, width: u32, height: u32) void {
        if (width == self.width and height == self.height) return;

        self.width = width;
        self.height = height;

        self.matrixUniformArray[1] = IDENTITY.ortographic(0, @floatFromInt(width), 0, @floatFromInt(height), self.near, self.far);
        self.changes[1] = true;

        const rowChars: f32 = @floatFromInt(width / self.font.width);
        const colChars: f32 = @floatFromInt(height / self.font.height);

        self.rowChars = @intFromFloat(rowChars / self.scale);
        self.colChars = @intFromFloat(colChars / self.scale);
        self.charMax = self.rowChars * self.colChars;

        self.lines.maxCols = self.rowChars;
        self.lines.maxRows = self.colChars;

        const allocator = self.allocator.allocator();
        const transforms = allocator.alloc([2]f32, self.charMax) catch {
            std.log.err("Failed to resize text window, out of memory, size: {}", .{self.charMax});
            return;
        };
        defer allocator.free(transforms);

        if (self.charMax > self.instanceMax) {
            std.log.err("Failed to resize text window, required glyph slot count: {}, given: {}", .{self.charMax, self.instanceMax});
            return;
        }

        for (0..self.rowChars) |j| {
            for (0..self.colChars) |i| {
                const offset = self.offsetOf(j, i);

                const xPos: f32 = @floatFromInt(self.font.width * j);
                const yPos: f32 = @floatFromInt(self.font.height * i);

                transforms[offset] = .{ xPos, -yPos };
            }
        }

        self.instanceTransforms.pushData(0, transforms);
    }

    pub fn resizeListen(ptr: *anyopaque, width: u32, height: u32) void {
        const self: *Painter = @ptrCast(@alignCast(ptr));
        self.resize(width, height);
    }

    fn insertChangeForTexture(self: *Painter, indice: u32, textureId: u32, x: u32, y: u32) error{OutOfMemory}!void {
        const instanceValue = @as(u32, 0xFFFF) << @as(u5, @intCast(16 * (indice % 2)));
        self.instanceTransformIndicesArray[indice / 2] &= ~instanceValue;

        const charValue = @as(u32, 0xFF) << @as(u5, @intCast(8 * (indice % 4)));
        self.charTransformIndicesArray[indice / 4] &= ~charValue;

        const offset = self.offsetOf(x, y);

        self.instanceTransformIndicesArray[indice / 2] |= offset << @as(u5, @intCast(16 * (indice % 2)));
        self.charTransformIndicesArray[indice / 4] |= textureId << @as(u5, @intCast(8 * (indice % 4)));

        // if (self.charIndiceChanges.items.len > 0) {
        //     const change = &self.charIndiceChanges.items[self.charIndiceChanges.items.len - 1];

        //     if (change.offset + change.count == indice) {
        //         change.count += 1;

        //         return;
        //     }
        // }

        // try self.charIndiceChanges.append(.{
        //     .offset = indice,
        //     .count = 1,
        // });
    }

    fn insertChangeForSolid(self: *Painter, indice: u32, scaleId: u32, x: u32, y: u32) error{OutOfMemory}!void {
        const instanceValue = @as(u32, 0xFFFF) >> @as(u5, @intCast(16 * (indice % 2)));
        self.instanceTransformIndicesArray[indice / 2] &= ~instanceValue;

        const solidValue = @as(u32, 0xFF) >> @as(u5, @intCast(8 * (indice % 4)));
        self.solidTransformIndicesArray[indice / 4] &= ~solidValue;

        const offset = self.offsetOf(x, y);

        self.instanceTransformIndicesArray[indice / 2] |= offset << @as(u5, @intCast(16 * (indice % 2)));
        self.solidTransformIndicesArray[indice / 4] |= scaleId << @as(u5, @intCast(8 * (indice % 4)));

        // if (self.solidIndiceChanges.items.len > 0) {
        //     const change = &self.solidIndiceChanges.items[self.solidIndiceChanges.items.len - 1];

        //     if (change.offset + change.count == indice) {
        //         change.count += 1;

        //         return;
        //     }
        // }

        // try self.solidIndiceChanges.append(.{
        //     .offset = indice,
        //     .count = 1,
        // });
    }

    fn initCursor(self: *Painter) error{OutOfMemory}!void {
        defer self.instanceCount += 1;

        const heightScale = @as(f32, @floatFromInt(@as(i32, @intCast(self.font.height)) - @divFloor(self.font.descender, 2))) / @as(f32, @floatFromInt(self.textureSize));
        const widthScale = @as(f32, @floatFromInt(self.font.width)) / @as(f32, @floatFromInt(self.textureSize));

        self.solidTransforms.pushData(0, &.{IDENTITY.scale(.{widthScale, heightScale, 1, 1}).translate(.{-@as(f32, @floatFromInt(self.font.width)) / 2.0, @floatFromInt(@divFloor(self.font.descender, 2)), 0})});//IDENTITY.scale(.{
    }

    pub fn hasChange(self: *Painter) bool {

        // defer self.charIndiceChanges.clearRetainingCapacity();
        // defer self.solidIndiceChanges.clearRetainingCapacity();

        // for (self.charIndiceChanges.items) |change| {
        //     const instanceTransformOffset = change.offset / 2;
        //     const instanceTransformCount = change.count / 2;

        //     const charTransformOffset = change.offset / 4;
        //     const charTransformCount = change.count / 4;

        //     self.instanceTransformIndices.pushData(instanceTransformOffset, self.instanceTransformIndicesArray[instanceTransformOffset..instanceTransformOffset + instanceTransformCount + 1]);
        //     self.charTransformIndices.pushData(charTransformOffset, self.charTransformIndicesArray[charTransformOffset..charTransformOffset + charTransformCount + 1]);
        // }

        // for (self.solidIndiceChanges.items) |change| {
        //     const instanceTransformOffset = change.offset / 2;
        //     const instanceTransformCount = change.count / 2;

        //     const solidTransformOffset = change.offset / 4;
        //     const solidTransformCount = change.count / 4;

        //     self.instanceTransformIndices.pushData(instanceTransformOffset, self.instanceTransformIndicesArray[instanceTransformOffset..instanceTransformOffset + instanceTransformCount + 1]);
        //     self.solidTransformIndices.pushData(solidTransformOffset, self.solidTransformIndicesArray[solidTransformOffset..solidTransformOffset + solidTransformCount + 1]);
        // }

        const matrixChange = self.checkMatrixChange();
        const contentChange = self.checkContentChange();

        return matrixChange or contentChange;
    }

    fn checkMatrixChange(self: *Painter) bool {
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

        return flag or count > 0;
    }

    fn checkContentChange(self: *Painter) bool {
        if (!self.lines.change) return false;
        self.lines.change = false;

        var iter = self.lines.iter();

        self.resetChars();

        var lineCount: u32 = 0;
        while (iter.hasNextLine()) {
            var charCount: u32 = 0;

            while (iter.nextChars()) |chars| {
                for (chars) |c| {
                    self.insertChar(c, charCount, lineCount) catch @panic("failed");
                    charCount += 1;
                }
            }

            lineCount += 1;
        }

        self.insertChangeForSolid(0, 0, self.lines.cursor.x - self.lines.xOffset, self.lines.cursor.y - self.lines.yOffset) catch @panic("cursor failed");

        self.solidTransformIndices.pushData(0, self.solidTransformIndicesArray[0..1]);
        self.instanceTransformIndices.pushData(0, self.instanceTransformIndicesArray[0..self.totalChars / 2 + 1]);
        self.charTransformIndices.pushData(0, self.charTransformIndicesArray[0..self.totalChars / 4 + 1]);

        return true;
    }

    fn processWithModifiers(self: *Painter, keys: *const EnumSet(Key), controlActive: bool, altActive: bool) void {
        if (controlActive) {
            if (keys.contains(.LowerB)) {
                self.lines.moveBack(1);
            }

            if (keys.contains(.LowerF)) {
                self.lines.moveFoward(1);
            }

            if (keys.contains(.LowerN)) {
                self.lines.moveLineDown(1);
            }

            if (keys.contains(.LowerP)) {
                self.lines.moveLineUp(1);
            }
        }
        // _ = self;
        // _ = keys;
        // _ = controlActive;
        _ = altActive;
    }

    fn newCharSet(self: *Painter, set: *CharSet, code: u32) error{ CharNotFound, Max }!void {
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

    fn insertChar(self: *Painter, char: u32, x: u32, y: u32) error{Max, CharNotFound, OutOfMemory}!void {
        if (self.instanceCount >= self.charMax) {
            std.log.err("Maximun number of instances", .{});
            return error.Max;
        }

        const charSetEntry = try self.chars.getOrPut(char);
        if (!charSetEntry.found_existing) try self.newCharSet(charSetEntry.value_ptr, char);

        const set = charSetEntry.value_ptr;

        if (set.textureId) |id| {
            self.totalChars += 1;
            try self.insertChangeForTexture(self.totalChars, id, x, y);
        }
    }

    fn offsetOf(self: *Painter, x: usize, y: usize) u32 {
        return @intCast((y * self.rowChars) + x);

    }

    fn resetChars(self: *Painter) void {
        self.totalChars = 0;
    }

    fn drawChars(self: *Painter) void {
        self.charTransforms.bind(2);
        self.charTransformIndices.bind(3);

        self.texture.bind(self.textureLocation, 0);

        self.rectangle.draw(1, self.totalChars);

        self.texture.unbind(0);
    }

    fn drawCursors(self: *Painter) void {
        self.solidTransforms.bind(2);
        self.solidTransformIndices.bind(3);

        self.rectangle.draw(0, 1);
    }

    pub fn draw(self: *Painter) void {
        self.programTexture.start();
        self.drawChars();
        self.programTexture.end();

        self.programNoTexture.start();
        self.drawCursors();
        self.programNoTexture.end();
    }

    pub fn deinit(self: *const Painter) void {
        self.texture.deinit();
        self.rectangle.deinit();
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

const LineIter = struct {
    buffer: ?*Lines.BufferNode,
    line: ?*Lines.LineNode,
    cursor: Cursor,

    minX: u32,
    minY: u32,
    maxX: u32,
    maxY: u32,

    const zero: [2]u8 = .{0, 0};

    fn hasNextLine(self: *LineIter) bool {
        const line = self.line orelse return false;
        self.cursor.x = 0;
        defer self.line = line.next;

        self.buffer = line.data.findBufferOffset(&self.cursor, self.minX);

        return true;
    }

    fn nextChars(self: *LineIter) ?[]u8 {
        defer self.cursor.offset = 0;

        if (self.cursor.x >= self.maxX) return null;

        const buffer = self.buffer orelse {
            self.cursor.y += 1;

            return null;
        };

        defer self.cursor.x += buffer.data.len;
        defer self.buffer = buffer.next;

        return buffer.data.handle[self.cursor.offset..min(self.maxX - self.cursor.x, buffer.data.len)];
    }
};

const LinesChange = struct {
    x: u32,
    y: u32,
    buffer: []u8,
};

const CharInfo = struct {
    x: u32,
    y: u32,
    char: u32,
};

const Lines = struct {
    cursor: Cursor,

    yOffset: u32,
    xOffset: u32,
    maxCols: u32,
    maxRows: u32,

    lines: List(Line),

    // newChars: [20]CharInfo,
    // newCharsLen: u32,

    change: bool,

    currentLine: *LineNode,
    currentBuffer: *BufferNode,

    freePool: FreePool,

    const LineNode = List(Line).Node;
    const BufferNode = List(LineBuffer).Node;
    const MIN_BUFFER_SIZE: u32 = 30;

    const FreePool = struct {
        buffers: List(LineBuffer),
        lines: List(Line),

        allocator: FixedBufferAllocator,

        fn new(allocator: FixedBufferAllocator) FreePool {
            return .{
                .buffers = .{},
                .lines = .{},
                .allocator = allocator,
            };
        }

        fn newLine(self: *FreePool) error{OutOfMemory}!*LineNode {
            if (self.lines.pop()) |line| {
                line.data.buffer.append(try self.newBuffer());

                return line;
            }

            const line = try self.allocator.allocator().create(LineNode);

            line.data.buffer = .{};
            line.data.buffer.append(try self.newBuffer());

            return line;
        }

        fn newBuffer(self: *FreePool) error{OutOfMemory}!*BufferNode {
            if (self.buffers.pop()) |buffer| {
                return buffer;
            }

            const allocator = self.allocator.allocator();
            const buffer = try allocator.create(BufferNode);

            try buffer.data.init(allocator, MIN_BUFFER_SIZE);

            return buffer;
        }

        fn freeLine(self: *FreePool, line: *LineNode) void {
            while (line.data.buffer.pop()) |buffer| {
                self.buffers.append(buffer);
            }

            self.lines.append(line);
        }

        fn freeBuffer(self: *FreePool, buffer: *BufferNode) void {
            buffer.data.len = 0;
            self.buffers.append(buffer);
        }
    };

    const BufferNodeWithOffset = struct {
        offset: u32,
        buffer: *BufferNode,
    };

    const LineBuffer = struct {
        handle: [*]u8,
        len: u32,
        capacity: u32,

        fn init(self: *LineBuffer, allocator: Allocator, size: u32) error{OutOfMemory}!void {
            const handle = try allocator.alloc(u8, size);

            self.handle = handle.ptr;
            self.capacity = @intCast(handle.len);
            self.len = 0;
        }

    };

    const Line = struct {
        buffer: List(LineBuffer),

        fn print(self: *Line) void {
            var buffer = self.buffer.first;

            var count: u32 = 0;
            while (buffer) |b| {
                std.debug.print("{d:0>3} -> [{s}]\n", .{count, b.data.handle[0..b.data.len]});
                buffer = b.next;
                count += 1;
            }
        }

        fn findBufferOffset(self: *Line, cursor: *Cursor, offset: u32) ?*BufferNode {
            var firstBuffer = self.buffer.first;

            while (firstBuffer) |buffer| {
                if (buffer.data.len + cursor.x >= offset) break;

                cursor.x += @intCast(buffer.data.len);

                firstBuffer = buffer.next;
            }

            cursor.offset = offset - cursor.x;

            return firstBuffer;
        }
    };

    fn new(maxCols: u32, maxRows: u32, allocator: Allocator) error{OutOfMemory}!Lines {
        var self: Lines = undefined;

        self.cursor.x = 0;
        self.cursor.y = 0;
        self.cursor.offset = 0;
        self.xOffset = 0;
        self.yOffset = 0;
        self.maxCols = maxCols;
        self.maxRows = maxRows;
        self.change = true;

        self.freePool = FreePool.new(FixedBufferAllocator.init(try allocator.alloc(u8, std.mem.page_size)));

        self.currentLine = try self.freePool.newLine();
        self.currentBuffer = self.currentLine.data.buffer.first orelse unreachable;

        self.lines = .{};
        self.lines.append(self.currentLine);

        return self;
    }

    fn moveLineDown(self: *Lines, count: u32) void {
        defer self.change = true;
        var c = count;

        while (self.currentLine.next) |l| {
            if (c == 0) break;

            self.currentLine = l;

            self.cursor.y += 1;
            c -= 1;
        }

        self.checkScreenWithCursor();
    }

    fn moveLineUp(self: *Lines, count: u32) void {
        defer self.change = true;

        var c = count;

        while (self.currentLine.prev) |l| {
            if (c == 0) break;

            self.currentLine = l;

            self.cursor.y -= 1;
            c -= 1;
        }

        self.checkScreenWithCursor();
    }

    fn checkScreenWithCursor(self: *Lines) void {
        const x = self.cursor.x;
        self.cursor.x = 0;

        if (self.currentLine.data.findBufferOffset(&self.cursor, x)) |buffer| {
            self.currentBuffer = buffer;
            self.cursor.x = x;
        } else {
            self.currentBuffer = self.currentLine.data.buffer.last orelse unreachable;
            self.cursor.offset = self.currentBuffer.data.len;
        }
    }

    fn moveFoward(self: *Lines, count: u32) void {
        defer self.change = true;

        const bufferWithOffset = self.moveFowardBufferNode(self.currentLine, self.currentBuffer, self.cursor.offset, count);

        self.currentBuffer = bufferWithOffset.buffer;
        self.cursor.offset = bufferWithOffset.offset;
    }

    fn moveFowardBufferNode(self: *Lines, line: *LineNode, buffer: *BufferNode, offset: u32, count: u32) BufferNodeWithOffset {
        if (count + offset > buffer.data.len) {
            self.cursor.x += @intCast(buffer.data.len - offset);

            if (buffer.next) |next| {
                std.debug.assert(buffer.data.len == buffer.data.capacity);
                return self.moveFowardBufferNode(line, next, 0, count - (buffer.data.len - offset));
            }

            return .{
                .offset = @intCast(buffer.data.len),
                .buffer = buffer,
            };
        }

        self.cursor.x += count;

        return .{
            .offset = offset + count,
            .buffer = buffer,
        };
    }

    fn moveBack(self: *Lines, count: u32) void {
        defer self.change = true;

        const bufferWithOffset = self.moveBackBufferNode(self.currentLine, self.currentBuffer, self.cursor.offset, count);

        self.currentBuffer = bufferWithOffset.buffer;
        self.cursor.offset = bufferWithOffset.offset;
    }

    fn moveBackBufferNode(self: *Lines, line: *LineNode, buffer: *BufferNode, offset: u32, count: u32) BufferNodeWithOffset {
        if (count > offset) {
            self.cursor.x -= offset;

            if (buffer.prev) |prev| {
                std.debug.assert(prev.data.len == prev.data.capacity);

                return self.moveBackBufferNode(line, prev, prev.data.len, count - offset);
            }

            return .{
                .offset = 0,
                .buffer = buffer,
            };
        }

        self.cursor.x -= count;

        return .{
            .offset = offset - count,
            .buffer = buffer,
        };
    }

    fn insertChar(self: *Lines, char: u8) error{OutOfMemory}!void {
        try self.insertString(&.{char});
    }

    fn insertString(self: *Lines, chars: []const u8) error{OutOfMemory}!void {
        defer self.change = true;

        const bufferWithOffset = try self.insertBufferNodeChars(self.currentLine, self.currentBuffer, self.cursor.offset, chars);

        self.cursor.offset = bufferWithOffset.offset;
        self.currentBuffer = bufferWithOffset.buffer;
        self.cursor.x += @intCast(chars.len);
    }

    fn deleteForward(self: *Lines, count: u32) void {
        defer self.change = true;

        self.deleteBufferNodeCount(self.currentLine, self.currentBuffer, self.cursor.offset, count);
    }

    fn deleteBufferNodeCount(self: *Lines, line: *LineNode, buffer: *BufferNode, offset: u32, count: u32) void {
        if (count == 0) return;

        if (count >= buffer.data.len - offset) {
            var next = buffer.next;
            var c = count - (buffer.data.len - offset);

            while (next) |n| {
                if (n.data.len > c) break;
                c -= @intCast(n.data.len);
                next = n.next;
                self.removeBufferNode(line, n);
            }

            if (next) |n| {
                const nextCount = min(buffer.data.len - offset, n.data.len - c);
                defer buffer.data.len = @intCast(offset + nextCount);
                std.mem.copyForwards(u8, buffer.data.handle[offset..offset + nextCount], n.data.handle[c..c + nextCount]);

                self.deleteBufferNodeCount(line, n, 0, @intCast(c + nextCount));
            } else {
                buffer.data.len = offset;
            }
        } else {
            std.mem.copyForwards(u8, buffer.data.handle[offset..buffer.data.len - count], buffer.data.handle[offset + count..buffer.data.len]);

            if (buffer.data.len == buffer.data.capacity) {
                self.deleteBufferNodeCount(line, buffer, buffer.data.len - count, count);
            } else {
                buffer.data.len -= count;
            }
        }
    }

    fn insertBufferNodeChars(self: *Lines, line: *LineNode, buffer: *BufferNode, offset: u32, chars: []const u8) error{OutOfMemory}!BufferNodeWithOffset {
        if (offset > buffer.data.len) return error.OutOfMemory;
        if (chars.len == 0) return .{
            .buffer = buffer,
            .offset = 0,
        };

        if (chars.len + offset > buffer.data.capacity) {
            defer buffer.data.len = buffer.data.capacity;

            try self.checkBufferNodeNext(line, buffer);
            _ = try self.insertBufferNodeChars(line, buffer.next.?, 0, buffer.data.handle[offset..buffer.data.len]);

            std.mem.copyForwards(u8, buffer.data.handle[offset..buffer.data.capacity], chars[0..buffer.data.capacity - offset]);
            return try self.insertBufferNodeChars(line, buffer.next.?, 0, chars[buffer.data.capacity - offset..]);
        } else if (chars.len + buffer.data.len > buffer.data.capacity) {
            defer buffer.data.len = buffer.data.capacity;

            try self.checkBufferNodeNext(line, buffer);

            _ = try self.insertBufferNodeChars(line, buffer.next.?, 0, buffer.data.handle[buffer.data.capacity - chars.len..buffer.data.len]);

            std.mem.copyBackwards(u8, buffer.data.handle[offset + chars.len..buffer.data.capacity], buffer.data.handle[offset..buffer.data.capacity - chars.len]);
        } else {
            defer buffer.data.len += @intCast(chars.len);

            std.mem.copyBackwards(u8, buffer.data.handle[offset + chars.len..chars.len + buffer.data.len], buffer.data.handle[offset..buffer.data.len]);
        }

        std.mem.copyForwards(u8, buffer.data.handle[offset..offset + chars.len], chars);

        return .{
            .buffer = buffer,
            .offset = @intCast(offset + chars.len),
        };
    }

    fn removeBufferNode(self: *Lines, line: *LineNode, buffer: *BufferNode) void {
        line.data.buffer.remove(buffer);
        self.freePool.freeBuffer(buffer);
    }

    fn checkBufferNodeNext(self: *Lines, line: *LineNode, buffer: *BufferNode) error{OutOfMemory}!void {
        if (buffer.next) |_| {} else {
            const newBuffer = try self.freePool.newBuffer();
            line.data.buffer.insertAfter(buffer, newBuffer);
        }
    }

    fn newLine(self: *Lines) error{OutOfMemory}!void {
        defer self.change = true;

        // const next = self.currentBuffer.next;
        // self.currentBuffer.next = null;
        // self.currentLine.data.buffer.remove(self.currentBuffer);
        const line = try self.freePool.newLine();

        self.lines.insertAfter(self.currentLine, line);
        self.currentLine = line;
        self.currentBuffer = line.data.buffer.first orelse unreachable;


        // const copyContent = self.currentBuffer.data.handle[self.cursor.offset..self.currentBuffer.data.len];
        // self.currentBuffer.data.len = self.cursor.offset;
        // self.currentBuffer = line.data.buffer.first orelse unreachable;
        // self.currentBuffer.data.len = @intCast(copyContent.len);

        // std.mem.copyForwards(u8, self.currentBuffer.data.handle[0..copyContent.len], copyContent);

        self.xOffset = 0;
        self.cursor.offset = 0;
        self.cursor.x = 0;
        self.cursor.y += 1;
    }

    fn checkCursor(self: *Lines) void {
        if (self.cursor.x >= self.maxCols + self.xOffset) {
            self.xOffset = self.cursor.x - self.maxCols + 1;
        } else if (self.cursor.x < self.xOffset) {
            self.xOffset = self.cursor.x;
        }

        if (self.cursor.y >= self.maxRows + self.yOffset) {
            self.yOffset = self.cursor.x - self.maxRows + 1;
        } else if (self.cursor.y < self.yOffset) {
            self.yOffset = self.cursor.y;
        }
    }

    fn removeLine(self: *Lines) void {
        const currentLine: ?*LineNode = null;

        if (self.currentLine.next) |line| {
            currentLine = line;
        } else if (self.currentLine.prev) |line| {
            self.cursor.y -= 1;
            currentLine = line;
        }

        self.lines.remove(self.currentLine);
        self.freePool.freeLine(self.currentLine);

        self.currentLine = currentLine orelse self.freePool.newLine();
        self.currentBuffer = self.currentLine.data.buffer.first;

        self.xOffset = 0;
        self.cursor.offset = 0;
        self.cursor.x = 0;
    }

    fn iter(self: *Lines) LineIter {
        self.checkCursor();

        var currentLine = self.currentLine;
        var currentY = self.cursor.y;

        while (currentY > self.yOffset) : (currentY -= 1) {
            currentLine = currentLine.prev orelse unreachable;
        }

        // std.log.info("geting iter with max x: {}", .{self.maxCols});

        return LineIter {
            .line = currentLine,
            .buffer = currentLine.data.buffer.first,
            .minX = self.xOffset,
            .minY = self.yOffset,
            .maxX = self.xOffset + self.maxCols,
            .maxY = self.yOffset + self.maxRows,
            .cursor = .{
                .y = self.yOffset,
                .x = 0,
                .offset = 0,
            },
        };
    }

    fn print(self: *Lines) void {
        var line = self.lines.first;

        while (line) |l| {
            l.data.print();
            std.debug.print("\n", .{});

            line = l.next;
        }
    }
};

const Change = struct {
    offset: u32,
    count: u32,
};

const CharSet = struct {
    textureId: ?u16,
    advance: u16,
    bearing: [2]i32,
};

const Cursor = struct {
    x: u32,
    y: u32,
    offset: u32,
};

fn min(first: usize, second: usize) usize {
    return if (first < second) first else second;
}

fn max(first: usize, second: usize) usize {
    return if (first > second) first else second;
}

// test "testing" {
//     var lines = try Lines.new(30, 20, std.testing.allocator);
//     defer std.testing.allocator.free(lines.allocator.buffer);

//     try lines.insertString("987654321");
//     try lines.insertString("987654321");
//     try lines.insertString("987654321");
//     try lines.insertString("987654321");
//     try lines.insertString("987654321");
//     try lines.insertString("987654321");
//     try lines.insertString("987654321");
//     try lines.insertString("987654321");
//     try lines.insertString("987654321");
//     try lines.insertString("987654321");
//     try lines.insertString("987654321");
//     try lines.insertString("987654321");
//     try lines.insertString("987654321");
//     try lines.insertString("987654321");
//     try lines.insertString("987654321");
//     try lines.insertString("987654321");

//     const line = 1;
//     const offset = 1;
//     lines.moveBack(line * 10 + offset + 1);

//     lines.deleteForward(1);
//     lines.print();
//     try lines.insertString("He");

//     // lines.moveBack(70);

//     lines.deleteForward(3);
//     lines.moveBack(line * 10 + offset + 1);
//     lines.deleteForward(4);

//     try lines.insertString("This is the new thing");

//     lines.print();
// }
test "tseting ass well" {
    var lines = try Lines.new(30, 20, std.testing.allocator);
    defer std.testing.allocator.free(lines.freePool.allocator.buffer);

    try lines.insertString("0123456789012345678901234567890");
    try lines.newLine();
    try lines.insertString("four ");
    try lines.insertString("five ");
    try lines.insertString("fix ");

    var iter = lines.iter();

    while (iter.hasNextLine()) {
        while (iter.nextChars()) |chars| {
            std.debug.print("chars: {s}\n", .{chars});
        }

        std.debug.print("next line\n", .{});
    }
}
