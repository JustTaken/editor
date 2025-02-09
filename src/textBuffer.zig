const std = @import("std");
const font = @import("font.zig");
const lib = @import("root.zig");
const math = @import("math.zig");
const input = @import("input.zig");

const FreeType = font.FreeType;
const Char = font.Char;
const Map = std.AutoArrayHashMap;
const Allocator = std.mem.Allocator;
const EnumSet = std.EnumSet;

const Texture = lib.Texture;
const Buffer = lib.Buffer;
const Mesh = lib.Mesh;

const Matrix = math.Matrix;
const Vec = math.Vec;

const MAX_CHAR_INSTANCES: u32 = 128;
const MAX_TOTAL_INSTANCES: u32 = 1024;

const IDENTITY = Matrix(4).identity();

const Input = input.Xkbcommon;
const Key = input.Key;

const VELOCITY: f32 = 1.0;

const INSTANCE_MODEL_LOCATION: u32 = 0;
const INDEX_MODEL_LOCATION: u32 = 1;

pub const TextBuffer = struct {
    font: FreeType,
    chars: Map(u32, CharSet),
    rectangle: Mesh,

    texture: Texture,

    indexToInstances: Buffer(u32),
    instanceTransforms: Buffer(Matrix(4)),
    instanceCount: u32,
    instanceMax: u32,

    textureLocation: u32,

    cursorX: f32,
    cursorY: f32,

    charCount: u16,
    charMax: u32,
    size: u16,

    const CharSet = struct {
        textureId: ?u16,
        advance: u16,
        bearing: [2]i32,
    };

    pub fn new(
        size: u16,
        instanceMax: u32,
        charMax: u32,
        textureLocation: u32,
        allocator: Allocator,
    ) error{ Init, Read, OutOfMemory }!TextBuffer {
        var self: TextBuffer = undefined;

        self.instanceTransforms = Buffer(Matrix(4)).new(.shader_storage_buffer, instanceMax, null);
        self.indexToInstances = Buffer(u32).new(.shader_storage_buffer, instanceMax, null);
        self.texture = Texture.new(size, size, charMax, .r8, .red, .unsigned_byte, .@"2d_array", null);
        self.rectangle = try Mesh.new("assets/plane.obj", allocator);

        self.textureLocation = textureLocation;
        self.size = size;
        self.instanceMax = instanceMax;
        self.charMax = charMax;

        self.cursorX = 0;
        self.cursorY = 0;
        self.instanceCount = 0;
        self.charCount = 0;

        self.font = try FreeType.new("assets/font.ttf", size);
        self.chars = Map(u32, CharSet).init(allocator);
        try self.chars.ensureTotalCapacity(charMax * 2);

        std.log.info("Font height: {}, self size: {}", .{self.font.height, self.size});

        return self;
    }

    pub fn listen(ptr: *anyopaque, keys: *EnumSet(Key), controlActive: bool, altActive: bool) void {
        const self: *TextBuffer = @ptrCast(@alignCast(ptr));

        if (controlActive or altActive) self.processWithModifiers(keys, controlActive, altActive) else self.processKeys(keys);
    }

    fn processKeys(self: *TextBuffer, keys: *EnumSet(Key)) void {
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
            },
            else => return,
        }
    }

    fn processWithModifiers(self: *TextBuffer, keys: *EnumSet(Key), controlActive: bool, altActive: bool) void {
        _ = self;
        _ = keys;
        _ = controlActive;
        _ = altActive;
    }

    fn newCharSet(self: *TextBuffer, set: *CharSet, code: u32) error{ CharNotFound, Max }!void {
        set.textureId = null;

        if (self.charCount >= self.charMax) {
            std.log.err("Max number of chars", .{});

            return error.Max;
        }

        const index = self.charCount;

        const char = try self.font.findChar(code);

        if (char.buffer) |b| {
            self.charCount += 1;
            self.texture.pushData(char.width, char.height, index, .red, .unsigned_byte, b);
            set.textureId = index;
        }

        set.advance = @intCast(char.advance);
        set.bearing = char.bearing;
    }

    fn addInstance(self: *TextBuffer, set: *CharSet) error{Max}!void {
        if (self.instanceCount >= self.instanceMax) {
            std.log.err("Maximun number of instances", .{});
            return error.Max;
        }

        const index = self.instanceCount;

        if (set.textureId) |id| {
            const deltaX: f32 = @floatFromInt(set.bearing[0] * 2);
            const deltaY: f32 = @floatFromInt((self.size - set.bearing[1]) * 2);

            self.indexToInstances.pushData(index, &.{id});
            self.instanceTransforms.pushData(index, &.{IDENTITY.translate(.{ self.cursorX + deltaX, self.cursorY - deltaY, 0 })});
            self.instanceCount += 1;
        }

        self.cursorX += @floatFromInt(set.advance >> 5);
    }

    pub fn draw(self: *TextBuffer) void {
        if (self.instanceCount == 0) return;

        self.texture.bind(self.textureLocation, 0);
        self.instanceTransforms.bind(INSTANCE_MODEL_LOCATION);
        self.indexToInstances.bind(INDEX_MODEL_LOCATION);
        self.rectangle.draw(0, self.instanceCount);
    }

    pub fn deinit(self: *const TextBuffer) void {
        self.instanceTransforms.deinit();
        self.indexToInstances.deinit();
        self.texture.deinit();
        self.rectangle.deinit();
    }
};
