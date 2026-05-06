#!/usr/bin/env bash
# Simula Runner with memory profiling
# Usage: ./simula_run.sh [--profiled] [--timeout SECS]
#   --profiled    Use the profiled build (result-debug) with GHCRTS heap profiling
#   --timeout N   Kill after N seconds (default: no timeout)

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE_DIR="${SCRIPT_DIR}/profile"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MEM_TRACE="${PROFILE_DIR}/mem_trace_${TIMESTAMP}.log"
RUN_LOG="${PROFILE_DIR}/run_${TIMESTAMP}.log"
HP_FILE="${PROFILE_DIR}/heap_${TIMESTAMP}.hp"

mkdir -p "${PROFILE_DIR}"

USE_PROFILED=false
TIMEOUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profiled) USE_PROFILED=true; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ "${USE_PROFILED}" == "true" ]]; then
  SIMULA_BIN="${SCRIPT_DIR}/result-debug/bin/simula-debug"
  if [[ ! -f "${SIMULA_BIN}" ]]; then
    echo "Profiled build not found at ${SIMULA_BIN}"
    echo ""
    echo "The profiled build (simula-debug) failed to link on this system due to"
    echo "GHC RTS profiling libraries lacking -fPIC for shared library linkage."
    echo ""
    echo "Falling back to non-profiled build with system-level RSS monitoring."
    echo "To attempt a profiled build later: nix build '.#simula-debug'"
    echo ""
    USE_PROFILED=false
  fi
fi

if [[ "${USE_PROFILED}" == "true" ]]; then
  export GHCRTS="-s -hT -i0.1 -po ${HP_FILE}"
  echo "Profiling enabled: GHCRTS=${GHCRTS}"
else
  SIMULA_BIN="${SCRIPT_DIR}/result/bin/simula"
  if [[ ! -f "${SIMULA_BIN}" ]]; then
    echo "Build not found at ${SIMULA_BIN}"
    echo "Build it with: nix build"
    exit 1
  fi
  echo "Non-profiled build. System-level RSS monitoring only."
fi

echo "Starting Simula..."
echo "Memory trace: ${MEM_TRACE}"
echo "Run log:      ${RUN_LOG}"
echo ""

cleanup() {
  echo ""
  echo "Shutting down Simula..."
}

if [[ -n "${TIMEOUT}" ]]; then
  echo "Will timeout after ${TIMEOUT} seconds."
  timeout "${TIMEOUT}" "${SIMULA_BIN}" > "${RUN_LOG}" 2>&1 &
else
  "${SIMULA_BIN}" > "${RUN_LOG}" 2>&1 &
fi
SIMULA_PID=$!

echo "Simula PID: ${SIMULA_PID}"
echo "Monitoring memory every 3s. Press Ctrl+C to stop."
echo "timestamp,rss_kb,vsz_kb" > "${MEM_TRACE}"

while kill -0 "${SIMULA_PID}" 2>/dev/null; do
  ps -p "${SIMULA_PID}" -o rss=,vsz= --no-headers 2>/dev/null \
    | awk -v t="$(date +%H:%M:%S)" '{print t "," $1 "," $2}' \
    >> "${MEM_TRACE}"
  sleep 3
done

wait "${SIMULA_PID}" 2>/dev/null || true
echo ""
echo "Simula exited."
echo "Memory trace saved to: ${MEM_TRACE}"

if [[ "${USE_PROFILED}" == "true" ]] && [[ -f "${HP_FILE}" ]]; then
  echo "Heap profile saved to: ${HP_FILE}"
  if command -v hp2ps &>/dev/null; then
    hp2ps -c "${HP_FILE}" && echo "Visualization: ${HP_FILE%.hp}.eps"
  fi
fi

# Print summary
if [[ -f "${MEM_TRACE}" ]]; then
  echo ""
  echo "--- Memory Summary ---"
  awk -F',' 'NR>1 {if(NR==2 || $2>max) {max=$2; max_t=$1}} END {printf "Peak RSS: %.0f MB at %s\n", max/1024, max_t}' "${MEM_TRACE}"
  awk -F',' 'NR>1 {sum+=$2; count++} END {printf "Avg RSS:  %.0f MB\n", (sum/count)/1024}' "${MEM_TRACE}"
fi
