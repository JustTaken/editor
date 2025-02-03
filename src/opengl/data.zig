const std = @import("std");
const gl = @import("zgl");

const Allocator = std.mem.Allocator;

const Texture = @import("texture.zig").Texture;

const VertexInfo = struct {
    size: u32,
    typ: gl.Type,
    stride: u32,
    offset: u32,
};

pub const Data = struct {
    array: gl.VertexArray,
    vertex: gl.Buffer,
    index: gl.Buffer,

    vertexInfos: []VertexInfo,

    size: usize,

    pub fn new(
        comptime T: type,
        vertices: []const T,
        indices: []const u32,
        allocator: Allocator,
    ) error{OutOfMemory}!Data {
        var self: Data = undefined;

        self.array = gl.genVertexArray();

        var buffers: [2]gl.Buffer = undefined;
        gl.genBuffers(&buffers);

        self.vertex = buffers[0];
        self.vertex.bind(.array_buffer);
        self.vertex.data(T, vertices, .static_draw);

        self.index = buffers[1];
        self.index.bind(.element_array_buffer);
        self.index.data(u32, indices, .static_draw);

        gl.bindBuffer(@enumFromInt(0), .array_buffer);
        gl.bindBuffer(@enumFromInt(0), .element_array_buffer);

        const fields = @typeInfo(T).Struct.fields;
        self.vertexInfos = try allocator.alloc(VertexInfo, fields.len);

        inline for (fields, 0..) |field, i| {
            var size: u32 = 1;
            const typ = getType(field.type, &size);

            self.vertexInfos[i] = .{
                .size = size,
                .typ = typ,
                .offset = @offsetOf(T, field.name),
                .stride = @sizeOf(T),
            };
        }

        self.size = indices.len;

        return self;
    }

    pub fn startRecord(self: *Data) void {
        gl.bindVertexArray(self.array);
    }

    pub fn bindIndex(self: *Data) void {
        gl.bindBuffer(self.index, .element_array_buffer);
    }

    pub fn bindVertex(self: *Data) void {
        gl.bindBuffer(self.vertex, .array_buffer);

        for (self.vertexInfos, 0..) |info, i| {
            gl.vertexAttribPointer(@intCast(i), info.size, info.typ, false, info.stride, info.offset);
            gl.enableVertexAttribArray(@intCast(i));
        }
    }

    pub fn bindTextures(_: *Data, textures: []const Texture) void {
        for (textures, 0..) |tex, index| {
            gl.activeTexture(@enumFromInt(index + @intFromEnum(gl.TextureUnit.texture_0)));
            gl.bindTexture(tex.handle, .@"2d");

            gl.uniform1i(tex.loc, @intCast(index));
        }
    }

    pub fn stopRecord(_: *Data) void {
        gl.bindVertexArray(@enumFromInt(0));
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
