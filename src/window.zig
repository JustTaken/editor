const std = @import("std");
const wayland = @import("wayland");

const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const Allocator = std.mem.Allocator;

const Renderer = @import("renderer.zig").OpenGL;
const Input = @import("input.zig").Xkbcommon;

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

    renderer: Renderer,
    input: Input,

    running: bool,

    pub fn init(
        self: *Window,
        width: u32,
        height: u32,
        allocator: Allocator,
    ) !void {
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

        try self.renderer.init(
            width,
            height,
            self.display,
            self.surface,
            allocator,
        );

        self.running = true;
    }

    pub fn draw(self: *Window) !void {
        try self.renderer.render();
        if (self.display.dispatch() != .SUCCESS) return error.Dispatch;

        sleep(30);
    }

    pub fn deinit(self: *Window) void {
        self.renderer.deinit();
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

fn sleep(ms: u32) void {
    std.time.sleep(ms * std.time.ns_per_ms);
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
        .global_remove => {},
    }
}

fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, data: *Window) void {
    switch (event) {
        .name => {},
        .capabilities => |d| {
            if (!d.capabilities.keyboard) @panic("Do not support keyboard");

            data.keyboard = seat.getKeyboard() catch @panic("Failed to get keyboard");
            data.keyboard.setListener(*Window, keyboardListener, data);
        },
    }
}

fn wmBaseListener(wmBase: *xdg.WmBase, event: xdg.WmBase.Event, _: *Window) void {
    switch (event) {
        .ping => |p| wmBase.pong(p.serial),
    }
}

fn wmSurfaceListener(wmSurface: *xdg.Surface, event: xdg.Surface.Event, _: *Window) void {
    switch (event) {
        .configure => |c| wmSurface.ackConfigure(c.serial),
    }
}

fn toplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, data: *Window) void {
    switch (event) {
        .close => data.running = false,
        .wm_capabilities => |c| _ = c,
        .configure_bounds => |c| _ = c,
        .configure => |c| data.renderer.resize(c.width, c.height),
    }
}

fn keyboardListener(keyboard: *wl.Keyboard, event: wl.Keyboard.Event, data: *Window) void {
    _ = keyboard;

    switch (event) {
        .key => |k| data.input.handle(k.key, k.state),
        .modifiers => |m| data.input.mask(m.mods_depressed, m.mods_latched, m.mods_locked, m.group),
        .repeat_info => |i| data.input.repeatInfo(i.rate, i.delay),
        .enter => |e| std.debug.print("Enter: {}\n", .{e}),
        .leave => |l| std.debug.print("Leave: {}\n", .{l}),
        .keymap => |k| {
            defer std.posix.close(k.fd);

            const file = std.posix.mmap(null, k.size, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, k.fd, 0) catch @panic("Failed to open file");
            defer std.posix.munmap(file);

            data.input.init(@ptrCast(file), k.format) catch @panic("Failed to initialize keymap");
        },
    }
}
