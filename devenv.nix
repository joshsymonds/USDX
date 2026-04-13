{ pkgs, lib, ... }:

let
  runtimeLibs = with pkgs; [
    SDL2 SDL2_image
    ffmpeg_7
    sqlite freetype
    portaudio portmidi
    lua5_4
    xorg.libX11 xorg.libXext xorg.libXrandr xorg.libXcursor xorg.libXi xorg.libXinerama
    libGL
    projectm_3 opencv4
  ];
in
{
  packages = with pkgs; [
    # Free Pascal compiler
    fpc

    # USDX required libs
    SDL2
    SDL2_image
    ffmpeg_7
    sqlite
    freetype
    portaudio
    portmidi
    lua5_4
    dejavu_fonts

    # X11 libs for USDX linker (SDL2 links against libX11 directly)
    xorg.libX11
    xorg.libXext
    xorg.libXrandr
    xorg.libXcursor
    xorg.libXi
    xorg.libXinerama
    libGL

    # Optional USDX features
    projectm_3    # audio visualization (libprojectM)
    opencv4       # webcam support
    cmake         # needed by some optional feature probes

    # Build tooling
    autoconf
    automake
    pkg-config
    gnumake
    gcc

    # Workflow helpers
    just
    git
  ];

  enterShell = ''
    export LD_LIBRARY_PATH="${lib.makeLibraryPath runtimeLibs}:/run/opengl-driver/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    echo "USDX devenv: fpc $(fpc -iV 2>/dev/null || echo '?')"
  '';
}
