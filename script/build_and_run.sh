#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="VoiceInk Dev"
BUNDLE_ID="com.prakashjoshipax.VoiceInk"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.codex-build"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

SIGNING_IDENTITY="${LOCAL_CODESIGN_IDENTITY:-}"
SIGNING_CERTIFICATE_NAME=""
DEVELOPMENT_TEAM_ID="${LOCAL_DEVELOPMENT_TEAM:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY_LINES="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: /')"
  SIGNING_IDENTITIES="$(printf '%s\n' "$SIGNING_IDENTITY_LINES" | awk '{ print $2 }')"
  SIGNING_IDENTITY_COUNT="$(printf '%s\n' "$SIGNING_IDENTITIES" | awk 'NF { count++ } END { print count + 0 }')"
  if [[ "$SIGNING_IDENTITY_COUNT" -eq 1 ]]; then
    SIGNING_IDENTITY="$(printf '%s\n' "$SIGNING_IDENTITIES" | awk 'NF { print; exit }')"
    SIGNING_CERTIFICATE_NAME="$(printf '%s\n' "$SIGNING_IDENTITY_LINES" | sed -E 's/^[^"]*"([^"]+)".*$/\1/')"
  fi
fi

if [[ -n "$SIGNING_IDENTITY" && "$SIGNING_IDENTITY" != "-" ]]; then
  if [[ -z "$DEVELOPMENT_TEAM_ID" && -n "$SIGNING_CERTIFICATE_NAME" ]]; then
    DEVELOPMENT_TEAM_ID="$(security find-certificate -c "$SIGNING_CERTIFICATE_NAME" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -E 's/.*OU=([^, ]+).*/\1/')"
  fi
  BUILD_SIGNING_IDENTITY="Apple Development"
  SIGNING_REQUIRED=YES
  echo "Using stable local signing identity: $SIGNING_IDENTITY (team $DEVELOPMENT_TEAM_ID)"
else
  SIGNING_IDENTITY="-"
  BUILD_SIGNING_IDENTITY="-"
  DEVELOPMENT_TEAM_ID=""
  SIGNING_REQUIRED=NO
  echo "Using ad-hoc signing (permissions may need approval after rebuilds)"
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

make -C "$ROOT_DIR" setup
xcodebuild \
  -project "$ROOT_DIR/VoiceInk.xcodeproj" \
  -scheme VoiceInk \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY="$BUILD_SIGNING_IDENTITY" \
  CODE_SIGNING_REQUIRED="$SIGNING_REQUIRED" \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM_ID" \
  CODE_SIGN_ENTITLEMENTS="$ROOT_DIR/VoiceInk/VoiceInk.local.entitlements" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  build

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Built app not found at $APP_BUNDLE" >&2
  exit 1
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 3
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
