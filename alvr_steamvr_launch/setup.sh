#!/usr/bin/env bash
#
# setup.sh - make ALVR + SteamVR work on this machine, reproducibly.
#
# Why this exists
# ---------------
# SteamVR's vrcompositor must take a DRM lease on the virtual "ALVR
# display". ALVR implements that with a vrcompositor-wrapper plus a
# Vulkan layer (VK_LAYER_ALVR_capture) and a drm-lease shim. On this
# machine only the ALVR **20.6.1** wrapper/layer expose the display that
# matches the driver's 4992x2624 render target. With the ALVR 20.12.1
# layer, vrcompositor fails with
#
#     Failed to start compositor: VRInitError_Compositor_CannotDRMLeaseDisplay
#
# and the headset shows a black screen instead of the SteamVR mountain,
# with a "key component isn't working correctly" error.
#
# The ALVR driver itself is 20.12.1 (20.6.1's driver segfaults SteamVR).
# So the fix is a mixed setup:
#
#   driver/dashboard : ALVR 20.12.1   (custom build in ~/Code/alvr)
#   vrcompositor set : ALVR 20.6.1    (wrapper + Vulkan layer + shim)
#
# This script (re)creates that 20.6.1 compositor set from the GC-rooted
# stock appimage, registers the 20.12.1 driver, fixes SteamVR settings,
# and installs a watchdog (steamvr-addons.service) that keeps the
# wrapper/layer pinned and add-ons enabled. It is idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ALVR_SRC="$HOME/Code/alvr"
ALVR_RESULT="$ALVR_SRC/result"
COMPAT="$ALVR_SRC/.alvr-compat"
STOCK="$ALVR_SRC/.alvr-compat-gc-root"

STEAM_DIR="$HOME/.local/share/Steam"
STEAMVR="$STEAM_DIR/steamapps/common/SteamVR"
STEAMVR_BIN="$STEAMVR/bin/linux64"
VRPATHREG="$STEAMVR_BIN/vrpathreg"
SETTINGS="$STEAM_DIR/config/steamvr.vrsettings"
COMPOSITOR="$STEAMVR_BIN/vrcompositor"
OPENVRPATHS="$HOME/.config/openvr/openvrpaths.vrpath"
ALVR_CONFIG="$HOME/.config/alvr/session.json"

CRASHFIX_SHIM="$SCRIPT_DIR/crashfix/alvr_drm_lease_shim.so"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------
# 0. Basic sanity
# ----------------------------------------------------------------------
[ -d "$STEAMVR" ] || die "SteamVR not found at $STEAMVR"

# ----------------------------------------------------------------------
# 1. Custom ALVR 20.12.1 (driver + dashboard)
# ----------------------------------------------------------------------
if [ ! -x "$ALVR_RESULT/bin/alvr_dashboard" ]; then
    info "Custom ALVR build missing; running 'nix build' in $ALVR_SRC"
    ( cd "$ALVR_SRC" && nix build )
fi

ALVR_STORE="$(readlink -f "$ALVR_RESULT")"
# Resolve through the manifest symlink so we register the real store path
# (the flake's result is a symlinkJoin; registering it directly would add
# a second, duplicate ALVR driver to openvrpaths.vrpath).
DRIVER_MANIFEST="$(readlink -f "$ALVR_STORE/lib/alvr/driver.vrdrivermanifest")"
DRIVER_PATH="$(dirname "$DRIVER_MANIFEST")"
[ -f "$DRIVER_MANIFEST" ] || die "ALVR driver manifest not found in $ALVR_STORE/lib/alvr"
info "ALVR 20.12.1 driver: $DRIVER_PATH"

# ----------------------------------------------------------------------
# 2. Stock ALVR 20.6.1 compositor set (from the GC-rooted appimage)
# ----------------------------------------------------------------------
if [ ! -e "$STOCK/usr/libexec/alvr/vrcompositor-wrapper" ]; then
    candidate="$(ls -d /nix/store/*-alvr-20.6.1-extracted 2>/dev/null | head -n1 || true)"
    [ -n "$candidate" ] \
        || die "ALVR 20.6.1 compat set not found (looked for /nix/store/*-alvr-20.6.1-extracted)"
    warn "$STOCK is stale; re-pointing it at $candidate"
    ln -sfn "$candidate" "$STOCK"
fi

# ----------------------------------------------------------------------
# 3. Build the compat compositor set (this is the actual bug fix)
# ----------------------------------------------------------------------
info "Installing ALVR 20.6.1 vrcompositor-wrapper + Vulkan layer"
install -d \
    "$COMPAT/usr/libexec/alvr" \
    "$COMPAT/usr/lib64" \
    "$COMPAT/usr/share/vulkan/explicit_layer.d"

# wrapper + manifest + Vulkan layer, all from the stock 20.6.1 appimage
rm -f "$COMPAT/usr/libexec/alvr/vrcompositor-wrapper"
install -m755 "$STOCK/usr/libexec/alvr/vrcompositor-wrapper" \
               "$COMPAT/usr/libexec/alvr/vrcompositor-wrapper"
rm -f "$COMPAT/usr/share/vulkan/explicit_layer.d/alvr_x86_64.json"
install -m644 "$STOCK/usr/share/vulkan/explicit_layer.d/alvr_x86_64.json" \
               "$COMPAT/usr/share/vulkan/explicit_layer.d/alvr_x86_64.json"
# *** The 20.6.1 layer is the critical piece. ***
rm -f "$COMPAT/usr/lib64/libalvr_vulkan_layer.so"
install -m755 "$STOCK/usr/lib64/libalvr_vulkan_layer.so" \
               "$COMPAT/usr/lib64/libalvr_vulkan_layer.so"

# drm-lease shim: preserve a pre-existing (NVIDIA crash-fix) shim, back
# it up, otherwise install the stock 20.6.1 shim.
SHIM="$COMPAT/usr/libexec/alvr/alvr_drm_lease_shim.so"
if [ -f "$SHIM" ]; then
    install -Dm755 "$SHIM" "$CRASHFIX_SHIM" 2>/dev/null || true
elif [ -f "$CRASHFIX_SHIM" ]; then
    install -Dm755 "$CRASHFIX_SHIM" "$SHIM"
else
    rm -f "$SHIM"
    install -m755 "$STOCK/usr/libexec/alvr/alvr_drm_lease_shim.so" "$SHIM"
    warn "Using stock drm-lease shim (no NVIDIA crash-fix backup found)"
fi

# ----------------------------------------------------------------------
# 4. Register the ALVR 20.12.1 driver with SteamVR
# ----------------------------------------------------------------------
if [ -x "$VRPATHREG" ]; then
    # Drop every existing ALVR driver entry so exactly one (ours) remains.
    mapfile -t stale < <(python3 - "$OPENVRPATHS" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
except Exception:
    sys.exit(0)
for p in cfg.get("external_drivers", []):
    if "alvr" in p.lower():
        print(p)
PY
)
    for p in "${stale[@]:-}"; do
        [ -n "$p" ] || continue
        [ "$p" = "$DRIVER_PATH" ] && continue
        info "Removing stale ALVR driver: $p"
        "$VRPATHREG" removedriver "$p" >/dev/null 2>&1 || true
    done
    if ! grep -q "$DRIVER_PATH" "$OPENVRPATHS" 2>/dev/null; then
        info "Registering ALVR driver with SteamVR"
        "$VRPATHREG" adddriver "$DRIVER_PATH"
    else
        info "ALVR driver already registered"
    fi
else
    warn "vrpathreg not found; skipping driver registration"
fi

# ----------------------------------------------------------------------
# 5. SteamVR settings: never Safe-Mode ALVR, disable crash-prone paths
# ----------------------------------------------------------------------
if [ -f "$SETTINGS" ]; then
    info "Fixing $SETTINGS"
    python3 - "$SETTINGS" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
    steamvr = cfg.setdefault("steamvr", {})
    steamvr.pop("blocked_by_safe_mode", None)
    steamvr["enableMotionSmoothing"] = True
    steamvr["disableAsync"] = False
    steamvr["enableHomeApp"] = False
    # The GTX 1050 Ti cannot afford manual supersampling: at
    # renderTargetScale 1.3 on top of the ALVR render target, the app fell
    # behind, game_latency exceeded 250ms and ALVR resynced the pose (the
    # recenter). Let SteamVR auto-scale and cap the resolution.
    steamvr["supersampleManualOverride"] = False
    steamvr["renderTargetScale"] = 1.0
    steamvr["maxRecommendedResolution"] = 2048
    # NVIDIA + XWayland: the Vulkan async-reprojection path segfaults the
    # compositor in libnvidia-glcore (ValveSoftware/SteamVR-for-Linux#488,
    # #550). Keep it off; SteamVR's own default is false.
    steamvr["enableLinuxVulkanAsync"] = False
    # Per-app/global "Use Legacy Reprojection Mode". On Linux the ALVR
    # direct-mode driver disables SteamVR's async reprojection, so head
    # rotation is not corrected at scan-out; the legacy path is the
    # workaround recommended in ALVR issues #2082 / #2667.
    steamvr["legacyReprojection"] = True
    # Valid mirror keys. The old values (mirrorViewDisplayMode 0,
    # mirrorViewEye 2) made vrcompositor log "Found bad mirror window
    # settings" and take a fallback path right before the direct-mode
    # surface setup. Use SteamVR's defaults instead.
    steamvr["mirrorView"] = 0
    steamvr["showLegacyMirrorView"] = False
    steamvr["mirrorViewDisplayMode"] = 1
    steamvr["mirrorViewEye"] = 1
    steamvr["showMirrorView"] = False

with open(path, "w") as f:
    json.dump(cfg, f, indent=3)
PY
else
    warn "$SETTINGS not found; launch SteamVR once, then re-run setup.sh"
fi

# ----------------------------------------------------------------------
# 5b. ALVR session settings: keep the encoder inside the GTX 1050 Ti's
#     Pascal NVENC limits. H.264 level 5.x caps the bitrate at ~240 Mbps;
#     the dashboard's 350 Mbps made every per-second bitrate
#     reconfiguration fail:
#
#         Encoder: failed to reconfigure nvenc: invalid param (8):
#                  Invalid value for HRD bitrate.
#
#     Each failure stalls the stream (the view lags, then snaps back), so
#     pin a valid constant bitrate + fast NVENC config. This runs before
#     the dashboard starts (the `alvr` launcher calls setup.sh first), so
#     the dashboard reads these values. It also re-applies them on every
#     launch, because the dashboard rewrites session.json on exit.
# ----------------------------------------------------------------------
if [ -f "$ALVR_CONFIG" ]; then
    info "Fixing $ALVR_CONFIG"
    python3 - "$ALVR_CONFIG" <<'PY'
import json, os, sys
path = sys.argv[1]
raw = open(path, encoding="utf-8", errors="replace").read()
try:
    cfg = json.loads(raw)
except json.JSONDecodeError:
    # The ALVR dashboard rewrites session.json non-atomically; a write that
    # raced ours can leave two concatenated JSON objects. Keep the first
    # complete object instead of aborting and leaving the file unreadable.
    cfg, _ = json.JSONDecoder().raw_decode(raw)
    print("WARN: repaired truncated/concatenated session.json", file=sys.stderr)

ovr = cfg.setdefault("openvr_config", {})
ovr["eye_resolution_width"] = 1280
ovr["eye_resolution_height"] = 1280
ovr["target_eye_resolution_width"] = 1280
ovr["target_eye_resolution_height"] = 1280
ovr["refresh_rate"] = 72
ovr["codec"] = 0
ovr["force_sw_encoding"] = False
ovr["enable_foveated_encoding"] = True
# Async reprojection in ALVR's Vulkan layer: reprojects the submitted eye
# textures with the newest head pose at present time. Without it (and with
# SteamVR async disabled by the direct-mode driver) head rotation is only
# updated at encode time, which feels like laggy/off tracking.
ovr["linux_async_compute"] = False
ovr["linux_async_reprojection"] = True
ovr["nvenc_quality_preset"] = 1          # P1 (fastest)
ovr["nvenc_tuning_preset"] = 3           # UltraLowLatency
ovr["nvenc_multi_pass"] = 0              # Disabled
ovr["nvenc_adaptive_quantization_mode"] = 0  # Disabled

ss = cfg.setdefault("session_settings", {})
video = ss.setdefault("video", {})
video["preferred_fps"] = 72.0
video["max_buffering_frames"] = 1.0
video["enforce_server_frame_pacing"] = True

# ALVR derives the real per-eye render/stream resolution from these two,
# NOT from openvr_config.eye_resolution_* (which it overwrites on connect).
# They were "Absolute 1856" -> 3712x1920, far beyond the GTX 1050 Ti, so
# the app fell behind and game_latency exceeded 250ms -> ALVR logged
# "Desync detected" and resynced the pose (the recenter). Pin them low.
for _key in ("transcoding_view_resolution", "emulated_headset_view_resolution"):
    _fs = video.setdefault(_key, {})
    _fs["variant"] = "Absolute"
    _fs.setdefault("Absolute", {})["width"] = 1280
    _fs["Absolute"].setdefault("height", {"set": False, "content": 0})["set"] = False

bitrate = video.setdefault("bitrate", {})
mode = bitrate.setdefault("mode", {})
mode["variant"] = "ConstantMbps"
mode["ConstantMbps"] = 100
bitrate.setdefault("adapt_to_framerate", {})["enabled"] = False

ec = video.setdefault("encoder_config", {})
ec.setdefault("rate_control_mode", {})["variant"] = "Cbr"
nvenc = ec.setdefault("nvenc", {})
nvenc.setdefault("quality_preset", {})["variant"] = "P1"
nvenc.setdefault("tuning_preset", {})["variant"] = "UltraLowLatency"
nvenc.setdefault("multi_pass", {})["variant"] = "Disabled"
nvenc.setdefault("adaptive_quantization_mode", {})["variant"] = "Disabled"

conn = ss.setdefault("connection", {})
conn["max_queued_server_video_frames"] = 16

ss.setdefault("extra", {}).setdefault("patches", {})["linux_async_reprojection"] = True

log = ss.setdefault("extra", {}).setdefault("logging", {})
log["log_to_disk"] = True
log["log_tracking"] = True
log["notification_level"] = {"variant": "Debug"}
clr = log.setdefault("client_log_report_level", {})
clr["enabled"] = True
clr.setdefault("content", {})["variant"] = "Debug"
dbg = log.setdefault("debug_groups", {})
for _k in ("server_impl", "client_impl", "server_core", "client_core",
           "connection", "sockets", "server_gfx", "client_gfx",
           "encoder", "decoder"):
    dbg[_k] = True
ss.pop("logging", None)  # remove the key written by an earlier buggy version

# Write atomically so a concurrent dashboard write cannot interleave.
_tmp = path + ".tmp"
with open(_tmp, "w") as f:
    json.dump(cfg, f, indent=2)
os.replace(_tmp, path)
PY
else
    warn "$ALVR_CONFIG not found; launch ALVR once, then re-run setup.sh"
fi

# ----------------------------------------------------------------------
# 5c. NVIDIA GL crash mitigation. vrcompositor's worker thread segfaults
#     inside libnvidia-glcore.so (see `coredumpctl list`); the view then
#     freezes and snaps back a second or two later. GL threaded
#     optimizations are a known cause of libnvidia-glcore crashes, so
#     turn them off for the whole SteamVR process tree by exporting it in
#     SteamVR's own launcher (which the SteamVR launch options already
#     invoke, so vrcompositor inherits it). Idempotent.
# ----------------------------------------------------------------------
VRMONITOR_SH="$STEAMVR/bin/vrmonitor.sh"
if [ -f "$VRMONITOR_SH" ] && ! grep -q '__GL_THREADED_OPTIMIZATIONS' "$VRMONITOR_SH"; then
    info "Patching $VRMONITOR_SH (__GL_THREADED_OPTIMIZATIONS=0)"
    python3 - "$VRMONITOR_SH" <<'PY'
import sys
p = sys.argv[1]
out, inserted = [], False
for ln in open(p).read().splitlines(keepends=True):
    out.append(ln)
    if not inserted and ln.startswith("VRBINDIR="):
        out.append("export __GL_THREADED_OPTIMIZATIONS=0\n")
        inserted = True
open(p, "w").writelines(out)
PY
fi

# ----------------------------------------------------------------------
# 5d. SteamVR must run in the host environment, NOT inside a Steam Linux
#     Runtime. The runtimes break the ALVR driver (that is why ALVR's
#     Linux-Troubleshooting wiki mandates the vrmonitor.sh launch
#     option); forcing, e.g., "Steam Linux Runtime 1.0 (scout)" makes the
#     stream lag badly. Steam only rewrites config.vdf on exit, so edit it
#     here only when Steam is closed; otherwise warn.
# ----------------------------------------------------------------------
CONFIG_VDF="$STEAM_DIR/config/config.vdf"
if [ -f "$CONFIG_VDF" ]; then
    if pgrep -x steam >/dev/null 2>&1; then
        if grep -A5 '"250820"' "$CONFIG_VDF" | grep -q 'steamlinuxruntime'; then
            warn "SteamVR is forced to run in a Steam Linux Runtime. ALVR needs it native:"
            warn "  Steam -> SteamVR -> Properties -> Compatibility -> uncheck 'Force the use of a specific Steam Play compatibility tool'."
        fi
    else
        python3 - "$CONFIG_VDF" <<'PY'
import re, sys
p = sys.argv[1]
t = open(p, errors="surrogateescape").read()
t, n = re.subn(
    r'\n[ \t]*"250820"[ \t]*\n[ \t]*\{[^{}]*"steamlinuxruntime"[^{}]*\}\n',
    '\n', t, count=1)
if n:
    open(p, "w", errors="surrogateescape").write(t)
    print("removed forced Steam Linux Runtime for SteamVR")
PY
    fi
fi

rm -f \
    "$STEAM_DIR/config/vrserver_crash_timestamp.txt" \
    "$STEAM_DIR/logs/vrserver_crash_timestamp.txt" \
    "$STEAMVR_BIN/vrserver_crash_timestamp.txt"

# ----------------------------------------------------------------------
# 6. Install + start the watchdog service
# ----------------------------------------------------------------------
info "Installing steamvr-addons watchdog service"
install -d "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/steamvr-addons.service" <<EOF
[Unit]
Description=Keep SteamVR add-ons enabled and pin the ALVR 20.6.1 compositor
After=default.target

[Service]
Type=simple
ExecStart=$SCRIPT_DIR/steamvr-keep-addons-enabled.sh
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
chmod 755 "$SCRIPT_DIR/steamvr-keep-addons-enabled.sh"
systemctl --user daemon-reload
systemctl --user enable steamvr-addons >/dev/null 2>&1 || true
systemctl --user restart steamvr-addons

# ----------------------------------------------------------------------
# 7. Pin the compositor wrapper now (the watchdog keeps it pinned)
# ----------------------------------------------------------------------
ln -sfn "$COMPAT/usr/libexec/alvr/vrcompositor-wrapper" "$COMPOSITOR"

info "Done."
echo
echo "  ALVR driver : $DRIVER_PATH"
echo "  compositor  : $COMPOSITOR -> $(readlink "$COMPOSITOR")"
echo "  layer       : $COMPAT/usr/lib64/libalvr_vulkan_layer.so"
echo
echo "Launch ALVR with: $SCRIPT_DIR/alvr"
echo "Then connect the Quest and press 'Launch SteamVR' in ALVR."
