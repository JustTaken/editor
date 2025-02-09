const std = @import("std");

const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

pub const Char = struct {
    width: u32,
    height: u32,
    advance: u32,
    bearing: [2]i32,
    buffer: ?[*]u8,
};

pub const FreeType = struct {
    lib: c.FT_Library,
    face: c.FT_Face,
    height: u16,

    pub fn new(path: [:0]const u8, size: u32) error{Init}!FreeType {
        var self: FreeType = undefined;

        if (c.FT_Init_FreeType(&self.lib) != 0) return error.Init;
        if (c.FT_New_Face(self.lib, path, 0, &self.face) != 0) return error.Init;
        if (c.FT_Set_Pixel_Sizes(self.face, size, size) != 0) return error.Init;
        self.height = @intCast((self.face[0].size[0].metrics.ascender - self.face[0].size[0].metrics.descender) >> 5);

        return self;
    }

    pub fn findChar(self: *FreeType, code: u32) error{CharNotFound}!Char {
        var char: Char = undefined;

        if (c.FT_Load_Char(self.face, code, c.FT_LOAD_RENDER) != 0) return error.CharNotFound;

        char.advance = @intCast(self.face[0].glyph[0].advance.x);
        char.width = @intCast(self.face[0].glyph[0].bitmap.width);
        char.height = @intCast(self.face[0].glyph[0].bitmap.rows);
        char.bearing = .{ self.face[0].glyph[0].bitmap_left, self.face[0].glyph[0].bitmap_top };
        char.buffer = self.face[0].glyph[0].bitmap.buffer;

        return char;
    }

    pub fn deinit(self: *const FreeType) void {
        c.FT_Done_Face(self.face);
        c.FT_Done_FreeType(self.lib);
    }
};
