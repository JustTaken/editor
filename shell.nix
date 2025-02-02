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
    libxkbcommon
    libxkbcommon.dev
    pkg-config
    stb
  ];

  LD_LIBRARY_PATH = "${pkgs.wayland}/lib:${pkgs.libGL}/lib:${pkgs.libxkbcommon}/lib";
  C_INCLUDE_PATH = "${pkgs.wayland.dev}/include:${pkgs.libGL.dev}/include:${pkgs.libxkbcommon.dev}/include:${pkgs.stb}/include";
}
