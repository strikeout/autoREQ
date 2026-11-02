#!/bin/sh
# Builds AutoREQ.app with a Developer ID signature, notarizes it, staples the ticket,
# and writes build/AutoREQ.zip.
#
# Before the first run, store the notary credentials in the keychain once:
#   xcrun notarytool store-credentials autoreq-notary --apple-id YOU@EXAMPLE.COM --team-id DKS4MDJ9QH
# The command asks for an app-specific password from appleid.apple.com.
set -eu
cd "$(dirname "$0")/.."
PROFILE=${NOTARY_PROFILE:-autoreq-notary}
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)}
if [ -z "$IDENTITY" ]; then
  echo "No Developer ID Application identity is in the keychain." >&2
  exit 1
fi
echo "Signing with: $IDENTITY"
SIGN_IDENTITY="$IDENTITY" ./scripts/bundle.sh
codesign --verify --strict --deep build/AutoREQ.app
rm -f build/AutoREQ.zip
ditto -c -k --keepParent build/AutoREQ.app build/AutoREQ.zip
xcrun notarytool submit build/AutoREQ.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple build/AutoREQ.app
# Zip the app again, so the download holds the stapled ticket.
rm -f build/AutoREQ.zip
ditto -c -k --keepParent build/AutoREQ.app build/AutoREQ.zip
spctl --assess --type execute --verbose build/AutoREQ.app
echo "Notarized: build/AutoREQ.zip"
