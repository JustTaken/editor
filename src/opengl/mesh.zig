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

    pub fn addInstances(self: *Mesh, count: u32) error{OutOfMemory}![]Instance {
        const capacity = self.instances.capacity;
        const len = self.instances.items.len;

        if (len + count > capacity) return error.OutOfMemory;

        const instances = self.instances.addManyAtAssumeCapacity(len, count);

        for (instances) |*instance| {
            instance.transform = Matrix(4).identity();
        }

        gl.bindBuffer(self.instance, .shader_storage_buffer);

        self.instance.subData(len * @sizeOf(Instance), Instance, self.instances.items[len..len + count]);

        gl.bindBuffer(gl.Buffer.invalid, .shader_storage_buffer);

        return instances;
    }

    pub fn updateInstances(self: *Mesh, instances: []Instance) void {
        const ptr = @intFromPtr(instances.ptr);
        const index = ptr / @sizeOf(Instance);

        gl.bindBuffer(self.instance, .shader_storage_buffer);

        self.instance.subData(index * @sizeOf(Instance), Instance, instances);

        gl.bindBuffer(gl.Buffer.invalid, .shader_storage_buffer);
    }

    pub fn draw(self: *Mesh) void {
        gl.bindVertexArray(self.array);

        gl.drawElementsInstanced(.triangles, self.size, .unsigned_int, 0, self.instances.items.len);

        gl.bindVertexArray(gl.VertexArray.invalid);
    }

    pub fn deinit(self: *const Mesh) void {
        self.vertex.delete();
        self.index.delete();
        self.array.delete();
    }
};

const Face = struct {
    vertice: [3]u32,
    normal: [3]u32,
    texture: [3]u32,
};
const ObjFormat = struct {
    vertices: ArrayList([3]f32),
    normals: ArrayList([3]f32),
    textureCoords: ArrayList([3]f32),
    faces: ArrayList(Face),

    fn init(self: *ObjFormat, path: []const u8, allocator: Allocator) error{OutOfMemory, Read}!void {
        const buffer = try allocator.alloc(u8, 1024);
        defer allocator.free(buffer);

        const source = std.fs.cwd().readFile(path, buffer) catch return error.Read;

        var offset: usize = 0;
        while (until(source[offset..], '\n')) |line| : (offset += line.len) {
            if (std.mem.startsWith(u8, line, "v ")) break;
        } else return error.Read;

        self.vertices = try ArrayList([3]f32).initCapacity(allocator, 10);
        errdefer self.vertices.deinit();

        while (until(source[offset..], '\n')) |line| : (offset += line.len){
            if (!std.mem.startsWith(u8, line, "v ")) break;
            std.debug.print("vertices: {s}", .{line});
        } else return error.Read;

        self.normals = try ArrayList([3]f32).initCapacity(allocator, 10);
        errdefer self.normals.deinit();

        while (until(source[offset..], '\n')) |line| : (offset += line.len){
            if (!std.mem.startsWith(u8, line, "vn ")) break;
            std.debug.print("normals: {s}", .{line});
        } else return error.Read;

        self.textureCoords = try ArrayList([3]f32).initCapacity(allocator, 10);
        errdefer self.textureCoords.deinit();

        while (until(source[offset..], '\n')) |line| : (offset += line.len){
            if (!std.mem.startsWith(u8, line, "vt ")) break;
            std.debug.print("textures: {s}", .{line});
        } else return error.Read;

        while (until(source[offset..], '\n')) |line| : (offset += line.len){
            if (std.mem.startsWith(u8, line, "f ")) break;
        } else return error.Read;

        self.faces = try ArrayList(Face).initCapacity(allocator, 10);
        errdefer self.faces.deinit();

        while (until(source[offset..], '\n')) |line| : (offset += line.len){
            if (!std.mem.startsWith(u8, line, "f ")) break;
            std.debug.print("faces: {s}", .{line});
        }
    }

    fn until(buffer: []u8, char: u8) ?[]u8 {
        if (buffer.len == 0) return null;

        var i: u32 = 0;

        while (buffer[i] != char) {
            i += 1;

            if (i >= buffer.len) {
                return null;
            }
        }

        return buffer[0..i + 1];
    }

    fn deinit(self: *ObjFormat) void {
        self.faces.deinit();
        self.textureCoords.deinit();
        self.normals.deinit();
        self.vertices.deinit();
    }
};

test "Reading file" {
    var obj: ObjFormat = undefined;
    try obj.init("assets/cube.obj", std.testing.allocator);
    defer obj.deinit();
}
