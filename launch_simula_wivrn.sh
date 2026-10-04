#!/usr/bin/env bash
#
# launch_simula_wivrn.sh - run Simula on the Quest via WiVRn (OpenXR).
#
# This is the DEFAULT/standard way to run Simula (SteamVR/ALVR is deprecated).
# It is self-contained: it builds nothing at runtime except by Nix, and it
# starts every server-side component:
#
#   1. wivrn-server  - WiVRn 26.9 built by ./wivrn/flake.nix with:
#        * NVENC enabled (nixpkgs' WiVRn builds with WIVRN_USE_NVENC=FALSE,
#          which is why hardware encoding and good colour were impossible;
#          the Vulkan encoder is glitchy/pink on NVIDIA),
#        * ffmpeg_7 (NVENC API 12.1) so it matches the installed NVIDIA
#          driver 565.77 (NVENC API 12.2), unlike ffmpeg 9 (API 13),
#        * a patch to suppress controller/hand-interaction devices
#          (WIVRN_NO_CONTROLLERS=1) so Simula does not spawn pointer rays.
#   2. OpenXR runtime selection via XR_RUNTIME_JSON.
#   3. Audio routing: the WiVRn virtual speaker (wivrn.sink) is set as the
#      default output so game audio reaches the headset (WiVRn's README).
#   4. godot/simula, run under a glibc-2.44 loader because WiVRn 26.9's
#      Monado runtime needs GLIBC_2.43 and Simula is built against 2.39.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

WIVRN="${SCRIPT_DIR}/.wivrn-nvenc-26.9"
RUNTIME_JSON="${WIVRN}/share/openxr/1/openxr_wivrn.json"
PROJECT_JSON="${SCRIPT_DIR}/result/opt/simula/project.godot"
GLIBC244="/nix/store/h4wfwic161kxrr74jlzla5lsm28hgary-glibc-2.44-25"

# Build the NVENC WiVRn if it is not present (reproducible from ./wivrn/flake.nix).
if [ ! -x "${WIVRN}/bin/wivrn-server" ]; then
    echo "Building WiVRn 26.9 (NVENC) from ./wivrn/flake.nix ..."
    nix build "${SCRIPT_DIR}#wivrn-nvenc" --out-link "${SCRIPT_DIR}/.wivrn-nvenc-26.9"
fi

[ -f "${RUNTIME_JSON}" ] || { echo "WiVRn runtime not found: ${RUNTIME_JSON}" >&2; exit 1; }
[ -f "${PROJECT_JSON}" ] || { echo "Simula build not found: ${PROJECT_JSON}" >&2; echo "Run 'nix build' in ${SCRIPT_DIR} first." >&2; exit 1; }

# --- 1. WiVRn server ---------------------------------------------------
# Server detection: the process comm is truncated (".wivrn-server-w"), so
# match on the command line of *this* build.
if ! pgrep -f "${WIVRN}/bin/wivrn-server" >/dev/null 2>&1; then
    echo "Starting WiVRn server (NVENC, no controllers)..."
    # LD_LIBRARY_PATH exposes /run/opengl-driver/lib so libavcodec can
    # dlopen libnvidia-encode.so.1 (NixOS keeps it outside the RUNPATH).
    # WIVRN_NO_CONTROLLERS=1 suppresses controllers/hand-interaction.
    nohup env -u LD_LIBRARY_PATH \
        LD_LIBRARY_PATH=/run/opengl-driver/lib \
        XDG_RUNTIME_DIR="/run/user/$(id -u)" \
        WIVRN_NO_CONTROLLERS=1 \
        "${WIVRN}/bin/wivrn-server" >/tmp/wivrn-server.log 2>&1 </dev/null &
    # Wait for the control port to come up.
    for _ in $(seq 1 20); do
        ss -ltn 2>/dev/null | grep -q ':9757 ' && break
        sleep 0.5
    done
fi

# --- 2. OpenXR runtime -------------------------------------------------
export XR_RUNTIME_JSON="${RUNTIME_JSON}"
echo "XR_RUNTIME_JSON=${XR_RUNTIME_JSON}"

# --- 3. Audio ----------------------------------------------------------
# WiVRn creates a virtual speaker named "wivrn.sink"; the headset hears
# whatever is routed to it. Make it the default output for the session.
if command -v pactl >/dev/null 2>&1 && pactl list short sinks 2>/dev/null | grep -q wivrn.sink; then
    pactl set-default-sink wivrn.sink 2>/dev/null || true
    echo "Default audio output set to wivrn.sink (headset)."
fi

# --- 4. Simula (godot) -------------------------------------------------
# Simula uses its OpenXR backend whenever XR_RUNTIME_JSON is set
# (addons/godot-haskell-plugin/src/Plugin/Simula.hs).
GODOT_BIN="$(command -v godot)"
echo "Launching Simula..."
exec "${GLIBC244}/lib/ld-linux-x86-64.so.2" \
    --library-path "${GLIBC244}/lib:${LD_LIBRARY_PATH:-}" \
    "${GODOT_BIN}" -m "${PROJECT_JSON}" "$@"
