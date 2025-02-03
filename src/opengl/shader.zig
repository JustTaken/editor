const std = @import("std");
const gl = @import("zgl");
const texture = @import("texture.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Data = @import("data.zig").Data;

const TextureHandler = texture.TextureHandler;
const TextureInfo = texture.Texture.Info;

pub const Uniform = struct {
    loc: ?u32,

    const Variant = enum(u32) {
        i1,
        f1,
        f2,
        f3,
        f4,
        mat4
    };

    fn getType(comptime variant: Variant) type {
        return switch (variant) {
            .i1 => i32,
            .f1 => f32,
            .f2 => [2]f32,
            .f3 => [3]f32,
            .f4 => [4]f32,
            .mat4 => [4][4]f32,
        };
    }
};

const UniformMap = std.ArrayHashMap([:0]const u8, Uniform, std.array_hash_map.StringContext, true);

pub const Program = struct {
    handle: gl.Program,
    uniforms: UniformMap,
    textureHandler: TextureHandler,

    data: Data,

    pub fn new(
        comptime T: type,
        vertices: []const T,
        indices: []const u32,
        uniforms: []const [:0]const u8,
        textureInfos: []const TextureInfo,
        shaderPaths: [2][]const u8,
        allocator: Allocator,
    ) error{ Read, Compile, NotFound, OutOfMemory }!Program {
        var self: Program = undefined;

        self.handle = gl.Program.create();

        const vertex = try shader(.vertex, shaderPaths[0], allocator);
        defer vertex.delete();

        self.handle.attach(vertex);

        const fragment = try shader(.fragment, shaderPaths[1], allocator);
        defer fragment.delete();

        self.handle.attach(fragment);

        self.handle.link();

        self.data = try Data.new(T, vertices, indices, allocator);

        const locs = try allocator.alloc(u32, textureInfos.len);

        for (textureInfos, 0..) |info, i| {
            locs[i] = self.handle.uniformLocation(info.name) orelse return error.NotFound;
        }

        self.textureHandler = try TextureHandler.new(textureInfos, locs, allocator);

        self.uniforms = UniformMap.init(allocator);
        self.uniforms.ensureTotalCapacity(uniforms.len + 5) catch return error.OutOfMemory;

        for (uniforms) |name| {
            self.uniforms.put(name, .{ .loc = self.handle.uniformLocation(name) }) catch return error.OutOfMemory;
        }

        return self;
    }

    fn setUniform(self: *Program, comptime variant: Uniform.Variant, name: [:0]const u8, data: Uniform.getType(variant)) error{NotFound}!void {
        const uniform = self.uniforms.get(name) orelse return error.NotFound;

        if (uniform.loc) |loc| {
            switch (variant) {
                .i1 => gl.uniform1i(loc, data),
                .f1 => gl.uniform1f(loc, data),
                .f2 => gl.uniform2f(loc, data[0], data[1]),
                .f3 => gl.uniform3f(loc, data[0], data[1], data[2]),
                .f4 => gl.uniform4f(loc, data[0], data[1], data[2], data[3]),
                .mat4 => gl.uniform4fv(loc, &data),
            }
        } else @panic("Uniform does not have location");
    }

    fn shader(kind: gl.ShaderType, path: []const u8, allocator: Allocator) error{ Read, Compile, OutOfMemory }!gl.Shader {
        const buffer = try allocator.alloc(u8, 1024);
        defer allocator.free(buffer);

        const source = std.fs.cwd().readFile(path, buffer) catch return error.Read;

        const self = gl.Shader.create(kind);

        self.source(1, &source);
        self.compile();

        if (0 == self.get(.compile_status)) {
            const result = self.getCompileLog(allocator) catch return error.OutOfMemory;
            std.debug.print("error: {s}\n", .{result});

            return error.Compile;
        }

        return self;
    }

    pub fn record(self: *Program) void {
        gl.useProgram(self.handle);

        self.handle.use();
        self.data.startRecord();

        self.data.bindVertex();
        self.data.bindIndex();
        self.data.bindTextures(self.textureHandler.textures.items);

        self.data.stopRecord();

        gl.useProgram(@enumFromInt(0));
    }

    pub fn draw(self: *Program) void {
        self.handle.use();
        self.data.use();
    }

    pub fn deinit(self: *const Program) void {
        self.data.deinit();
        self.handle.delete();
    }
};
