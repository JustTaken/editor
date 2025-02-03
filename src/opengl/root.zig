const std = @import("std");
const gl = @import("zgl");
const wl = @import("wayland").client.wl;
const shader = @import("shader.zig");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const FixedAllocator = std.heap.FixedBufferAllocator;

const Program = shader.Program;
const Uniform = shader.Uniform;
const Data = @import("data.zig").Data;

const egl = @cImport({
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
});

const VertexData = struct {
    position: [3]f32,
    color: [3]f32,
    texture: [2]f32,
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
            egl.EGL_CONTEXT_MAJOR_VERSION,       4,
            egl.EGL_CONTEXT_MINOR_VERSION,       6,
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
                try Data.new(
                    VertexData,
                    &.{
                        .{ .position = .{ 0.5, 0.5, 0.0 }, .color = .{ 1.0, 0.0, 0.0 }, .texture = .{ 1.0, 1.0 } },
                        .{ .position = .{ 0.5, -0.5, 0.0 }, .color = .{ 0.0, 1.0, 0.0 }, .texture = .{ 1.0, 0.0 } },
                        .{ .position = .{ -0.5, -0.5, 0.0 }, .color = .{ 0.0, 0.0, 1.0 }, .texture = .{ 0.0, 0.0 } },
                        .{ .position = .{ -0.5, 0.5, 0.0 }, .color = .{ 1.0, 0.0, 1.0 }, .texture = .{ 0.0, 1.0 } },
                    },
                    &.{
                        0, 1, 3,
                        1, 2, 3,
                    },
                    &.{},
                    &.{
                        .{ .path = "assets/container.jpg", .name = "textureSampler" },
                        .{ .path = "assets/awesomeface.png", .name = "textureSampler2" },
                    },
                    fixedAllocator,
                ),
                .{ "assets/vertex.glsl", "assets/fragment.glsl" },
                fixedAllocator,
            ),
        ) catch return error.OutOfMemory;

        self.width = width;
        self.height = height;

        gl.viewport(0, 0, width, height);
        gl.scissor(0, 0, width, height);
        gl.clearColor(1.0, 1.0, 0.5, 1.0);
    }

    pub fn drawTriangle(self: *OpenGL) void {
        self.programs.items[0].draw();
    }

    pub fn clear(_: *OpenGL) void {
        gl.clear(.{ .color = true });
    }

    pub fn render(self: *OpenGL) error{ InvalidDisplay, InvalidSurface, ContextLost, SwapBuffers }!void {
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
