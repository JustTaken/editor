const std = @import("std");
const gl = @import("zgl");

const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const ArrayList = std.ArrayList;

const Program = @import("shader.zig").Program;
const Texture = @import("texture.zig").Texture;
const Matrix = @import("../math.zig").Matrix;

const Instance = struct {
    transform: Matrix(4),
};

pub const Mesh = struct {
    program: *Program,

    array: gl.VertexArray,
    vertex: gl.Buffer,
    index: gl.Buffer,
    instance: gl.Buffer,

    newTextures: ArrayList(*Texture),
    textures: ArrayList(*Texture),
    instances: ArrayList(Instance),

    size: u32,

    allocator: FixedBufferAllocator,

    pub fn init(
        self: *Mesh,
        comptime T: type,
        program: *Program,
        vertices: []const T,
        indices: []const u32,
        maxInstances: u32,
        allocator: Allocator,
    ) error{OutOfMemory}!void {
        const fields = @typeInfo(T).Struct.fields;

        self.allocator = FixedBufferAllocator.init(try allocator.alloc(u8, 1024));
        const fixedAllocator = self.allocator.allocator();

        self.newTextures = try ArrayList(*Texture).initCapacity(fixedAllocator, 2);
        self.textures = try ArrayList(*Texture).initCapacity(fixedAllocator, 2);
        self.instances = try ArrayList(Instance).initCapacity(fixedAllocator, maxInstances);

        self.program = program;
        self.array = gl.genVertexArray();

        var buffers: [3]gl.Buffer = undefined;
        gl.genBuffers(&buffers);

        gl.bindVertexArray(self.array);

        self.vertex = buffers[0];
        gl.bindBuffer(self.vertex, .array_buffer);
        gl.bufferData(.array_buffer, T, vertices, .static_draw);

        inline for (fields, 0..) |field, i| {
            gl.enableVertexAttribArray(@intCast(i));
            gl.vertexAttribDivisor(@intCast(i), 0);
            gl.vertexAttribPointer(@intCast(i), field.type.size(), getGlType(field.type.inner()), false, @sizeOf(T), @offsetOf(T, field.name));
        }

        gl.bindBuffer(gl.Buffer.invalid, .array_buffer);

        self.instance = buffers[1];
        gl.bindBuffer(self.instance, .shader_storage_buffer);
        gl.bufferData(.shader_storage_buffer, Instance, self.instances.unusedCapacitySlice(), .dynamic_draw);
        gl.bindBufferBase(.shader_storage_buffer, 0, self.instance);

        // gl.bindBuffer(gl.Buffer.invalid, .sha);

        self.index = buffers[2];
        gl.bindBuffer(self.index, .element_array_buffer);
        gl.bufferData(.element_array_buffer, u32, indices, .static_draw);

        gl.bindVertexArray(gl.VertexArray.invalid);

        self.size = @intCast(indices.len);
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

    pub fn addInstance(self: *Mesh) error{OutOfMemory}!u32 {
        const capacity = self.instances.capacity;
        const len = self.instances.items.len;

        if (len >= capacity) return error.OutOfMemory;

        self.instances.appendAssumeCapacity(.{
            .transform = Matrix(4).translate(.{0.5, 0.0, 0.0}),
        });

        gl.bindBuffer(self.instance, .shader_storage_buffer);

        self.instance.subData(len * @sizeOf(Instance), Instance, self.instances.items[len..len + 1]);

        gl.bindBuffer(gl.Buffer.invalid, .shader_storage_buffer);

        return @intCast(len);
    }

    pub fn updateInstance(self: *Mesh, index: u32, data: Matrix(4)) void {
        self.instances.items[index].transform = data;

        gl.bindBuffer(self.instance, .shader_storage_buffer);

        self.instance.subData(index * @sizeOf(Instance), Instance, self.instances.items[index..index + 1]);

        gl.bindBuffer(gl.Buffer.invalid, .shader_storage_buffer);
    }

    pub fn addTexture(self: *Mesh, texture: *Texture) error{OutOfMemory}!void {
        try self.newTextures.append(texture);
    }

    pub fn draw(self: *Mesh) void {
        gl.bindVertexArray(self.array);

        const newTextures = self.newTextures.items.len;
        for (0..newTextures) |_| {
            const texture = self.newTextures.pop();
            const index = self.textures.items.len;

            gl.activeTexture(@enumFromInt(index + @intFromEnum(gl.TextureUnit.texture_0)));
            gl.bindTexture(texture.handle, .@"2d");
            gl.uniform1i(texture.loc, @intCast(index));

            self.textures.append(texture) catch @panic("TODO");
        }

        gl.drawElementsInstanced(.triangles, self.size, .unsigned_int, 0, self.instances.items.len);

        gl.bindVertexArray(gl.VertexArray.invalid);
    }

    pub fn deinit(self: *const Mesh) void {
        self.vertex.delete();
        self.index.delete();
        self.array.delete();
    }
};
