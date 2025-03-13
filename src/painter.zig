const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const List = std.DoublyLinkedList;

const Program = @import("opengl/shader.zig").Program;
const Shader = @import("opengl/shader.zig").Shader;
const Buffer = @import("opengl/buffer.zig").Buffer;
const Mesh = @import("opengl/mesh.zig").Mesh;
const Lines = @import("lines.zig").Lines;
const FreePool = @import("lines.zig").FreePool;
const CharInfo = @import("lines.zig").CharInfo;
const GlyphGenerator = @import("lines.zig").GlyphGenerator;

const Matrix = @import("math.zig").Matrix;

const Key = @import("input.zig").Key;

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

    colorTransforms: Buffer([4]f32),
    instanceTransforms: Buffer(Matrix(4)),
    textureIndices: Buffer(u32),

    programTexture: Program,
    programNoTexture: Program,

    uniforms: Buffer(Matrix(4)),
    uniformChange: bool,

    cursorPosition: [2]u32,
    cursorScale: Matrix(4),
    commandLineBackScale: Matrix(4),

    textureLocation: u32,

    instanceCount: u32,
    solidCount: u32,
    charCount: u32,

    width: u32,
    height: u32,

    near: f32,
    far: f32,

    commands: ArrayList(Command),

    allocator: *FixedBufferAllocator,

    const Command = struct {
        name: []const u8,
        f: *const fn (*Painter, argumens: *std.mem.SplitIterator(u8, .sequence)) void,
    };

    const Config = struct {
        width: u32,
        height: u32,
        size: u32,
        instanceMax: u32,
        near: f32,
        far: f32,
        charKindMax: u32,
        allocator: *FixedBufferAllocator,
    };

    const LinesNode = List(Lines).Node;

    pub fn init(self: *Painter, config: Config) error{ Init, Compile, Read, NotFound, OutOfMemory }!void {
        self.allocator = config.allocator;

        self.near = config.near;
        self.far = config.far;

        self.uniformChange = false;
        self.instanceCount = 0;
        self.charCount = 0;
        self.solidCount = 0;

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

        self.instanceTransforms = try Buffer(Matrix(4)).new(.shader_storage_buffer, config.instanceMax, allocator);
        self.colorTransforms = try Buffer([4]f32).new(.shader_storage_buffer, config.instanceMax, allocator);
        self.textureIndices = try Buffer(u32).new(.shader_storage_buffer, config.instanceMax, allocator);
        self.uniforms = try Buffer(Matrix(4)).new(.uniform_buffer, 2, allocator);

        try self.glyphGenerator.init(config.size, config.charKindMax, allocator);
        self.resize(config.width, config.height);
        self.cursorPosition = .{0, 0};

        self.freePool = FreePool.new(self.allocator);
        self.commands = try ArrayList(Command).initCapacity(allocator, 20);
        try self.commands.append(.{
            .name = "edit",
            .f = editCommand,
        });

        self.textBuffers = List(Lines) {};

        const currentBuffer = try allocator.create(LinesNode);
        try currentBuffer.data.init(&self.freePool);
        try self.commandLine.init(&self.freePool);

        self.textBuffers.append(currentBuffer);

        self.focus = .TextBuffer;

        self.uniforms.bind(0);
        self.instanceTransforms.bind(0);
        self.colorTransforms.bind(1);
        self.textureIndices.bind(2);
    }

    pub fn keyListen(ptr: *anyopaque, key: Key, controlActive: bool, altActive: bool) void {
        const self: *Painter = @ptrCast(@alignCast(ptr));

        if (controlActive or altActive) self.processWithModifiers(key, controlActive, altActive) else self.processKey(key);
    }

    fn processCommandString(self: *Painter, string: []const u8) error{Command, Operator, Argument, Execute}!void {
        var it = std.mem.splitSequence(u8, string, " ");

        const command_name = it.next() orelse return error.Command;

        for (self.commands.items) |command| {
            if (std.mem.eql(u8, command.name, command_name)) {
                command.f(self, &it);
                return;
            }
        }
    }

    fn editCommand(self: *Painter, it: *std.mem.SplitIterator(u8, .sequence)) void {
        const argument_value = it.next() orelse {
            std.log.err("missing argument in edit command", .{});
            return;
        };

        var buffer = self.textBuffers.first;

        while (buffer) |b| {
            if (std.mem.eql(u8, b.data.name[0..b.data.nameLen], argument_value)) {
                self.textBuffers.remove(b);
                self.textBuffers.append(b);

                return;
            }

            buffer = b.next;
        }

        const nextTextBuffer = self.allocator.allocator().create(LinesNode) catch {
            std.log.err("Out Of memory when opening: {s}", .{argument_value});
            return;
        };

        nextTextBuffer.data.fromFile(&self.freePool, argument_value) catch |e| {
            self.allocator.allocator().destroy(nextTextBuffer);

            std.log.err("Open file: {s}, {}", .{argument_value, e});

            return;
        };

        self.textBuffers.append(nextTextBuffer);
    }

    fn processKeyCommand(self: *Painter, key: Key) void {
        switch (key) {
            .ArrowRight => {
                self.updateView(self.uniforms.array.items[0].translate(.{-10.0, 0, 0}));
            },
            .ArrowLeft => {
                self.updateView(self.uniforms.array.items[0].translate(.{10.0, 0, 0}));
            },
            .ArrowUp => {
                self.updateView(self.uniforms.array.items[0].translate(.{0, 10, 0}));
            },
            .ArrowDown => {
                self.updateView(self.uniforms.array.items[0].translate(.{0, 10, 0}));
            },
            .Escape => {
                if (self.focus == .CommandLine) {
                    self.commandLine.clear();
                    self.focus = .TextBuffer;
                }
            },
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
                        self.processCommandString(stringCommand[0..count]) catch |e| {
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

        const toInsert = switch (self.focus) {
            .TextBuffer => &self.textBuffers.last.?.data,
            else => &self.commandLine,
        };

        toInsert.insertChar(@intCast(i)) catch |e| {
            std.log.err("Failed to insert {} into the buffer: {}", .{ key, e });

            return;
        };
    }

    fn resize(self: *Painter, width: u32, height: u32) void {
        if (width == self.width and height == self.height) return;

        self.width = width;
        self.height = height;

        const size: f32 = @floatFromInt(self.glyphGenerator.size);
        const font_height: f32 = @floatFromInt(self.glyphGenerator.font.height);
        const font_width: f32 = @floatFromInt(self.glyphGenerator.font.width);
        const float_width: f32 = @floatFromInt(self.width);
        const float_height: f32 = @floatFromInt(self.height);

        self.glyphGenerator.defaultTransform = IDENTITY.scale(.{size, size, 1, 1}).translate(.{font_width, -(font_height / 2), 2}); // @WARNING font_width do not reflect the right size of every char, it is just the bounding box of a maximun char size, so this x translation is wrong
        self.cursorScale = IDENTITY.scale(.{font_width, font_height, 1, 1}).translate(.{font_width / 2, -(font_height / 2), 1});
        self.commandLineBackScale = IDENTITY.scale(.{float_width, font_height, 1, 1}).translate(.{float_width / 2, font_height / 2 - float_height, 0});

        self.updateView(IDENTITY);
        self.updateProjection(IDENTITY.ortographic(0, float_width, 0, float_height, 0, 10.0));
    }

    pub fn resizeListen(ptr: *anyopaque, width: u32, height: u32) void {
        const self: *Painter = @ptrCast(@alignCast(ptr));
        self.resize(width, height);
    }

    fn insertInstance(self: *Painter, transform: Matrix(4), color: [4]f32) error{OutOfMemory}!void {
        defer self.instanceCount += 1;

        try self.instanceTransforms.array.append(transform);
        try self.colorTransforms.array.append(color);
    }

    fn updateView(self: *Painter, transform: Matrix(4)) void {
        defer self.uniformChange = true;

        self.uniforms.array.items.len = 2;
        self.uniforms.array.items[0] = transform;
    }

    fn updateProjection(self: *Painter, transform: Matrix(4)) void {
        defer self.uniformChange = true;

        self.uniforms.array.items.len = 2;
        self.uniforms.array.items[1] = transform;
    }

    pub fn hasChange(self: *Painter) bool {
        const matrixChange = self.checkMatrixChange() catch return false;
        const contentChange = self.checkContentChange() catch return false;

        return matrixChange or contentChange;
    }

    fn checkMatrixChange(self: *Painter) error{OutOfMemory}!bool {
        if (!self.uniformChange) return false;

        self.uniformChange = false;
        self.uniforms.push();

        return true;
    }

    fn putLines(self: *Painter, lines: *Lines, width: u32, height: u32, xOffset: i32, yOffset: i32) error{ Max, CharNotFound, OutOfMemory }!Matrix(4) {
        var iter = lines.rangeIter(width, height, xOffset, yOffset, &self.glyphGenerator) orelse return error.Max;

        var infoArray: [100]CharInfo = undefined;
        while (iter.nextLine(&infoArray)) |infos| {
            for (infos) |i| {
                try self.insertChar(i, .{1, 1, 1, 1});
            }
        }

        return iter.cursorTransform;
    }

    fn checkContentChange(self: *Painter) error{ Max, CharNotFound, OutOfMemory }!bool {
        const textBuffer = &self.textBuffers.last.?.data;
        if (!textBuffer.change and !self.commandLine.change) return false;

        textBuffer.change = false;
        self.commandLine.change = false;

        self.resetInstances();

        const bufferCursorTransform = try self.putLines(textBuffer, self.width, self.height, 0, 0);
        const commandLineCursorTransform = try self.putLines(&self.commandLine, self.width, self.glyphGenerator.font.height, 0, -@as(i32, @intCast(self.height - self.glyphGenerator.font.height)));

        const cursorTransform = if (self.focus == .TextBuffer) bufferCursorTransform else commandLineCursorTransform;

        try self.insertInstance(cursorTransform.mult(self.cursorScale), .{1, 1, 0.0, 1});
        try self.insertInstance(self.commandLineBackScale, .{1, 0, 0, 1});

        self.solidCount = self.instanceCount - self.charCount;

        self.instanceTransforms.push();
        self.colorTransforms.push();
        self.textureIndices.push();

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
                    .LowerD => textBuffer.deleteForward(1) catch return,
                    .LowerA => textBuffer.lineStart(),
                    .LowerE => textBuffer.lineEnd(),
                    .LowerS => textBuffer.save() catch return,
                    .Space => textBuffer.toggleSelection(),
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
                    .LowerD => self.commandLine.deleteForward(1) catch return,
                    .LowerA => self.commandLine.lineStart(),
                    .LowerE => self.commandLine.lineEnd(),
                    else => {},
                };
            },
        }
    }

    fn insertChar(self: *Painter, info: CharInfo, color: [4]f32) error{ Max, CharNotFound, OutOfMemory }!void {
        if (info.id) |id| {
            defer self.charCount += 1;

            try self.textureIndices.array.append(id);
            try self.insertInstance(info.transform, color);
        }
    }

    fn resetInstances(self: *Painter) void {
        self.charCount = 0;
        self.instanceCount = 0;

        self.instanceTransforms.array.clearRetainingCapacity();
        self.colorTransforms.array.clearRetainingCapacity();
        self.textureIndices.array.clearRetainingCapacity();
    }

    fn drawWithTexture(self: *Painter) void {
        self.glyphGenerator.texture.bind(self.textureLocation, 1);

        self.rectangle.draw(0, self.charCount);

        self.glyphGenerator.texture.unbind(1);
    }

    fn drawNoTexture(self: *Painter) void {
        self.rectangle.draw(self.charCount, self.solidCount);
    }

    pub fn draw(self: *Painter) void {
        self.programNoTexture.start();
        self.drawNoTexture();
        self.programNoTexture.end();

        self.programTexture.start();
        self.drawWithTexture();
        self.programTexture.end();
    }

    pub fn deinit(self: *const Painter) void {
        self.rectangle.deinit();
        self.glyphGenerator.deinit();
        self.instanceTransforms.deinit();
        self.textureIndices.deinit();
        self.uniforms.deinit();
        self.programTexture.deinit();
        self.programNoTexture.deinit();
    }
};
