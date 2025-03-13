let
  pkgs = import <nixpkgs> {};
in
pkgs.mkShell {
  packages = with pkgs; [
    (callPackage "/home/joao/.local/share/projects/builds/kak" {})
    emacs30-pgtk
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
    freetype.dev
    freetype
    gdb
    renderdoc
  ];

  LD_LIBRARY_PATH = "${pkgs.wayland}/lib:${pkgs.libGL}/lib:${pkgs.libxkbcommon}/lib:${pkgs.freetype}/lib";
  C_INCLUDE_PATH = "${pkgs.wayland.dev}/include:${pkgs.libGL.dev}/include:${pkgs.libxkbcommon.dev}/include:${pkgs.stb}/include:${pkgs.freetype.dev}/include";
}
