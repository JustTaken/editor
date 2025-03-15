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
const Label = @import("lines.zig").Label;
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

pub const Painter = struct {
    glyphGenerator: GlyphGenerator,
    rectangle: Mesh,

    freePool: FreePool,

    textBuffers: List(Lines),
    commandLine: Lines,
    commandLineRight: Label,
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
        try self.commandLineRight.init(100, "0:0", allocator);

        self.textBuffers.append(currentBuffer);
        self.commandHandler = try CommandHandler.new(self, &.{
            try Command.withSubCommands("edit", &.{
                Command.withFunction("file", .Path, editFileCommand),
                Command.withFunction("buffer", .Buffer, editBufferCommand),
            }, allocator),
        }, allocator);

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

    fn processWithModifiers(self: *Painter, key: Key, controlActive: bool, altActive: bool) void {
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
                } else if (altActive) switch (key) {
                    .LowerN => textBuffer.moveLineDown(10),
                    .LowerP => textBuffer.moveLineUp(10),
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

    fn processKeyCommand(self: *Painter, key: Key) void {
        switch (key) {
            .ArrowRight => self.updateView(self.uniforms.array.items[0].translate(.{-10.0, 0, 0})),
            .ArrowLeft => self.updateView(self.uniforms.array.items[0].translate(.{10.0, 0, 0})),
            .ArrowUp => self.updateView(self.uniforms.array.items[0].translate(.{0, -10, 0})),
            .ArrowDown => self.updateView(self.uniforms.array.items[0].translate(.{0, 10, 0})),
            .Escape => self.focusTextBuffer(),
            .Enter => {
                switch (self.focus) {
                    .TextBuffer => self.textBuffers.last.?.data.newLine() catch return,
                    .CommandLine => {
                        var stringBuffer: [100]u8 = undefined;
                        const string = self.commandLine.lines.first.?.data.write(&stringBuffer);
                        var iter = std.mem.splitSequence(u8, string, " ");

                        if(self.commandHandler.getCommandFunction(null, &iter)) |f| {
                            const success = f(self, &iter);
                            _ = success;
                        }

                        self.focusTextBuffer();
                    },
                }
            },
            else => {},
        }
    }

    fn processKey(self: *Painter, key: Key) void {
        const char: u32 = @intFromEnum(key);

        if (char > Key.NON_DISPLAYABLE) {
            self.processKeyCommand(key);

            return;
        }

        switch (self.focus) {
            .TextBuffer => self.writeToBuffer(char) catch return,//
            .CommandLine => self.writeToCommandLine(char) catch return,
        }
    }

    fn focusTextBuffer(self: *Painter) void {
        if (self.focus != .CommandLine) return;

        self.commandLine.clear();
        self.commandHandler.reset();
        self.popup.reset();
        self.focus = .TextBuffer;
    }

    fn updateRightLabel(self: *Painter) error{OutOfMemory}!void {
        const buffer = &self.textBuffers.last.?.data;
        var content: [100]u8 = undefined;

        const location = std.fmt.bufPrint(&content, "{d}:{d}", .{buffer.cursor.y, buffer.cursor.x}) catch return error.OutOfMemory;
        try self.commandLineRight.insert(location);
    }

    fn writeToBuffer(self: *Painter, char: u32) error{OutOfMemory}!void {
        const buffer = &self.textBuffers.last.?.data;
        try buffer.insertChar(@intCast(char));
    }

    fn writeToCommandLine(self: *Painter, char: u32) error{OutOfMemory}!void {
        try self.commandLine.insertChar(@intCast(char));

        var content: [100]u8 = undefined;

        const command = self.commandLine.currentLine.data.write(&content);
        var iter = std.mem.splitSequence(u8, command, " ");

        try self.commandHandler.updateCandidates(null, &iter);

        self.popup.reset();

        for (self.commandHandler.candidates.items) |candidate| {
            try self.popup.insert(candidate);
        }
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

        self.commandLine.change = true;
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

    fn putLabel(self: *Painter, label: *const Label, width: u32, aligment: Label.Align, xOffset: i32, yOffset: i32, zOffset: i32) error{OutOfMemory}!void {
        var infoArray: [100]CharInfo = undefined;

        if (label.chars(width, aligment, xOffset, yOffset, zOffset, &infoArray, &self.glyphGenerator)) |chars| {
            for (chars) |i| {
                try self.insertChar(i, .{1, 1, 1, 1});
            }
        }
    }

    fn putPopup(self: *Painter, popup: *Popup) error{ OutOfMemory }!void {
        if (popup.blocks.items.len > 0) {
            const lines = self.popup.lines(4);
            const height = lines * self.glyphGenerator.font.height;
            const yOffset: i32 = @intCast(self.height - (height + self.glyphGenerator.font.height));

            try self.putCharIter(popup.iter(self.width, height, 0, -yOffset, 1, 4, &self.glyphGenerator));
            try self.insertInstance(IDENTITY.scale(.{@floatFromInt(self.width), @floatFromInt(height), 1, 1}).translate(.{@floatFromInt(self.width / 2), @floatFromInt(-yOffset - @as(i32, @intCast(height / 2))), 1}), .{0.5, 0.5, 0.5, 1});
        }
    }

    fn checkContentChange(self: *Painter) error{ OutOfMemory }!bool {
        const textBuffer = &self.textBuffers.last.?.data;
        if (!textBuffer.change and !self.commandLine.change) return false;

        textBuffer.change = false;
        self.commandLine.change = false;

        self.resetInstances();

        try self.updateRightLabel();

        try self.putCharIter(textBuffer.iter(self.width, self.height - self.glyphGenerator.font.height, 0, 0, 0, &self.glyphGenerator));
        try self.putCharIter(self.commandLine.iter(self.width, self.glyphGenerator.font.height, 0, -@as(i32, @intCast(self.height - self.glyphGenerator.font.height)), 1, &self.glyphGenerator));
        try self.putLabel(&self.commandLineRight, self.width, .Right, -@as(i32, @intCast(self.glyphGenerator.font.width)), -@as(i32, @intCast(self.height - self.glyphGenerator.font.height)), 1);
        try self.putPopup(&self.popup);

        const cursorTransform = switch (self.focus) {
            .TextBuffer => textBuffer.iterHandler.getCursor(),
            .CommandLine => self.commandLine.iterHandler.getCursor(),
        };

        try self.insertInstance(cursorTransform.mult(self.cursorScale), .{1, 1, 0.0, 1});
        try self.insertInstance(self.commandLineBackScale, .{0.5, 0.5, 0.5, 1});

        self.solidCount = self.instanceCount - self.charCount;

        self.instanceTransforms.push();
        self.colorTransforms.push();
        self.textureIndices.push();

        return true;
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

const ArgumentKind = enum(u8) {
    Path,
    Buffer,
    None,
};

const CommandEndKind = enum(u8) {
    Function,
    SubCommands,
};

const CmdFn = *const fn (*Painter, *std.mem.SplitIterator(u8, .sequence)) bool;

const CommandEnd = union(CommandEndKind) {
    Function: CmdFn,
    SubCommands: []const Command,
};

const Command = struct {
    name: []const u8,
    end: CommandEnd,
    argumentKind: ArgumentKind,

    fn withFunction(name: []const u8, argumentKind: ArgumentKind, f: CmdFn) Command {
        return .{
            .name = name,
            .argumentKind = argumentKind,
            .end = .{
                .Function = f,
            },
        };
    }

    fn withSubCommands(name: []const u8, subcommands: []const Command, allocator: Allocator) error{OutOfMemory}!Command {
        const subs = try allocator.alloc(Command, subcommands.len);
        @memcpy(subs, subcommands);

        return .{
            .name = name,
            .argumentKind = .None,
            .end = .{
                .SubCommands = subs,
            },
        };
    }
};

const CommandHandler = struct {
    commands: ArrayList(Command),
    candidates: ArrayList([]const u8),
    index: ?u32,

    context: *Painter,

    fn new(context: *Painter, commands: []const Command, allocator: Allocator) error{OutOfMemory}!CommandHandler {
        var self: CommandHandler = undefined;

        self.context = context;
        self.candidates = try ArrayList([]const u8).initCapacity(allocator, commands.len);
        self.commands = try ArrayList(Command).initCapacity(allocator, 100);

        try self.commands.appendSlice(commands);
        self.index = null;

        return self;
    }

    fn updateCandidates(self: *CommandHandler, list: ?[]const Command, iter: *std.mem.SplitIterator(u8, .sequence)) error{OutOfMemory}!void {
        self.reset();

        const command = iter.next() orelse return;
        const commands = list orelse self.commands.items;

        for (commands) |cmd| {
            if (std.mem.startsWith(u8, cmd.name, command)) {
                if (try self.includeCommand(cmd, iter)) break;
            }
        }
    }

    fn includeCommand(self: *CommandHandler, cmd: Command, iter: *std.mem.SplitIterator(u8, .sequence)) error{OutOfMemory}!bool {
        switch (cmd.end) {
            .Function => {
                const argument = iter.next() orelse {
                    try self.candidates.append(cmd.name);

                    return false;
                };

                try self.matchArgument(cmd, argument);

                return true;
            },
            .SubCommands => |cmds| {
                _ = iter.peek() orelse {
                    try self.candidates.append(cmd.name);

                    return false;
                };

                try self.updateCandidates(cmds, iter);

                return true;
            }
        }
    }

    fn matchArgument(self: *CommandHandler, cmd: Command, argument: []const u8) error{OutOfMemory}!void {
        switch (cmd.argumentKind) {
            .Path => {
                var dirPath: []const u8 = argument[0..0];
                var filePath: []const u8 = argument[0..];

                for (0..argument.len) |i| {
                    if (argument[argument.len - i - 1] == '/') {
                        filePath = argument[argument.len - i..];
                        dirPath = argument[0..argument.len - i - 1];

                        break;
                    }
                }

                var dir = std.fs.cwd();
                var relativeDirPath: [100]u8 = [_]u8{'.', '/'} ++ ([_]u8{' '} ** 98);

                for (0..dirPath.len) |i| {
                    relativeDirPath[i + 2] = dirPath[i];
                }

                dir = dir.openDir(relativeDirPath[0..dirPath.len + 2], .{.iterate = true}) catch |e| {
                    std.log.err("{s} failed {}", .{relativeDirPath[0..dirPath.len + 2], e});
                    return;
                };

                defer dir.close();

                var iter = dir.iterate();
                while (iter.next() catch return) |path| {
                    if (std.mem.startsWith(u8, path.name, filePath)) {
                        try self.candidates.append(path.name);
                    }
                }
            },
            .Buffer => {
                var buffer = self.context.textBuffers.first;

                while (buffer) |b| {
                    if (std.mem.startsWith(u8, b.data.name[0..b.data.nameLen], argument)) {
                        try self.candidates.append(b.data.name[0..b.data.nameLen]);
                    }

                    buffer = b.next;
                }
            },
            .None => {}
        }
    }

    fn getCommandFunction(self: *const CommandHandler, list: ?[]const Command, iter: *std.mem.SplitIterator(u8, .sequence)) ?CmdFn {
        const command = iter.next() orelse return null;
        const commands = list orelse self.commands.items;

        for (commands) |cmd| {
            if (std.mem.startsWith(u8, cmd.name, command)) {
                switch (cmd.end) {
                    .SubCommands => |cmds| return self.getCommandFunction(cmds, iter),
                    .Function => |f| return f,
                }
            }
        }

        return null;
    }

    fn reset(self: *CommandHandler) void {
        self.candidates.clearRetainingCapacity();
        self.index = null;
    }
};

fn editBufferCommand(painter: *Painter, it: *std.mem.SplitIterator(u8, .sequence)) bool {
    const argument_value = it.next() orelse {
        std.log.err("missing argument in edit command", .{});
        return false;
    };

    var buffer = painter.textBuffers.first;

    while (buffer) |b| {
        if (std.mem.eql(u8, b.data.name[0..b.data.nameLen], argument_value)) {
            painter.textBuffers.remove(b);
            painter.textBuffers.append(b);

            return true;
        }

        buffer = b.next;
    }

    return false;
}

fn editFileCommand(painter: *Painter, it: *std.mem.SplitIterator(u8, .sequence)) bool {
    const startIndex = it.index;

    if (editBufferCommand(painter, it)) return true;

    it.index = startIndex;

    const argument_value = it.next() orelse {
        std.log.err("missing argument in edit command", .{});
        return false;
    };

    const nextTextBuffer = painter.allocator.allocator().create(LinesNode) catch {
        std.log.err("Out Of memory when opening: {s}", .{argument_value});
        return false;
    };

    nextTextBuffer.data.fromFile(&painter.freePool, argument_value) catch |e| {
        painter.allocator.allocator().destroy(nextTextBuffer);

        std.log.err("Open file: {s}, {}", .{argument_value, e});

        return false;
    };

    painter.textBuffers.append(nextTextBuffer);

    return true;
}
