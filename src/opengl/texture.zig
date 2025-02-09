const std = @import("std");
const gl = @import("zgl");

const c = @cImport({
    @cInclude("stb/stb_image.h");
});

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

pub const Texture = struct {
    handle: gl.Texture,

    pub fn fromPath(path: [:0]const u8, internalFormat: gl.TextureInternalFormat, pixelType: gl.PixelType) Texture {
        var width: i32 = 0;
        var height: i32 = 0;
        var channels: i32 = 0;

        const data = c.stbi_load(path, &width, &height, &channels, 0);
        defer c.stbi_image_free(data);

        const dataFormat: gl.PixelFormat = switch (channels) {
            1 => .red,
            3 => .rgb,
            4 => .rgba,
            else => @panic("color mode not supported"),
        };

        return Texture.new(
            @intCast(width),
            @intCast(height),
            internalFormat,
            dataFormat,
            pixelType,
            .@"2d",
            null,
            data,
        );
    }

    pub fn new(
        width: u32,
        height: u32,
        depth: ?u32,
        internalFormat: gl.TextureInternalFormat,
        dataFormat: gl.PixelFormat,
        pixelType: gl.PixelType,
        target: gl.TextureTarget,
        data: ?[*]const u8,
    ) Texture {
        var self: Texture = undefined;

        self.handle = gl.genTexture();

        gl.bindTexture(self.handle, target);

        gl.texParameter(target, .wrap_s, .mirrored_repeat);
        gl.texParameter(target, .wrap_t, .mirrored_repeat);
        gl.texParameter(target, .min_filter, .linear);
        gl.texParameter(target, .mag_filter, .nearest);

        if (depth) |d| gl.textureImage3D(target, 0, internalFormat, width, height, d, dataFormat, pixelType, data) else gl.textureImage2D(target, 0, internalFormat, width, height, dataFormat, pixelType, data);

        gl.bindTexture(gl.Texture.invalid, target);

        return self;
    }

    pub fn pushData(
        self: *const Texture,
        width: u32,
        height: u32,
        depth: ?u32,
        dataFormat: gl.PixelFormat,
        pixelType: gl.PixelType,
        data: ?[*]const u8,
    ) void {
        if (depth) |d| gl.textureSubImage3D(self.handle, 0, 0, 0, d, width, height, 1, dataFormat, pixelType, data) else gl.textureSubImage2D(self.handle, 0, 0, 0, width, height, dataFormat, pixelType, data);
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
