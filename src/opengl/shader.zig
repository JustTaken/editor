const std = @import("std");
const gl = @import("zgl");

const Allocator = std.mem.Allocator;

pub const Program = struct {
    handle: gl.Program,

    pub fn new(
        vertexPath: []const u8,
        fragmentPath: []const u8,
        allocator: Allocator,
    ) error{ Read, Compile, OutOfMemory }!Program {
        var self: Program = undefined;
        self.handle = gl.Program.create();

        const vertex = try shader(.vertex, vertexPath, allocator);
        defer vertex.delete();

        self.handle.attach(vertex);

        const fragment = try shader(.fragment, fragmentPath, allocator);
        defer fragment.delete();

        self.handle.attach(fragment);

        self.handle.link();

        const message = try gl.getProgramInfoLog(self.handle, allocator);
        if (message.len > 0) {
            std.log.err("Shader: {s}", .{message});
        }

        return self;
    }

    pub fn start(self: *Program) void {
        gl.useProgram(self.handle);
    }

    pub fn end(_: *Program) void {
        gl.useProgram(gl.Program.invalid);
    }

    pub fn uniformLocation(self: *Program, name: [:0]const u8) error{NotFound}!u32 {
        return self.handle.uniformLocation(name) orelse return error.NotFound;
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

        std.log.err("shader compilation: {s}", .{result});

        return error.Compile;
    }

    return self;
}
