# Monado-ALVR: Monado OpenXR runtime with the ALVR streaming driver.
#
# Build layout (as required by the upstream WIP instructions):
#   monado-alvr/                     <- cmake source dir
#   alvr_render/                     <- sibling, add_subdirectory'd in
#   alvr-monado/build/alvr_server_core/libalvr_server_core.so  <- from alvr-server-core
#   alvr-monado/build/alvr_server_core/alvr_server_core.h      <- replaces alvr_binding.h symlink
{
  lib,
  stdenv,
  cmake,
  ninja,
  pkg-config,
  python3,
  glslang,
  eigen,
  libdrm,
  wayland,
  wayland-protocols,
  wayland-scanner,
  libXau,
  libxcb,
  libXdmcp,
  libXext,
  libXrandr,
  libGL,
  shaderc,
  vulkan-headers,
  vulkan-loader,
  zlib,
  zstd,
  ffmpeg-full,
  x264,
  src,
  alvrRenderSrc,
  alvr-server-core,
  ...
}:

let
  # ffmpeg with CUDA/NVENC for hardware encoding (required by the 1050 Ti).
  ffmpeg = ffmpeg-full.override { withUnfree = true; };
in
stdenv.mkDerivation {
  pname = "monado-alvr";
  version = "unstable-2024-12-28";

  src = stdenv.mkDerivation {
    name = "monado-alvr-src-layout";
    dontUnpack = true;
    buildCommand = ''
      mkdir -p $out
      cp -r ${src} $out/monado-alvr
      cp -r ${alvrRenderSrc} $out/alvr_render
      chmod -R u+w $out

      # Patch alvr_render (software encode path, shader dir, cmake fixes)
      (cd $out/alvr_render && patch -p1 < ${./patches/alvr-render.patch})

      # ALVR server core: lib + generated C header in the layout the cmake expects.
      # Replace the alvr_binding.h symlink (points into ../alvr-monado/build/...) with the real header.
      mkdir -p $out/alvr-monado/build/alvr_server_core
      cp ${alvr-server-core}/lib/libalvr_server_core.so $out/alvr-monado/build/alvr_server_core/
      cp ${alvr-server-core}/lib/alvr_server_core.h $out/alvr-monado/build/alvr_server_core/
      rm $out/alvr_render/src/alvr_binding.h
      cp ${alvr-server-core}/lib/alvr_server_core.h $out/alvr_render/src/alvr_binding.h
    '';
  };

  sourceRoot = "monado-alvr";

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    python3
    glslang
  ];

  buildInputs = [
    eigen
    libdrm
    wayland
    wayland-protocols
    wayland-scanner
    libXau
    libxcb
    libXdmcp
    libXext
    libXrandr
    libGL
    shaderc
    vulkan-headers
    vulkan-loader
    zlib
    zstd
    ffmpeg
    x264
  ];

  cmakeFlags = [
    "-DXRT_FEATURE_SERVICE=ON"
    "-DXRT_OPENXR_INSTALL_ABSOLUTE_RUNTIME_PATH=ON"
    "-DXRT_BUILD_DRIVER_ALVR=ON"
    "-DXRT_HAVE_LIBUSB=OFF"
    "-DXRT_HAVE_OPENVR=OFF"
    "-DXRT_HAVE_DBUS=OFF"
    "-DXRT_HAVE_LIBUVC=OFF"
    "-DXRT_BUILD_DRIVER_NS=OFF"
    "-DXRT_BUILD_DRIVER_SIMULATED=OFF"
    "-DXRT_BUILD_DRIVER_TWRAP=OFF"
    "-DXRT_BUILD_DRIVER_REMOTE=OFF"
    "-DXRT_BUILD_DRIVER_WMR=OFF"
    "-DXRT_BUILD_DRIVER_VIVE=OFF"
    "-DXRT_BUILD_DRIVER_OHMD=OFF"
    "-DXRT_BUILD_SAMPLES=OFF"
    "-DXRT_BUILD_TESTS=OFF"
    "-DXRT_BUILD_DOCS=OFF"
    "-DCMAKE_BUILD_TYPE=Release"
  ];

  # Runtime shaders for the ALVR render pipeline (prebuilt .spv from alvr_render).
  # Encoder.cpp / FormatConverter.cpp resolve these via the ALVR_SHADER_DIR define.
  env.CXXFLAGS = "-DALVR_SHADER_DIR=\\\"$out/share/alvr-render/shader\\\"";

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib
    install -Dm755 src/xrt/targets/service/monado-service $out/libexec/monado-service
    install -Dm755 src/xrt/targets/cli/monado-cli $out/bin/monado-cli
    install -Dm755 src/xrt/targets/ctl/monado-ctl $out/bin/monado-ctl
    install -Dm644 src/xrt/targets/libmonado/libopenxr_monado.so.0 $out/lib/libopenxr_monado.so.0

    # Runtime manifest (absolute paths via XRT_OPENXR_INSTALL_ABSOLUTE_RUNTIME_PATH)
    mkdir -p $out/share/openxr/1
    cp openxr_monado.json $out/share/openxr/1/ 2>/dev/null || true

    # ALVR render shaders
    mkdir -p $out/share/alvr-render/shader
    cp -r ../alvr_render/src/shader/*.spv $out/share/alvr-render/shader/

    # Setuid-capable wrapper for device access is handled by the NixOS config;
    # here we just link the binaries into bin/.
    ln -sf $out/libexec/monado-service $out/bin/monado-service

    runHook postInstall
  '';

  postFixup = ''
    # Ensure libopenxr_monado + ffmpeg libs are found at runtime.
    for f in $out/libexec/monado-service $out/bin/monado-cli; do
      patchelf --add-rpath $out/lib --add-rpath ${lib.makeLibraryPath [ ffmpeg vulkan-loader libGL ]} $f 2>/dev/null || true
    done
  '';

  meta = {
    description = "Monado OpenXR runtime with integrated ALVR streaming driver";
    homepage = "https://github.com/alvr-org/Monado-ALVR";
    license = lib.licenses.boost;
    platforms = lib.platforms.linux;
    mainProgram = "monado-service";
  };
}
