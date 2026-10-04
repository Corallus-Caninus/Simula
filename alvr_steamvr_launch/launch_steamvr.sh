#!/usr/bin/env bash
#
# launch_steamvr.sh - start SteamVR with the ALVR compositor pinned.
#
# Equivalent to pressing "Launch SteamVR" in the ALVR dashboard, but it
# re-pins the vrcompositor wrapper immediately beforehand so there is no
# window in which SteamVR starts with the incompatible 20.12.1 wrapper.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/setup.sh"

STEAM_BIN="${STEAM_BIN:-/etc/profiles/per-user/$USER/bin/steam}"
command -v "$STEAM_BIN" >/dev/null 2>&1 || STEAM_BIN="$(command -v steam || true)"
[ -n "$STEAM_BIN" ] || { echo "Could not find the steam launcher" >&2; exit 1; }

exec "$STEAM_BIN" steam://rungameid/250820 "$@"
