const std = @import("std");
const gl = @import("zgl");
const math = @import("../math.zig");

const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const ArrayList = std.ArrayList;

const Texture = @import("texture.zig").Texture;
const Vec = math.Vec;

const Vertex = struct {
    position: Vec(3),
    normal: Vec(3),
    texture: Vec(2),
};

pub const Mesh = struct {
    array: gl.VertexArray,
    vertex: gl.Buffer,
    index: gl.Buffer,

    size: u32,

    allocator: FixedBufferAllocator,

    pub fn new(
        path: []const u8,
        allocator: Allocator,
    ) error{ OutOfMemory, Read }!Mesh {
        var self: Mesh = undefined;

        const fields = @typeInfo(Vertex).Struct.fields;

        const allocationBuffer = try allocator.alloc(u8, std.mem.page_size);
        var fixedAllocator = FixedBufferAllocator.init(allocationBuffer);

        var obj = try ObjFormat.new(path, fixedAllocator.allocator());

        self.array = gl.genVertexArray();

        var buffers: [2]gl.Buffer = undefined;
        gl.genBuffers(&buffers);

        gl.bindVertexArray(self.array);

        const vertexData = try obj.getVertexData(fixedAllocator.allocator());

        self.vertex = buffers[0];
        gl.bindBuffer(self.vertex, .array_buffer);
        gl.bufferData(.array_buffer, Vertex, vertexData.items, .static_draw);

        vertexData.deinit();

        inline for (fields, 0..) |field, i| {
            gl.enableVertexAttribArray(@intCast(i));
            gl.vertexAttribDivisor(@intCast(i), 0);
            gl.vertexAttribPointer(@intCast(i), field.type.size(), getGlType(field.type.inner()), false, @sizeOf(Vertex), @offsetOf(Vertex, field.name));
        }

        gl.bindBuffer(gl.Buffer.invalid, .array_buffer);

        const indices = try obj.getIndices(fixedAllocator.allocator());

        self.index = buffers[1];
        gl.bindBuffer(self.index, .element_array_buffer);
        gl.bufferData(.element_array_buffer, u16, indices.items, .static_draw);

        self.size = @intCast(indices.items.len);

        allocator.free(allocationBuffer);

        gl.bindVertexArray(gl.VertexArray.invalid);

        return self;
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

    pub fn draw(self: Mesh, offset: u32, count: u32) void {
        gl.bindVertexArray(self.array);

        gl.binding.drawElementsInstancedBaseInstance(gl.binding.TRIANGLES, @intCast(self.size), gl.binding.UNSIGNED_SHORT, @ptrFromInt(0), @intCast(count), @intCast(offset));

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
    geometry: Geometry,

    const Geometry = enum {
        Quad,
    };

    fn init(self: *Face, content: []const u8, allocator: Allocator) error{ Read, OutOfMemory }!void {
        var offset: usize = 0;
        var i: usize = 0;
        var count: u32 = 1;

        for (content) |c| {
            if (c == ' ') count += 1;
        }

        switch (count) {
            4 => self.geometry = .Quad,
            else => return error.Read,
        }

        self.vertice = try ArrayList(u16).initCapacity(allocator, count);
        errdefer self.vertice.deinit();

        self.normal = try ArrayList(u16).initCapacity(allocator, count);
        errdefer self.normal.deinit();

        self.texture = try ArrayList(u16).initCapacity(allocator, count);
        errdefer self.texture.deinit();

        while (nonWhitespace(content[offset..], &offset)) |data| : (i += 1) {
            var dataOffset: usize = 0;
            if (nonBar(data, &dataOffset)) |number| self.vertice.addOneAssumeCapacity().* = (std.fmt.parseInt(u16, number, 10) catch return error.Read) - 1 else return error.Read;
            if (nonBar(data, &dataOffset)) |number| self.texture.addOneAssumeCapacity().* = (std.fmt.parseInt(u16, number, 10) catch return error.Read) - 1 else return error.Read;
            if (nonBar(data, &dataOffset)) |number| self.normal.addOneAssumeCapacity().* = (std.fmt.parseInt(u16, number, 10) catch return error.Read) - 1 else return error.Read;
        }

        if (i != count) return error.Read;
    }

    fn pushIndices(self: *const Face, array: *ArrayList(u16), offset: *u16) error{OutOfMemory}!void {
        const off = offset.*;

        switch (self.geometry) {
            .Quad => try array.appendSlice(&.{ 2 + off, 1 + off, 0 + off, 0 + off, 3 + off, 2 + off }),
        }

        offset.* += self.size();
    }

    fn size(self: *const Face) u16 {
        return @intCast(self.vertice.items.len);
    }
};

const ObjFormat = struct {
    vertices: ArrayList([3]f32),
    normals: ArrayList([3]f32),
    textures: ArrayList([2]f32),

    faces: ArrayList(Face),

    fn new(path: []const u8, allocator: Allocator) error{ OutOfMemory, Read }!ObjFormat {
        var self: ObjFormat = undefined;

        const source = std.fs.cwd().readFileAlloc(allocator, path, 2048) catch return error.Read;
        defer allocator.free(source);

        var offset: usize = 0;
        while (until(source[offset..], '\n')) |line| : (offset += line.len + 1) {
            if (std.mem.startsWith(u8, line, "v ")) break;
        } else return error.Read;

        self.vertices = try ArrayList([3]f32).initCapacity(allocator, 10);

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

        while (until(source[offset..], '\n')) |line| : (offset += line.len + 1) {
            const linePattern = "vt ";
            if (!std.mem.startsWith(u8, line, linePattern)) break;
            try fillNumber(f32, 2, try self.textures.addOne(), line[linePattern.len..], nonWhitespace, std.fmt.parseFloat);
        } else return error.Read;

        while (until(source[offset..], '\n')) |line| : (offset += line.len + 1) {
            if (std.mem.startsWith(u8, line, "f ")) break;
        } else return error.Read;

        self.faces = try ArrayList(Face).initCapacity(allocator, 10);

        while (until(source[offset..], '\n')) |line| : (offset += line.len + 1) {
            const linePattern = "f ";
            if (!std.mem.startsWith(u8, line, linePattern)) break;

            const face = try self.faces.addOne();
            try face.init(line[linePattern.len..], allocator);
        }

        return self;
    }

    fn getVertexData(self: *ObjFormat, allocator: Allocator) error{OutOfMemory}!ArrayList(Vertex) {
        var vertexData = try ArrayList(Vertex).initCapacity(allocator, self.faces.items.len * 4);

        for (self.faces.items) |face| {
            for (0..face.size()) |i| {
                try vertexData.append(.{
                    .position = Vec(3).init(self.vertices.items[face.vertice.items[i]]),
                    .normal = Vec(3).init(self.normals.items[face.normal.items[i]]),
                    .texture = Vec(2).init(self.textures.items[face.texture.items[i]]),
                });
            }
        }

        return vertexData;
    }

    fn getIndices(self: *ObjFormat, allocator: Allocator) error{OutOfMemory}!ArrayList(u16) {
        var indices = try ArrayList(u16).initCapacity(allocator, self.faces.items.len * 6);

        var offset: u16 = 0;
        for (self.faces.items) |face| {
            try face.pushIndices(&indices, &offset);
        }

        return indices;
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
    const buffer = try std.testing.allocator.alloc(u8, 4096);
    defer std.testing.allocator.free(buffer);
    var allocator = FixedBufferAllocator.init(buffer);

    var obj = try ObjFormat.new("assets/plane.obj", allocator.allocator());
    const indices = try obj.getIndices(allocator.allocator());
    try std.testing.expectEqual(indices.len, 6);
}
