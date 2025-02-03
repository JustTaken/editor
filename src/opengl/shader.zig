const std = @import("std");
const gl = @import("zgl");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Data = @import("data.zig").Data;

pub const Program = struct {
    handle: gl.Program,

    data: Data,

    pub fn new(
        data: Data,
        shaderPaths: [2][]const u8,
        allocator: Allocator,
    ) error{ Read, Compile, NotFound, OutOfMemory }!Program {
        var self: Program = undefined;

        self.handle = gl.Program.create();

        const vertex = try shader(.vertex, shaderPaths[0], allocator);
        defer vertex.delete();

        self.handle.attach(vertex);

        const fragment = try shader(.fragment, shaderPaths[1], allocator);
        defer fragment.delete();

        self.handle.attach(fragment);

        self.handle.link();

        self.data = data;
        try self.data.resolveUniforms(self.handle);

        return self;
    }

    fn shader(kind: gl.ShaderType, path: []const u8, allocator: Allocator) error{ Read, Compile, OutOfMemory }!gl.Shader {
        const buffer = try allocator.alloc(u8, 1024);
        defer allocator.free(buffer);

        const source = std.fs.cwd().readFile(path, buffer) catch return error.Read;

        const self = gl.Shader.create(kind);

        self.source(1, &source);
        self.compile();

        if (0 == self.get(.compile_status)) {
            const result = self.getCompileLog(allocator) catch return error.OutOfMemory;
            std.debug.print("error: {s}\n", .{result});

            return error.Compile;
        }

        return self;
    }

    pub fn draw(self: *Program) void {
        self.handle.use();
        self.data.use();
    }

    pub fn deinit(self: *const Program) void {
        self.data.deinit();
        self.handle.delete();
    }
};
