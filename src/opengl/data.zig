const std = @import("std");
const gl = @import("zgl");

const c = @cImport({
    @cInclude("stb/stb_image.h");
});

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const TextureHandler = struct {
    textures: ArrayList(Texture),

    const Texture = struct {
        name: [:0]const u8,
        handle: gl.Texture,
        width: u32,
        height: u32,
        channels: u32,
        data: [*]u8,

        fn new(path: [:0]const u8, name: [:0]const u8, index: usize) Texture {
            var self: Texture = undefined;

            self.name = name;

            var width: i32 = undefined;
            var height: i32 = undefined;
            var channels: i32 = undefined;

            self.handle = gl.genTexture();

            self.data = c.stbi_load(path, &width, &height, &channels, 0);
            defer c.stbi_image_free(self.data);

            self.width = @intCast(width);
            self.height = @intCast(height);
            self.channels = @intCast(channels);

            gl.activeTexture(@enumFromInt(index + @intFromEnum(gl.TextureUnit.texture_0)));
            self.handle.bind(.@"2d");

            gl.texParameter(.@"2d", .wrap_s, .mirrored_repeat);
            gl.texParameter(.@"2d", .wrap_t, .mirrored_repeat);
            gl.texParameter(.@"2d", .min_filter, .nearest_mipmap_nearest);
            gl.texParameter(.@"2d", .mag_filter, .nearest);

            const inputMode: gl.PixelFormat = switch (self.channels) {
                3 => .rgb,
                4 => .rgba,
                else => @panic("color mode not supported")
            };

            gl.textureImage2D(.@"2d", 0, .rgb, self.width, self.height, inputMode, .unsigned_byte, self.data);
            gl.generateMipmap(.@"2d");

            return self;
        }
    };

    fn new(infos: []const TextureInfo, allocator: Allocator) error{OutOfMemory}!TextureHandler {
        var self: TextureHandler = undefined;

        self.textures = ArrayList(Texture).initCapacity(allocator, infos.len) catch return error.OutOfMemory;

        for (infos, 0..) |info, i| {
            self.textures.append(Texture.new(info.path, info.name, i)) catch return error.OutOfMemory;
        }

        return self;
    }
};

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
pub const TextureInfo = struct {
    name: [:0]const u8,
    path: [:0]const u8,
};

pub const Data = struct {
    array: gl.VertexArray,
    vertex: gl.Buffer,
    index: gl.Buffer,

    uniforms: UniformMap,
    textureHandler: TextureHandler,

    size: usize,

    pub fn new(
        comptime T: type,
        vertices: []const T,
        indices: []const u32,
        uniforms: []const [:0]const u8,
        textureInfos: []const TextureInfo,
        allocator: Allocator,
    ) error{OutOfMemory}!Data {
        var self: Data = undefined;

        self.array = gl.VertexArray.create();
        self.array.bind();

        var buffers: [2]gl.Buffer = undefined;
        gl.genBuffers(&buffers);

        self.vertex = buffers[0];
        self.vertex.bind(.array_buffer);
        self.vertex.data(T, vertices, .static_draw);

        inline for (@typeInfo(T).Struct.fields, 0..) |field, i| {
            var size: u32 = 1;
            const t = getType(field.type, &size);

            gl.vertexAttribPointer(i, size, t, false, @sizeOf(T), @offsetOf(T, field.name));
            gl.enableVertexAttribArray(i);
        }

        self.index = buffers[1];
        self.index.bind(.element_array_buffer);
        self.index.data(u32, indices, .static_draw);

        self.textureHandler = try TextureHandler.new(textureInfos, allocator);

        gl.bindVertexArray(@enumFromInt(0));

        self.uniforms = UniformMap.init(allocator);
        self.uniforms.ensureTotalCapacity(uniforms.len + textureInfos.len + 5) catch return error.OutOfMemory;

        for (uniforms) |name| {
            self.uniforms.put(name, .{.loc = null }) catch return error.OutOfMemory;
        }

        self.size = indices.len;

        return self;
    }

    pub fn resolveUniforms(self: *Data, program: gl.Program) error{OutOfMemory, NotFound}!void {
        program.use();

        var iter = self.uniforms.iterator();

        while (iter.next()) |entry| {
            entry.value_ptr.loc = program.uniformLocation(entry.key_ptr.*);
        }

        for (self.textureHandler.textures.items, 0..) |texture, i| {
            self.uniforms.put(texture.name, .{.loc = program.uniformLocation(texture.name)}) catch return error.OutOfMemory;

            try self.setUniform(.i1, texture.name, @intCast(i));
        }
    }

    fn setUniform(self: *Data, comptime variant: Uniform.Variant, name: [:0]const u8, data: Uniform.getType(variant)) error{NotFound}!void {
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


    fn getGlType(comptime T: type) gl.Type {
        return switch (@typeInfo(T)) {
            .Float => |f| switch (f.bits) {
                32 => return .float,
                64 => return .double,
                else => {
                    unreachable;
                },
            },
            .Int => |i| {
                if (i.bits > 32) @panic("Integer greater than 32 bits");
                if (i.signedness == .signed) return .int;
                return .unsigned_int;
            },
            else => @panic("Gl Type not supported"),
        };
    }

    fn getType(comptime T: type, size: *u32) gl.Type {
        switch (@typeInfo(T)) {
            .Float, .Int => return getGlType(T),
            .Array => |a| {
                size.* *= a.len;
                return getType(a.child, size);
            },
            else => @panic("Not supported"),
        }
    }

    pub fn use(self: *Data) void {
        self.array.bind();
        gl.drawElements(.triangles, self.size, .unsigned_int, 0);
        gl.bindVertexArray(@enumFromInt(0));
    }

    pub fn deinit(self: *const Data) void {
        self.vertex.delete();
        self.index.delete();
        self.array.delete();
    }
};
