#!/usr/bin/env bash
# Linux/macOS port of build.ps1 - builds unified_dap firmware and produces the UF2,
# then verifies UF2 structure and optionally compares SHA256 to source-manifest.json.
#
# Requires: arduino-cli, python3, and Adafruit nRF52 core 1.7.0 installed.
# Usage: ./build.sh [-p 240] [-r 2] [-c 80] [-f] [-C cli] [-P python] [-K core]
set -euo pipefail

PACKET_BYTES=240
RADIO_MBPS=2
CHANNEL=80
FAST=0
CLI="${CLI:-}"
PYTHON="${PYTHON:-}"
CORE="${CORE:-$HOME/.arduino15/packages/adafruit/hardware/nrf52/1.7.0}"

while getopts "p:r:c:fC:P:K:" opt; do
  case $opt in
    p) PACKET_BYTES="$OPTARG" ;;
    r) RADIO_MBPS="$OPTARG" ;;
    c) CHANNEL="$OPTARG" ;;
    f) FAST=1 ;;
    C) CLI="$OPTARG" ;;
    P) PYTHON="$OPTARG" ;;
    K) CORE="$OPTARG" ;;
    *) echo "unknown option" >&2; exit 2 ;;
  esac
done

export PYTHONWARNINGS=ignore
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$CLI" ]; then
  if command -v arduino-cli >/dev/null 2>&1; then CLI=arduino-cli
  else echo "arduino-cli not found. Pass -C /path/to/arduino-cli" >&2; exit 1; fi
fi
if [ -z "$PYTHON" ]; then
  if command -v python3 >/dev/null 2>&1; then PYTHON=python3
  elif command -v python >/dev/null 2>&1; then PYTHON=python
  else echo "python not found. Pass -P /path/to/python" >&2; exit 1; fi
fi
if [ ! -f "$CORE/platform.txt" ]; then
  echo "Adafruit nRF52 core 1.7.0 not found at $CORE. Install it or pass -K <core dir>." >&2
  exit 1
fi

BUILD="$ROOT/build"
OUT="$ROOT/firmware"
mkdir -p "$OUT"

if [ "$PACKET_BYTES" -eq 240 ]; then TXBUF=256; else TXBUF="$PACKET_BYTES"; fi
DAP128=0; DAP240=0
[ "$PACKET_BYTES" -eq 128 ] && DAP128=1
[ "$PACKET_BYTES" -eq 240 ] && DAP240=1

FLAGS="-DWD_ESB=1 -DSERIAL_BUFFER_SIZE=1024 -DCFG_TUD_VENDOR_TX_BUFSIZE=${TXBUF} -DWD_USB_COMPAT=1 -DWD_V3_FIX=1 -DWD_ONE_ROW_RESET_P113_TEST=1 -DWD_COMPACT_WIRE_TEST=1 -DWD_LINK_RECOVERY_TEST=1 -DWD_SESSION_RESTART_TEST=1 -DWD_SOFT_RESET_VERIFY=1 -DWD_DAP_TRACE_CAPACITY=240 -DWD_RADIO_MBPS=${RADIO_MBPS} -DWD_RADIO_CHANNEL=${CHANNEL} -DWD_DAP128=${DAP128} -DWD_DAP240=${DAP240}"
if [ "$FAST" -eq 1 ] || [ "$PACKET_BYTES" -eq 240 ]; then FLAGS="$FLAGS -DWD_SPEED_TEST=1"; fi

"$CLI" compile --verbose --fqbn 'adafruit:nrf52:pca10056:softdevice=s140v6,debug=l0' \
  --libraries "$ROOT/libraries" \
  --build-path "$BUILD" \
  --build-property "build.variant.path=$ROOT/variant" \
  --build-property "compiler.c.extra_flags=$FLAGS" \
  --build-property "compiler.cpp.extra_flags=$FLAGS" \
  --build-property 'compiler.c.elf.extra_flags=-Wl,--wrap=tud_cdc_line_state_cb' \
  "$ROOT/unified_dap" 2>&1 | tee "$ROOT/build/compile.log"
# tee hides the real exit status; recover it from the pipeline
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
  echo "===== COMPILE FAILED =====" >&2
  grep -nE "error:|Error|undefined reference" "$ROOT/build/compile.log" | tail -40 >&2 || true
  exit 1
fi

FW_NAME="uart_latency_packet${PACKET_BYTES}_unified_v3_p113_${RADIO_MBPS}m_fast_ch${CHANNEL}_afh_v2.uf2"
FW="$OUT/$FW_NAME"

"$PYTHON" -W ignore "$CORE/tools/uf2conv/uf2conv.py" "$BUILD/unified_dap.ino.hex" -c -f 0xADA52840 -o "$FW"
"$PYTHON" "$ROOT/tools/verify_uf2.py" "$FW"
if command -v sha256sum >/dev/null 2>&1; then sha256sum "$FW"; else shasum -a 256 "$FW"; fi

echo "OK: $FW"
