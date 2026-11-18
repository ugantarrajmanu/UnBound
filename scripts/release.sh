#!/usr/bin/env bash
# Builds the downloadable files and publishes them as a GitHub Release.
#   scripts/release.sh            # version from android/app/build.gradle.kts (versionName)
#   scripts/release.sh 1.0.1
# Assets (fixed names so .../releases/latest/download/<name> always works):
#   unbound-host-macos.tar.gz   Mac server, Apple Silicon + Intel
#   Unbound.apk                 Android tablet app (release-signed)
# Needs: gh logged in as an account that can push to the repo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(sed -n 's/.*versionName = "\(.*\)".*/\1/p' "$ROOT/android/app/build.gradle.kts")}"
TAG="v$VERSION"
OUT="$ROOT/dist/release"
rm -rf "$OUT" && mkdir -p "$OUT"
step() { printf '\n==> %s\n' "$*"; }

[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || { echo "Commit your changes first." >&2; exit 1; }
git -C "$ROOT" push -q origin HEAD

step "Building Mac server $TAG (arm64 + x86_64)"
ARGS=(-c release --package-path "$ROOT/mac" --product unbound-host --arch arm64 --arch x86_64)
swift build "${ARGS[@]}" 2>&1 | grep -E 'error' || true
BIN="$(swift build "${ARGS[@]}" --show-bin-path)/unbound-host"
lipo -info "$BIN"
codesign --force --sign - "$BIN"
tar -czf "$OUT/unbound-host-macos.tar.gz" -C "$(dirname "$BIN")" unbound-host

step "Building Android app $TAG (release)"
if command -v jenv >/dev/null && J="$(cd "$ROOT" && jenv prefix 2>/dev/null)"; then export JAVA_HOME="$J"; fi
if [[ -z "${UNBOUND_KEYSTORE:-}" ]]; then
  [[ -f "$HOME/.unbound-signing/keystore.env" ]] || { echo "No release key. Run scripts/package.sh once to create it." >&2; exit 1; }
  export UNBOUND_KEYSTORE="$HOME/.unbound-signing/release.jks"
  # shellcheck disable=SC1091
  source "$HOME/.unbound-signing/keystore.env"; export UNBOUND_KEYSTORE_PASSWORD
fi
(cd "$ROOT/android" && ./gradlew -q --console=plain assembleRelease)
cp "$ROOT/android/app/build/outputs/apk/release/app-release.apk" "$OUT/Unbound.apk"

(cd "$OUT" && shasum -a 256 unbound-host-macos.tar.gz Unbound.apk > SHA256SUMS.txt && cat SHA256SUMS.txt)

step "Publishing $TAG"
NOTES="$OUT/notes.md"
cat > "$NOTES" <<MD
## Install

**Mac** (macOS 13+, no Xcode needed):
\`\`\`
curl -fsSL https://raw.githubusercontent.com/ugantarrajmanu/UnBound/main/scripts/install.sh | bash
unbound-host serve
\`\`\`

**Tablet** (Android 8+): download **Unbound.apk** below on the tablet and open it
(allow "Install unknown apps" when asked).

**Connect:** plug the tablet into the Mac with a USB-C cable and tap **OK** on "Open Unbound?".
MD
if gh release view "$TAG" -R ugantarrajmanu/UnBound >/dev/null 2>&1; then
  gh release upload "$TAG" -R ugantarrajmanu/UnBound --clobber "$OUT/unbound-host-macos.tar.gz" "$OUT/Unbound.apk" "$OUT/SHA256SUMS.txt"
else
  gh release create "$TAG" -R ugantarrajmanu/UnBound --target main --title "Unbound $VERSION" --notes-file "$NOTES" \
    "$OUT/unbound-host-macos.tar.gz" "$OUT/Unbound.apk" "$OUT/SHA256SUMS.txt"
fi
echo "https://github.com/ugantarrajmanu/UnBound/releases/tag/$TAG"
