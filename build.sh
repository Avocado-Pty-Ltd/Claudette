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

# Stamp the version. Info.plist in the repo carries a placeholder; the real
# number comes from the release tag (APP_VERSION, e.g. 0.1.7) and the CI run
# (APP_BUILD), so About and the Finder Get Info window agree with the release.
# A local build with neither set falls back to the nearest tag, and when no
# tag is reachable (shallow clone, fresh fork) to 0.0.0-dev.<sha> — always
# something that identifies the build, never the placeholder.
if [[ -z "${APP_VERSION:-}" ]]; then
    APP_VERSION="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//' || true)"
fi
if [[ -z "${APP_VERSION}" ]]; then
    SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    APP_VERSION="0.0.0-dev.${SHA}"
fi
if [[ -z "${APP_BUILD:-}" ]]; then
    APP_BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION}" "${CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${APP_BUILD}" "${CONTENTS}/Info.plist"
echo "▸ Version ${APP_VERSION} (build ${APP_BUILD})"

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
