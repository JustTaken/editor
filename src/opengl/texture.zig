const std = @import("std");
const gl = @import("zgl");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

pub const Texture = struct {
    handle: gl.Texture,

    pub fn new(
        width: u32,
        height: u32,
        channels: u32,
        format: gl.TextureInternalFormat,
        data: [*]u8,
    ) Texture {
        var self: Texture = undefined;

        self.handle = gl.genTexture();

        gl.bindTexture(self.handle, .@"2d");

        gl.texParameter(.@"2d", .wrap_s, .mirrored_repeat);
        gl.texParameter(.@"2d", .wrap_t, .mirrored_repeat);
        gl.texParameter(.@"2d", .min_filter, .nearest_mipmap_nearest);
        gl.texParameter(.@"2d", .mag_filter, .nearest);

        const inputMode: gl.PixelFormat = switch (channels) {
            1 => .red,
            3 => .rgb,
            4 => .rgba,
            else => @panic("color mode not supported"),
        };

        gl.textureImage2D(.@"2d", 0, format, width, height, inputMode, .unsigned_byte, data);
        gl.generateMipmap(.@"2d");

        gl.bindTexture(gl.Texture.invalid, .@"2d");

        return self;
    }

    pub fn bind(self: *const Texture, loc: u32, index: u32) void {
        gl.bindTextureUnit(self.handle, index);
        gl.uniform1i(loc, @intCast(index));
    }

    pub fn unbind(_: *const Texture, index: u32) void {
        gl.bindTextureUnit(gl.Texture.invalid, index);
    }

    pub fn deinit(self: *const Texture) void {
        self.handle.delete();
    }
};
