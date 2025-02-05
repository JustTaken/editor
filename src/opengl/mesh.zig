const std = @import("std");
const gl = @import("zgl");

const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const ArrayList = std.ArrayList;

const Program = @import("shader.zig").Program;
const Texture = @import("texture.zig").Texture;
const Vec = @import("../math.zig").Vec;

const Instance = struct {
    position: Vec(3),
};

const VertexInfo = struct {
    size: u32,
    typ: gl.Type,
    stride: u32,
    offset: u32,
    divisor: u32,
};

pub const Mesh = struct {
    program: *Program,

    array: gl.VertexArray,
    vertex: gl.Buffer,
    index: gl.Buffer,
    instance: gl.Buffer,

    vertexInfos: []VertexInfo,

    newTextures: ArrayList(*Texture),
    textures: ArrayList(*Texture),
    instances: ArrayList(Instance),

    size: u32,
    // isUpdated: bool,

    allocator: FixedBufferAllocator,

    pub fn init(
        self: *Mesh,
        comptime T: type,
        program: *Program,
        vertices: []const T,
        indices: []const u32,
        allocator: Allocator,
    ) error{OutOfMemory}!void {
        const fields = @typeInfo(T).Struct.fields;

        // self.isUpdated = true;
        self.allocator = FixedBufferAllocator.init(try allocator.alloc(u8, 1024));
        const fixedAllocator = self.allocator.allocator();

        self.vertexInfos = try fixedAllocator.alloc(VertexInfo, fields.len);
        self.newTextures = try ArrayList(*Texture).initCapacity(fixedAllocator, 2);
        self.textures = try ArrayList(*Texture).initCapacity(fixedAllocator, 2);
        self.instances = try ArrayList(Instance).initCapacity(fixedAllocator, 2);

        self.program = program;
        self.array = gl.genVertexArray();

        var buffers: [3]gl.Buffer = undefined;
        gl.genBuffers(&buffers);

        gl.bindVertexArray(self.array);

        self.vertex = buffers[0];
        gl.bindBuffer(self.vertex, .array_buffer);
        gl.bufferData(.array_buffer, T, vertices, .static_draw);

        inline for (fields, 0..) |field, i| {
            self.vertexInfos[i] = .{
                .size = field.type.size(),
                .typ = getGlType(field.type.inner()),
                .stride = @sizeOf(T),
                .offset = @offsetOf(T, field.name),
                .divisor = 0,
            };

            gl.enableVertexAttribArray(@intCast(i));
            gl.vertexAttribDivisor(@intCast(i), 0);
            gl.vertexAttribPointer(@intCast(i), field.type.size(), getGlType(field.type.inner()), false, @sizeOf(T), @offsetOf(T, field.name));
        }

        gl.bindBuffer(gl.Buffer.invalid, .array_buffer);

        self.index = buffers[1];
        gl.bindBuffer(self.index, .element_array_buffer);
        gl.bufferData(.element_array_buffer, u32, indices, .static_draw);
        // gl.bindBuffer(gl.Buffer.invalid, .element_array_buffer);

        self.instance = buffers[2];
        self.instance.bind(.array_buffer);
        self.instance.data(Instance, self.instances.unusedCapacitySlice(), .dynamic_draw);

        const instanceLayoutOffset = fields.len;
        inline for (@typeInfo(Instance).Struct.fields, 0..) |field, i| {
            gl.enableVertexAttribArray(@intCast(instanceLayoutOffset + i));
            gl.vertexAttribDivisor(@intCast(instanceLayoutOffset + i), 1);
            gl.vertexAttribPointer(@intCast(instanceLayoutOffset + i), field.type.size(), getGlType(field.type.inner()), false, @sizeOf(field.type), @offsetOf(Instance, field.name));
        }

        gl.bindBuffer(gl.Buffer.invalid, .array_buffer);

        gl.bindVertexArray(gl.VertexArray.invalid);

        self.size = @intCast(indices.len);

        // self.configure();
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

    // fn configure(self: *Mesh) void {
    //     if (!self.isUpdated) return;

    //     self.isUpdated = false;
    //     self.program.meshUpdates.append(self) catch @panic("Buy ram lol");
    // }

    pub fn addInstance(self: *Mesh) error{OutOfMemory}!u32 {
        const capacity = self.instances.capacity;
        const len = self.instances.items.len;

        try self.instances.append(.{
            .position = Vec(3).init(.{0.0, 0.0, 0.0}),
        });

        gl.bindBuffer(self.instance, .array_buffer);

        if (self.instances.capacity > capacity) {
             self.instance.data(Instance, self.instances.unusedCapacitySlice(), .dynamic_draw);
        } else {
            self.instance.subData(len * @sizeOf(Instance), Instance, self.instances.items[len..]);
        }

        gl.bindBuffer(gl.Buffer.invalid, .array_buffer);

        return @intCast(len);
    }

    pub fn addTexture(self: *Mesh, texture: *Texture) error{OutOfMemory}!void {
        // gl.bindVertexArray(self.array);

        // gl.activeTexture(@enumFromInt(self.textures.items.len + @intFromEnum(gl.TextureUnit.texture_0)));
        // gl.bindTexture(texture.handle, .@"2d");

        // try self.textures.append(texture);
        try self.newTextures.append(texture);

        // gl.bindVertexArray(gl.VertexArray.invalid);

        // self.configure();
    }

    // pub fn update(self: *Mesh) void {
    //     gl.bindVertexArray(self.array);

        // gl.bindBuffer(self.index, .element_array_buffer);
        // gl.bindBuffer(self.vertex, .array_buffer);
        // gl.bindBuffer(self.vertex, .array_buffer);

        // for (self.vertexInfos, 0..) |info, i| {
        //     gl.enableVertexAttribArray(@intCast(i));
        //     gl.vertexAttribDivisor(@intCast(i), 0);
        //     gl.vertexAttribPointer(@intCast(i), info.size, info.typ, false, info.stride, info.offset);
        // }

        // gl.bindBuffer(self.instance, .array_buffer);

        // const instanceLayoutOffset = self.vertexInfos.len;
        // inline for (@typeInfo(Instance).Struct.fields, 0..) |field, i| {
        //     gl.vertexAttribPointer(@intCast(instanceLayoutOffset + i), field.type.size(), getGlType(field.type.inner()), false, @sizeOf(field.type), @offsetOf(Instance, field.name));
        //     gl.enableVertexAttribArray(@intCast(instanceLayoutOffset + i));
        //     gl.vertexAttribDivisor(@intCast(instanceLayoutOffset + i), 1);
        // }

        // gl.bindVertexArray(gl.VertexArray.invalid);
    //     self.isUpdated = true;
    // }

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

        // gl.drawElements(.triangles, self.size, .unsigned_int, 0);
        gl.drawElementsInstanced(.triangles, self.size, .unsigned_int, 0, self.instances.items.len);

        gl.bindVertexArray(gl.VertexArray.invalid);
    }

    pub fn deinit(self: *const Mesh) void {
        self.vertex.delete();
        self.index.delete();
        self.array.delete();
    }
};
