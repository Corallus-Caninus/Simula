#!/usr/bin/env bash

# stop_steamvr.sh - Fully stop SteamVR and every OpenVR process.
#
# The SteamVR X button only hides the window on Linux and vrserver can
# linger after exit (ValveSoftware/SteamVR-for-Linux#876), which is why
# SteamVR seems impossible to kill. This script asks Steam to shut VR
# down gracefully, then force-kills anything left over.

set -o errexit
set -o pipefail

STEAM_BIN="${STEAM_BIN:-/etc/profiles/per-user/$USER/bin/steam}"

echo "--- Requesting clean SteamVR shutdown via Steam ---"
"$STEAM_BIN" steam://quitvr || true

echo "--- Waiting for graceful shutdown ---"
for i in $(seq 1 20); do
    if ! pgrep -x "vrserver" > /dev/null 2>&1 && ! pgrep -x "vrmonitor" > /dev/null 2>&1; then
        echo "SteamVR stopped."
        exit 0
    fi
    printf "."
    sleep 0.5
done
echo ""

echo "--- SteamVR still running, force-killing remaining processes ---"
# vrmonitor is the parent; vrserver exits when the monitor dies
# (-waitformonitor), but kill both explicitly to be safe.
pkill -x vrmonitor || true
pkill -x vrserver || true
pkill -x vrcompositor || true
pkill -f "vrstartup.sh" || true
sleep 2

if pgrep -x "vrserver" > /dev/null 2>&1 || pgrep -x "vrmonitor" > /dev/null 2>&1; then
    echo "Warning: some SteamVR processes are still alive:"
    ps aux | grep -E 'vrmonitor|vrserver|vrcompositor' | grep -v grep || true
    exit 1
fi

echo "SteamVR stopped."