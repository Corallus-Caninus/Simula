#!/usr/bin/env sh
# Script to unblock ALVR from SteamVR Safe Mode
SETTINGS="$HOME/.local/share/Steam/config/steamvr.vrsettings"

if [ -f "$SETTINGS" ]; then
    echo "Unblocking ALVR in $SETTINGS..."
    # Set all blocked_by_safe_mode entries to false
    sed -i 's/"blocked_by_safe_mode" : true/"blocked_by_safe_mode" : false/g' "$SETTINGS"
    echo "Done. Please restart SteamVR."
else
    echo "Error: SteamVR settings file not found at $SETTINGS"
fi
