#!/usr/bin/env bash
# setup_config.sh - Prepare Simula ALVR configuration from templates
# 1. Update ALVR session.json
TEMPLATE_JSON="config/alvr/session.json.template"
SESSION_JSON="config/alvr/session.json"
if [ -f "$TEMPLATE_JSON" ]; then
    echo "Personalizing ALVR session configuration from template..."
    
    # Start with a fresh copy from the template
    cp "$TEMPLATE_JSON" "$SESSION_JSON"
    
    # Replace the USER_REPLACE_ME placeholder with the actual current user's name
    sed -i "s|USER_REPLACE_ME|$USER|g" "$SESSION_JSON"
    
    # Clear client_connections to avoid trying to connect to a specific previous headset
    if command -v python3 &>/dev/null; then
        python3 -c "
import json
import sys
with open('$SESSION_JSON', 'r') as f:
    data = json.load(f)
data['client_connections'] = {}
with open('$SESSION_JSON', 'w') as f:
    json.dump(data, f, indent=2)
"
        echo "  - Client connections cleared."
    else
        sed -i '/"client_connections": {/,/^  },/c\  "client_connections": {},' "$SESSION_JSON"
        echo "  - Client connections cleared (using fallback)."
    fi
else
    echo "Warning: $TEMPLATE_JSON not found. Check if you've renamed it."
fi
# 2. Update HUD.config network interface
TEMPLATE_HUD="config/HUD.config.template"
HUD_CONFIG="config/HUD.config"
if [ -f "$TEMPLATE_HUD" ]; then
    echo "Updating HUD network interface from template..."
    cp "$TEMPLATE_HUD" "$HUD_CONFIG"
    
    # Try to find the most likely active network interface
    DEFAULT_IF=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
    if [ -n "$DEFAULT_IF" ]; then
        sed -i "s/IF_REPLACE_ME/$DEFAULT_IF/g" "$HUD_CONFIG"
        echo "  - Network interface set to $DEFAULT_IF."
    fi
fi
# 3. Ensure scripts are executable
chmod +x config/alvr/audio-setup.sh
chmod +x launch_simula_stack.sh
chmod +x unblock_alvr.sh
chmod +x cleanup_config.sh
# 4. Copy configuration to user's home directories
echo "Installing configuration files to user directories..."
# Simula config
mkdir -p "$HOME/.config/Simula"
if [ -f "config/config.dhall" ]; then
    cp "config/config.dhall" "$HOME/.config/Simula/config.dhall"
    echo "  - Copied config/config.dhall to $HOME/.config/Simula/config.dhall"
fi
# ALVR config
mkdir -p "$HOME/.config/alvr"
if [ -f "$SESSION_JSON" ]; then
    cp "$SESSION_JSON" "$HOME/.config/alvr/session.json"
    echo "  - Copied $SESSION_JSON to $HOME/.config/alvr/session.json"
fi
# Audio setup script (since session.json points to it in ~/.config/alvr/)
if [ -f "config/alvr/audio-setup.sh" ]; then
    cp "config/alvr/audio-setup.sh" "$HOME/.config/alvr/audio-setup.sh"
    chmod +x "$HOME/.config/alvr/audio-setup.sh"
    echo "  - Copied config/alvr/audio-setup.sh to $HOME/.config/alvr/audio-setup.sh"
fi
# 5. Update SteamVR settings to match ALVR resolution expectations
echo "Updating SteamVR settings to match ALVR requirements..."
nix-shell -p python3 --run "python3 << 'EOF'
import json
import os
path = os.path.expanduser(\"~/.local/share/Steam/config/steamvr.vrsettings\")
if not os.path.exists(path):
    print(f\"  - Warning: SteamVR settings not found at {path}\")
    exit(0)
print(f\"  - Modifying: {path}\")
try:
    with open(path, \"r\") as f:
        data = json.load(f)
except Exception as e:
    print(f\"  - Error reading/parsing steamvr.vrsettings: {e}\")
    exit(1)
if \"steamvr\" not in data:
    data[\"steamvr\"] = {}
# Force 2.0 resolution scale for a bit of extra supersampling
data[\"steamvr\"][\"renderTargetScale\"] = 2.0
# Ensure async is disabled to match template
data[\"steamvr\"][\"disableAsync\"] = True
# Prevent SteamVR from capping resolution based on GPU speed
data[\"steamvr\"][\"maxRecommendedResolution\"] = 4096
# Disable motion smoothing which can cause issues with ALVR/Simula
data[\"steamvr\"][\"enableMotionSmoothing\"] = False
# Remove GPU-speed-based overrides if they exist
if \"GpuSpeed\" in data:
    if \"gpuSpeedRenderTargetScale\" in data[\"GpuSpeed\"]:
        print(f\"  - Current gpuSpeedRenderTargetScale: {data['GpuSpeed']['gpuSpeedRenderTargetScale']}\")
        data[\"GpuSpeed\"][\"gpuSpeedRenderTargetScale\"] = 2.0
        print(\"  - Set gpuSpeedRenderTargetScale to 2.0\")
try:
    with open(path, \"w\") as f:
        json.dump(data, f, indent=3)
    print(\"  - Successfully updated steamvr.vrsettings\")
except Exception as e:
    print(f\"  - Error writing to steamvr.vrsettings: {e}\")
EOF"
# 6. Final permission fix for Simula config (handling existing root-owned files if any)
if [ -d "$HOME/.config/Simula" ]; then
    chmod -R u+rw "$HOME/.config/Simula" 2>/dev/null || true
fi
echo "Done! Configuration is now personalized and installed for $USER."
echo "You can run this script again anytime to refresh your config."
