const std = @import("std");
const gl = @import("zgl");

const c = @cImport({
    @cInclude("stb/stb_image.h");
});

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

pub const Texture = struct {
    handle: gl.Texture,
    name: [:0]const u8,
    loc: u32,
    width: u32,
    height: u32,
    channels: u32,
    data: [*]u8,

    pub fn init(
        self: *Texture,
        path: [:0]const u8,
        name: [:0]const u8,
        loc: u32,
    ) void {
        self.loc = loc;
        self.name = name;

        var width: i32 = undefined;
        var height: i32 = undefined;
        var channels: i32 = undefined;

        self.handle = gl.genTexture();

        gl.bindTexture(self.handle, .@"2d");

        gl.texParameter(.@"2d", .wrap_s, .mirrored_repeat);
        gl.texParameter(.@"2d", .wrap_t, .mirrored_repeat);
        gl.texParameter(.@"2d", .min_filter, .nearest_mipmap_nearest);
        gl.texParameter(.@"2d", .mag_filter, .nearest);

        self.data = c.stbi_load(path, &width, &height, &channels, 0);
        defer c.stbi_image_free(self.data);

        self.width = @intCast(width);
        self.height = @intCast(height);
        self.channels = @intCast(channels);

        const inputMode: gl.PixelFormat = switch (self.channels) {
            3 => .rgb,
            4 => .rgba,
            else => @panic("color mode not supported"),
        };

        gl.textureImage2D(.@"2d", 0, .rgb, self.width, self.height, inputMode, .unsigned_byte, self.data);
        gl.generateMipmap(.@"2d");

        gl.bindTexture(gl.Texture.invalid, .@"2d");
    }

    pub fn deinit(self: *const Texture) void {
        self.handle.delete();
    }
};
