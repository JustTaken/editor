const std = @import("std");
const gl = @import("zgl");

const Allocator = std.mem.Allocator;

pub const Program = struct {
    handle: gl.Program,

    pub fn new(
        vertex: Shader,
        fragment: Shader,
        allocator: Allocator,
    ) error{ Read, Compile, OutOfMemory }!Program {
        var self: Program = undefined;
        self.handle = gl.Program.create();

        self.handle.attach(vertex.handle);
        self.handle.attach(fragment.handle);

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

pub const Shader = struct {
    handle: gl.Shader,
    kind: gl.ShaderType,

    pub fn fromPath(kind: gl.ShaderType, path: []const u8, allocator: Allocator) error{ Read, Compile, OutOfMemory}!Shader {
        var self: Shader = undefined;
        self.kind = kind;

        const buffer = try allocator.alloc(u8, 1024);
        defer allocator.free(buffer);

        const source = std.fs.cwd().readFile(path, buffer) catch return error.Read;

        self.handle = gl.Shader.create(kind);

        self.handle.source(1, &source);
        self.handle.compile();

        if (0 == self.handle.get(.compile_status)) {
            const result = try self.handle.getCompileLog(allocator);

            std.log.err("shader compilation: {s}", .{result});

            return error.Compile;
        }

        return self;
    }

    pub fn deinit(self: *const Shader) void {
        self.handle.delete();
    }
};
