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
        program: *Program,
        path: []const u8,
        maxInstances: u32,
        allocator: Allocator,
        // comptime T: type,
        // program: *Program,
        // vertices: []const T,
        // indices: []const u32,
        // maxInstances: u32,
        // allocator: Allocator,
    ) error{OutOfMemory}!void {
        // const fields = @typeInfo(T).Struct.fields;

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

        self.instance.subData(len * @sizeOf(Instance), Instance, self.instances.items[len .. len + count]);

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
    vertice: ArrayList(u16),
    normal: ArrayList(u16),
    texture: ArrayList(u16),

    fn init(self: *Face, content: []const u8, allocator: Allocator) error{Read, OutOfMemory}!void {
        var offset: usize = 0;
        var i: usize = 0;
        var count: u32 = 1;

        for (content) |c| {
            if (c == ' ') count += 1;
        }
        
        self.vertice = try ArrayList(u16).initCapacity(allocator, count);
        errdefer self.vertice.deinit();

        self.normal = try ArrayList(u16).initCapacity(allocator, count);
        errdefer self.normal.deinit();

        self.texture = try ArrayList(u16).initCapacity(allocator, count);
        errdefer self.texture.deinit();

        while (nonWhitespace(content[offset..], &offset)) |data| : (i += 1) {
            var dataOffset: usize = 0;
            if (nonBar(data, &dataOffset)) |number| self.vertice.addOneAssumeCapacity().* = std.fmt.parseInt(u16, number, 10) catch return error.Read else return error.Read;
            if (nonBar(data, &dataOffset)) |number| self.normal.addOneAssumeCapacity().* = std.fmt.parseInt(u16, number, 10) catch return error.Read else return error.Read;
            if (nonBar(data, &dataOffset)) |number| self.texture.addOneAssumeCapacity().* = std.fmt.parseInt(u16, number, 10) catch return error.Read else return error.Read;
        }

        if (i != count) return error.Read;
    }

    fn deinit(self: *Face) void {
        self.vertice.deinit();
        self.normal.deinit();
        self.texture.deinit();
    }
};

const ObjFormat = struct {
    vertices: ArrayList([3]f32),
    normals: ArrayList([3]f32),
    textures: ArrayList([2]f32),
    faces: ArrayList(Face),

    fn init(self: *ObjFormat, path: []const u8, allocator: Allocator) error{ OutOfMemory, Read }!void {
        const buffer = try allocator.alloc(u8, 1024);
        defer allocator.free(buffer);

        const source = std.fs.cwd().readFile(path, buffer) catch return error.Read;

        var offset: usize = 0;
        while (until(source[offset..], '\n')) |line| : (offset += line.len + 1) {
            if (std.mem.startsWith(u8, line, "v ")) break;
        } else return error.Read;

        self.vertices = try ArrayList([3]f32).initCapacity(allocator, 10);
        errdefer self.vertices.deinit();

        while (until(source[offset..], '\n')) |line| : (offset += line.len + 1) {
            const linePattern = "v ";
            if (!std.mem.startsWith(u8, line, linePattern)) break;
            try fillNumber(f32, 3, try self.vertices.addOne(), line[linePattern.len..], nonWhitespace, std.fmt.parseFloat);
        } else return error.Read;

        self.normals = try ArrayList([3]f32).initCapacity(allocator, 10);
        errdefer self.normals.deinit();

        while (until(source[offset..], '\n')) |line| : (offset += line.len + 1) {
            const linePattern = "vn ";
            if (!std.mem.startsWith(u8, line, linePattern)) break;
            try fillNumber(f32, 3, try self.normals.addOne(), line[linePattern.len..], nonWhitespace, std.fmt.parseFloat);
        } else return error.Read;

        self.textures = try ArrayList([2]f32).initCapacity(allocator, 10);
        errdefer self.textures.deinit();

        while (until(source[offset..], '\n')) |line| : (offset += line.len + 1) {
            const linePattern = "vt ";
            if (!std.mem.startsWith(u8, line, linePattern)) break;
            try fillNumber(f32, 2, try self.textures.addOne(), line[linePattern.len..], nonWhitespace, std.fmt.parseFloat);
        } else return error.Read;

        while (until(source[offset..], '\n')) |line| : (offset += line.len + 1) {
            if (std.mem.startsWith(u8, line, "f ")) break;
        } else return error.Read;

        self.faces = try ArrayList(Face).initCapacity(allocator, 10);
        errdefer {
            self.faces.deinit();

            for (self.faces.items) |*face| {
                face.deinit();
            }
        }

        while (until(source[offset..], '\n')) |line| : (offset += line.len + 1) {
            const linePattern = "f ";
            if (!std.mem.startsWith(u8, line, linePattern)) break;

            const face = try self.faces.addOne();
            try face.init(line[linePattern.len..], allocator);
        }

        // std.debug.print("Vertice: \n\t{d}\n", .{self.vertices.items});
        // std.debug.print("Vertice: \n\t{d}\n", .{self.normals.items});
        // std.debug.print("Vertice: \n\t{d}\n", .{self.textures.items});

        // for (self.faces.items) |face| {
        //     std.debug.print("Face: \n\t{d}\n\t{d}\n\t{d}\n", .{face.vertice.items, face.normal.items, face.texture.items});
        // }
    }

    fn deinit(self: *ObjFormat) void {
        for (self.faces.items) |*face| {
            face.deinit();
        }

        self.faces.deinit();
        self.textures.deinit();
        self.normals.deinit();
        self.vertices.deinit();
    }
};

fn fillNumber(
    comptime T: type,
    comptime N: u32,
    numbers: *[N]T,
    line: []const u8,
    skip: fn ([]const u8, *usize) ?[]const u8,
    format: fn (comptime type, []const u8) T,
) error{Read}!void {
    var i: usize = 0;
    var offset: usize = 0;

    while (skip(line[offset..], &offset)) |number| : (i += 1) {
        numbers[i] = format(T, number) catch return error.Read;
    }

    if (i != N) return error.Read;
}

fn nonWhitespace(buffer: []const u8, offset: *usize) ?[]const u8 {
    if (buffer.len == 0) return null;

    var start: usize = 0;
    while (buffer[start] == ' ') {
        start += 1;
        if (start >= buffer.len) return null;
    }

    var end: usize = start;
    while (buffer[end] != ' ') {
        end += 1;
        if (end >= buffer.len) break;
    }

    offset.* += end;

    return buffer[start..end];
}

fn nonBar(buffer: []const u8, offset: *usize) ?[]const u8 {
    if (offset.* >= buffer.len) return null;
    var start = offset.*;

    if (buffer[start] == '/') start += 1;

    var end = start;
    while (buffer[end] != '/') {
        end += 1;
        if (end >= buffer.len) break;
    }

    offset.* += end;
    return buffer[start..end];
}

fn until(buffer: []const u8, char: u8) ?[]const u8 {
    if (buffer.len == 0) return null;

    var i: u32 = 0;

    while (buffer[i] != char) {
        i += 1;

        if (i >= buffer.len) {
            return null;
        }
    }

    return buffer[0..i];
}

test "Reading file" {
    var obj: ObjFormat = undefined;
    try obj.init("assets/cube.obj", std.testing.allocator);
    defer obj.deinit();
}
