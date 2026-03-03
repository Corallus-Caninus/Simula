#!/usr/bin/env bash
# Paths to binaries
STEAM_BIN="/etc/profiles/per-user/$USER/bin/steam"
ALVR_BIN="/etc/profiles/per-user/$USER/bin/alvr"
SIMULA_BIN="./result/bin/simula"
# Optional: Run the ALVR unblock script just in case
if [ -f "./unblock_alvr.sh" ]; then
    echo "Running ALVR unblock check..."
    ./unblock_alvr.sh
fi
# SteamVR App ID
STEAMVR_APPID="250820"
echo "--- Launching SteamVR ---"
# Launch SteamVR via Steam applaunch
"$STEAM_BIN" -applaunch "$STEAMVR_APPID" &
echo "Waiting for SteamVR (vrserver) to initialize..."
# Wait for vrserver process to appear
until pgrep -x "vrserver" > /dev/null; do
    printf "."
    sleep 0.5
done
echo -e "
SteamVR is running."
echo "--- Launching ALVR ---"
# Launch ALVR Dashboard
"$ALVR_BIN" &
echo "Waiting for ALVR to initialize..."
# Wait for ALVR process (usually 'alvr' or 'alvr_dashboard')
until pgrep -f "alvr" > /dev/null; do
    printf "."
    sleep 0.5
done
echo -e "
ALVR is running."
echo "--- Launching Simula ---"
if [ ! -f "$SIMULA_BIN" ]; then
    echo "Simula binary not found at $SIMULA_BIN. Building first..."
    nix build .
fi
# Run Simula
exec "$SIMULA_BIN"
