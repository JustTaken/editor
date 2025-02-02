const std = @import("std");
const wl = @import("wayland").client.wl;
const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
});

const EVDEV_SCANCODE_OFFSET: u32 = 8;
const Keys = std.EnumSet(Key);

pub const Xkbcommon = struct {
    context: *xkb.xkb_context,
    keymap: *xkb.xkb_keymap,
    state: *xkb.xkb_state,

    keys: Keys,

    rate: u32,
    delay: u32,

    pub fn init(self: *Xkbcommon, keymap: [*:0]const u8, format: wl.Keyboard.KeymapFormat) error{Init, Keymap, State}!void {
        self.context = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse return error.Init;
        self.keymap = xkb.xkb_keymap_new_from_string(self.context, keymap, @intCast(@intFromEnum(format)), xkb.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return error.Keymap;
        self.state = xkb.xkb_state_new(self.keymap) orelse return error.State;
        self.keys = Keys.initEmpty();
        self.repeatInfo(20, 200);
    }

    pub fn mask(self: *Xkbcommon, depressed: u32, latched: u32, locked: u32, group: u32) void {
        _ = xkb.xkb_state_update_mask(self.state, depressed, latched, locked, 0, 0, group);
    }

    pub fn repeatInfo(self: *Xkbcommon, rate: i32, delay: i32) void {
        self.rate = @intCast(rate * std.time.ns_per_ms);
        self.delay = @intCast(delay * std.time.ns_per_ms);
    }

    pub fn handle(self: *Xkbcommon, code: u32, state: wl.Keyboard.KeyState) void {
        const sym = xkb.xkb_state_key_get_one_sym(self.state, code + EVDEV_SCANCODE_OFFSET);
        // var name: [64]u8 = undefined;

        // _ = xkb.xkb_keysym_get_name(sym, &name, 64);

        const key: Key = std.meta.intToEnum(Key, sym) catch {
            std.log.err("Failed to register key: {} event", .{sym});
            return;
        };

        switch (state) {
            .pressed => self.keys.insert(key),
            .released => self.keys.remove(key),
            _ => {},
        }
    }
};

const Key = enum(u32) {
    Space = 32,
    Comma = 44,
    Minus = 45,
    Period = 46,
    Slash = 47,

    Zero = 48,
    One = 49,
    Two = 50,
    Three = 51,
    Four = 52,
    Five = 53,
    Six = 54,
    Seven = 55,
    Eight = 56,
    Nine = 57,
    Semicolon = 59,

    Equal = 61,

    Backslash = 92,

    BracketLeft = 91,
    BracketRight = 93,

    LowerA = 97,
    LowerB = 98,
    LowerC = 99,
    LowerD = 100,
    LowerE = 101,
    LowerF = 102,
    LowerG = 103,
    LowerH = 104,
    LowerI = 105,
    LowerJ = 106,
    LowerK = 107,
    LowerL = 108,
    LowerM = 109,
    LowerN = 110,
    LowerP = 112,
    LowerQ = 113,
    LowerR = 114,
    LowerT = 116,
    LowerU = 117,
    LowerS = 115,
    LowerV = 118,
    LowerW = 119,
    LowerX = 120,
    LowerY = 121,
    LowerZ = 122,

    ControlL = 65507,
    ControlR = 65508,

    Backspace = 65288,
    Tab = 65289,
    Enter = 65293,

    Escape = 65307,

    ArrowLeft = 65361,
    ArrowUp = 65362,
    ArrowRight = 65363,
    ArrowDown = 65364,

    F1 = 65470,
    F2 = 65471,
    F3 = 65472,
    F4 = 65473,
    F5 = 65474,
    F6 = 65475,
    F7 = 65476,
    F8 = 65477,
    F9 = 65478,
    F10 = 65479,
    F11 = 65480,
    F12 = 65481,

    ShiftL = 65505,
    ShiftR = 65506,

    AltL = 65513,

    SuperL = 65515,

    // _,
};

