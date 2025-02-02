const std = @import("std");
const gl = @import("zgl");
const wl = @import("wayland").client.wl;

const Window = @import("window.zig").Window;

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const FixedAllocator = std.heap.FixedBufferAllocator;
const GeometryMap = std.EnumMap(GeometryKind, Geometry);

const egl = @cImport({
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
});

const Vertex = struct {
    data: [3]f32,

    const Stride: u32 = 3 * @sizeOf(f32);

    fn new(x: f32, y: f32, z: f32) Vertex {
        return Vertex{
            .data = .{
                x,
                y,
                z,
            },
        };
    }
};

pub const Geometry = struct {
    array: gl.VertexArray,
    buffer: gl.Buffer,
    size: u32,

    fn new(comptime N: u32, vertices: [N]Vertex) Geometry {
        var self: Geometry = undefined;

        self.size = N;
        self.array = gl.VertexArray.create();
        self.array.bind();

        self.buffer = gl.Buffer.create();

        self.buffer.bind(.array_buffer);
        self.buffer.data(Vertex, &vertices, .static_draw);

        gl.vertexAttribPointer(0, N, .float, false, Vertex.Stride, 0);
        gl.enableVertexAttribArray(0);

        return self;
    }

    fn draw(self: *const Geometry) void {
        self.array.bind();
        gl.drawArrays(.triangles, 0, self.size);
    }
};

pub const GeometryKind = enum {
    Triangle,
};

const Program = struct {
    handle: gl.Program,
    vertex: gl.Shader,
    fragment: gl.Shader,

    geometries: GeometryMap,

    fn new(
        vertPath: []const u8,
        fragPath: []const u8,
        geometries: GeometryMap,
        allocator: Allocator,
    ) error{ Read, Compile, OutOfMemory }!Program {
        var self: Program = undefined;

        const buffer = try allocator.alloc(u8, 1024);
        defer allocator.free(buffer);

        self.handle = gl.Program.create();

        self.vertex = try shader(.vertex, vertPath, buffer);
        self.fragment = try shader(.fragment, fragPath, buffer);

        self.handle.attach(self.vertex);
        self.handle.attach(self.fragment);

        self.geometries = geometries;

        self.handle.link();

        return self;
    }

    fn shader(kind: gl.ShaderType, path: []const u8, buffer: []u8) error{ Read, Compile }!gl.Shader {
        const source = std.fs.cwd().readFile(path, buffer) catch return error.Read;

        const self = gl.Shader.create(kind);

        self.source(1, &source);
        self.compile();

        if (0 == self.get(.compile_status)) {
            return error.Compile;
        }

        return self;
    }

    fn draw(self: *Program, kind: GeometryKind) void {
        self.handle.use();

        const triangle = self.geometries.get(kind) orelse @panic("Failed to find trinangle geometry");

        triangle.draw();
    }

    fn deinit(self: *const Program) void {
        self.vertex.delete();
        self.fragment.delete();
        self.handle.delete();
    }
};

pub const OpenGL = struct {
    window: *wl.EglWindow,
    display: egl.EGLDisplay,
    context: egl.EGLContext,
    surface: egl.EGLSurface,

    width: u32,
    height: u32,

    programs: ArrayList(Program),

    allocator: FixedAllocator,

    pub fn init(
        self: *OpenGL,
        width: u32,
        height: u32,
        display: *wl.Display,
        surface: *wl.Surface,
        allocator: Allocator,
    ) !void {
        self.display = egl.eglGetPlatformDisplay(egl.EGL_PLATFORM_WAYLAND_KHR, display, null);

        var eglMajor: egl.EGLint = 0;
        var eglMinor: egl.EGLint = 0;

        if (egl.EGL_TRUE != egl.eglInitialize(self.display, &eglMajor, &eglMinor)) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_DISPLAY => return error.EglBadDisplay,
                else => return error.EglFail,
            }
        }

        const aglAttributes = [_]egl.EGLint{
            egl.EGL_SURFACE_TYPE,    egl.EGL_WINDOW_BIT,
            egl.EGL_RENDERABLE_TYPE, egl.EGL_OPENGL_BIT,
            egl.EGL_STENCIL_SIZE,    0,
            egl.EGL_SAMPLES,         0,
            egl.EGL_RED_SIZE,        8,
            egl.EGL_GREEN_SIZE,      8,
            egl.EGL_BLUE_SIZE,       8,
            egl.EGL_ALPHA_SIZE,      8,
            egl.EGL_NONE,
        };

        var eglConfig: egl.EGLConfig = undefined;
        var numConfigs: egl.EGLint = 0;

        if (egl.EGL_TRUE != egl.eglChooseConfig(self.display, &aglAttributes, &eglConfig, 1, &numConfigs)) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_ATTRIBUTE => return error.InvalidEglConfig,
                else => return error.EglConfig,
            }
        }

        if (egl.EGL_TRUE != egl.eglBindAPI(egl.EGL_OPENGL_API)) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_PARAMETER => return error.OpenGLUnsupported,
                else => return error.InvalidApi,
            }
        }

        const windowAttributes = [_]egl.EGLAttrib{
            egl.EGL_GL_COLORSPACE, egl.EGL_GL_COLORSPACE_LINEAR,
            egl.EGL_RENDER_BUFFER, egl.EGL_BACK_BUFFER,
            egl.EGL_NONE,
        };

        self.window = try wl.EglWindow.create(surface, @intCast(width), @intCast(height));
        self.surface = egl.eglCreatePlatformWindowSurface(self.display, eglConfig, self.window, &windowAttributes) orelse switch (egl.eglGetError()) {
            egl.EGL_BAD_MATCH => return error.MismatchedConfig,
            egl.EGL_BAD_CONFIG => return error.InvalidConfig,
            egl.EGL_BAD_NATIVE_WINDOW => return error.InvalidWindow,
            else => return error.FailedToCreatEglSurface,
        };

        if (egl.EGL_TRUE != egl.eglSurfaceAttrib(self.display, self.surface, egl.EGL_SWAP_BEHAVIOR, egl.EGL_BUFFER_DESTROYED)) {
            switch (egl.eglGetError()) {
                else => return error.SetSurfaceAttribute,
            }
        }

        const contextAttributes = [_]egl.EGLint{
            egl.EGL_CONTEXT_MAJOR_VERSION, 4,
            egl.EGL_CONTEXT_MINOR_VERSION, 6,
            egl.EGL_CONTEXT_OPENGL_PROFILE_MASK, egl.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
            egl.EGL_NONE,
        };

        self.context = egl.eglCreateContext(self.display, eglConfig, egl.EGL_NO_CONTEXT, &contextAttributes) orelse switch (egl.eglGetError()) {
            egl.EGL_BAD_ATTRIBUTE => return error.InvalidContextAttribute,
            egl.EGL_BAD_CONFIG => return error.CreateContextWithBadConfig,
            egl.EGL_BAD_MATCH => return error.UnsupportedConfig,
            else => return error.FailedToCreateContext,
        };

        if (egl.eglMakeCurrent(self.display, self.surface, self.surface, self.context) != egl.EGL_TRUE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_ACCESS => return error.EglThreadError,
                egl.EGL_BAD_MATCH => return error.MismatchedContextOrSurfaces,
                egl.EGL_BAD_NATIVE_WINDOW => return error.EglWindowInvalid,
                egl.EGL_BAD_CONTEXT => return error.InvalidEglContext,
                egl.EGL_BAD_ALLOC => return error.OutOfMemory,
                else => return error.FailedToMakeCurrent,
            }
        }

        try gl.loadExtensions(void, getProcAddress);

        self.allocator = FixedAllocator.init(try allocator.alloc(u8, 4096));
        const fixedAllocator = self.allocator.allocator();

        self.programs = try ArrayList(Program).initCapacity(fixedAllocator, 2);

        self.programs.append(
            try Program.new(
                "assets/vertex.glsl",
                "assets/fragment.glsl",
                GeometryMap.init(.{
                    .Triangle = Geometry.new(3, .{
                        Vertex.new(-1.0, 1.0, 0.0),
                        Vertex.new(1.0, 1.0, 0.0),
                        Vertex.new(0.0, -1.0, 0.0),
                    }),
                }),
                fixedAllocator,
            ),
        ) catch return error.OutOfMemory;

        self.width = width;
        self.height = height;

        gl.clearColor(1.0, 1.0, 0.5, 1.0);
    }

    pub fn drawTriangle(self: *OpenGL) void {
        self.programs.items[0].draw(.Triangle);
    }

    pub fn render(self: *OpenGL) error{ InvalidDisplay, InvalidSurface, ContextLost, SwapBuffers }!void {
        gl.clearColor(1.0, 0.0, 0.0, 1.0);
        gl.clear(.{ .color = true });

        self.drawTriangle();

        if (egl.eglSwapBuffers(self.display, self.surface) != egl.EGL_TRUE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_DISPLAY => return error.InvalidDisplay,
                egl.EGL_BAD_SURFACE => return error.InvalidSurface,
                egl.EGL_CONTEXT_LOST => return error.ContextLost,
                else => return error.SwapBuffers,
            }
        }
    }

    pub fn resize(self: *OpenGL, width: i32, height: i32) void {
        if (width == 0 or height == 0) return;
        if (width == self.width and height == self.height) return;

        self.width = @intCast(width);
        self.height = @intCast(height);

        self.window.resize(width, height, 0, 0);
        gl.viewport(0, 0, self.width, self.height);
        gl.scissor(0, 0, self.width, self.height);
    }

    pub fn deinit(self: *OpenGL) void {
        for (self.programs.items) |program| {
            program.deinit();
        }

        if (egl.EGL_TRUE != egl.eglDestroySurface(self.display, self.surface)) std.log.err("Failed to destroy egl surface", .{});
        self.window.destroy();

        if (egl.EGL_TRUE != egl.eglDestroyContext(self.display, self.context)) std.log.err("Failed to destroy egl context", .{});
        if (egl.EGL_TRUE != egl.eglTerminate(self.display)) std.log.err("Failed to terminate egl", .{});
    }
};

fn getProcAddress(_: type, proc: [:0]const u8) ?*const anyopaque {
    return @ptrCast(egl.eglGetProcAddress(proc));
}
