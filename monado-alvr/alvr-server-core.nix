# Builds the ALVR server core C library (libalvr_server_core.so) from the
# ALVR "monado" branch, plus the cbindgen-generated C header that the
# Monado-ALVR driver binds against.
{
  lib,
  stdenv,
  cargo,
  rustc,
  cacert,
  pkg-config,
  libclang,
  wayland,
  pipewire,
  libpulseaudio,
  libudev-zero,
  glibc,
  alsa-lib,
  src,
  ...
}:

let
  # The ALVR workspace requires the openvr submodule headers (alvr_session build.rs).
  openvr = builtins.fetchTarball {
    url = "https://codeload.github.com/ValveSoftware/openvr/tar.gz/v1.23.7";
    sha256 = "0kd8sj7p7r7xi8h2kk25nmpm4ic1inh5la8iga3i6p20v3cs9mna";
  };
in
stdenv.mkDerivation {
  pname = "alvr-server-core";
  version = "21.0.0-dev11";

  src = stdenv.mkDerivation {
    name = "alvr-server-core-src";
    dontUnpack = true;
    buildCommand = ''
      mkdir -p $out
      cp -r ${src}/. $out/
      chmod -R u+w $out
      mkdir -p $out/openvr
      cp -r ${openvr}/headers $out/openvr/headers
    '';
  };


  nativeBuildInputs = [
    cargo
    rustc
    cacert
    pkg-config
    libclang
  ];

  buildInputs = [
    wayland
    pipewire
    libpulseaudio
    libudev-zero
    glibc.dev
    alsa-lib
  ];

  # crates.io TLS needs the CA bundle (network access requires sandbox=false)
  buildPhase = ''
    runHook preBuild

    export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt
    export CARGO_HOME=$TMPDIR/.cargo
    export LIBCLANG_PATH=${libclang.lib}/lib
    export BINDGEN_EXTRA_CLANG_ARGS=-isystem\ ${glibc.dev}/include

    cargo install cbindgen --root $TMPDIR/cbindgen --locked
    export PATH="$TMPDIR/cbindgen/bin:$PATH"

    cargo build --release -p alvr_server_core
    cbindgen --crate alvr_server_core --output alvr_server_core.h --lang c

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib
    cp target/release/libalvr_server_core.so $out/lib/
    cp alvr_server_core.h $out/lib/
    runHook postInstall
  '';

  meta = {
    description = "ALVR server core (monado branch) as a C library";
    homepage = "https://github.com/alvr-org/ALVR";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
