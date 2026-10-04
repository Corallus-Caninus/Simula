#!/usr/bin/env bash
#
# steamvr-keep-addons-enabled.sh - keep the ALVR SteamVR stack healthy.
#
# Runs continuously as the `steamvr-addons` user service (see
# steamvr-addons.service, installed by setup.sh). It enforces four
# things that SteamVR / the ALVR driver otherwise clobber:
#
# 1. Add-ons never disabled.
#    When a driver crashes, SteamVR records a crash timestamp, starts in
#    Safe Mode next time and writes `blocked_by_safe_mode: true` into
#    steamvr.vrsettings. The settings UI then refuses to re-enable the
#    add-on. We strip the flag and the saved crash timestamp so ALVR can
#    always load.
#
# 2. vrcompositor wrapper pinned to the ALVR 20.6.1 wrapper.
#    The compositor only obtains the virtual "ALVR display" lease when
#    vrcompositor is wrapped by the 20.6.1 vrcompositor-wrapper. The
#    ALVR 20.12.1 driver re-points the symlink to its own wrapper on
#    SteamVR start, so we re-point it back within one second. SteamVR
#    retries the compositor until it comes up.
#
# 3. Vulkan layer pinned to the ALVR 20.6.1 layer.
#    This is the actual black-screen bug: the 20.12.1
#    libalvr_vulkan_layer.so does NOT expose the "ALVR display" to
#    SteamVR's compositor on this machine, so vrcompositor fails with
#    VRInitError_Compositor_CannotDRMLeaseDisplay and the headset stays
#    black. We keep the wrapper's sibling layer byte-identical to the
#    GC-rooted 20.6.1 appimage layer.
#
# 4. Compositor watchdog.
#    If SteamVR is up but vrcompositor has been dead for >60s it has
#    given up ("A key component of SteamVR isn't working correctly").
#    Restart SteamVR once so it gets fresh compositor retries.

set -o pipefail

HOME_DIR="${HOME}"
STEAM_CONFIG="$HOME_DIR/.local/share/Steam/config"
SETTINGS="$STEAM_CONFIG/steamvr.vrsettings"
STEAMVR_BIN="$HOME_DIR/.local/share/Steam/steamapps/common/SteamVR/bin/linux64"
COMPOSITOR="$STEAMVR_BIN/vrcompositor"

# ALVR 20.6.1 compositor set (wrapper + shim + Vulkan layer), and the
# stock 20.6.1 appimage it is derived from.
COMPAT="$HOME_DIR/Code/alvr/.alvr-compat"
STOCK="$HOME_DIR/Code/alvr/.alvr-compat-gc-root"
COMPAT_WRAPPER="$COMPAT/usr/libexec/alvr/vrcompositor-wrapper"
COMPAT_LAYER="$COMPAT/usr/lib64/libalvr_vulkan_layer.so"
STOCK_LAYER="$STOCK/usr/lib64/libalvr_vulkan_layer.so"

cleanup_once() {
    if [ -f "$SETTINGS" ] && grep -q '"blocked_by_safe_mode"' "$SETTINGS"; then
        sed -i '/"blocked_by_safe_mode"/d' "$SETTINGS"
    fi
    rm -f \
        "$STEAM_CONFIG/vrserver_crash_timestamp.txt" \
        "$HOME_DIR/.local/share/Steam/logs/vrserver_crash_timestamp.txt" \
        "$STEAMVR_BIN/vrserver_crash_timestamp.txt"
}

ensure_compositor_wrapper() {
    [ -n "$COMPAT_WRAPPER" ] || return 0

    if [ -L "$COMPOSITOR" ]; then
        # Driver (or anything else) re-wrapped it: pin it back.
        if [ "$(readlink "$COMPOSITOR")" != "$COMPAT_WRAPPER" ]; then
            ln -sfn "$COMPAT_WRAPPER" "$COMPOSITOR"
        fi
    elif [ -f "$COMPOSITOR" ] && [ -f "$COMPOSITOR.real" ]; then
        # SteamVR update restored its own binary over the wrapper.
        mv -f "$COMPOSITOR" "$COMPOSITOR.real"
        ln -sfn "$COMPAT_WRAPPER" "$COMPOSITOR"
    elif [ -f "$COMPOSITOR" ] && [ ! -f "$COMPOSITOR.real" ]; then
        # Never wrapped yet (fresh SteamVR install): wrap it.
        mv "$COMPOSITOR" "$COMPOSITOR.real"
        ln -sfn "$COMPAT_WRAPPER" "$COMPOSITOR"
    fi
}

ensure_layer() {
    [ -f "$STOCK_LAYER" ] || return 0
    [ -f "$COMPAT_LAYER" ] || return 0
    if ! cmp -s "$COMPAT_LAYER" "$STOCK_LAYER"; then
        # The 20.12.1 layer breaks DRM leasing: restore the 20.6.1 one.
        chmod u+w "$COMPAT_LAYER" 2>/dev/null || true
        cp -f "$STOCK_LAYER" "$COMPAT_LAYER" 2>/dev/null || \
            cat "$STOCK_LAYER" > "$COMPAT_LAYER" 2>/dev/null || true
    fi
}

cleanup_once
ensure_compositor_wrapper
ensure_layer

COMPOSITOR_DEAD_COUNT=0
RESTARTED_AT=0

while true; do
    sleep 1
    cleanup_once
    ensure_compositor_wrapper
    ensure_layer

    now=$(date +%s)
    # The compositor process name is truncated to "vrcompositor.re", so
    # match the full command line instead.
    if pgrep -x vrserver > /dev/null && ! pgrep -f vrcompositor > /dev/null; then
        COMPOSITOR_DEAD_COUNT=$((COMPOSITOR_DEAD_COUNT + 1))
        if [ "$COMPOSITOR_DEAD_COUNT" -ge 60 ] && \
           [ $((now - RESTARTED_AT)) -ge 300 ]; then
            echo "vrcompositor dead for 60s; restarting SteamVR"
            pkill -x vrmonitor || true
            pkill -x vrserver || true
            COMPOSITOR_DEAD_COUNT=0
            RESTARTED_AT=$now
        fi
    else
        COMPOSITOR_DEAD_COUNT=0
    fi
done
