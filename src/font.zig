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
    height: u32,
    width: u32,
    descender: i32,
    ascender: i32,

    pub fn new(path: [:0]const u8, size: u32) error{Init}!FreeType {
        var self: FreeType = undefined;

        if (c.FT_Init_FreeType(&self.lib) != 0) return error.Init;
        if (c.FT_New_Face(self.lib, path, 0, &self.face) != 0) return error.Init;
        if (c.FT_Set_Pixel_Sizes(self.face, size, size) != 0) return error.Init;


        self.ascender = @intCast(self.face[0].size[0].metrics.ascender >> 6);
        self.descender = @intCast(self.face[0].size[0].metrics.descender >> 6);

        self.height = @intCast(self.face[0].size[0].metrics.height >> 6);

        const baseChar = self.findChar('a') catch return error.Init;
        self.width = baseChar.advance;

        return self;
    }

    pub fn findChar(self: *FreeType, code: u32) error{CharNotFound}!Char {
        var char: Char = undefined;

        if (c.FT_Load_Char(self.face, code, c.FT_LOAD_RENDER) != 0) return error.CharNotFound;

        char.advance = @intCast(self.face[0].glyph[0].advance.x >> 6);
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

test "testing" {
    var font = try FreeType.new("assets/font.ttf", 50);
        // self.height = @intCast(( - ) >> 6);
    std.debug.print("advance: {}\n", .{font.width});

    const START: u32 = 'B';
    const COUNT: u32 = 1;
    for (START..START + COUNT) |k| {
        const code: u8 = @intCast(k);
        const char = try font.findChar(code);
        std.debug.print("char {c}\n", .{code});
        const buffer = char.buffer.?;

        for (0..char.height) |i| {
            for (0..char.width) |j| {
                if (buffer[i * char.width + j] == 0) {
                    std.debug.print("    ", .{});
                } else {
                    std.debug.print("{d:0>3} ", .{buffer[i * char.width + j]});
                }
            }

            std.debug.print("\n", .{});
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("ascender: {}, descender: {}, height: {}, actual: {}\n", .{font.face[0].size[0].metrics.ascender >> 6, font.face[0].size[0].metrics.descender >> 6, font.face[0].size[0].metrics.height >> 6, font.height});
    // _ = font;
}
