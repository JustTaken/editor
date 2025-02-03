const std = @import("std");
const Build = std.Build;

const Scanner = @import("zig-wayland").Scanner;

pub fn build(builder: *Build) !void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});

    const scanner = Scanner.create(builder, .{});
    const wayland = builder.createModule(.{ .root_source_file = scanner.result });
    const zgl = builder.dependency("zgl", .{
        .target = target,
        .optimize = optimize,
    });

    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");

    scanner.generate("wl_seat", 9);
    scanner.generate("wl_compositor", 6);
    scanner.generate("xdg_wm_base", 6);

    const exe = builder.addExecutable(.{
        .name = "editor",
        .root_source_file = builder.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("wayland", wayland);
    exe.root_module.addImport("zgl", zgl.module("zgl"));

    exe.addCSourceFile(.{ .file = builder.path("assets/stb.c") });

    exe.linkSystemLibrary("wayland-egl");
    exe.linkSystemLibrary("xkbcommon");
    exe.linkSystemLibrary("EGL");
    exe.linkLibC();

    builder.installArtifact(exe);

    const run_exe = builder.addRunArtifact(exe);
    const run_step = builder.step("run", "Run the executable");

    run_step.dependOn(&run_exe.step);
}
