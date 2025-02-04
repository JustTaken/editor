const std = @import("std");
const gl = @import("zgl");
const texture = @import("texture.zig");

const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const Mesh = @import("mesh.zig").Mesh;

pub const TextureInfo = texture.Texture.Info;

const Texture = texture.Texture;

const GroupType = @import("../math.zig").GroupType;

pub const Uniform = struct {
    loc: u32,
    groupType: GroupType,
    size: u32,

    pub fn init(self: *Uniform, loc: u32, groupType: GroupType, size: u32) void {
        self.loc = loc;
        self.groupType = groupType;
        self.size = size;
    }

    pub fn update(self: *Uniform, data: anytype) void {
        const T = @TypeOf(data);
        const dataType = T.groupType();
        const dataSize = T.size();

        if (dataSize != self.size) {
            std.log.err("Data size differ to the instanciated uniform", .{});
        }

        if (dataType != self.groupType) {
            std.log.err("Data type differ to the instanciated uniform", .{});
        }

        switch (dataType) {
            .MatrixF32 => {
                switch (dataSize) {
                    4 => gl.uniformMatrix4fv(self.loc, false, &.{data.value()}),
                    else => unreachable,
                }
            },
            .VecF32 => {
                const v: [*]const f32 = @ptrCast(@alignCast(&data.value()));

                switch (dataSize) {

                    1 => gl.uniform1f(self.loc, v[0]),
                    2 => gl.uniform2f(self.loc, v[0], v[1]),
                    3 => gl.uniform3f(self.loc, v[0], v[1], v[2]),
                    4 => gl.uniform4f(self.loc, v[0], v[1], v[2], v[3]),
                    else => unreachable,
                }
            },
        }
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
        groupType: GroupType,
        size: u32,
    ) error{ OutOfMemory, NotFound }!*Uniform {
        const loc = self.handle.uniformLocation(name) orelse return error.NotFound;

        const uniform = try self.allocator.allocator().create(Uniform);

        uniform.init(loc, groupType, size);

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
