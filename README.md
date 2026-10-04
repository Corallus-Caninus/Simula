# Simula — VR setup (WiVRn / OpenXR)

**The standard VR backend for Simula on this machine is [WiVRn](https://github.com/WiVRn/WiVRn) (OpenXR + Monado).**

**SteamVR + ALVR is deprecated** — do not use it. It is kept only as a
historical fallback (see `alvr_steamvr_launch/`) and is **not** the supported
path. Every problem we hit (vrcompositor crashing in `libnvidia-glcore`,
`Desync`/pose-resync recentering, display-lease failures, the 20.6.1/20.12.1
compositor-driver mismatch) is specific to the SteamVR path and disappears
with WiVRn.

## TL;DR

```bash
nix build .#simula          # or: nix build
./result/bin/simula         # this is all you run
```

`result/bin/simula` now:

1. **Starts WiVRn automatically** if `wivrn-server` is not already running.
2. Sets `XR_RUNTIME_JSON` to the WiVRn 26.9 OpenXR runtime, which makes
   Simula use its **OpenXR** backend (`Plugin/Simula.hs` chooses OpenXR
   whenever `XR_RUNTIME_JSON` is set).
3. Routes game audio to the headset (`wivrn.sink` as default sink).
4. Runs `godot` under a glibc‑2.44 loader (see "glibc" below).

On the headset, open the **WiVRn** app (v26.9) and connect to the published
service (`nixos`) over your wired link.

## What `.#wivrn-nvenc` is and why it exists

`nixpkgs`' WiVRn is not usable for this machine as-is:

| Problem | Fix in `.#wivrn-nvenc` |
| --- | --- |
| nixpkgs builds WiVRn with `WIVRN_USE_NVENC=FALSE`, leaving only the buggy **Vulkan** encoder on NVIDIA (pink / flashing / corrupted frames) | build with `-DWIVRN_USE_NVENC:BOOL=TRUE` |
| nixpkgs links **ffmpeg 9**, which requires **NVENC API 13**; the installed driver (565.77) supports only **API 12.2** | link **ffmpeg_7** (nv-codec-headers 12.1 → API 12.1) |
| WiVRn always exposes controllers / hand-interaction devices; Simula then spawns pointer rays that hijack input | patch (`wivrn/disable-controllers.patch`) gated by `WIVRN_NO_CONTROLLERS=1` |

Everything is defined in `flake.nix` (`packages.wivrn-nvenc`) and is fully
reproducible:

```bash
nix build .#wivrn-nvenc
```

## glibc

WiVRn 26.9's Monado runtime links against **GLIBC_2.43**. Simula is built
against **glibc 2.39**. The launcher therefore runs `godot` under a
**glibc‑2.44 loader** (`ld-linux --library-path`), which is backward
compatible and lets the OpenXR runtime be loaded.

## Required system configuration (NixOS)

In the system `configuration.nix` (`~/Code/configuration.nix`):

```nix
services.wivrn.enable = true;
services.wivrn.openFirewall = true;   # UDP/TCP 9757
services.monado.defaultRuntime = false; # WiVRn provides its own runtime
```

The NVIDIA driver must expose its encode library to the process; the
launcher sets `LD_LIBRARY_PATH=/run/opengl-driver/lib` when starting
`wivrn-server` so `libavcodec` can load `libnvidia-encode.so.1`.

## Quality settings (per-headset, in the WiVRn app)

Bitrate, render resolution, codec and bit-depth are **client-side** settings
in the WiVRn app (not the server):

- **Bitrate** — up to 200 Mbps (800 with extended config)
- **Render resolution** — the supersampling knob; raise until FPS drops
- **Codec** — H.265; **Bit depth** — 10-bit (better colour; 8-bit forces
  H.264 and washes colours out)

## Reproducing on a fresh system

1. `git clone` this repo, `cd` in.
2. `nix build .#simula` (builds Simula **and** pulls in `.#wivrn-nvenc`).
3. `./result/bin/simula`.
4. In the headset: WiVRn app → connect to the PC.

No manual `nix build .#wivrn-nvenc` step is required — the Simula wrapper
references the package directly and starts it.

## Files

- `flake.nix` — `packages.simula` (wrapper does WiVRn/OpenXR/audio) and
  `packages.wivrn-nvenc` (the patched WiVRn 26.9).
- `wivrn/disable-controllers.patch` — suppresses controller/hand devices.
- `launch_simula_wivrn.sh` — optional standalone launcher (same behaviour as
  the wrapper; useful without rebuilding).
- `alvr_steamvr_launch/`, `monado-alvr/` — **deprecated** SteamVR/ALVR
  experiments, kept for reference.
