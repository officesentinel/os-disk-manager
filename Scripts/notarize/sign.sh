#!/usr/bin/env bash
# OS Disk Manager — codesign + entitlement attachment.
#
# Phase 3.4 implementation. Invoked by `bundle.sh` after .app assembly,
# before `notarize.sh` ships the artifact to Apple.
#
# Required env vars:
#   TEAM_ID                       — 10-char Apple Developer Team ID
#   DEVELOPER_ID_APPLICATION      — full identity name, e.g.
#                                   "Developer ID Application: Office Sentinel (ABCD123456)"
# Optional:
#   ENTITLEMENTS_APP              — defaults to Resources/Entitlements/DiskWipeApp.entitlements
#   ENTITLEMENTS_HELPER           — defaults to Resources/Entitlements/DiskWipeHelper.entitlements
#   APP_PATH                      — defaults to /Applications/DiskWipe.app
#
# Behaviour: hardened-runtime sign of every Mach-O inside the bundle,
# inside-out (engines and frameworks before the outer .app), then verify.
#
# Falls back to ad-hoc signing (-) with a loud warning when TEAM_ID is
# unset, so local Phase 3 work is still possible without a paid
# Developer Program account.

set -euo pipefail

# Default to the staging copy in the source tree (writable by current user).
# bundle.sh creates ./DiskWipe.app before installing to /Applications/, so
# this signs the writable copy. For re-signing an already-installed bundle,
# pass APP_PATH=/Applications/DiskWipe.app and run under sudo.
APP_PATH="${APP_PATH:-$(pwd)/DiskWipe.app}"
ENTITLEMENTS_APP="${ENTITLEMENTS_APP:-Resources/Entitlements/DiskWipeApp.entitlements}"
ENTITLEMENTS_HELPER="${ENTITLEMENTS_HELPER:-Resources/Entitlements/DiskWipeHelper.entitlements}"

cd "$(dirname "$0")/../.."

if [ ! -d "$APP_PATH" ]; then
    echo "==> ERROR: $APP_PATH does not exist. Run bundle.sh first."
    exit 1
fi
if [ ! -f "$ENTITLEMENTS_APP" ]; then
    echo "==> ERROR: missing $ENTITLEMENTS_APP"
    exit 1
fi

# Identity selection. Hardened runtime (--options runtime) requires a real
# Developer ID; ad-hoc identity errors out with "internal error in Code Signing
# subsystem". We therefore drop hardened-runtime + timestamp + entitlements
# in ad-hoc mode (still useful for local debug builds but NOT notarisable).
if [ -n "${TEAM_ID:-}" ] && [ -n "${DEVELOPER_ID_APPLICATION:-}" ]; then
    IDENTITY="$DEVELOPER_ID_APPLICATION"
    HARDEN_FLAGS=(--options runtime --timestamp)
    USE_ENTITLEMENTS=1
    echo "==> Signing with Developer ID: $IDENTITY (hardened runtime ON)"
else
    IDENTITY="-"
    HARDEN_FLAGS=()
    USE_ENTITLEMENTS=0
    echo "==> WARNING: no TEAM_ID / DEVELOPER_ID_APPLICATION set; ad-hoc signing only."
    echo "==> Hardened runtime DISABLED — resulting bundle is debuggable only,"
    echo "==> NOT accepted by GateKeeper from a download. For notarisation, re-run"
    echo "==> with TEAM_ID and DEVELOPER_ID_APPLICATION exported."
fi

# Helper goes inside Contents/Library/LaunchDaemons/.
# (Phase 3.2 will add this; for now we sign whatever is there, if anything.)
HELPER_PATH="$APP_PATH/Contents/Library/LaunchDaemons/diskwipe-helper"
if [ -x "$HELPER_PATH" ]; then
    echo "==> Signing helper: $HELPER_PATH"
    if [ "$USE_ENTITLEMENTS" = "1" ] && [ -f "$ENTITLEMENTS_HELPER" ]; then
        codesign --force "${HARDEN_FLAGS[@]}" \
            --entitlements "$ENTITLEMENTS_HELPER" --sign "$IDENTITY" "$HELPER_PATH"
    else
        codesign --force --sign "$IDENTITY" "$HELPER_PATH"
    fi
fi

# Engine binary (today: lives at Contents/MacOS/diskwipe-engine inside the
# bundle, also symlinked at /usr/local/bin/ by install). Sign in-place.
ENGINE_PATH="$APP_PATH/Contents/MacOS/diskwipe-engine"
if [ -x "$ENGINE_PATH" ]; then
    echo "==> Signing engine: $ENGINE_PATH"
    codesign --force "${HARDEN_FLAGS[@]}" --sign "$IDENTITY" "$ENGINE_PATH"
fi

# Outer .app.
echo "==> Signing outer bundle: $APP_PATH"
if [ "$USE_ENTITLEMENTS" = "1" ]; then
    codesign --force "${HARDEN_FLAGS[@]}" \
        --entitlements "$ENTITLEMENTS_APP" --sign "$IDENTITY" "$APP_PATH"
else
    codesign --force --sign "$IDENTITY" "$APP_PATH"
fi

echo
echo "==> Verification:"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo
echo "==> Displaying signature:"
codesign -dv --entitlements - "$APP_PATH" 2>&1 | head -40

if [ "$IDENTITY" = "-" ]; then
    echo
    echo "==> Ad-hoc signature applied. To produce a notarisable build, run:"
    echo "      TEAM_ID=ABCD123456 \\"
    echo "      DEVELOPER_ID_APPLICATION='Developer ID Application: ... (ABCD123456)' \\"
    echo "      $0"
fi
