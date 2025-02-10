const std = @import("std");
const font = @import("font.zig");
const lib = @import("root.zig");
const math = @import("math.zig");
const input = @import("input.zig");

const Map = std.AutoArrayHashMap;
const Allocator = std.mem.Allocator;
const EnumSet = std.EnumSet;

const Texture = lib.Texture;
const Buffer = lib.Buffer;
const Mesh = lib.Mesh;

const FreeType = font.FreeType;
const Char = font.Char;

const Matrix = math.Matrix;

const Key = input.Key;

const IDENTITY = Matrix(4).identity();

const VELOCITY: f32 = 1.0;

pub const TextBuffer = struct {
    font: FreeType,
    chars: Map(u32, CharSet),
    rectangle: Mesh,

    instances: Buffer(Matrix(4)).Slice,
    textureIndices: Buffer(u32).Slice,
    texture: Texture,

    instanceCount: u32,
    instanceMax: u32,

    textureLocation: u32,

    cursorTransform: Matrix(4),
    cursorX: f32,
    cursorY: f32,
    cursorIndex: u32,

    textureCount: u16,
    textureMax: u32,
    size: u16,

    change: bool,

    const CharSet = struct {
        textureId: ?u16,
        advance: u16,
        bearing: [2]i32,
    };

    pub fn new(
        comptime size: u16,
        instanceMax: u32,
        textureMax: u32,
        textureLocation: u32,
        instances: *Buffer(Matrix(4)),
        textureIndices: *Buffer(u32),
        allocator: Allocator,
    ) error{ Init, Read, OutOfMemory }!TextBuffer {
        var self: TextBuffer = undefined;

        const overSize = size + 2;
        self.texture = Texture.new(overSize, overSize, textureMax, .r8, .red, .unsigned_byte, .@"2d_array", null);

        self.instances = try instances.getSlice(instanceMax);
        self.textureIndices = try textureIndices.getSlice(instanceMax);

        self.size = overSize;
        self.textureLocation = textureLocation;
        self.instanceMax = instanceMax;
        self.textureMax = textureMax;

        self.cursorX = 0;
        self.cursorY = 0;
        self.instanceCount = 0;
        self.textureCount = 0;
        self.cursorIndex = 0;
        self.change = true;

        self.rectangle = try Mesh.new("assets/plane.obj", allocator);
        self.font = try FreeType.new("assets/font.ttf", size);
        self.chars = Map(u32, CharSet).init(allocator);
        try self.chars.ensureTotalCapacity(textureMax * 2);

        self.initCursor();

        return self;
    }

    fn initCursor(self: *TextBuffer) void {
        self.cursorIndex = self.instanceCount;
        self.instanceCount += 1;

        const heightScale = @as(f32, @floatFromInt(self.font.height)) / @as(f32, @floatFromInt(self.size));
        const widthScale = @as(f32, @floatFromInt(self.font.width)) / @as(f32, @floatFromInt(self.size));
        self.cursorTransform = IDENTITY.scale(.{widthScale, heightScale, 1, 1}).translate(.{-@as(f32, @floatFromInt(self.font.width)) / 2.0, 0, 0 });

        self.updateCursor();
    }

    pub fn listen(ptr: *anyopaque, keys: *const EnumSet(Key), controlActive: bool, altActive: bool) void {
        const self: *TextBuffer = @ptrCast(@alignCast(ptr));

        if (controlActive or altActive) self.processWithModifiers(keys, controlActive, altActive) else self.processKeys(keys);
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
                self.cursorY -= @floatFromInt(self.font.height);
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

        if (char.buffer) |b| {
            self.textureCount += 1;
            set.textureId = index;
            self.texture.pushData(char.width, char.height, index, .red, .unsigned_byte, b);
        }

        set.advance = @intCast(char.advance);
        set.bearing = char.bearing;
    }

    fn addInstance(self: *TextBuffer, set: *CharSet) error{Max}!void {
        if (self.instanceCount >= self.instanceMax) {
            std.log.err("Maximun number of instances", .{});
            return error.Max;
        }

        if (set.textureId) |id| {
            const deltaX: f32 = @floatFromInt(set.bearing[0]);
            const deltaY: f32 = @floatFromInt((self.size - set.bearing[1]));

            const index = self.instanceCount;

            self.textureIndices.pushData(index, &.{id});
            self.instanceCount += 1;
            self.instances.pushData(index, &.{IDENTITY.translate(.{ self.cursorX + deltaX, self.cursorY - deltaY, 0 })});
        }

        self.cursorX += @floatFromInt(set.advance >> 6);
        self.updateCursor();
    }

    fn updateCursor(self: *TextBuffer) void {
        self.change = true;
        self.instances.pushData(self.cursorIndex, &.{self.cursorTransform.translate(.{self.cursorX, self.cursorY, 0})});
    }

    pub fn drawChars(self: *TextBuffer) void {
        if (self.instanceCount == 0) return;

        self.texture.bind(self.textureLocation, 0);
        self.rectangle.draw(1, self.instanceCount - 1);
    }

    pub fn drawCursors(self: *TextBuffer) void {
        self.rectangle.draw(self.cursorIndex, 1);
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
