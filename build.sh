#!/usr/bin/env bash
# Build Claudette.app — a proper macOS .app bundle
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

CONFIG="${CONFIG:-release}"
APP_NAME="Claudette"
BUNDLE="build/${APP_NAME}.app"
CONTENTS="${BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RES_DIR="${CONTENTS}/Resources"

echo "▸ Building Swift package (${CONFIG})…"
swift build -c "${CONFIG}" --arch arm64

BIN_PATH="$(swift build -c "${CONFIG}" --arch arm64 --show-bin-path)"
BIN="${BIN_PATH}/${APP_NAME}"

if [[ ! -x "${BIN}" ]]; then
    echo "✗ Binary not found at ${BIN}" >&2
    exit 1
fi

echo "▸ Assembling ${APP_NAME}.app…"
rm -rf "${BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"
cp "${BIN}" "${MACOS_DIR}/${APP_NAME}"
cp Info.plist "${CONTENTS}/Info.plist"

# Copy any bundled resources (from the SwiftPM bundle) into Resources/
BUNDLED_RESOURCES="${BIN_PATH}/${APP_NAME}_${APP_NAME}.bundle"
if [[ -d "${BUNDLED_RESOURCES}" ]]; then
    cp -R "${BUNDLED_RESOURCES}" "${RES_DIR}/"
fi

# App icon. Preferred path is the pre-built icon/Claudette.icns produced by
# icon/render_icon.swift + iconutil; fall back to a stray Claudette.icns at
# repo root if someone dropped one there for a quick swap.
if [[ -f icon/Claudette.icns ]]; then
    cp icon/Claudette.icns "${RES_DIR}/Claudette.icns"
elif [[ -f Claudette.icns ]]; then
    cp Claudette.icns "${RES_DIR}/Claudette.icns"
fi

# Ad-hoc code sign so Gatekeeper allows launch
echo "▸ Signing…"
codesign --force --deep --sign - "${BUNDLE}"

echo "✓ Built ${BUNDLE}"
echo ""
echo "Run it:   open \"${BUNDLE}\""
echo "Install:  cp -R \"${BUNDLE}\" /Applications/"
