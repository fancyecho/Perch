#!/usr/bin/env bash
# Signs an app bundle. Usage: scripts/sign.sh <path/to/App.app>
#
# With a code-signing identity named "Perch Developer" in the keychain (or PERCH_SIGN_IDENTITY set),
# every build carries the same signature, so macOS keeps Perch's privacy permissions (Accessibility,
# browser automation) across updates. Without one it falls back to an ad-hoc signature, which macOS
# treats as a new app after every build.
set -euo pipefail

APP="${1:?usage: scripts/sign.sh <App.app>}"
IDENTITY="${PERCH_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"Perch Developer"'; then
  IDENTITY="Perch Developer"
fi
codesign --force --sign "${IDENTITY:--}" "$APP" >/dev/null
