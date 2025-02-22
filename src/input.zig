const std = @import("std");
const wl = @import("wayland").client.wl;
const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
});

const EVDEV_SCANCODE_OFFSET: u32 = 8;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const Keys = std.EnumSet(Key);

pub const Xkbcommon = struct {
    context: *xkb.xkb_context,
    keymap: *xkb.xkb_keymap,
    state: *xkb.xkb_state,

    keys: Keys,
    last: ?Key,

    keyArray: ArrayList(Key),

    listeners: [3]*anyopaque,
    listenerFns: [3]*const fn (*anyopaque, Key, bool, bool) void,
    listenerCount: u32,

    controlIndex: u32,
    altIndex: u32,

    rate: i32,
    delay: i32,

    time: isize,
    repeating: bool,
    working: bool,

    initialized: bool,

    pub fn new(allocator: Allocator) error{OutOfMemory}!Xkbcommon {
        var self: Xkbcommon = undefined;

        self.keyArray = try ArrayList(Key).initCapacity(allocator, 5);

        self.keys = Keys.initEmpty();
        self.repeatInfo(20, 200);
        self.repeating = false;
        self.working = false;
        self.initialized = false;
        self.listenerCount = 0;

        return self;
    }

    pub fn init(self: *Xkbcommon, keymap: [*:0]const u8, format: wl.Keyboard.KeymapFormat) error{ Init, Keymap, State }!void {
        self.context = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse return error.Init;
        self.keymap = xkb.xkb_keymap_new_from_string(self.context, keymap, @intCast(@intFromEnum(format)), xkb.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return error.Keymap;
        self.state = xkb.xkb_state_new(self.keymap) orelse return error.State;

        self.controlIndex = xkb.xkb_keymap_mod_get_index(self.keymap, xkb.XKB_MOD_NAME_CTRL);
        self.altIndex = xkb.xkb_keymap_mod_get_index(self.keymap, xkb.XKB_MOD_NAME_ALT);

        self.time = std.time.milliTimestamp();
        self.initialized = true;
        self.last = null;
    }

    fn resetRepeat(self: *Xkbcommon) void {
        if (self.working) {
            self.keyArray.clearRetainingCapacity();
        }

        self.repeating = false;
        self.working = false;
        self.time = std.time.milliTimestamp();

        var iter = self.keys.iterator();

        while (iter.next()) |k| {
            self.keys.remove(k);
        }
    }

    pub fn tick(self: *Xkbcommon) void {
        if (self.keys.count() == 0 and self.keyArray.items.len == 0) return;
        const time = std.time.milliTimestamp();

        if (!self.repeating) {
            if (time >= self.time + self.delay) self.repeating = true;
        }

        if (self.working and !(self.repeating and time >= self.time + self.rate)) return;

        self.time = time;
        self.working = true;

        const controlPressed = self.isControlPressed();
        const altPressed = self.isAltPressed();

        if (!self.working) {
            for (self.keyArray.items) |key| {
                for (0..self.listenerCount) |i| {
                    self.listenerFns[i](self.listeners[i], key, controlPressed, altPressed);
                }
            }

            const last = self.keyArray.pop();

            self.keyArray.clearRetainingCapacity();

            if (self.keys.contains(last)) {
                self.keyArray.append(last) catch return;
            }
        } else {
            for (0..self.listenerCount) |i| {
                self.listenerFns[i](self.listeners[i], self.keyArray.getLast(), controlPressed, altPressed);
            }
        }


        // std.debug.print("pressing some keys: {}\n", .{self.keyArray.items.len});
        // const last = self.keyArray.pop();

        // var iter = self.keys.iterator();
        // while (iter.next()) |key| {
        //     for (0..self.listenerCount) |i| {
        //         self.listenerFns[i](self.listeners[i], key, controlPressed, altPressed);
        //     }

        //     self.keys.remove(key);
        //     std.debug.print("{}, ", .{key});
        // }

        // std.debug.print("inserting: {}\n", .{self.last.?});

        // self.keys.insert(self.last.?);
    }

    pub fn newListener(self: *Xkbcommon, listener: *anyopaque, f: *const fn (*anyopaque, Key, bool, bool) void) void {
        self.listeners[self.listenerCount] = listener;
        self.listenerFns[self.listenerCount] = f;
        self.listenerCount += 1;
    }

    pub fn mask(self: *Xkbcommon, depressed: u32, latched: u32, locked: u32, group: u32) void {
        _ = xkb.xkb_state_update_mask(self.state, depressed, latched, locked, 0, 0, group);
    }

    pub fn repeatInfo(self: *Xkbcommon, rate: i32, delay: i32) void {
        self.rate = rate;
        self.delay = delay;
    }

    pub fn isControlPressed(self: *const Xkbcommon) bool {
        return xkb.xkb_state_mod_index_is_active(self.state, self.controlIndex, xkb.XKB_STATE_MODS_DEPRESSED) != 0;
    }

    pub fn isAltPressed(self: *const Xkbcommon) bool {
        return xkb.xkb_state_mod_index_is_active(self.state, self.altIndex, xkb.XKB_STATE_LAYOUT_EFFECTIVE) != 0;
    }

    pub fn leave(self: *Xkbcommon) void {
        var iter = self.keys.iterator();

        while (iter.next()) |k| {
            self.keys.remove(k);
        }

        self.last = null;
    }

    pub fn handle(self: *Xkbcommon, code: u32, state: wl.Keyboard.KeyState) void {
        const sym = xkb.xkb_state_key_get_one_sym(self.state, code + EVDEV_SCANCODE_OFFSET);

        const key: Key = std.meta.intToEnum(Key, sym) catch {
            var name: [64]u8 = undefined;

            _ = xkb.xkb_keysym_get_name(sym, &name, 64);

            std.log.err("Failed to register key: {s} code: {} event", .{ name, sym });

            return;
        };

        if (xkb.xkb_keymap_key_repeats(self.keymap, code + EVDEV_SCANCODE_OFFSET) == 0) return;
        self.resetRepeat();

        switch (state) {
            .pressed => {
                self.keyArray.append(key) catch return;
                // self.last = key;
                // std.debug.print("last: {}\n", .{key});
                self.keys.insert(key);
            },
            .released => {
                self.keys.remove(key);
            },
            _ => {},
        }
    }

    pub fn deinit(self: *const Xkbcommon) void {
        if (!self.initialized) return;

        xkb.xkb_state_unref(self.state);
        xkb.xkb_keymap_unref(self.keymap);
        xkb.xkb_context_unref(self.context);
    }
};


pub const Key = enum(u32) {
    Space = 32,
    Exclamation = 33,
    DoubleQuote = 34,
    NumberSign = 35,
    Dollar = 36,
    Percent = 37,
    Anpersand = 38,
    Apostrophe = 39,
    ParenLeft = 40,
    ParenRight = 41,
    Asterisk = 42,
    Plus = 43,
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
    Colon = 58,
    Semicolon = 59,

    Less = 60,
    Equal = 61,
    Greater = 62,
    Question = 63,
    At = 64,

    UpperA = 65,
    UpperB = 66,
    UpperC = 67,
    UpperD = 68,
    UpperE = 69,
    UpperF = 70,
    UpperG = 71,
    UpperH = 72,
    UpperI = 73,
    UpperJ = 74,
    UpperK = 75,
    UpperL = 76,
    UpperM = 77,
    UpperN = 78,
    UpperO = 79,
    UpperP = 80,
    UpperQ = 81,
    UpperR = 82,
    UpperT = 83,
    UpperU = 84,
    UpperS = 85,
    UpperV = 86,
    UpperW = 87,
    UpperX = 88,
    UpperY = 89,
    UpperZ = 90,

    BracketLeft = 91,
    Backslash = 92,
    BracketRight = 93,
    Circum = 94,

    Underscore = 95,

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
    LowerO = 111,
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
    BraceLeft = 123,
    Pipe = 124,
    BreceRight = 125,

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
    CapsLock = 65509,
    MetaL = 65511,

    AltL = 65513,

    SuperL = 65515,

    pub const NON_DISPLAYABLE: u32 = 65000;
};
