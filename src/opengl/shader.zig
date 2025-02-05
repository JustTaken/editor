const std = @import("std");
const gl = @import("zgl");
const texture = @import("texture.zig");
const math = @import("../math.zig");

const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const ArrayList = std.ArrayList;

const Mesh = @import("mesh.zig").Mesh;

const Texture = texture.Texture;
pub const TextureInfo = texture.Texture.Info;

const GroupType = math.GroupType;

pub const Uniform = struct {
    program: *Program,
    loc: u32,
    size: u32,
    groupType: GroupType,
    isUpdated: bool,

    data: [16]f32,

    pub fn init(self: *Uniform, program: *Program, loc: u32, groupType: GroupType, size: u32) void {
        self.program = program;
        self.loc = loc;
        self.groupType = groupType;
        self.size = size;
        self.isUpdated = true;
    }

    pub fn pushData(self: *Uniform, data: anytype) void {
        const T = @TypeOf(data);
        const dataType = T.groupType();
        const dataSize = T.size();

        if (dataSize != self.size) {
            std.log.err("Data size differ to the instanciated uniform", .{});
        }

        if (dataType != self.groupType) {
            std.log.err("Data type differ to the instanciated uniform", .{});
        }

        const selfData: *@TypeOf(data) = @ptrCast(@alignCast(&self.data));
        selfData.* = data;

        self.configure();
    }

    fn configure(self: *Uniform) void {
        if (!self.isUpdated) return;

        self.isUpdated = false;
        self.program.uniformUpdates.append(self) catch @panic("Increase total memory?");
    }

    pub fn update(self: *Uniform) void {
        switch (self.groupType) {
            .MatrixF32 => {
                switch (self.size) {
                    4 => gl.uniformMatrix4fv(self.loc, false, &.{@bitCast(self.data)}),
                    else => unreachable,
                }
            },
            .VecF32 => {
                const v: [*]const f32 = @ptrCast(@alignCast(&self.data));

                switch (self.size) {
                    1 => gl.uniform1f(self.loc, v[0]),
                    2 => gl.uniform2f(self.loc, v[0], v[1]),
                    3 => gl.uniform3f(self.loc, v[0], v[1], v[2]),
                    4 => gl.uniform4f(self.loc, v[0], v[1], v[2], v[3]),
                    else => unreachable,
                }
            },
        }

        self.isUpdated = true;
    }
};

pub const Program = struct {
    handle: gl.Program,

    uniformUpdates: ArrayList(*Uniform),
    meshUpdates: ArrayList(*Mesh),

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

        self.uniformUpdates = try ArrayList(*Uniform).initCapacity(fixedAllocator, 10);
        self.meshUpdates = try ArrayList(*Mesh).initCapacity(fixedAllocator, 10);

        const vertex = try shader(.vertex, vertexPath, fixedAllocator);
        defer vertex.delete();

        self.handle.attach(vertex);

        const fragment = try shader(.fragment, fragmentPath, fixedAllocator);
        defer fragment.delete();

        self.handle.attach(fragment);

        self.handle.link();

        return self;
    }

    pub fn draw(self: *Program, meshs: []const *Mesh) void {
        gl.useProgram(self.handle);

        const uniformLen = self.uniformUpdates.items.len;
        for (0..uniformLen) |_| {
            self.uniformUpdates.pop().update();
        }

        const meshLen = self.meshUpdates.items.len;
        for (0..meshLen) |_| {
            self.meshUpdates.pop().update();
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
        try mesh.init(T, self, vertices, indices, alloc);

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

        uniform.init(self, loc, groupType, size);

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
