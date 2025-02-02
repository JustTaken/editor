const Window = @import("window.zig").Window;
const OpenGL = @import("renderer.zig").OpenGL;

pub fn main() !void {
    var window: Window = undefined;

    try window.init(800, 600);
    defer window.deinit();

    while (window.running) {
        try window.draw();
    }
    // try OpenGL.init();
}
