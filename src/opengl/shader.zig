const std = @import("std");
const gl = @import("zgl");
const texture = @import("texture.zig");

const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const Mesh = @import("mesh.zig").Mesh;

pub const TextureInfo = texture.Texture.Info;

const Texture = texture.Texture;

pub const Uniform = struct {
    loc: ?u32,
    variant: Variant,

    const Variant = enum(u32) { i1, f1, f2, f3, f4, mat2, mat4 };

    pub fn update(self: *Uniform, comptime variant: Variant, data: getType(variant)) void {
        std.debug.assert(self.variant == variant);

        switch (variant) {
            .i1 => gl.uniform1i(self.loc, data),
            .f1 => gl.uniform1f(self.loc, data),
            .f2 => gl.uniform2f(self.loc, data[0], data[1]),
            .f3 => gl.uniform3f(self.loc, data[0], data[1], data[2]),
            .f4 => gl.uniform4f(self.loc, data[0], data[1], data[2], data[3]),
            .mat2 => gl.uniformMatrix2fv(self.loc, false, &.{data}),
            .mat4 => gl.uniformMatrix4fv(self.loc, false, &.{data}),
        }
    }

    fn getType(comptime variant: Variant) type {
        return switch (variant) {
            .i1 => i32,
            .f1 => f32,
            .f2 => [2]f32,
            .f3 => [3]f32,
            .f4 => [4]f32,
            .mat2 => [2][2]f32,
            .mat4 => [4][4]f32,
        };
    }
};

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

        self.allocator = FixedBufferAllocator.init(try allocator.alloc(u8, 2 * 1024));
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
    ) error{OutOfMemory}!*Mesh {
        const alloc = self.allocator.allocator();

        const mesh = try alloc.create(Mesh);
        try mesh.init(T, vertices, indices, alloc);

        return mesh;
    }

    pub fn newUniform(
        self: *Program,
        name: [:0]const u8,
        variant: Uniform.Variant,
    ) error{ OutOfMemory, NotFound }!*Uniform {
        const loc = self.handle.uniformLocation(name) orelse return error.NotFound;

        const uniform = try self.allocator.allocator().create(Uniform);

        uniform.variant = variant;
        uniform.loc = loc;

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
