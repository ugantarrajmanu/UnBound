#!/usr/bin/env bash
# One command for the USB-C workflow: build both sides, install the tablet app,
# then start the host. Plugging the tablet in (or having it plugged in) connects it.
#   scripts/run-usb.sh                 # 1920x1200 @ 90 fps
#   scripts/run-usb.sh --fps 60        # any extra args go to `unbound-host serve`
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Android builds use the JDK pinned by jenv (.java-version → 21); fall back to any JDK 17+.
java_major() { "$1/bin/java" -version 2>&1 | awk -F'"' '/version/ {split($2, v, "."); print (v[1] == "1" ? v[2] : v[1])}'; }
if command -v jenv >/dev/null && JENV_HOME="$(cd "$ROOT" && jenv prefix 2>/dev/null)"; then
  export JAVA_HOME="$JENV_HOME"
fi
if [[ -z "${JAVA_HOME:-}" || ! -x "$JAVA_HOME/bin/java" || "$(java_major "$JAVA_HOME")" -lt 17 ]]; then
  for j in "/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
           "$(/usr/libexec/java_home -v 17+ 2>/dev/null || true)"; do
    if [[ -n "$j" && -x "$j/bin/java" && "$(java_major "$j")" -ge 17 ]]; then export JAVA_HOME="$j"; break; fi
  done
fi
echo "==> Using JDK $(java_major "$JAVA_HOME") at $JAVA_HOME"

# A fresh clone has no android/local.properties; point Gradle at the standard SDK location.
if [[ -z "${ANDROID_HOME:-}" && ! -f "$ROOT/android/local.properties" ]]; then
  export ANDROID_HOME="$HOME/Library/Android/sdk"
  [[ -d "$ANDROID_HOME" ]] || { echo "Android SDK not found. Install Android Studio (or set ANDROID_HOME)." >&2; exit 1; }
fi

echo "==> Building Mac host"
swift build -c release --package-path "$ROOT/mac"

if command -v adb >/dev/null || [[ -x "$HOME/Library/Android/sdk/platform-tools/adb" ]]; then
  echo "==> Building and installing the tablet app (skips if no tablet is attached)"
  (cd "$ROOT/android" && ./gradlew -q assembleDebug)
  ADB="$(command -v adb || echo "$HOME/Library/Android/sdk/platform-tools/adb")"
  "$ADB" devices | awk 'NR>1 && $2=="unauthorized" {print "    " $1 ": tap \"Allow USB debugging\" on the tablet, then run this again"}'
  for serial in $("$ADB" devices | awk 'NR>1 && $2=="device" {print $1}'); do
    if out="$("$ADB" -s "$serial" install -r -d "$ROOT/android/app/build/outputs/apk/debug/app-debug.apk" 2>&1)"; then
      echo "    installed on $serial"
    elif [[ "$out" == *INSTALL_FAILED_UPDATE_INCOMPATIBLE* ]]; then
      echo "    $serial has the downloaded (release) Unbound app; uninstall it on the tablet first, then run this again" >&2
      exit 1
    else
      echo "$out" >&2; exit 1
    fi
  done
fi

echo "==> Starting host (Ctrl+C to stop and remove the virtual display)"
FPS_ARGS=(--fps 90)
for a in "$@"; do [[ "$a" == "--fps" || "$a" == "--refresh" ]] && FPS_ARGS=(); done
BIN="$(swift build -c release --package-path "$ROOT/mac" --show-bin-path)/unbound-host"
exec "$BIN" serve --usb ${FPS_ARGS[@]+"${FPS_ARGS[@]}"} "$@"
