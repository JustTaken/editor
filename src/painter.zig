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
    charIndiceChanges: ArrayList(Change),

    solidTransforms: Buffer(Matrix(4)),
    solidTransformIndices: Buffer(u32),
    solidTransformIndicesArray: []u32,
    solidIndiceChanges: ArrayList(Change),

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

        self.charIndiceChanges = try ArrayList(Change).initCapacity(allocator, 5);
        self.solidIndiceChanges = try ArrayList(Change).initCapacity(allocator, 2);

        self.textureSize = @intCast(overSize);
        self.textureLocation = textureLocation;
        self.instanceMax = config.instanceMax;
        self.textureMax = config.charKindMax;

        resize(self, config.width, config.height);

        self.instanceCount = 0;
        self.textureCount = 0;
        self.cursorX = 0;
        self.cursorY = 0;

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
        const instanceValue = @as(u32, 0xFFFF) >> @as(u5, @intCast(16 * (indice % 2)));
        self.instanceTransformIndicesArray[indice / 2] &= ~instanceValue;

        const charValue = @as(u32, 0xFF) >> @as(u5, @intCast(8 * (indice % 4)));
        self.charTransformIndicesArray[indice / 4] &= ~charValue;

        const offset = self.offsetOf(x, y);

        self.instanceTransformIndicesArray[indice / 2] |= offset << @as(u5, @intCast(16 * (indice % 2)));
        self.charTransformIndicesArray[indice / 4] |= textureId << @as(u5, @intCast(8 * (indice % 4)));

        if (self.charIndiceChanges.items.len > 0) {
            const change = &self.charIndiceChanges.items[self.charIndiceChanges.items.len - 1];

            if (change.offset + change.count == indice) {
                change.count += 1;

                return;
            }
        }

        try self.charIndiceChanges.append(.{
            .offset = indice,
            .count = 1,
        });
    }

    fn insertChangeForSolid(self: *Painter, indice: u32, scaleId: u32, x: u32, y: u32) error{OutOfMemory}!void {
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

    fn initCursor(self: *Painter) error{OutOfMemory}!void {
        defer self.instanceCount += 1;

        const heightScale = @as(f32, @floatFromInt(@as(i32, @intCast(self.font.height)) - @divFloor(self.font.descender, 2))) / @as(f32, @floatFromInt(self.textureSize));
        const widthScale = @as(f32, @floatFromInt(self.font.width)) / @as(f32, @floatFromInt(self.textureSize));

        self.solidTransforms.pushData(0, &.{IDENTITY.scale(.{widthScale, heightScale, 1, 1}).translate(.{-@as(f32, @floatFromInt(self.font.width)) / 2.0, @floatFromInt(@divFloor(self.font.descender, 2)), 0})});//IDENTITY.scale(.{

        try self.updateCursor(self.cursorX, self.cursorY);
    }

    fn updateCursor(self: *Painter, x: u32, y: u32) error{OutOfMemory}!void {
        // const cursorExcededRight = self.cursorX > self.rowChars;
        // const cursorExcededBottom = self.cursorY > self.rowChars;

        // if (cursorExcededRight) {}
        // if (cursorExcededBottom) {}

        try self.insertChangeForSolid(0, 0, x, y);
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

        defer self.charIndiceChanges.clearRetainingCapacity();
        defer self.solidIndiceChanges.clearRetainingCapacity();

        for (self.charIndiceChanges.items) |change| {
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

        return self.charIndiceChanges.items.len > 0 or self.solidIndiceChanges.items.len > 0 or flag or count > 0;
    }

    fn processWithModifiers(self: *Painter, keys: *const EnumSet(Key), controlActive: bool, altActive: bool) void {
        _ = self;
        _ = keys;
        _ = controlActive;
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

    fn insertChar(self: *Painter, set: *CharSet) error{Max, OutOfMemory}!void {
        if (self.instanceCount >= self.charMax) {
            std.log.err("Maximun number of instances", .{});
            return error.Max;
        }


        if (set.textureId) |id| {
            try self.insertChangeForTexture(self.instanceCount, id, self.cursorX, self.cursorY);
            self.instanceCount += 1;
        }

        self.cursorX += 1;

        try self.updateCursor(self.cursorX, self.cursorY);
    }

    fn offsetOf(self: *Painter, x: usize, y: usize) u32 {
        return @intCast((y * self.rowChars) + x);
    }

    fn drawChars(self: *Painter) void {
        if (self.instanceCount <= 1) return;

        self.charTransforms.bind(2);
        self.charTransformIndices.bind(3);

        self.texture.bind(self.textureLocation, 0);

        self.rectangle.draw(1, self.instanceCount - 1);

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

const Lines = struct {
    cursor: Cursor,

    lines: List(Line),

    currentLine: *LineNode,
    currentBuffer: *BufferNode,

    allocator: FixedBufferAllocator,

    const LineNode = List(Line).Node;
    const BufferNode = List(LineBuffer).Node;

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

        fn shiftData(self: *LineBuffer, offset: u32, count: u32) error{OutOfMemory}!void {
            if (count > self.capacity) return error.OutOfMemory;
            if (offset > self.len) return error.OutOfMemory;
            var n = self.len;

            if (self.len + count > self.capacity) n = self.capacity - count;

            for (offset..n) |i| {
                self.handle[offset + i + count] = self.handle[offset + i];
            }

            self.len = n + count;
        }
    };

    const Line = struct {
        buffer: List(LineBuffer),

        fn init(self: *Line, allocator: Allocator) error{OutOfMemory}!*BufferNode {
            self.buffer = List(LineBuffer) {};

            return try self.append(allocator);
        }

        fn append(self: *Line, allocator: Allocator) error{OutOfMemory}!*BufferNode {
            const buffer = try allocator.create(BufferNode);
            try buffer.data.init(allocator, 30);

            self.buffer.append(buffer);

            return buffer;
        }

        fn print(self: *Line) void {
            var buffer = self.buffer.first;

            while (buffer) |b| {
                std.debug.print("{s}", .{b.data.handle[0..b.data.len]});
                buffer = b.next;
            }
        }
    };

    fn new(allocator: Allocator) error{OutOfMemory}!Lines {
        var self: Lines = undefined;

        self.cursor.x = 0;
        self.cursor.y = 0;
        self.cursor.offset = 0;

        self.allocator = FixedBufferAllocator.init(try allocator.alloc(u8, std.mem.page_size));
        const fixedAllocator = self.allocator.allocator();

        self.currentLine = try self.allocator.allocator().create(LineNode);
        self.currentBuffer = try self.currentLine.data.init(fixedAllocator);

        self.lines = List(Line) {};
        self.lines.append(self.currentLine);

        return self;
    }

    fn insertChar(self: *Lines, char: u8) error{OutOfMemory}!void {
        try self.insertString(&.{char});
    }

    fn insertString(self: *Lines, chars: []const u8) error{OutOfMemory}!void {
        const bufferWithOffset = try self.insertBufferNodeChars(self.currentLine, self.currentBuffer, self.cursor.offset, chars);

        self.cursor.offset = bufferWithOffset.offset;
        self.currentBuffer = bufferWithOffset.buffer;
    }

    fn insertBufferNodeChars(self: *Lines, line: *LineNode, buffer: *BufferNode, offset: u32, chars: []const u8) error{OutOfMemory}!BufferNodeWithOffset {
        if (offset > buffer.data.len) return error.OutOfMemory;
        if (chars.len == 0) return .{
            .buffer = buffer,
            .offset = 0,
        };

        if (chars.len > buffer.data.capacity - offset) {
            defer buffer.data.len += buffer.data.capacity - offset;
            try self.checkBufferNodeNext(line, buffer, @intCast(chars.len));
            _ = try self.insertBufferNodeChars(line, buffer.next.?, 0, buffer.data.handle[offset..buffer.data.len]);

            @memcpy(buffer.data.handle[offset..buffer.data.capacity], chars[0..buffer.data.capacity - offset]);
            return try self.insertBufferNodeChars(line, buffer.next.?, 0, chars[buffer.data.capacity - offset..]);
        } else if (chars.len + buffer.data.len > buffer.data.capacity) {
            try self.checkBufferNodeNext(line, buffer, @intCast(chars.len));
            _ = try self.insertBufferNodeChars(line, buffer.next.?, 0, buffer.data.handle[buffer.data.capacity - chars.len..buffer.data.len]);
        }

        defer buffer.data.len += @intCast(chars.len);

        @memcpy(buffer.data.handle[offset..offset + chars.len], chars);

        return .{
            .buffer = buffer,
            .offset = @intCast(offset + chars.len),
        };
    }

    fn checkBufferNodeNext(self: *Lines, line: *LineNode, buffer: *BufferNode, size: u32) error{OutOfMemory}!void {
        if (buffer.next) |_| {} else {
            const newBuffer = try self.allocator.allocator().create(BufferNode);
            try newBuffer.data.init(self.allocator.allocator(), size);

            line.data.buffer.insertAfter(buffer, newBuffer);
        }
    }

    fn max(first: usize, second: usize) usize {
        return if (first > second) first else second;
    }

    fn min(first: usize, second: usize) usize {
        return if (first < second) first else second;
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

test "testing" {
    var lines = try Lines.new(std.testing.allocator);
    defer std.testing.allocator.free(lines.allocator.buffer);

    try lines.insertString("criancas nao fumem na escola se nao o diretor vai pegar voces e dar algumas boas pauladas\n");
    try lines.insertString("criancas nao fumem na escola se nao o diretor vai pegar voces e dar algumas boas pauladas\n");
    try lines.insertString("criancas nao fumem na escola se nao o diretor vai pegar voces e dar algumas boas pauladas\n");
    try lines.insertString("criancas nao fumem na escola se nao o diretor vai pegar voces e dar algumas boas pauladas\n");
    try lines.insertString("criancas nao fumem na escola se nao o diretor vai pegar voces e dar algumas boas pauladas\n");
    try lines.insertString("criancas nao fumem na escola se nao o diretor vai pegar voces e dar algumas boas pauladas\n");
    try lines.insertString("criancas nao fumem na escola se nao o diretor vai pegar voces e dar algumas boas pauladas\n");
    try lines.insertString("criancas nao fumem na escola se nao o diretor vai pegar voces e dar algumas boas pauladas\n");
    try lines.insertString("criancas nao fumem na escola se nao o diretor vai pegar voces e dar algumas boas pauladas\n");
    try lines.insertString("criancas nao fumem na escola se nao o diretor vai pegar voces e dar algumas boas pauladas\n");
    try lines.insertString("criancas nao fumem na escola se nao o diretor vai pegar voces e dar algumas boas pauladas\n");

    lines.print();
}
