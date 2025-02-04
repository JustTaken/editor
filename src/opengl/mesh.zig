const std = @import("std");
const gl = @import("zgl");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Texture = @import("texture.zig").Texture;

const VertexInfo = struct {
    size: u32,
    typ: gl.Type,
    stride: u32,
    offset: u32,
};

pub const Mesh = struct {
    array: gl.VertexArray,
    vertex: gl.Buffer,
    index: gl.Buffer,

    vertexInfos: []VertexInfo,
    textures: ArrayList(*Texture),

    size: usize,

    pub fn init(
        self: *Mesh,
        comptime T: type,
        vertices: []const T,
        indices: []const u32,
        allocator: Allocator,
    ) error{OutOfMemory}!void {
        self.textures = try ArrayList(*Texture).initCapacity(allocator, 2);
        self.array = gl.genVertexArray();

        var buffers: [2]gl.Buffer = undefined;
        gl.genBuffers(&buffers);

        self.vertex = buffers[0];
        self.vertex.bind(.array_buffer);
        self.vertex.data(T, vertices, .static_draw);

        self.index = buffers[1];
        self.index.bind(.element_array_buffer);
        self.index.data(u32, indices, .static_draw);

        gl.bindBuffer(gl.Buffer.invalid, .array_buffer);
        gl.bindBuffer(gl.Buffer.invalid, .element_array_buffer);

        const fields = @typeInfo(T).Struct.fields;
        self.vertexInfos = try allocator.alloc(VertexInfo, fields.len);

        inline for (fields, 0..) |field, i| {
            const size: u32 = field.type.size();
            const typ = getGlType(field.type.inner());

            self.vertexInfos[i] = .{
                .size = size,
                .typ = typ,
                .offset = @offsetOf(T, field.name),
                .stride = @sizeOf(T),
            };
        }

        self.size = indices.len;
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

    pub fn addTexture(self: *Mesh, texture: *Texture) error{OutOfMemory}!void {
        try self.textures.append(texture);
    }

    pub fn configure(self: *Mesh) void {
        gl.bindVertexArray(self.array);

        gl.bindBuffer(self.index, .element_array_buffer);
        gl.bindBuffer(self.vertex, .array_buffer);

        for (self.vertexInfos, 0..) |info, i| {
            gl.vertexAttribPointer(@intCast(i), info.size, info.typ, false, info.stride, info.offset);
            gl.enableVertexAttribArray(@intCast(i));
        }

        for (self.textures.items, 0..) |tex, index| {
            gl.activeTexture(@enumFromInt(index + @intFromEnum(gl.TextureUnit.texture_0)));
            gl.bindTexture(tex.handle, .@"2d");

            gl.uniform1i(tex.loc, @intCast(index));
        }

        gl.bindVertexArray(gl.VertexArray.invalid);
    }

    pub fn draw(self: *Mesh) void {
        gl.bindVertexArray(self.array);

        gl.drawElements(.triangles, self.size, .unsigned_int, 0);

        gl.bindVertexArray(gl.VertexArray.invalid);
    }

    pub fn deinit(self: *const Mesh) void {
        self.vertex.delete();
        self.index.delete();
        self.array.delete();
    }
};
