const std = @import("std");

const Allocator = std.mem.Allocator;
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

const Focus = enum {
    TextBuffer,
    CommandLine,
};

pub const Painter = struct {
    glyphGenerator: GlyphGenerator,
    rectangle: Mesh,

    freePool: FreePool,

    textBuffers: List(Lines),
    commandLine: Lines,
    focus: Focus,

    instanceTransforms: Buffer([2]f32).Indexer,
    charTransforms: Buffer([2]f32).Indexer,
    solidTransforms: Buffer(Matrix(4)).Indexer,
    depthTransforms: Buffer(f32).Indexer,

    programTexture: Program,
    programNoTexture: Program,

    matrixUniforms: Buffer(Matrix(4)),
    matrixUniformArray: [2]Matrix(4),
    changes: [2]bool,

    scaleUniforms: Buffer(f32),
    scaleUniformArray: [2]f32,

    textureLocation: u32,

    instanceMax: u32,
    totalInstances: u32,

    scale: f32,
    rowChars: u32,
    colChars: u32,

    width: u32,
    height: u32,

    near: f32,
    far: f32,

    textureIndiceStart: u32,

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

    const LinesNode = List(Lines).Node;

    pub fn init(self: *Painter, config: Config) error{ Init, Compile, Read, NotFound, OutOfMemory }!void {
        self.allocator = FixedBufferAllocator.init(try config.allocator.alloc(u8, 24 * std.mem.page_size));

        self.width = config.width;
        self.height = config.height;
        self.near = config.near;
        self.far = config.far;
        self.scale = config.scale;
        self.textureIndiceStart = 2;

        const allocator = self.allocator.allocator();

        const vertexShader = try Shader.fromPath(.vertex, "assets/vertex.glsl", allocator);
        const fragmentShader = try Shader.fromPath(.fragment, "assets/fragment.glsl", allocator);

        self.programTexture = try Program.new(vertexShader, fragmentShader, allocator);
        self.textureLocation = try self.programTexture.uniformLocation("textureSampler1");

        vertexShader.deinit();
        fragmentShader.deinit();

        const rawVertexShader = try Shader.fromPath(.vertex, "assets/rawVertex.glsl", allocator);
        const rawFragmentShader = try Shader.fromPath(.fragment, "assets/rawFrag.glsl", allocator);

        self.programNoTexture = try Program.new(rawVertexShader, rawFragmentShader, allocator);

        rawVertexShader.deinit();
        rawFragmentShader.deinit();

        self.rectangle = try Mesh.new("assets/plane.obj", allocator);

        self.instanceTransforms = try Buffer([2]f32).new(.shader_storage_buffer, config.instanceMax, null).indexer(config.instanceMax, u16, allocator);
        self.charTransforms = try Buffer([2]f32).new(.shader_storage_buffer, config.charKindMax, null).indexer(config.instanceMax, u8, allocator);
        self.solidTransforms = try Buffer(Matrix(4)).new(.shader_storage_buffer, 2, null).indexer(2, u8, allocator);
        self.depthTransforms = try Buffer(f32).new(.shader_storage_buffer, 2, &.{ 1, 0 }).indexer(config.instanceMax, u8, allocator);
        self.depthTransforms.pushIndex(0, 1);
        _ = self.depthTransforms.syncIndex(config.instanceMax);

        self.scaleUniformArray[0] = @floatFromInt(config.size / 2);
        self.scaleUniformArray[1] = config.scale;
        self.scaleUniforms = Buffer(f32).new(.uniform_buffer, 2, &self.scaleUniformArray);

        self.matrixUniformArray = .{ IDENTITY.translate(.{ self.scaleUniformArray[0], -self.scaleUniformArray[0], 1.0 }), IDENTITY.ortographic(0, @floatFromInt(config.width), 0, @floatFromInt(config.height), config.near, config.far) };
        self.matrixUniforms = Buffer(Matrix(4)).new(.uniform_buffer, 2, &self.matrixUniformArray);
        self.changes = .{false} ** 2;

        try self.glyphGenerator.init(config.size, &self.charTransforms, config.charKindMax, allocator);

        self.instanceMax = config.instanceMax;
        self.totalInstances = 0;

        resize(self, config.width, config.height);

        self.freePool = FreePool.new(FixedBufferAllocator.init(try allocator.alloc(u8, 2 * std.mem.page_size)));

        self.textBuffers = List(Lines) {};

        const currentBuffer = try allocator.create(LinesNode);
        try currentBuffer.data.init(&self.freePool);

        self.textBuffers.append(currentBuffer);

        try self.commandLine.init(&self.freePool);

        self.focus = .TextBuffer;

        self.initCursor();
        self.initCommandLineBack();

        self.instanceTransforms.bind(0, 1);
        self.depthTransforms.bind(2, 3);

        self.matrixUniforms.bind(0);
        self.scaleUniforms.bind(2);
    }

    pub fn keyListen(ptr: *anyopaque, key: Key, controlActive: bool, altActive: bool) void {
        const self: *Painter = @ptrCast(@alignCast(ptr));

        if (controlActive or altActive) self.processWithModifiers(key, controlActive, altActive) else self.processKey(key);
    }

    fn processStringCommand(self: *Painter, string: []const u8) error{Command, Operator, Argument, Execute}!void {
        var it = std.mem.splitSequence(u8, string, " ");
        const command = it.next() orelse return error.Command;
        const operator = it.next() orelse return error.Operator;
        const argument = it.next() orelse return error.Argument;

        if (!std.mem.eql(u8, command, "open")) return;
        if (!std.mem.eql(u8, operator, "file")) return;

        const nexTextBuffer = self.allocator.allocator().create(LinesNode) catch return error.Execute;
        nexTextBuffer.data.fromFile(&self.freePool, argument) catch return error.Execute;
        self.textBuffers.append(nexTextBuffer);
    }

    fn processKeyCommand(self: *Painter, key: Key) void {
        switch (key) {
            .Enter => {
                switch (self.focus) {
                    .TextBuffer => self.textBuffers.last.?.data.newLine() catch return,
                    .CommandLine => {
                        const allocator = self.allocator.allocator();
                        const stringCommand = allocator.alloc(u8, 100) catch {
                            std.log.err("Failed to get command line content", .{});
                            return;
                        };
                        defer allocator.free(stringCommand);

                        const count = self.commandLine.currentLine.data.write(stringCommand);
                        self.processStringCommand(stringCommand[0..count]) catch |e| {
                            std.log.err("Failed to execute command, cause: {}", .{e});
                            return;
                        };

                        self.commandLine.clear();
                        self.focus = .TextBuffer;
                    },
                }
            },
            else => {},
        }
    }

    fn processKey(self: *Painter, key: Key) void {
        const i: u32 = @intFromEnum(key);

        if (i > Key.NON_DISPLAYABLE) {
            self.processKeyCommand(key);
            return;
        }

        const toInsert: *Lines = if (self.focus == .TextBuffer) &self.textBuffers.last.?.data else &self.commandLine;

        toInsert.insertChar(@intCast(i)) catch |e| {
            std.log.err("Failed to insert {} into the buffer: {}", .{ key, e });

            return;
        };
    }

    fn resize(self: *Painter, width: u32, height: u32) void {
        if (width == self.width and height == self.height) return;

        self.width = width;
        self.height = height;

        self.initCommandLineBack();

        self.matrixUniformArray[1] = IDENTITY.ortographic(0, @floatFromInt(width), 0, @floatFromInt(height), self.near, self.far);
        self.changes[1] = true;

        const rowChars: f32 = @floatFromInt(width / self.glyphGenerator.font.width);
        const colChars: f32 = @floatFromInt(height / self.glyphGenerator.font.height);

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
            std.log.err("Failed to resize text window, required glyph slot count: {}, given: {}", .{ charMax, self.instanceMax });
            return;
        }

        for (0..self.rowChars) |j| {
            for (0..self.colChars) |i| {
                const offset = self.offsetOf(j, i);

                const xPos: f32 = @floatFromInt(self.glyphGenerator.font.width * j);
                const yPos: f32 = @floatFromInt(self.glyphGenerator.font.height * i);

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
    }

    fn insertChangeForSolid(self: *Painter, indice: u32, scaleId: u32, x: u32, y: u32) void {
        const offset = self.offsetOf(x, y);

        self.instanceTransforms.pushIndex(indice, offset);
        self.solidTransforms.pushIndex(indice, scaleId);
    }

    fn initCommandLineBack(self: *Painter) void {
        const heightScale = @as(f32, @floatFromInt(@as(i32, @intCast(self.glyphGenerator.font.height)) - @divFloor(self.glyphGenerator.font.descender, 2))) / @as(f32, @floatFromInt(self.glyphGenerator.size));
        const widthScale = @as(f32, @floatFromInt(self.width)) / self.scaleUniformArray[0];

        self.solidTransforms.pushData(1, &.{IDENTITY.scale(.{ widthScale, heightScale, 1, 1 }).translate(.{ 0, @floatFromInt(@divFloor(self.glyphGenerator.font.descender, 2)), 0 })});
    }

    fn initCursor(self: *Painter) void {
        const heightScale = @as(f32, @floatFromInt(@as(i32, @intCast(self.glyphGenerator.font.height)) - @divFloor(self.glyphGenerator.font.descender, 2))) / @as(f32, @floatFromInt(self.glyphGenerator.size));
        const widthScale = @as(f32, @floatFromInt(self.glyphGenerator.font.width)) / @as(f32, @floatFromInt(self.glyphGenerator.size));

        self.solidTransforms.pushData(0, &.{IDENTITY.scale(.{ widthScale, heightScale, 1, 1 }).translate(.{ -@as(f32, @floatFromInt(self.glyphGenerator.font.width)) / 2.0, @floatFromInt(@divFloor(self.glyphGenerator.font.descender, 2)), 0 })}); //IDENTITY.scale(.{
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

    fn putLines(self: *Painter, lines: *Lines, cols: u32, rows: u32, xOffset: u32, yOffset: u32) void {
        var iter = lines.rangeIter(cols, rows);

        var lineCount: u32 = 0;
        while (iter.hasNextLine()) {
            var charCount: u32 = 0;

            while (iter.nextChars()) |chars| {
                for (chars) |c| {
                    self.insertChar(c, charCount + xOffset, lineCount + yOffset) catch @panic("failed");
                    charCount += 1;
                }
            }

            lineCount += 1;
        }

        // std.log.info("drawing {} lines, from max: {}", .{lineCount, rows});
    }

    fn checkContentChange(self: *Painter) bool {
        const textBuffer = &self.textBuffers.last.?.data;
        if (!textBuffer.change and !self.commandLine.change) return false;

        textBuffer.change = false;
        self.commandLine.change = false;

        self.resetInstances();

        self.totalInstances += 2;

        self.putLines(textBuffer, self.rowChars, self.colChars - 1, 0, 0);
        self.putLines(&self.commandLine, self.rowChars, 1, 0, self.colChars - 1);

        const xPos = if (self.focus == .TextBuffer) textBuffer.cursor.x - textBuffer.xOffset else self.commandLine.cursor.x - self.commandLine.xOffset;
        const yPos = if (self.focus == .TextBuffer) textBuffer.cursor.y - textBuffer.yOffset else self.colChars - 1;

        self.insertChangeForSolid(0, 0, xPos, yPos);
        self.insertChangeForSolid(1, 1, 0, self.colChars - 1);

        _ = self.instanceTransforms.syncIndex(self.instanceMax);
        _ = self.solidTransforms.syncIndex(1);
        _ = self.charTransforms.syncIndex(self.instanceMax);

        return true;
    }

    fn processWithModifiers(self: *Painter, key: Key, controlActive: bool, altActive: bool) void {
        _ = altActive;

        switch (self.focus) {
            .TextBuffer => {
                const textBuffer = &self.textBuffers.last.?.data;
                if (controlActive) switch (key) {
                    .LowerB => textBuffer.moveBack(1),
                    .LowerF => textBuffer.moveFoward(1),
                    .LowerN => textBuffer.moveLineDown(1),
                    .LowerP => textBuffer.moveLineUp(1),
                    .LowerD => textBuffer.deleteForward(1),
                    .LowerA => textBuffer.lineStart(),
                    .LowerE => textBuffer.lineEnd(),
                    .LowerS => textBuffer.save() catch return,
                    .Enter => {
                        self.focus = .CommandLine;
                        self.commandLine.change = true;
                    },
                    else => {},
                };
            },
            .CommandLine => {
                if (controlActive) switch (key) {
                    .LowerB => self.commandLine.moveBack(1),
                    .LowerF => self.commandLine.moveFoward(1),
                    .LowerD => self.commandLine.deleteForward(1),
                    .LowerA => self.commandLine.lineStart(),
                    .LowerE => self.commandLine.lineEnd(),
                    else => {},
                };
            },
        }
    }

    fn insertChar(self: *Painter, char: u32, x: u32, y: u32) error{ Max, CharNotFound, OutOfMemory }!void {
        if (try self.glyphGenerator.get(char)) |id| {
            defer self.totalInstances += 1;
            self.insertChangeForTexture(self.totalInstances, id, x, y);
        }
    }

    fn offsetOf(self: *Painter, x: usize, y: usize) u32 {
        return @intCast((y * self.rowChars) + x);
    }

    fn resetInstances(self: *Painter) void {
        self.totalInstances = 0;
    }

    fn drawChars(self: *Painter) void {
        self.charTransforms.bind(4, 5);

        self.glyphGenerator.texture.bind(self.textureLocation, 0);

        self.rectangle.draw(self.textureIndiceStart, self.totalInstances - self.textureIndiceStart);

        self.glyphGenerator.texture.unbind(0);
    }

    fn drawCursors(self: *Painter) void {
        self.solidTransforms.bind(4, 5);

        self.rectangle.draw(0, self.textureIndiceStart);
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
        self.rectangle.deinit();
        self.glyphGenerator.deinit();
        self.instanceTransforms.deinit();
        self.matrixUniforms.deinit();
        self.scaleUniforms.deinit();
        self.charTransforms.deinit();
        self.solidTransforms.deinit();
        self.depthTransforms.deinit();
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

    const zero: [2]u8 = .{ 0, 0 };

    fn hasNextLine(self: *RangeIter) bool {
        if (self.cursor.y >= self.maxY) return false;

        const line = self.line orelse return false;

        self.cursor.x = 0;
        self.cursor.y += 1;
        defer self.line = line.next;

        self.buffer = line.data.findBufferOffset(&self.cursor, self.minX);

        return true;
    }

    fn nextChars(self: *RangeIter) ?[]u8 {
        defer self.cursor.offset = 0;

        if (self.cursor.x >= self.maxX) return null;

        const buffer = self.buffer orelse return null;

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

    fn init(self: *LineBuffer, allocator: Allocator, size: u32) error{OutOfMemory}!void {
        const handle = try allocator.alloc(u8, size);

        self.handle = handle.ptr;
        self.capacity = @intCast(handle.len);
        self.len = 0;
    }

    fn fromBytes(self: *LineBuffer, bytes: []u8) void {
        self.handle = bytes.ptr;
        self.capacity = @intCast(bytes.len);
        self.len = self.capacity;
    }
};

const Line = struct {
    buffer: List(LineBuffer),

    fn write(self: *Line, out: []u8) u32 {
        var buffer = self.buffer.first;

        var count: u32 = 0;
        while (buffer) |b| {
            std.mem.copyForwards(u8, out[count..], b.data.handle[0..b.data.len]);
            buffer = b.next;
            count += b.data.len;
        }

        return count;
    }

    fn print(self: *Line) void {
        var buffer = self.buffer.first;

        var count: u32 = 0;
        while (buffer) |b| {
            std.debug.print(" {d:0>3} -> [{s}]\n", .{ count, b.data.handle[0..b.data.len] });
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

    fn bufferFromFile(self: *FreePool, path: []const u8) error{OutOfMemory, CannotHandleThisBig, NotFound}!List(LineBuffer) {
        const allocator = self.allocator.allocator();
        const content = std.fs.cwd().readFileAlloc(allocator, path, std.mem.page_size) catch |e| {
            switch (e) {
                error.FileTooBig => return error.CannotHandleThisBig,
                error.FileNotFound => return error.NotFound,
                else => return error.OutOfMemory,
            }
        };

        var list = List(LineBuffer) {};

        var start: u16 = 0;
        for (content, 0..) |c, i| {
            if (c == '\n') {
                const currentBuffer = try allocator.create(BufferNode);
                currentBuffer.data.fromBytes(content[start..i]);
                list.append(currentBuffer);
                start = @intCast(i + 1);
            }
        }

        if (start != content.len) {
            const currentBuffer = try allocator.create(BufferNode);
            currentBuffer.data.fromBytes(content[start..]);
            list.append(currentBuffer);
        }

        return list;
    }

    fn newLine(self: *FreePool) error{OutOfMemory}!*LineNode {
        if (self.lines.pop()) |line| {
            line.data.buffer = .{};

            return line;
        }

        const line = try self.allocator.allocator().create(LineNode);

        line.data.buffer = .{};

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
    name: [100]u8,
    nameLen: usize,

    const BufferNodeWithOffset = struct {
        offset: u32,
        buffer: *BufferNode,
    };

    const DefaultName = "scratch";

    fn init(self: *Lines, freePool: *FreePool) error{OutOfMemory}!void {
        self.reset();
        self.freePool = freePool;

        self.currentLine = try self.freePool.newLine();
        self.currentBuffer = try self.freePool.newBuffer();
        self.currentLine.data.buffer.append(self.currentBuffer);

        self.lines = .{};
        self.lines.append(self.currentLine);

        for (DefaultName, 0..) |n, i| {
            self.name[i] = n;
        }

        self.nameLen = DefaultName.len;
    }

    fn fromFile(self: *Lines, freePool: *FreePool, path: []const u8) error{OutOfMemory, NotFound}!void {
        self.reset();
        self.freePool = freePool;

        const buffers = self.freePool.bufferFromFile(path) catch return error.NotFound;

        var currentBuffer = buffers.first;
        while (currentBuffer) |buffer| {
            currentBuffer = buffer.next;

            const line = try self.freePool.newLine();

            line.data.buffer.append(buffer);
            self.lines.append(line);
        }

        self.currentLine = self.lines.first.?;
        self.currentBuffer = self.currentLine.data.buffer.first.?;

        for (path, 0..) |n, i| {
            self.name[i] = n;
        }

        self.nameLen = path.len;
    }

    fn save(self: *Lines) error{Write, NotFound, OutOfMemory}!void {
        var line = self.lines.first;

        var allocator = FixedBufferAllocator.init(try self.freePool.allocator.allocator().alloc(u8, std.mem.page_size));
        const alloc = allocator.allocator();
        var content = try ArrayList(u8).initCapacity(alloc, 1024);

        while (line) |l| {
            var buffer = l.data.buffer.first;

            while (buffer) |b| {
                try content.appendSlice(b.data.handle[0..b.data.len]);
                buffer = b.next;
            }

            try content.append('\n');

            line = l.next;
        }

        const file = std.fs.cwd().createFile(self.name[0..self.nameLen], .{}) catch return error.NotFound;
        file.writeAll(content.items) catch return error.Write;
    }

    fn reset(self: *Lines) void {
        self.cursor.x = 0;
        self.cursor.y = 0;
        self.cursor.offset = 0;
        self.xOffset = 0;
        self.yOffset = 0;
        self.change = true;
        self.lines = .{};
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

        var count: u32 = 0;
        for (chars, 0..) |c, i| {
            if (c == '\n') {
                _ = try self.insertBufferNodeChars(self.currentLine, self.currentBuffer, self.cursor.offset, chars[count..i]);

                self.currentLine = try self.freePool.newLine();
                self.currentBuffer = try self.freePool.newBuffer();
                self.cursor.offset = 0;
                self.cursor.x = 0;

                count = @intCast(i + 1);
            }
        }

        if (count == chars.len) return;

        const bufferWithOffset = try self.insertBufferNodeChars(self.currentLine, self.currentBuffer, self.cursor.offset, chars[count..]);

        self.cursor.offset = bufferWithOffset.offset;
        self.currentBuffer = bufferWithOffset.buffer;
        self.cursor.x += @intCast(chars.len);
    }

    fn deleteForward(self: *Lines, count: u32) void {
        defer self.change = true;

        self.deleteBufferNodeCount(self.currentLine, self.currentBuffer, self.cursor.offset, count);
    }

    fn nextBufferOrJoin(self: *Lines, line: *LineNode, buffer: *BufferNode, count: *u32) ?*BufferNode {
        if (buffer.next) |_| {} else {
            if (line.next) |l| {
                while (l.data.buffer.pop()) |buf| {
                    line.data.buffer.insertAfter(buffer, buf);
                }

                self.lines.remove(l);
                self.freePool.freeLine(l);

                count.* -= 1;
            }
        }

        return buffer.next;
    }

    fn nextBuffer(_: *Lines, _: *LineNode, buffer: *BufferNode, _: *u32) ?*BufferNode {
        return buffer.next;
    }

    fn deleteBufferNodeCount(self: *Lines, line: *LineNode, buffer: *BufferNode, offset: u32, count: u32) void {
        if (count == 0) {
            if (offset == 0 and buffer.data.len == 0) {
                line.data.buffer.remove(buffer);
            }

            return;
        }

        if (count >= buffer.data.len - offset) {
            const f: *const fn (*Lines, *LineNode, *BufferNode, *u32) ?*BufferNode = if (count > buffer.data.len - offset) nextBufferOrJoin else nextBuffer;

            var c = count - (buffer.data.len - offset);

            var next = f(self, line, buffer, &c);

            while (next) |n| {
                if (n.data.len >= c) break;
                c -= @intCast(n.data.len);

                next = f(self, line, n, &c);
                self.removeBufferNode(line, n);
            }

            if (next) |n| {
                const nextCount = min(buffer.data.capacity - offset, n.data.len - c);

                defer buffer.data.len = @intCast(offset + nextCount);
                std.mem.copyForwards(u8, buffer.data.handle[offset .. offset + nextCount], n.data.handle[c .. c + nextCount]);

                self.deleteBufferNodeCount(line, n, 0, @intCast(c + nextCount));
            } else {
                buffer.data.len = @intCast(offset);
            }
        } else {
            std.mem.copyForwards(u8, buffer.data.handle[offset .. buffer.data.len - count], buffer.data.handle[offset + count .. buffer.data.len]);

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

            std.mem.copyForwards(u8, buffer.data.handle[offset..buffer.data.capacity], chars[0 .. buffer.data.capacity - offset]);
            return try self.insertBufferNodeChars(line, buffer.next.?, 0, chars[buffer.data.capacity - offset ..]);
        } else if (chars.len + buffer.data.len > buffer.data.capacity) {
            defer buffer.data.len = buffer.data.capacity;

            try self.checkBufferNodeNext(line, buffer);

            _ = try self.insertBufferNodeChars(line, buffer.next.?, 0, buffer.data.handle[buffer.data.capacity - chars.len .. buffer.data.len]);

            std.mem.copyBackwards(u8, buffer.data.handle[offset + chars.len .. buffer.data.capacity], buffer.data.handle[offset .. buffer.data.capacity - chars.len]);
        } else {
            defer buffer.data.len += @intCast(chars.len);

            std.mem.copyBackwards(u8, buffer.data.handle[offset + chars.len .. chars.len + buffer.data.len], buffer.data.handle[offset..buffer.data.len]);
        }

        std.mem.copyForwards(u8, buffer.data.handle[offset .. offset + chars.len], chars);

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
        const line = try self.freePool.newLine();

        self.lines.insertAfter(self.currentLine, line);

        while (self.currentBuffer.next) |n| {
            self.currentLine.data.buffer.remove(n);
            line.data.buffer.append(n);
        }

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

    fn clear(self: *Lines) void {
        defer self.change = true;

        self.cursor.x = 0;
        self.cursor.y = 0;
        self.cursor.offset = 0;

        var line = self.lines.last;

        while (line) |l| {
            self.lines.remove(l);
            self.freePool.freeLine(l);

            line = l.prev;
        }

        self.currentLine = self.freePool.newLine() catch unreachable;
        self.currentBuffer = self.freePool.newBuffer() catch unreachable;
        self.currentLine.data.buffer.append(self.currentBuffer);
        self.lines.append(self.currentLine);
    }

    fn rangeIter(self: *Lines, maxCols: u32, maxRows: u32) RangeIter {
        self.checkCursor(maxCols, maxRows);

        var currentLine = self.currentLine;
        var currentY = self.cursor.y;

        while (currentY > self.yOffset) : (currentY -= 1) {
            currentLine = currentLine.prev.?;
        }

        return RangeIter{
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

        var count: u32 = 0;
        while (line) |l| {
            std.debug.print("{}:\n", .{count});
            l.data.print();

            line = l.next;
            count += 1;
        }
    }
};

const GlyphGenerator = struct {
    font: FreeType,
    charIds: Map(u32, ?u16),
    texture: Texture,
    count: u32,
    max: u32,
    transforms: *Buffer([2]f32).Indexer,
    size: u32,

    fn init(
        self: *GlyphGenerator,
        size: u32,
        transforms: *Buffer([2]f32).Indexer,
        maxGlyphs: u32,
        allocator: Allocator,
    ) error{ Init, OutOfMemory }!void {
        self.size = size + 2;
        self.texture = Texture.new(self.size, self.size, maxGlyphs, .r8, .red, .unsigned_byte, .@"2d_array", null);
        self.font = try FreeType.new("assets/font.ttf", size);
        self.charIds = Map(u32, ?u16).init(allocator);

        try self.charIds.ensureTotalCapacity((maxGlyphs * 4) / 5);

        self.transforms = transforms;
        self.max = maxGlyphs;
        self.count = 0;
    }

    fn get(self: *GlyphGenerator, code: u32) error{ Max, CharNotFound, OutOfMemory }!?u16 {
        const set = try self.charIds.getOrPut(code);

        if (!set.found_existing) {
            if (self.count >= self.max) return error.Max;

            const char = self.font.findChar(code) catch return null;

            if (char.buffer) |b| {
                defer self.count += 1;

                set.value_ptr.* = @intCast(self.count);

                self.texture.pushData(char.width, char.height, self.count, .red, .unsigned_byte, b);

                const size: i32 = @intCast(self.size);
                const deltaX: f32 = @floatFromInt(char.bearing[0]);
                const deltaY: f32 = @floatFromInt((size - char.bearing[1]));

                self.transforms.pushData(self.count, &.{.{ deltaX, -deltaY }});
            }
        }

        return set.value_ptr.*;
    }

    fn deinit(self: *const GlyphGenerator) void {
        self.texture.deinit();
    }
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

test "testing" {
    var fixedAllocator = FixedBufferAllocator.init(try std.testing.allocator.alloc(u8, 24 * std.mem.page_size));
    defer std.testing.allocator.free(fixedAllocator.buffer);

    var freePool = FreePool.new(FixedBufferAllocator.init(try fixedAllocator.allocator().alloc(u8, std.mem.page_size)));
    var lines = try Lines.new(&freePool);

    try lines.insertString("#include <stdio.h>");
    try lines.newLine();
    try lines.newLine();
    try lines.insertString("int main() {");
    try lines.newLine();
    try lines.insertString("}");
    lines.moveLineUp(1);
    lines.lineEnd();
    try lines.newLine();
    try lines.insertString("    std.debug.print(\"Hello world\");");
    try lines.newLine();
    try lines.insertString("    return 0;");

    lines.moveLineUp(2);
    lines.lineEnd();

    try lines.newLine();
    try lines.newLine();

    lines.print();
    lines.deleteForward(1);

    lines.print();
}
