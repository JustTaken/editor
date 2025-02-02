let
  pkgs = import <nixpkgs> {};
in
pkgs.mkShell {
  packages = with pkgs; [
    helix
    git
    zig
    zls
    libGL
    libGL.dev
    wayland.dev
    wayland
    wayland-scanner
    wayland-protocols
    vulkan-loader
    pkg-config
  ];

  LD_LIBRARY_PATH = "${pkgs.wayland}/lib:${pkgs.libGL}/lib";
  C_INCLUDE_PATH = "${pkgs.wayland.dev}/include:${pkgs.libGL.dev}/include";
}
