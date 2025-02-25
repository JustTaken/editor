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

    pub const Error = error {
        EglLoadingExtensions,
        EglMakeCurrent,
        EglContext,
        EglDisplay,
        EglConfigAttribute,
        EglMatch,
        EglCreateConetxt,
        EglAlloc,
        EglAttribute,
        EglConfig,
        EglAccess,
        EglFail,
        EglParameter,
        EglApi,
        EglNativeWindow,
        EglCreatSurface,
        EglSurfaceAttribute,
    };

    /// Initializes opengl context with EGL library using the passed wayland
    /// display and surface.
    pub fn init(
        self: *OpenGL,
        width: u32,
        height: u32,
        display: *wl.Display,
        surface: *wl.Surface,
    ) Error!void {
        self.display = egl.eglGetPlatformDisplay(egl.EGL_PLATFORM_WAYLAND_KHR, display, null);

        var eglMajor: egl.EGLint = 0;
        var eglMinor: egl.EGLint = 0;

        if (egl.EGL_TRUE != egl.eglInitialize(self.display, &eglMajor, &eglMinor)) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_DISPLAY => return Error.EglDisplay,
                else => return Error.EglFail,
            }
        }

        // Egl configuration attributes, enabling attributes has to be done here.
        const aglAttributes = [_]egl.EGLint{
            egl.EGL_SURFACE_TYPE,    egl.EGL_WINDOW_BIT,
            egl.EGL_RENDERABLE_TYPE, egl.EGL_OPENGL_BIT,
            egl.EGL_STENCIL_SIZE,    0,
            egl.EGL_SAMPLES,         0,
            egl.EGL_RED_SIZE,        8,
            egl.EGL_GREEN_SIZE,      8,
            egl.EGL_BLUE_SIZE,       8,
            egl.EGL_ALPHA_SIZE,      8,
            egl.EGL_DEPTH_SIZE,      8,
            egl.EGL_NONE,
        };

        var eglConfig: egl.EGLConfig = undefined;
        var numConfigs: egl.EGLint = 0;

        if (egl.EGL_TRUE != egl.eglChooseConfig(self.display, &aglAttributes, &eglConfig, 1, &numConfigs)) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_ATTRIBUTE => return Error.EglConfigAttribute,
                else => return Error.EglConfig,
            }
        }

        if (egl.EGL_TRUE != egl.eglBindAPI(egl.EGL_OPENGL_API)) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_PARAMETER => return Error.EglParameter,
                else => return Error.EglApi,
            }
        }

        const windowAttributes = [_]egl.EGLAttrib{
            egl.EGL_GL_COLORSPACE, egl.EGL_GL_COLORSPACE_LINEAR,
            egl.EGL_RENDER_BUFFER, egl.EGL_BACK_BUFFER,
            egl.EGL_NONE,
        };

        self.window = wl.EglWindow.create(surface, @intCast(width), @intCast(height)) catch return Error.EglNativeWindow;
        self.surface = egl.eglCreatePlatformWindowSurface(self.display, eglConfig, self.window, &windowAttributes) orelse switch (egl.eglGetError()) {
            egl.EGL_BAD_MATCH => return Error.EglMatch,
            egl.EGL_BAD_CONFIG => return Error.EglConfig,
            egl.EGL_BAD_NATIVE_WINDOW => return Error.EglNativeWindow,
            else => return Error.EglCreatSurface,
        };

        if (egl.EGL_TRUE != egl.eglSurfaceAttrib(self.display, self.surface, egl.EGL_SWAP_BEHAVIOR, egl.EGL_BUFFER_DESTROYED)) {
            switch (egl.eglGetError()) {
                else => return Error.EglSurfaceAttribute,
            }
        }

        // Specifies the current opengl version, and the core profile to enforce the "new"
        // opengl api usage
        const contextAttributes = [_]egl.EGLint{
            egl.EGL_CONTEXT_MAJOR_VERSION,       4,
            egl.EGL_CONTEXT_MINOR_VERSION,       6,
            egl.EGL_CONTEXT_OPENGL_PROFILE_MASK, egl.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
            egl.EGL_NONE,
        };

        self.context = egl.eglCreateContext(self.display, eglConfig, egl.EGL_NO_CONTEXT, &contextAttributes) orelse switch (egl.eglGetError()) {
            egl.EGL_BAD_ATTRIBUTE => return Error.EglAttribute,
            egl.EGL_BAD_CONFIG => return Error.EglConfig,
            egl.EGL_BAD_MATCH => return Error.EglMatch,
            else => return Error.EglCreateConetxt,
        };

        if (egl.eglMakeCurrent(self.display, self.surface, self.surface, self.context) != egl.EGL_TRUE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_ACCESS => return Error.EglAccess,
                egl.EGL_BAD_MATCH => return Error.EglMatch,
                egl.EGL_BAD_NATIVE_WINDOW => return Error.EglNativeWindow,
                egl.EGL_BAD_CONTEXT => return Error.EglContext,
                egl.EGL_BAD_ALLOC => return Error.EglAlloc,
                else => return Error.EglMakeCurrent,
            }
        }

        gl.loadExtensions(void, getProcAddress) catch return Error.EglLoadingExtensions;

        // Enabling debug in my experience has to be a two factor process, first enable the
        // `debug_output` then enable `debug_output_synchronous`
        gl.enable(.debug_output);
        gl.enable(.debug_output_synchronous);

        // Enable clockwise front face orientation
        gl.enable(.cull_face);

        gl.enable(.depth_test);
        gl.depthFunc(.less_or_equal);

        gl.enable(.blend);
        gl.blendFunc(.src_alpha, .one_minus_src_alpha);

        // Font bitmaps may not be aligned to 4
        // bytes as opengl might enforce by default
        gl.pixelStore(.unpack_alignment, 1);

        gl.debugMessageCallback({}, errorCallback);

        self.width = width;
        self.height = height;

        gl.viewport(0, 0, width, height);
        gl.scissor(0, 0, width, height);
        gl.clearColor(224.0 / 255.0, 122.0 / 255.0, 95.0 / 255.0, 1.0);
    }

    pub fn render(self: *OpenGL) error{ InvalidDisplay, InvalidSurface, ContextLost, SwapBuffers }!void {
        // Opengl is working with double buffering, so the back buffer is the one that the
        // previous draw calls rendered to, now to show this pixel buffer into the screen
        // swaping with the current shwoing one is neede.
        if (egl.eglSwapBuffers(self.display, self.surface) != egl.EGL_TRUE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_DISPLAY => return error.InvalidDisplay,
                egl.EGL_BAD_SURFACE => return error.InvalidSurface,
                egl.EGL_CONTEXT_LOST => return error.ContextLost,
                else => return error.SwapBuffers,
            }
        }

        // Clear the current back buffer, in other words, the buffer that was beeing display just
        // before the previous call to eglSwapBuffers, now it is blank.
        gl.clear(.{ .color = true, .depth = true });
    }

    /// Called when window display change the size, so opengl needs to change its scissor and viewport
    pub fn resizeListener(ptr: *anyopaque, width: u32, height: u32) void {
        const self: *OpenGL = @ptrCast(@alignCast(ptr));

        if (width == self.width and height == self.height) return;

        self.width = width;
        self.height = height;

        self.window.resize(@intCast(width), @intCast(height), 0, 0);

        gl.viewport(0, 0, self.width, self.height);
        gl.scissor(0, 0, self.width, self.height);

        self.render() catch @panic("TODO");
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
