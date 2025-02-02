const Window = @import("window.zig").Window;
const OpenGL = @import("renderer.zig").OpenGL;

pub fn main() !void {
    var window: Window = undefined;

    try window.init();
    defer window.deinit();
    // try OpenGL.init();
}
