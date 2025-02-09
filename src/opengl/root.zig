const std = @import("std");
const gl = @import("zgl");
const wl = @import("wayland").client.wl;

const egl = @cImport({
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
});

pub const OpenGL = struct {
    window: *wl.EglWindow,
    display: egl.EGLDisplay,
    context: egl.EGLContext,
    surface: egl.EGLSurface,

    width: u32,
    height: u32,

    pub fn init(
        self: *OpenGL,
        width: u32,
        height: u32,
        display: *wl.Display,
        surface: *wl.Surface,
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

        gl.enable(.debug_output);
        gl.enable(.debug_output_synchronous);
        gl.enable(.cull_face);
        gl.enable(.depth_test);
        gl.enable(.blend);
        gl.blendFunc(.src_alpha, .one_minus_src_alpha);
        gl.pixelStore(.unpack_alignment, 1);
        gl.debugMessageCallback({}, errorCallback);

        self.width = width;
        self.height = height;

        gl.viewport(0, 0, width, height);
        gl.scissor(0, 0, width, height);
        gl.clearColor(0.0, 0.0, 0.0, 1.0);
    }

    pub fn render(self: *OpenGL) error{ InvalidDisplay, InvalidSurface, ContextLost, SwapBuffers }!void {
        if (egl.eglSwapBuffers(self.display, self.surface) != egl.EGL_TRUE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_DISPLAY => return error.InvalidDisplay,
                egl.EGL_BAD_SURFACE => return error.InvalidSurface,
                egl.EGL_CONTEXT_LOST => return error.ContextLost,
                else => return error.SwapBuffers,
            }
        }

        gl.clear(.{ .color = true, .depth = true });
    }

    pub fn resizeListener(ptr: *anyopaque, width: u32, height: u32) void {
        const self: *OpenGL = @ptrCast(@alignCast(ptr));

        if (width == self.width and height == self.height) return;

        self.width = width;
        self.height = height;

        self.window.resize(@intCast(width), @intCast(height), 0, 0);

        gl.viewport(0, 0, self.width, self.height);
        gl.scissor(0, 0, self.width, self.height);
    }

    pub fn deinit(self: *OpenGL) void {
        if (egl.eglMakeCurrent(self.display, egl.EGL_NO_SURFACE, egl.EGL_NO_SURFACE, egl.EGL_NO_CONTEXT) != egl.EGL_TRUE) std.log.err("Failed to unbound egl context", .{});
        if (egl.EGL_TRUE != egl.eglDestroyContext(self.display, self.context)) std.log.err("Failed to destroy egl context", .{});

        if (egl.EGL_TRUE != egl.eglDestroySurface(self.display, self.surface)) std.log.err("Failed to destroy egl surface", .{});

        self.window.destroy();

        if (egl.EGL_TRUE != egl.eglTerminate(self.display)) std.log.err("Failed to terminate egl", .{});
    }
};

fn getProcAddress(_: type, proc: [:0]const u8) ?*const anyopaque {
    return @ptrCast(egl.eglGetProcAddress(proc));
}

fn errorCallback(source: gl.DebugSource, msg_type: gl.DebugMessageType, id: usize, severity: gl.DebugSeverity, message: []const u8) void {
    std.log.err("sourcee: {}, typ: {}, id: {}, severity: {}\n{s}", .{ source, msg_type, id, severity, message });
}
