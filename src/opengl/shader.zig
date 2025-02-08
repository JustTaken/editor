const std = @import("std");
const gl = @import("zgl");
const texture = @import("texture.zig");

const c = @cImport({
    @cInclude("stb/stb_image.h");
});

const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const Mesh = @import("mesh.zig").Mesh;
const Buffer = @import("buffer.zig").Buffer;

const Texture = texture.Texture;
pub const TextureInfo = texture.Texture.Info;

pub const Program = struct {
    handle: gl.Program,

    allocator: FixedBufferAllocator,

    pub fn new(
        vertexPath: []const u8,
        fragmentPath: []const u8,
        allocator: Allocator,
    ) error{ Read, Compile, OutOfMemory }!Program {
        var self: Program = undefined;
        self.handle = gl.Program.create();

        self.allocator = FixedBufferAllocator.init(try allocator.alloc(u8, 2 * std.mem.page_size));
        const fixedAllocator = self.allocator.allocator();

        const vertex = try shader(.vertex, vertexPath, fixedAllocator);
        defer vertex.delete();

        self.handle.attach(vertex);

        const fragment = try shader(.fragment, fragmentPath, fixedAllocator);
        defer fragment.delete();

        self.handle.attach(fragment);

        self.handle.link();

        return self;
    }

    pub fn start(self: *Program) void {
        gl.useProgram(self.handle);
    }

    pub fn end(_: *Program) void {
        gl.useProgram(gl.Program.invalid);
    }

    pub fn newTexture(_: *Program, width: u32, height: u32, channels: u32, format: gl.TextureInternalFormat, data: [*]u8) Texture {
        return Texture.new(width, height, channels, format, data);
    }

    pub fn newTextureFromPath(_: *Program, path: [:0]const u8, format: gl.TextureInternalFormat) Texture {
        var width: i32 = 0;
        var height: i32 = 0;
        var channels: i32 = 0;

        const data = c.stbi_load(path, &width, &height, &channels, 0);
        defer c.stbi_image_free(data);

        return Texture.new(@intCast(width), @intCast(height), @intCast(channels), format, data);
    }

    pub fn uniformLocation(self: *Program, name: [:0]const u8) error{NotFound}!u32 {
        return self.handle.uniformLocation(name) orelse return error.NotFound;
    }

    pub fn newMesh(
        self: *Program,
        path: []const u8,
    ) error{ OutOfMemory, Read }!Mesh {
        return try Mesh.new(path, self.allocator.allocator());
    }

    pub fn newBuffer(
        _: *Program,
        comptime T: type,
        comptime N: u32,
        kind: gl.BufferTarget,
        usage: gl.BufferUsage,
        data: [N]T,
    ) error{OutOfMemory}!Buffer(T, N) {
        return Buffer(T, N).new(kind, usage, data);
    }

    pub fn deinit(self: *const Program) void {
        self.handle.delete();
    }
};

fn shader(kind: gl.ShaderType, path: []const u8, allocator: Allocator) error{ Read, Compile, OutOfMemory }!gl.Shader {
    const buffer = try allocator.alloc(u8, 1024);
    defer allocator.free(buffer);

    const source = std.fs.cwd().readFile(path, buffer) catch return error.Read;

    const self = gl.Shader.create(kind);

    self.source(1, &source);
    self.compile();

    if (0 == self.get(.compile_status)) {
        const result = try self.getCompileLog(allocator);
        std.debug.print("error: {s}\n", .{result});

        return error.Compile;
    }

    return self;
}
