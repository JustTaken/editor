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
const Popup = @import("lines.zig").Popup;
const FreePool = @import("lines.zig").FreePool;
const CharInfo = @import("lines.zig").CharInfo;
const Iter = @import("lines.zig").CharIter;
const GlyphGenerator = @import("lines.zig").GlyphGenerator;

const Matrix = @import("math.zig").Matrix;

const Key = @import("input.zig").Key;

const IDENTITY = Matrix(4).identity();

const VELOCITY: f32 = 3.0;

const Focus = enum {
    TextBuffer,
    CommandLine,
};

const LinesNode = List(Lines).Node;

const Command = struct {
    name: []const u8,
    f: *const fn (*Painter, argumens: *std.mem.SplitIterator(u8, .sequence)) void,
};

pub const Painter = struct {
    glyphGenerator: GlyphGenerator,
    rectangle: Mesh,

    freePool: FreePool,

    textBuffers: List(Lines),
    commandLine: Lines,
    popup: Popup,
    focus: Focus,

    colorTransforms: Buffer([4]f32),
    instanceTransforms: Buffer(Matrix(4)),
    textureIndices: Buffer(u32),

    programTexture: Program,
    programNoTexture: Program,

    uniforms: Buffer(Matrix(4)),
    uniformChange: bool,

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

    commandHandler: CommandHandler,

    allocator: *FixedBufferAllocator,

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

        self.freePool = FreePool.new(self.allocator);
        self.textBuffers = List(Lines) {};

        const currentBuffer = try allocator.create(LinesNode);

        try currentBuffer.data.init(&self.freePool);
        try self.commandLine.init(&self.freePool);
        try self.popup.init(allocator);

        self.textBuffers.append(currentBuffer);
        self.commandHandler = try CommandHandler.new(&.{.{ .name = "edit", .f = editCommand }}, allocator);

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

    fn processKeyCommand(self: *Painter, key: Key) void {
        switch (key) {
            .ArrowRight => self.updateView(self.uniforms.array.items[0].translate(.{-10.0, 0, 0})),
            .ArrowLeft => self.updateView(self.uniforms.array.items[0].translate(.{10.0, 0, 0})),
            .ArrowUp => self.updateView(self.uniforms.array.items[0].translate(.{0, -10, 0})),
            .ArrowDown => self.updateView(self.uniforms.array.items[0].translate(.{0, 10, 0})),
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
                        // const allocator = self.allocator.allocator();
                        // const stringCommand = allocator.alloc(u8, 100) catch {
                        //     std.log.err("Failed to get command line content", .{});
                        //     return;
                        // };
                        // defer allocator.free(stringCommand);

                        // self.processCommandString(stringCommand[0..count]) catch |e| {
                        //     std.log.err("Failed to execute command, cause: {}", .{e});
                        //     return;
                        // };

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

        switch (self.focus) {
            .TextBuffer => self.textBuffers.last.?.data.insertChar(@intCast(i)) catch return,
            .CommandLine => self.writeToCommandLine(i) catch return,
        }
    }

    fn writeToCommandLine(self: *Painter, char: u32) error{OutOfMemory}!void {
        try self.commandLine.insertChar(@intCast(char));

        var content: [100]u8 = undefined;

        const command = self.commandLine.currentLine.data.write(&content);
        try self.commandHandler.updateCandidates(command);

        self.popup.reset();

        for (self.commandHandler.candidates.items) |candidate| {
            try self.popup.insert(candidate.name);
            // std.debug.print("inserting, {s}\n", .{candidate.name});
        }

        // self.popup.print();
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

        self.glyphGenerator.defaultTransform = IDENTITY.scale(.{size, size, 1, 1}).translate(.{font_width, -(font_height / 2), 0}); // @WARNING font_width do not reflect the right size of every char, it is just the bounding box of a maximun char size, so this x translation is wrong
        self.cursorScale = IDENTITY.scale(.{font_width, font_height, 1, 1}).translate(.{font_width / 2, -(font_height / 2), 0});
        self.commandLineBackScale = IDENTITY.scale(.{float_width, font_height, 1, 1}).translate(.{float_width / 2, font_height / 2 - float_height, 0.5});

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

    fn putCharIter(self: *Painter, iter: Iter) error{ OutOfMemory }!void {
        var infoArray: [100]CharInfo = undefined;

        while (iter.next(&infoArray)) |infos| {
            for (infos) |i| {
                try self.insertChar(i, .{1, 1, 1, 1});
            }
        }
    }

    // fn putLines(self: *Painter, buffer: *Lines, width: u32, height: u32, xOffset: i32, yOffset: i32, zOffset: i32, generator: *GlyphGenerator) error{ Max, OutOfMemory }!Matrix(4) {
    //     var iter = lines.iter(width, height, xOffset, yOffset, zOffset, generator);

    //     return iter.getCursor();
    // }

    // fn putPopup(self: *Painter, buffer: *Popup, width: u32, height: u32, xOffset: i32, yOffset: i32, zOffset: i32, perLine: u32, generator: *GlyphGenerator) error{Max, OutOfMemory}!void {
    //     var iter = lines.iter(width, height, xOffset, yOffset, zOffset, perLine, generator);

    //     while (iter.next(&infoArray)) |infos| {
    //         for (infos) |i| {
    //             try self.insertChar(i, .{1, 1, 1, 1});
    //         }
    //     }
    // }

    // fn putLinesWithCursor(self: *Popup, buffer: anytype, width: u32, height: u32, xOffset: i32, yOffset: i32, zOffset: i32, generator: *GlyphGenerator) error{ Max, CharNotFound, OutOfMemory }!void {
    // // fn putLinesWithCursor(self: *Painter, iter: anytype) error{ Max, CharNotFound, OutOfMemory }!Matrix(4) {
    //     try self.putLines(buffer, width, height, xOffset, yOffset, zOffset, generator);
    //     return iter.getCursor();
    // }

    fn checkContentChange(self: *Painter) error{ OutOfMemory }!bool {
        const textBuffer = &self.textBuffers.last.?.data;
        if (!textBuffer.change and !self.commandLine.change) return false;

        textBuffer.change = false;
        self.commandLine.change = false;

        self.resetInstances();

        try self.putCharIter(textBuffer.iter(self.width, self.height - self.glyphGenerator.font.height, 0, 0, 0, &self.glyphGenerator));
        try self.putCharIter(self.commandLine.iter(self.width, self.glyphGenerator.font.height, 0, -@as(i32, @intCast(self.height - self.glyphGenerator.font.height)), 1, &self.glyphGenerator));

        var cursorTransform: Matrix(4) = undefined;

        switch (self.focus) {
            .TextBuffer => cursorTransform = textBuffer.iterHandler.getCursor(),
            .CommandLine => {
                cursorTransform = self.commandLine.iterHandler.getCursor();

                if (self.popup.blocks.items.len > 0) {
                    const height = (self.popup.lines(4) + 1) * self.glyphGenerator.font.height;
                    try self.putCharIter(self.popup.iter(self.width, height, 0, -@as(i32, @intCast(self.height - height)), 1, 4, &self.glyphGenerator));
                    // std.debug.print("puting in\n", .{});
                }
            }
        }

        try self.insertInstance(cursorTransform.mult(self.cursorScale), .{1, 1, 0.0, 1});
        try self.insertInstance(self.commandLineBackScale, .{0.5, 0.5, 0.5, 1});

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
                    .LowerD => textBuffer.deleteForward(1),
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
                    .LowerD => self.commandLine.deleteForward(1),
                    .LowerA => self.commandLine.lineStart(),
                    .LowerE => self.commandLine.lineEnd(),
                    else => {},
                };
            },
        }
    }

    fn insertChar(self: *Painter, info: CharInfo, color: [4]f32) error{ OutOfMemory }!void {
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

const CommandHandler = struct {
    commands: ArrayList(Command),
    candidates: ArrayList(Command),
    index: u32,

    fn new(commands: []const Command, allocator: Allocator) error{OutOfMemory}!CommandHandler {
        var self: CommandHandler = undefined;

        self.candidates = try ArrayList(Command).initCapacity(allocator, commands.len);
        self.commands = try ArrayList(Command).initCapacity(allocator, commands.len);
        try self.commands.appendSlice(commands);
        self.index = 0;

        return self;
    }

    fn updateCandidates(self: *CommandHandler, string: []const u8) error{OutOfMemory}!void {
        self.clear();

        for (self.commands.items) |cmd| {
            if (std.mem.startsWith(u8, cmd.name, string)) {
                try self.candidates.append(cmd);
            }
        }
    }

    fn clear(self: *CommandHandler) void {
        self.candidates.clearRetainingCapacity();
    }
};

fn editCommand(painter: *Painter, it: *std.mem.SplitIterator(u8, .sequence)) void {
    const argument_value = it.next() orelse {
        std.log.err("missing argument in edit command", .{});
        return;
    };

    var buffer = painter.textBuffers.first;

    while (buffer) |b| {
        if (std.mem.eql(u8, b.data.name[0..b.data.nameLen], argument_value)) {
            painter.textBuffers.remove(b);
            painter.textBuffers.append(b);

            return;
        }

        buffer = b.next;
    }

    const nextTextBuffer = painter.allocator.allocator().create(LinesNode) catch {
        std.log.err("Out Of memory when opening: {s}", .{argument_value});
        return;
    };

    nextTextBuffer.data.fromFile(&painter.freePool, argument_value) catch |e| {
        painter.allocator.allocator().destroy(nextTextBuffer);

        std.log.err("Open file: {s}, {}", .{argument_value, e});

        return;
    };

    painter.textBuffers.append(nextTextBuffer);
}
