const std = @import("std");
const wayland = @import("wayland");

const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const OpenGL = @import("renderer.zig").OpenGL;

pub const Window = struct {
    display: *wl.Display,
    registry: *wl.Registry,
    seat: *wl.Seat,
    compositor: *wl.Compositor,
    surface: *wl.Surface,
    wmBase: *xdg.WmBase,
    wmSurface: *xdg.Surface,
    toplevel: *xdg.Toplevel,
    keyboard: *wl.Keyboard,

    openGL: OpenGL,

    width: u32,
    height: u32,
    running: bool,

    pub fn init(self: *Window, width: u32, height: u32) !void {
        self.display = try wl.Display.connect(null);
        self.registry = try self.display.getRegistry();

        self.registry.setListener(*Window, registryListener, self);

        if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        self.wmSurface = try self.wmBase.getXdgSurface(self.surface);
        self.wmSurface.setListener(*Window, wmSurfaceListener, self);

        self.toplevel = try self.wmSurface.getToplevel();
        self.toplevel.setListener(*Window, toplevelListener, self);

        self.surface.commit();

        if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        self.width = width;
        self.height = height;

        try self.openGL.init(width, height, self.display, self.surface);

        self.running = true;
    }

    pub fn draw(self: *Window) !void {
        try self.openGL.update();
        if (self.display.dispatch() != .SUCCESS) return error.Dispatch;
        std.time.sleep(30 * std.time.ns_per_ms);
    }

    fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, data: *Window) void {
        switch (event) {
            .global => |global| {
                if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                    data.seat = registry.bind(global.name, wl.Seat, global.version) catch return;
                    data.seat.setListener(*Window, seatListener, data);
                } else if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                    data.compositor = registry.bind(global.name, wl.Compositor, global.version) catch return;
                    data.surface = data.compositor.createSurface() catch return;
                } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                    data.wmBase = registry.bind(global.name, xdg.WmBase, global.version) catch return;
                    data.wmBase.setListener(*Window, wmBaseListener, data);
                }
            },
            .global_remove => {}
        }
    }

    fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, data: *Window) void {
        switch (event) {
            .capabilities => |d| {
                if (d.capabilities.keyboard) {
                    data.keyboard = seat.getKeyboard() catch @panic("Failed to get keyboard");
                    data.keyboard.setListener(*Window, keyboardListener, data);
                } else {
                    @panic("Do not support keyboard");
                }
                // std.debug.print("Capabilities: {}, {} {}\n", .{d.capabilities.pointer, d.capabilities.keyboard, d.capabilities.touch});
            },
            .name => {}
        }
    }

    fn wmBaseListener(wmBase: *xdg.WmBase, event: xdg.WmBase.Event, _: *Window) void {
        switch (event) {
            .ping => |p| {
                wmBase.pong(p.serial);
            }
        }
    }

    fn wmSurfaceListener(wmSurface: *xdg.Surface, event: xdg.Surface.Event, _: *Window) void {
        switch (event) {
            .configure => |c| {
                wmSurface.ackConfigure(c.serial);
            }
        }
    }

    fn toplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, data: *Window) void {
        switch (event) {
            .close => data.running = false,
            .wm_capabilities => |c| {
                _ = c;
            },
            .configure_bounds => |c| {
                _ = c;
            },
            .configure => |c| {
                if (c.width == 0 or c.height == 0) return;

                data.width = @intCast(c.width);
                data.height = @intCast(c.height);
                data.openGL.resize(c.width, c.height);
            },
        }
    }

    fn keyboardListener(keyboard: *wl.Keyboard, event: wl.Keyboard.Event, data: *Window) void {
        _ = keyboard;
        _ = data;
        switch (event) {
            .keymap => |k| {
                std.debug.print("Keymap: {}\n", .{k});
            },
            .enter => |e| {
                std.debug.print("Enter: {}\n", .{e});
            },
            .leave => |l| {
                std.debug.print("Leave: {}\n", .{l});
            },
            .key => |k| {
                std.debug.print("Key: {}\n", .{k});
            },
            .modifiers => |m| {
                std.debug.print("Modifiers: {}\n", .{m});
            },
            .repeat_info => |r| {
                std.debug.print("Repeat info: {}\n", .{r});
            },
        }
    }

    pub fn deinit(self: *Window) void {
        self.openGL.deinit();
        self.keyboard.release();
        self.toplevel.destroy();
        self.wmSurface.destroy();
        self.wmBase.destroy();
        self.surface.destroy();
        self.compositor.destroy();
        self.registry.destroy();
        self.display.disconnect();
    }
};
