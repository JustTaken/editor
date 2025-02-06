const std = @import("std");
const gl = @import("zgl");
const texture = @import("texture.zig");
const math = @import("../math.zig");

const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const ArrayList = std.ArrayList;

const Mesh = @import("mesh.zig").Mesh;
const Matrix = @import("../math.zig").Matrix;
const Uniform = @import("uniform.zig").Uniform;

const Texture = texture.Texture;
pub const TextureInfo = texture.Texture.Info;

const GroupType = math.GroupType;

pub const Program = struct {
    handle: gl.Program,

    unboundTextures: ArrayList(*Texture),
    boundTextures: ArrayList(*Texture),

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

        self.boundTextures = try ArrayList(*Texture).initCapacity(fixedAllocator, 2);
        self.unboundTextures = try ArrayList(*Texture).initCapacity(fixedAllocator, 2);

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

        for (0..self.unboundTextures.items.len) |_| {
            const index: u32 = @intCast(self.boundTextures.items.len);
            const tex = self.unboundTextures.pop();

            gl.bindTextureUnit(tex.handle, index);
            gl.uniform1i(tex.loc, @intCast(index));

            self.boundTextures.append(tex) catch @panic("TODO");
        }

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

        try self.unboundTextures.append(tex);

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
        comptime N: u32,
        data: [N]T,
    ) error{ OutOfMemory, NotFound }!*Uniform(T, N) {
        const loc = self.handle.uniformBlockIndex(name) orelse return error.NotFound;

        const uniform = try self.allocator.allocator().create(Uniform(T, N));
        uniform.init(data, loc);

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
