#!/usr/bin/env bash

# cleanup_config.sh - Remove generated configuration files

echo "Cleaning up generated configuration files..."

# Remove local generated files
[ -f "config/alvr/session.json" ] && rm "config/alvr/session.json" && echo "  - Removed config/alvr/session.json"
[ -f "config/HUD.config" ] && rm "config/HUD.config" && echo "  - Removed config/HUD.config"

# Optional: Mention home directory files (not removing for safety unless requested)
echo ""
echo "Note: Files in ~/.config/Simula/ and ~/.config/alvr/ were not removed."
echo "Clean those manually if you wish to completely reset your system state."
