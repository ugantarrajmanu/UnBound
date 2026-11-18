#!/usr/bin/env bash
# Builds and starts the Unbound server. Plug the tablet in with a USB-C cable,
# tap OK on "Open Unbound?" on the tablet. Ctrl+C to stop.
#   scripts/start.sh                 # 60 fps
#   scripts/start.sh --fps 90        # 90 Hz tablets
#   scripts/start.sh --width 2560 --height 1600
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "==> Building…"
swift build -c release --package-path "$ROOT/mac" --product unbound-host 2>&1 | grep -E 'error|warning: unre' || true
BIN="$(swift build -c release --package-path "$ROOT/mac" --show-bin-path)/unbound-host"
# A running adb server holds the tablet's USB port; stop it (harmless if not running).
command -v adb >/dev/null && adb kill-server >/dev/null 2>&1 || true
exec "$BIN" serve "$@"
