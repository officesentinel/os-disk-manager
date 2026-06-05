#!/usr/bin/env bash
# OS Disk Manager — notarytool submission + stapler attachment.
#
# Phase 3.3 implementation. Run AFTER sign.sh.
#
# Authentication uses an Apple ID API key (preferred over App-specific
# password): https://appstoreconnect.apple.com/access/integrations/api
#
# Required env vars:
#   AC_API_KEY_ID                — e.g. "ABCD1234EF"
#   AC_API_ISSUER_ID             — UUID-formatted issuer ID
#   AC_API_KEY_PATH              — absolute path to the .p8 private key
#
# Optional:
#   APP_PATH                     — defaults to /Applications/DiskWipe.app
#   STAPLE                       — 1 (default) to staple after success
#
# Behaviour: zip the .app, submit, poll until terminal state, staple on
# success, verify staple, exit 0/1 accordingly. Surfaces the notarization
# log on failure so you can diagnose entitlement / hardened-runtime issues.

set -euo pipefail

APP_PATH="${APP_PATH:-/Applications/DiskWipe.app}"
STAPLE="${STAPLE:-1}"

cd "$(dirname "$0")/../.."

if [ -z "${AC_API_KEY_ID:-}" ] || [ -z "${AC_API_ISSUER_ID:-}" ] || [ -z "${AC_API_KEY_PATH:-}" ]; then
    echo "==> ERROR: missing one of AC_API_KEY_ID / AC_API_ISSUER_ID / AC_API_KEY_PATH"
    echo "    Get keys at https://appstoreconnect.apple.com/access/integrations/api"
    exit 1
fi
if [ ! -d "$APP_PATH" ]; then
    echo "==> ERROR: $APP_PATH does not exist."
    exit 1
fi
if [ ! -f "$AC_API_KEY_PATH" ]; then
    echo "==> ERROR: AC_API_KEY_PATH not readable: $AC_API_KEY_PATH"
    exit 1
fi

# Pre-flight: bundle must be Developer-ID signed, not ad-hoc.
if codesign -dv "$APP_PATH" 2>&1 | grep -q "Signature=adhoc"; then
    echo "==> ERROR: $APP_PATH is ad-hoc signed. Run sign.sh with TEAM_ID set first."
    exit 1
fi

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT
ZIP_PATH="$STAGING_DIR/DiskWipe.zip"

echo "==> Zipping bundle for upload: $ZIP_PATH"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Submitting to Apple notary service (this can take 5-30 minutes)…"
SUBMIT_OUT="$(xcrun notarytool submit "$ZIP_PATH" \
    --key       "$AC_API_KEY_PATH" \
    --key-id    "$AC_API_KEY_ID" \
    --issuer    "$AC_API_ISSUER_ID" \
    --wait \
    --output-format json)"

echo "$SUBMIT_OUT" | python3 -m json.tool

STATUS="$(echo "$SUBMIT_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"
SUBMISSION_ID="$(echo "$SUBMIT_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"

if [ "$STATUS" != "Accepted" ]; then
    echo "==> ERROR: notarization status = $STATUS"
    if [ -n "$SUBMISSION_ID" ]; then
        echo "==> Pulling failure log:"
        xcrun notarytool log "$SUBMISSION_ID" \
            --key "$AC_API_KEY_PATH" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID"
    fi
    exit 1
fi

echo "==> Accepted (submission $SUBMISSION_ID)."

if [ "$STAPLE" = "1" ]; then
    echo "==> Stapling ticket…"
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    echo "==> Stapled. Verifying gatekeeper acceptance:"
    spctl --assess --type execute --verbose=4 "$APP_PATH" || true
fi
