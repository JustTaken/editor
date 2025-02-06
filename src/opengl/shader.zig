const std = @import("std");
const gl = @import("zgl");
const texture = @import("texture.zig");
const math = @import("../math.zig");

const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const ArrayList = std.ArrayList;

const Mesh = @import("mesh.zig").Mesh;
const Matrix = @import("../math.zig").Matrix;

const Texture = texture.Texture;
pub const TextureInfo = texture.Texture.Info;

const GroupType = math.GroupType;

pub const Uniform = struct {
    handle: gl.Buffer,
    loc: u32,

    pub fn pushData(self: *Uniform, comptime T: type, data: []const T, offset: u32) void {
        gl.bindBuffer(self.handle, .uniform_buffer);
        gl.bufferSubData(.uniform_buffer, offset * @sizeOf(T), T, data);
        gl.bindBuffer(gl.Buffer.invalid, .uniform_buffer);
    }

    pub fn init(self: *Uniform, comptime T: type, data: []const T, loc: u32) void {
        self.handle = gl.Buffer.gen();
        self.loc = loc;

        gl.bindBuffer(self.handle, .uniform_buffer);
        gl.bufferData(.uniform_buffer, T, data, .dynamic_draw);
        gl.bindBufferBase(.uniform_buffer, self.loc, self.handle);
        gl.bindBuffer(gl.Buffer.invalid, .uniform_buffer);
    }

    pub fn deinit(self: *Uniform) void {
        self.handle.delete();
    }
};

pub const Program = struct {
    handle: gl.Program,

    allocator: FixedBufferAllocator,

    pub fn init(
        self: *Program,
        vertexPath: []const u8,
        fragmentPath: []const u8,
        allocator: Allocator,
    ) error{ Read, Compile, OutOfMemory }!void {
        self.handle = gl.Program.create();

        self.allocator = FixedBufferAllocator.init(try allocator.alloc(u8, 2 * 1024));
        const fixedAllocator = self.allocator.allocator();

        const vertex = try shader(.vertex, vertexPath, fixedAllocator);
        defer vertex.delete();

        self.handle.attach(vertex);

        const fragment = try shader(.fragment, fragmentPath, fixedAllocator);
        defer fragment.delete();

        self.handle.attach(fragment);

        self.handle.link();
    }

    pub fn draw(self: *Program, meshs: []const *Mesh) void {
        gl.useProgram(self.handle);

        for (meshs) |mesh| {
            mesh.draw();
        }

        gl.useProgram(gl.Program.invalid);
    }

    pub fn newTexture(
        self: *Program,
        name: [:0]const u8,
        path: [:0]const u8,
    ) error{ OutOfMemory, NotFound }!*Texture {
        const loc = self.handle.uniformLocation(name) orelse return error.NotFound;

        const tex = try self.allocator.allocator().create(Texture);
        tex.init(path, name, loc);

        return tex;
    }

    pub fn newMesh(
        self: *Program,
        comptime T: type,
        vertices: []const T,
        indices: []const u32,
        maxInstances: u32,
    ) error{OutOfMemory}!*Mesh {
        const alloc = self.allocator.allocator();

        const mesh = try alloc.create(Mesh);
        try mesh.init(T, self, vertices, indices, maxInstances, alloc);

        return mesh;
    }

    pub fn newUniformBlock(
        self: *Program,
        name: [:0]const u8,
        comptime T: type,
        data: []const T,
    ) error{ OutOfMemory, NotFound }!*Uniform {
        const loc = self.handle.uniformBlockIndex(name) orelse return error.NotFound;

        const uniform = try self.allocator.allocator().create(Uniform);
        uniform.init(T, data, loc);

        return uniform;
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
