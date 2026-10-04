#!/usr/bin/env bash
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ALVR_BIN="$SCRIPT_DIR/alvr"
SIMULA_BIN="./result/bin/simula"

STEAM_BIN="/etc/profiles/per-user/$USER/bin/steam"
STEAMVR_APPID="250820"
STEAMVR_DRIVERS="$HOME/.local/share/Steam/steamapps/common/SteamVR/drivers"

# ------------------------------------------------------------------
# Step 1: Unblock ALVR from SteamVR Safe Mode
# Must happen before SteamVR reads its settings. SteamVR re-writes
# "blocked_by_safe_mode" : true whenever a safe mode event occurs, and
# the settings UI refuses to re-enable a blocked driver (the add-ons
# button is greyed out). Stripping the key entirely on every launch
# guarantees the driver is never blocked.
# ------------------------------------------------------------------
ALVR_UNBLOCK_SETTINGS="$HOME/.local/share/Steam/config/steamvr.vrsettings"
if [ -f "$ALVR_UNBLOCK_SETTINGS" ]; then
    if grep -q '"blocked_by_safe_mode"' "$ALVR_UNBLOCK_SETTINGS"; then
        echo "Unblocking ALVR from SteamVR Safe Mode..."
        sed -i '/"blocked_by_safe_mode"/d' "$ALVR_UNBLOCK_SETTINGS"
    else
        echo "ALVR already unblocked."
    fi
else
    echo "Warning: SteamVR settings not found at $ALVR_UNBLOCK_SETTINGS"
fi

# ------------------------------------------------------------------
# Step 2: Register ALVR driver with SteamVR
# SteamVR loads its drivers at startup. If the ALVR driver isn't in
# the drivers/ directory when SteamVR starts, the headset won't be
# detected and ALVR won't be able to register its driver path.
#
# Uses the ALVR 20.14.1 build (see ./alvr wrapper). The 20.6.1 driver
# segfaulted vrserver on Linux; fixed upstream in 20.8.1+.
# ------------------------------------------------------------------
echo "--- Registering ALVR driver with SteamVR ---"
ALVR_GC_ROOT="$SCRIPT_DIR/.alvr-gc-root"
if [ -f "$ALVR_GC_ROOT" ]; then
    ALVR_DRIVER_DIR="$(readlink -f "$ALVR_GC_ROOT")/lib/alvr"
else
    ALVR_EXTRACTED="$(find /nix/store -maxdepth 1 -name '*alvr*extracted*' -type d 2>/dev/null | head -1)"
    if [ -n "$ALVR_EXTRACTED" ]; then
        ALVR_DRIVER_DIR="$ALVR_EXTRACTED/usr/lib64/alvr"
    fi
fi
if [ -n "$ALVR_DRIVER_DIR" ] && [ -f "$ALVR_DRIVER_DIR/driver.vrdrivermanifest" ]; then
    # Use vrpathreg to register ALVR as an external driver.
    # This modifies openvrpaths.vrpath's external_drivers list, which is
    # what SteamVR and ALVR expect — the symlink approach alone doesn't
    # update this registry, causing "ALVR driver path not registered".
    export LD_LIBRARY_PATH="$HOME/.local/share/Steam/steamapps/common/SteamVR/bin/linux64:$LD_LIBRARY_PATH"
    VR_PATHREG="$STEAMVR_DRIVERS/../bin/linux64/vrpathreg"
    "$VR_PATHREG" adddriver "$ALVR_DRIVER_DIR" 2>&1 && \
        echo "Registered: $ALVR_DRIVER_DIR"
else
    echo "Warning: Could not find ALVR driver directory (driver_dir=$ALVR_DRIVER_DIR)"
fi

# ------------------------------------------------------------------
# Step 3: Ensure Steam is running (for Steam IPC)
# ------------------------------------------------------------------
echo "--- Ensuring Steam is running ---"
if ! pgrep -x "steam" > /dev/null; then
    "$STEAM_BIN" &
    echo "Waiting for Steam to initialize..."
    for i in $(seq 1 60); do
        if pgrep -x "steam" > /dev/null; then
            echo "Steam is running."
            break
        fi
        if [ $i -eq 60 ]; then
            echo "Warning: Steam did not start within 30s, continuing."
        fi
        printf "."
        sleep 0.5
    done
    echo ""
else
    echo "Steam already running."
fi

# ------------------------------------------------------------------
# Step 4: Launch SteamVR first
# SteamVR must be running before ALVR so the ALVR driver is loaded
# and the server is available for ALVR to register with.
# ------------------------------------------------------------------
echo "--- Launching SteamVR ---"
"$STEAM_BIN" -applaunch "$STEAMVR_APPID" &
echo "Waiting for SteamVR (vrserver) to initialize..."
for i in $(seq 1 120); do
    if pgrep -x "vrserver" > /dev/null; then
        echo "SteamVR is running."
        break
    fi
    if [ $i -eq 120 ]; then
        echo "Timeout waiting for SteamVR after 60s."
    fi
    printf "."
    sleep 0.5
done
echo ""

# ------------------------------------------------------------------
# Step 5: Launch ALVR (connects to SteamVR's ALVR driver)
# ------------------------------------------------------------------
echo "--- Launching ALVR ---"
# Use a tmpfile to capture ALVR output for connection detection
ALVR_LOG="$(mktemp /tmp/alvr-launch-XXXXX.log)"
"$ALVR_BIN" >"$ALVR_LOG" 2>&1 &
ALVR_PID=$!
echo "Waiting for ALVR to connect to SteamVR..."
for i in $(seq 1 30); do
    # Check for the "Server connected" message that indicates ALVR
    # has established IPC with the SteamVR ALVR driver.
    if grep -q "Server connected" "$ALVR_LOG" 2>/dev/null; then
        echo "ALVR connected to SteamVR."
        break
    fi
    if ! kill -0 $ALVR_PID 2>/dev/null; then
        echo "Warning: ALVR process exited."
        tail -5 "$ALVR_LOG"
        break
    fi
    printf "."
    sleep 1
done
echo ""

# ------------------------------------------------------------------
# Step 6: Launch Simula
# ------------------------------------------------------------------
echo "--- Launching Simula ---"
if [ ! -f "$SIMULA_BIN" ]; then
    echo "Simula binary not found at $SIMULA_BIN. Building..."
    nix build "$SCRIPT_DIR"
fi

# When Simula is closed, tear SteamVR down as well. SteamVR's X button
# only hides the window on Linux and vrserver can linger after exit,
# which makes SteamVR look unkillable (stop_steamvr.sh fixes that).
cleanup_steamvr() {
    echo ""
    echo "--- Simula closed, shutting down SteamVR ---"
    "$SCRIPT_DIR/stop_steamvr.sh" || true
}

trap cleanup_steamvr EXIT INT TERM
"$SIMULA_BIN"
