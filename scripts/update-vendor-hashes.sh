#!/usr/bin/env bash
# Recomputes SHA-256 hashes for every vendor JS file and prints a snippet
# you can paste into LinkMapHTMLBuilder.swift's `vendorScriptSHA256` table.
#
# Run this whenever you update one of the bundled vendor libs (D3, Three.js,
# 3d-force-graph, umap-js). Without this update, the app refuses to load the
# changed file at runtime.

set -euo pipefail

VENDOR_DIR="$(cd "$(dirname "$0")/.." && pwd)/NotesMap/Resources/vendor"

if [[ ! -d "$VENDOR_DIR" ]]; then
    echo "Vendor directory not found: $VENDOR_DIR" >&2
    exit 1
fi

cd "$VENDOR_DIR"
echo "// Paste this into LinkMapHTMLBuilder.swift -> vendorScriptSHA256:"
echo "private static let vendorScriptSHA256: [String: String] = ["
for f in *.js; do
    hash=$(shasum -a 256 "$f" | awk '{print $1}')
    printf '    "%-25s "%s",\n' "${f}\":" "$hash"
done
echo "]"
