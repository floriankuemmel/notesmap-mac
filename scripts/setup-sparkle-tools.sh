#!/usr/bin/env bash
# setup-sparkle-tools.sh — downloads the Sparkle release-time helpers
# (generate_keys, sign_update, generate_appcast) into tools/sparkle/.
#
# These are NOT the Sparkle framework — that's pulled via SwiftPM. These
# are the standalone binaries you need to:
#   1. generate the EdDSA keypair (one-time)
#   2. sign each release DMG (every release)
#   3. generate the appcast XML from a release directory (optional helper)
#
# The tools/ directory is gitignored.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TOOLS_DIR="$ROOT/tools/sparkle"
# Pin to match the Sparkle SwiftPM version in project.yml.
SPARKLE_VERSION="2.9.1"
DOWNLOAD_URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"

if [[ -x "$TOOLS_DIR/bin/sign_update" ]]; then
    echo "✓ Sparkle tools already installed at $TOOLS_DIR/bin/"
    "$TOOLS_DIR/bin/sign_update" --help 2>&1 | head -1 || true
    exit 0
fi

echo "▶ Downloading Sparkle $SPARKLE_VERSION..."
mkdir -p "$TOOLS_DIR"
TMPFILE=$(mktemp -t sparkle-download.XXXXXX.tar.xz)
trap "rm -f $TMPFILE" EXIT

curl -fsSL -o "$TMPFILE" "$DOWNLOAD_URL"

echo "▶ Extracting to $TOOLS_DIR/..."
tar -xJf "$TMPFILE" -C "$TOOLS_DIR"

echo ""
echo "✓ Sparkle tools installed:"
ls "$TOOLS_DIR/bin/" 2>/dev/null || ls "$TOOLS_DIR"

echo ""
echo "Next steps:"
echo "  1. One-time: ./tools/sparkle/bin/generate_keys"
echo "     → prints the public key, stores private key in Keychain"
echo "     → BACK UP the private key into 1Password:"
echo "         ./tools/sparkle/bin/generate_keys -x ~/notesmap-sparkle-private.txt"
echo "         (then move file content into 1Password, delete the file)"
echo "  2. Paste the public key into project.yml (SUPublicEDKey)"
echo "  3. Re-run xcodegen generate"
