const std = @import("std");
const gl = @import("zgl");
const wl = @import("wayland").client.wl;

const Window = @import("window.zig").Window;

const egl = @cImport({
    // @cDefine("WL_EGL_PLATFORM", "1");
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
    @cUndef("WL_EGL_PLATFORM");
});

pub const OpenGL = struct {
    eglDisplay: egl.EGLDisplay,
    eglContext: egl.EGLContext,
    eglWindow: *wl.EglWindow,
    eglSurface: egl.EGLSurface,

    pub fn init(self: *OpenGL, width: u32, height: u32, display: *wl.Display, surface: *wl.Surface) !void {
        self.eglDisplay = egl.eglGetPlatformDisplay(egl.EGL_PLATFORM_WAYLAND_KHR, display, null);

        var egl_major: egl.EGLint = 0;
        var egl_minor: egl.EGLint = 0;

        if (egl.eglInitialize(self.eglDisplay, &egl_major, &egl_minor) != egl.EGL_TRUE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_DISPLAY => return error.EglBadDisplay,
                else => return error.EglFail,
            }
        }

        const egl_attributes: [12:egl.EGL_NONE]egl.EGLint = .{
            egl.EGL_SURFACE_TYPE, egl.EGL_WINDOW_BIT,
            egl.EGL_RENDERABLE_TYPE, egl.EGL_OPENGL_BIT,
            egl.EGL_RED_SIZE, 8,
            egl.EGL_GREEN_SIZE, 8,
            egl.EGL_BLUE_SIZE, 8,
            egl.EGL_ALPHA_SIZE, 8,
        };

        var egl_config: egl.EGLConfig = undefined;
        var num_configs: egl.EGLint = 0;

        if (egl.eglChooseConfig(self.eglDisplay, &egl_attributes, &egl_config, 1, &num_configs) != egl.EGL_TRUE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_ATTRIBUTE => return error.InvalidEglConfig,
                else => return error.EglConfig,
            }
        }

        if (egl.eglBindAPI(egl.EGL_OPENGL_API) != egl.EGL_TRUE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_PARAMETER => return error.OpenGLUnsupported,
                else => return error.InvalidApi,
            }
        }

        const context_attributes: [4:egl.EGL_NONE]egl.EGLint = .{
            egl.EGL_CONTEXT_MAJOR_VERSION, 4,
            egl.EGL_CONTEXT_MINOR_VERSION, 6,
        };

        self.eglContext = egl.eglCreateContext(self.eglDisplay, egl_config, egl.EGL_NO_CONTEXT, &context_attributes) orelse switch(egl.eglGetError()) {
            egl.EGL_BAD_ATTRIBUTE => return error.InvalidContextAttribute,
            egl.EGL_BAD_CONFIG => return error.CreateContextWithBadConfig,
            egl.EGL_BAD_MATCH => return error.UnsupportedConfig,
            else => return error.FailedToCreateContext,
        };

        try gl.loadExtensions(void, getProcAddress);
        self.eglWindow = try wl.EglWindow.create(surface, @intCast(width), @intCast(height));
        self.eglSurface = egl.eglCreatePlatformWindowSurface(self.eglDisplay, egl_config, self.eglWindow, null) orelse switch (egl.eglGetError()) {
            egl.EGL_BAD_MATCH => return error.MismatchedConfig,
            egl.EGL_BAD_CONFIG => return error.InvalidConfig,
            egl.EGL_BAD_NATIVE_WINDOW => return error.InvalidWindow,
            else => return error.FailedToCreatEglSurface,
        };

        if (egl.eglMakeCurrent(self.eglDisplay, self.eglSurface, self.eglSurface, self.eglContext) != egl.EGL_TRUE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_ACCESS => return error.EglThreadError,
                egl.EGL_BAD_MATCH => return error.MismatchedContextOrSurfaces,
                egl.EGL_BAD_NATIVE_WINDOW => return error.EglWindowInvalid,
                egl.EGL_BAD_CONTEXT => return error.InvalidEglContext,
                egl.EGL_BAD_ALLOC => return error.OutOfMemory,
                else => return error.FailedToMakeCurrent,
            }
        }

        gl.clearColor(1.0, 1.0, 0.5, 1.0);
    }

    pub fn update(self: *OpenGL) error{InvalidDisplay, InvalidSurface, ContextLost, SwapBuffers}!void {
        gl.clear(.{ .color = true });

        if (egl.eglSwapBuffers(self.eglDisplay, self.eglSurface) != egl.EGL_TRUE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_DISPLAY => return error.InvalidDisplay,
                egl.EGL_BAD_SURFACE => return error.InvalidSurface,
                egl.EGL_CONTEXT_LOST => return error.ContextLost,
                else => return error.SwapBuffers,
            }
        }
    }

    pub fn resize(self: *OpenGL, width: i32, height: i32) void {
        self.eglWindow.resize(width, height, 0, 0);
    }

    pub fn deinit(self: *OpenGL) void {
        _ = egl.eglDestroyContext(self.eglDisplay, self.eglContext);
        _ = egl.eglTerminate(self.eglDisplay);
    }
};

fn getProcAddress(_: type, proc: [:0]const u8) ?*const anyopaque {
    return @ptrCast(egl.eglGetProcAddress(proc));
}

