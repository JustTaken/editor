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

    freePool: FreePool,

    lines: [2]Lines,
    focusedIndex: u32,

    instanceTransforms: Buffer([2]f32).Indexer,
    charTransforms: Buffer([2]f32).Indexer,
    solidTransforms: Buffer(Matrix(4)).Indexer,
    depthTransforms: Buffer(f32).Indexer,

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

    instanceMax: u32,
    totalInstances: u32,

    cursorTransform: Matrix(4),
    cursorX: u32,
    cursorY: u32,

    textureSize: u16,

    scale: f32,
    rowChars: u32,
    colChars: u32,

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
        self.allocator = FixedBufferAllocator.init(try config.allocator.alloc(u8, 16 * std.mem.page_size));

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
        try self.chars.ensureTotalCapacity((config.charKindMax * 4) / 5);

        self.instanceTransforms = try Buffer([2]f32).new(.shader_storage_buffer, config.instanceMax, null).indexer(config.instanceMax, u16, allocator);
        self.charTransforms = try Buffer([2]f32).new(.shader_storage_buffer, config.charKindMax, null).indexer(config.instanceMax, u8, allocator);
        self.solidTransforms = try Buffer(Matrix(4)).new(.shader_storage_buffer, 1, null).indexer(1, u8, allocator);
        self.depthTransforms = try Buffer(f32).new(.shader_storage_buffer, 2, &.{0, -0.5}).indexer(config.instanceMax, u8, allocator);
        self.depthTransforms.pushIndex(0, 1);
        _ = self.depthTransforms.syncIndex();

        self.scaleUniformArray[0] = @floatFromInt(config.size / 2);
        self.scaleUniformArray[1] = config.scale;
        self.scaleUniforms = Buffer(f32).new(.uniform_buffer, 2, &self.scaleUniformArray);

        self.matrixUniformArray = .{ IDENTITY.translate(.{self.scaleUniformArray[0], -self.scaleUniformArray[0], -1}), IDENTITY.ortographic(0, @floatFromInt(config.width), 0, @floatFromInt(config.height), config.near, config.far) };
        self.matrixUniforms = Buffer(Matrix(4)).new(.uniform_buffer, 2, &self.matrixUniformArray);
        self.changes = .{false} ** 2;

        const overSize = config.size + 2;
        self.texture = Texture.new(overSize, overSize, config.charKindMax, .r8, .red, .unsigned_byte, .@"2d_array", null);

        self.textureSize = @intCast(overSize);
        self.textureLocation = textureLocation;
        self.instanceMax = config.instanceMax;
        self.textureMax = config.charKindMax;

        resize(self, config.width, config.height);

        self.textureCount = 0;
        self.totalInstances = 0;

        self.freePool = FreePool.new(FixedBufferAllocator.init(try self.allocator.allocator().alloc(u8, std.mem.page_size)));

        self.lines[0] = try Lines.new(&self.freePool);
        self.lines[1] = try Lines.new(&self.freePool);
        self.focusedIndex = 0;
        self.initCursor();

        self.instanceTransforms.bind(0, 1);
        self.depthTransforms.bind(2, 3);

        self.matrixUniforms.bind(0);
        self.scaleUniforms.bind(2);
    }

    pub fn processCommand(self: *Painter, key: Key) void {
        switch (key) {
            .Enter => {
                switch (self.focusedIndex) {
                    0 => self.lines[0].newLine() catch return,
                    1 => {
                        self.lines[1].clear();
                        self.focusedIndex = 0;
                    },
                    else => unreachable,
                }
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

            self.lines[self.focusedIndex].insertChar(@intCast(i)) catch |e| {
                std.log.err("Failed to insert {} into the buffer: {}", .{k, e});
                continue;
            };
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
        const charMax = self.rowChars * self.colChars;

        const allocator = self.allocator.allocator();
        const transforms = allocator.alloc([2]f32, charMax) catch {
            std.log.err("Failed to resize text window, out of memory, size: {}", .{charMax});
            return;
        };
        defer allocator.free(transforms);

        if (charMax > self.instanceMax) {
            std.log.err("Failed to resize text window, required glyph slot count: {}, given: {}", .{charMax, self.instanceMax});
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

    fn insertChangeForTexture(self: *Painter, indice: u32, textureId: u32, x: u32, y: u32) void {
        const offset = self.offsetOf(x, y);

        self.instanceTransforms.pushIndex(indice, offset);
        self.charTransforms.pushIndex(indice, textureId);

        // const instanceValue = @as(u32, 0xFFFF) << @as(u5, @intCast(16 * (indice % 2)));
        // self.instanceTransformIndicesArray[indice / 2] &= ~instanceValue;

        // const charValue = @as(u32, 0xFF) << @as(u5, @intCast(8 * (indice % 4)));
        // self.charTransformIndicesArray[indice / 4] &= ~charValue;


        // self.instanceTransformIndicesArray[indice / 2] |= offset << @as(u5, @intCast(16 * (indice % 2)));
        // self.charTransformIndicesArray[indice / 4] |= textureId << @as(u5, @intCast(8 * (indice % 4)));
    }

    fn insertChangeForSolid(self: *Painter, indice: u32, scaleId: u32, x: u32, y: u32) void {
        const offset = self.offsetOf(x, y);

        self.instanceTransforms.pushIndex(indice, offset);
        self.solidTransforms.pushIndex(indice, scaleId);

        // const instanceValue = @as(u32, 0xFFFF) >> @as(u5, @intCast(16 * (indice % 2)));
        // self.instanceTransformIndicesArray[indice / 2] &= ~instanceValue;

        // const solidValue = @as(u32, 0xFF) >> @as(u5, @intCast(8 * (indice % 4)));
        // self.solidTransformIndicesArray[indice / 4] &= ~solidValue;


        // self.instanceTransformIndicesArray[indice / 2] |= offset << @as(u5, @intCast(16 * (indice % 2)));
        // self.solidTransformIndicesArray[indice / 4] |= scaleId << @as(u5, @intCast(8 * (indice % 4)));
    }

    fn initCursor(self: *Painter) void {
        const heightScale = @as(f32, @floatFromInt(@as(i32, @intCast(self.font.height)) - @divFloor(self.font.descender, 2))) / @as(f32, @floatFromInt(self.textureSize));
        const widthScale = @as(f32, @floatFromInt(self.font.width)) / @as(f32, @floatFromInt(self.textureSize));

        self.solidTransforms.pushData(0, &.{IDENTITY.scale(.{widthScale, heightScale, 1, 1}).translate(.{-@as(f32, @floatFromInt(self.font.width)) / 2.0, @floatFromInt(@divFloor(self.font.descender, 2)), 0})});//IDENTITY.scale(.{
    }

    pub fn hasChange(self: *Painter) bool {
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
        if (!self.lines[0].change and !self.lines[1].change) return false;

        self.lines[0].change = false;
        self.lines[1].change = false;

        var iter = self.lines[0].rangeIter(self.rowChars, self.colChars - 1);

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

        iter = self.lines[1].rangeIter(self.rowChars, 1);

        while (iter.hasNextLine()) {
            var charCount: u32 = 0;

            while (iter.nextChars()) |chars| {
                for (chars) |c| {
                    self.insertChar(c, charCount, self.colChars - 1) catch @panic("failed");
                    charCount += 1;
                }
            }

            lineCount += 1;
        }

        const xPos = if (self.focusedIndex == 0) self.lines[0].cursor.x - self.lines[0].xOffset else self.lines[1].cursor.x - self.lines[1].xOffset;
        const yPos = if (self.focusedIndex == 0) self.lines[0].cursor.y - self.lines[0].yOffset else self.colChars - 1;

        self.insertChangeForSolid(0, 0, xPos, yPos);

        _ = self.instanceTransforms.syncIndex();
        _ = self.solidTransforms.syncIndex();
        _ = self.charTransforms.syncIndex();
        // self.instanceTransformIndices.pushData(self.instanceTransformIndicesArray[0..self.totalInstances / 2 + 1]);
        // .pushData(self.solidTransformIndicesArray[0..1]);
        // .pushData(self.charTransformIndicesArray[0..self.totalInstances / 4 + 1]);

        return true;
    }

    fn processWithModifiers(self: *Painter, keys: *const EnumSet(Key), controlActive: bool, altActive: bool) void {
        _ = altActive;

        switch (self.focusedIndex) {
            0 => {
                if (controlActive) {
                    if (keys.contains(.LowerB)) {
                        self.lines[0].moveBack(1);
                    }

                    if (keys.contains(.LowerF)) {
                        self.lines[0].moveFoward(1);
                    }

                    if (keys.contains(.LowerN)) {
                        self.lines[0].moveLineDown(1);
                    }

                    if (keys.contains(.LowerP)) {
                        self.lines[0].moveLineUp(1);
                    }

                    if (keys.contains(.LowerD)) {
                        self.lines[0].deleteForward(1);
                    }

                    if (keys.contains(.LowerA)) {
                        self.lines[0].lineStart();
                    }

                    if (keys.contains(.LowerE)) {
                        self.lines[0].lineEnd();
                    }

                    if (keys.contains(.Enter)) {
                        self.focusedIndex = 1;
                        self.lines[0].change = true;
                    }
                }
            },
            1 => { },
            else => unreachable,
        }
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
        const charSetEntry = try self.chars.getOrPut(char);
        if (!charSetEntry.found_existing) try self.newCharSet(charSetEntry.value_ptr, char);

        const set = charSetEntry.value_ptr;

        if (set.textureId) |id| {
            self.totalInstances += 1;
            self.insertChangeForTexture(self.totalInstances, id, x, y);
        }
    }

    fn offsetOf(self: *Painter, x: usize, y: usize) u32 {
        return @intCast((y * self.rowChars) + x);
    }

    fn resetChars(self: *Painter) void {
        self.totalInstances = 0;
    }

    fn drawChars(self: *Painter) void {
        self.charTransforms.bind(4, 5);

        self.texture.bind(self.textureLocation, 0);

        self.rectangle.draw(1, self.totalInstances);

        self.texture.unbind(0);
    }

    fn drawCursors(self: *Painter) void {
        self.solidTransforms.bind(4, 5);

        self.rectangle.draw(0, 1);
    }

    pub fn draw(self: *Painter) void {
        self.programNoTexture.start();
        self.drawCursors();
        self.programNoTexture.end();

        self.programTexture.start();
        self.drawChars();
        self.programTexture.end();
    }

    pub fn deinit(self: *const Painter) void {
        self.texture.deinit();
        self.rectangle.deinit();
        self.instanceTransforms.deinit();
        self.matrixUniforms.deinit();
        self.scaleUniforms.deinit();
        self.charTransforms.deinit();
        self.solidTransforms.deinit();
        self.programTexture.deinit();
        self.programNoTexture.deinit();
    }
};

const RangeIter = struct {
    buffer: ?*BufferNode,
    line: ?*LineNode,
    cursor: Cursor,

    minX: u32,
    minY: u32,
    maxX: u32,
    maxY: u32,

    const zero: [2]u8 = .{0, 0};

    fn hasNextLine(self: *RangeIter) bool {
        if (self.cursor.y >= self.maxY) return false;
        const line = self.line orelse return false;
        self.cursor.x = 0;
        defer self.line = line.next;

        self.buffer = line.data.findBufferOffset(&self.cursor, self.minX);

        return true;
    }

    fn nextChars(self: *RangeIter) ?[]u8 {
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

const CharInfo = struct {
    x: u32,
    y: u32,
    char: u32,
};

const LineBuffer = struct {
    handle: [*]u8,
    len: u16,
    capacity: u16,
    start: u16,

    fn init(self: *LineBuffer, allocator: Allocator, size: u32) error{OutOfMemory}!void {
        const handle = try allocator.alloc(u8, size);

        self.handle = handle.ptr;
        self.capacity = @intCast(handle.len);
        self.len = 0;
        self.start = 0;
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

    fn newLine(self: *FreePool, first: ?*BufferNode, last: ?*BufferNode) error{OutOfMemory}!*LineNode {
        if (self.lines.pop()) |line| {
            if (first) |b| {
                b.prev = null;
                line.data.buffer.first = b;
                line.data.buffer.last = last.?;
            } else {
                line.data.buffer.append(try self.newBuffer());
            }

            return line;
        }

        const line = try self.allocator.allocator().create(LineNode);

        line.data.buffer = .{};

        if (first) |b| {
            b.prev = null;
            line.data.buffer.first = b;
            line.data.buffer.last = last.?;
        } else {
            line.data.buffer.append(try self.newBuffer());
        }

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
            self.freeBuffer(buffer);
        }

        self.lines.append(line);
    }

    fn freeBuffer(self: *FreePool, buffer: *BufferNode) void {
        buffer.data.len = 0;
        self.buffers.append(buffer);
    }
};

const Lines = struct {
    cursor: Cursor,

    yOffset: u32,
    xOffset: u32,

    lines: List(Line),

    change: bool,

    currentLine: *LineNode,
    currentBuffer: *BufferNode,

    freePool: *FreePool,

    const BufferNodeWithOffset = struct {
        offset: u32,
        buffer: *BufferNode,
    };

    fn new(freePool: *FreePool) error{OutOfMemory}!Lines {
        var self: Lines = undefined;

        self.cursor.x = 0;
        self.cursor.y = 0;
        self.cursor.offset = 0;
        self.xOffset = 0;
        self.yOffset = 0;
        self.change = true;

        self.freePool = freePool;

        self.currentLine = try self.freePool.newLine(null, null);
        self.currentBuffer = self.currentLine.data.buffer.first.?;

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
            self.currentBuffer = self.currentLine.data.buffer.last.?;
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
                buffer.data.len = @intCast(offset);
            }
        } else {
            std.mem.copyForwards(u8, buffer.data.handle[offset..buffer.data.len - count], buffer.data.handle[offset + count..buffer.data.len]);

            if (buffer.data.len == buffer.data.capacity) {
                self.deleteBufferNodeCount(line, buffer, buffer.data.len - count, count);
            } else {
                buffer.data.len -= @intCast(count);
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

    fn lineEnd(self: *Lines) void {
        defer self.change = true;

        var buffer: ?*BufferNode = self.currentBuffer;

        while (buffer) |b| {
            self.cursor.x += @intCast(b.data.len - self.cursor.offset);
            self.cursor.offset = 0;

            buffer = b.next;
        }

        self.currentBuffer = self.currentLine.data.buffer.last.?;
        self.cursor.offset = self.currentBuffer.data.len;
    }

    fn lineStart(self: *Lines) void {
        defer self.change = true;

        self.currentBuffer = self.currentLine.data.buffer.first.?;
        self.cursor.offset = 0;
        self.cursor.x = 0;
    }

    fn newLine(self: *Lines) error{OutOfMemory}!void {
        defer self.change = true;

        try self.checkBufferNodeNext(self.currentLine, self.currentBuffer);

        const next = self.currentBuffer.next.?;
        const line = try self.freePool.newLine(next, self.currentLine.data.buffer.last);
        self.lines.insertAfter(self.currentLine, line);

        self.currentBuffer.next = null;
        self.currentLine.data.buffer.last = self.currentBuffer;

        _ = try self.insertBufferNodeChars(line, next, 0, self.currentBuffer.data.handle[self.cursor.offset..self.currentBuffer.data.len]);
        self.currentBuffer.data.len = @intCast(self.cursor.offset);

        self.currentLine = line;
        self.currentBuffer = next;

        self.cursor.offset = 0;
        self.cursor.x = 0;
        self.cursor.y += 1;
    }

    fn checkCursor(self: *Lines, maxCols: u32, maxRows: u32) void {
        if (self.cursor.x >= maxCols + self.xOffset) {
            self.xOffset = self.cursor.x - maxCols + 1;
        } else if (self.cursor.x < self.xOffset) {
            self.xOffset = self.cursor.x;
        }

        if (self.cursor.y >= maxRows + self.yOffset) {
            self.yOffset = self.cursor.y - maxRows + 1;
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

    fn clear(self: *Lines) void {
        defer self.change = true;
        self.cursor.x = 0;
        self.cursor.offset = 0;

        var line = self.lines.last;

        while (line) |l| {
            self.lines.remove(l);
            self.freePool.freeLine(l);

            line = l.prev;
        }

        self.lines.append(self.freePool.newLine(null, null) catch unreachable);
        self.currentLine = self.lines.first.?;
        self.currentBuffer = self.lines.first.?.data.buffer.first.?;
    }

    fn rangeIter(self: *Lines, maxCols: u32, maxRows: u32) RangeIter {
        self.checkCursor(maxCols, maxRows);

        var currentLine = self.currentLine;
        var currentY = self.cursor.y;

        while (currentY > self.yOffset) : (currentY -= 1) {
            currentLine = currentLine.prev.?;
        }

        return RangeIter {
            .line = currentLine,
            .buffer = currentLine.data.buffer.first,
            .minX = self.xOffset,
            .minY = self.yOffset,
            .maxX = self.xOffset + maxCols,
            .maxY = self.yOffset + maxRows,
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
