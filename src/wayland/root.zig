const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const Input = @import("../input.zig").Xkbcommon;

pub const Wayland = struct {
    display: *wl.Display,
    registry: *wl.Registry,
    seat: *wl.Seat,
    compositor: *wl.Compositor,
    surface: *wl.Surface,
    wmBase: *xdg.WmBase,
    wmSurface: *xdg.Surface,
    toplevel: *xdg.Toplevel,
    keyboard: *wl.Keyboard,

    input: Input,

    resizeCallbackFn: *const fn (*anyopaque, i32, i32) void,
    resizeCallbackListener: *anyopaque,

    running: bool,

    pub fn init(self: *Wayland) !void {
        self.display = try wl.Display.connect(null);
        self.registry = try self.display.getRegistry();

        self.registry.setListener(*Wayland, registryListener, self);

        if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        self.wmSurface = try self.wmBase.getXdgSurface(self.surface);
        self.wmSurface.setListener(*Wayland, wmSurfaceListener, self);

        self.toplevel = try self.wmSurface.getToplevel();
        self.toplevel.setListener(*Wayland, toplevelListener, self);

        self.surface.commit();

        if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    }

    pub fn update(self: *Wayland) error{Dispatch}!void {
        if (self.display.dispatch() != .SUCCESS) return error.Dispatch;
    }

    pub fn getHandle(self: *Wayland) *wl.Display {
        return self.display;
    }

    pub fn getSurface(self: *Wayland) *wl.Surface {
        return self.surface;
    }

    pub fn deinit(self: *const Wayland) void {
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

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, data: *Wayland) void {
    switch (event) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                data.seat = registry.bind(global.name, wl.Seat, global.version) catch return;
                data.seat.setListener(*Wayland, seatListener, data);
            } else if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                data.compositor = registry.bind(global.name, wl.Compositor, global.version) catch return;
                data.surface = data.compositor.createSurface() catch return;
            } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                data.wmBase = registry.bind(global.name, xdg.WmBase, global.version) catch return;
                data.wmBase.setListener(*Wayland, wmBaseListener, data);
            }
        },
        .global_remove => {},
    }
}

fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, data: *Wayland) void {
    switch (event) {
        .name => {},
        .capabilities => |d| {
            if (!d.capabilities.keyboard) @panic("Do not support keyboard");

            data.keyboard = seat.getKeyboard() catch @panic("Failed to get keyboard");
            data.keyboard.setListener(*Wayland, keyboardListener, data);
        },
    }
}

fn wmBaseListener(wmBase: *xdg.WmBase, event: xdg.WmBase.Event, _: *Wayland) void {
    switch (event) {
        .ping => |p| wmBase.pong(p.serial),
    }
}

fn wmSurfaceListener(wmSurface: *xdg.Surface, event: xdg.Surface.Event, _: *Wayland) void {
    switch (event) {
        .configure => |c| wmSurface.ackConfigure(c.serial),
    }
}

fn toplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, data: *Wayland) void {
    switch (event) {
        .close => data.running = false,
        .wm_capabilities => |c| _ = c,
        .configure_bounds => |c| _ = c,
        .configure => |c| data.resizeCallbackFn(data.resizeCallbackListener, c.width, c.height),
    }
}

fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, data: *Wayland) void {
    switch (event) {
        .key => |k| data.input.handle(k.key, k.state),
        .modifiers => |m| data.input.mask(m.mods_depressed, m.mods_latched, m.mods_locked, m.group),
        .repeat_info => |i| data.input.repeatInfo(i.rate, i.delay),
        .enter => |_| {},
        .leave => |_| {},
        .keymap => |k| {
            defer std.posix.close(k.fd);

            const file = std.posix.mmap(null, k.size, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, k.fd, 0) catch @panic("Failed to open file");
            defer std.posix.munmap(file);

            data.input.init(@ptrCast(file), k.format) catch @panic("Failed to initialize keymap");
        },
    }
}
