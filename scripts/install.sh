#!/usr/bin/env bash
# Installs the Unbound server (unbound-host) on a Mac. No Xcode needed.
#   curl -fsSL https://raw.githubusercontent.com/ugantarrajmanu/UnBound/main/scripts/install.sh | bash
set -euo pipefail
REPO="ugantarrajmanu/UnBound"
URL="https://github.com/$REPO/releases/latest/download/unbound-host-macos.tar.gz"

[[ "$(uname -s)" == Darwin ]] || { echo "Unbound runs on macOS only." >&2; exit 1; }
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 13 )) || { echo "Unbound needs macOS 13 or newer." >&2; exit 1; }

if [[ -w /usr/local/bin ]]; then DEST=/usr/local/bin; else DEST="$HOME/.local/bin"; fi
mkdir -p "$DEST"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading Unbound…"
curl -fL --progress-bar "$URL" -o "$TMP/unbound.tar.gz"
tar -xzf "$TMP/unbound.tar.gz" -C "$TMP"
install -m 755 "$TMP/unbound-host" "$DEST/unbound-host"
xattr -d com.apple.quarantine "$DEST/unbound-host" 2>/dev/null || true

echo "==> Installed $DEST/unbound-host"
case ":$PATH:" in
  *":$DEST:"*) ;;
  *) echo "    Add it to your PATH:  echo 'export PATH=\"$DEST:\$PATH\"' >> ~/.zshrc && source ~/.zshrc" ;;
esac
cat <<MSG

Next:
  1. Install the tablet app: https://github.com/$REPO/releases/latest  (Unbound.apk)
  2. Run:  unbound-host serve          (add --fps 90 for 90 Hz tablets)
  3. Plug the tablet in with a USB-C cable and tap OK on "Open Unbound?".
The first run asks for Screen Recording (and Accessibility for touch) for your Terminal app.
MSG
