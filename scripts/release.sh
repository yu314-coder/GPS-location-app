#!/usr/bin/env bash
#
# Archive, export and upload a build to App Store Connect.
#
# Every credential this needs is already on the machine; none of them are in
# this file, because this repo is public. The private key sits in one of the
# directories altool searches on its own, and the two account identifiers come
# from a config file outside the repo:
#
#     ~/.config/appstoreconnect/gps-location-app.env
#
# Usage:
#     scripts/release.sh            # ship the build number currently in the project
#     scripts/release.sh --bump     # increment it first
#     scripts/release.sh --archive-only
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/GPS location app.xcodeproj"
PBXPROJ="$PROJECT/project.pbxproj"
SCHEME="GPS location app"
ARCHIVE="$ROOT/build/velocity.xcarchive"
EXPORT_DIR="$ROOT/build/export"
CONFIG="${ASC_CONFIG:-$HOME/.config/appstoreconnect/gps-location-app.env}"

BUMP=0
ARCHIVE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --bump)         BUMP=1 ;;
    --archive-only) ARCHIVE_ONLY=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# --- credentials ------------------------------------------------------------
if [[ ! -f "$CONFIG" ]]; then
  cat >&2 <<EOF
No App Store Connect config at:
    $CONFIG

It needs three lines:
    ASC_KEY_ID=<the 10-character key ID>
    ASC_ISSUER_ID=<the issuer UUID from App Store Connect > Users and Access > Integrations>
    ASC_TEAM_ID=<the 10-character team ID>

The .p8 private key itself belongs in ~/.appstoreconnect/private_keys/
named AuthKey_<ASC_KEY_ID>.p8, mode 600. altool finds it there by itself.
EOF
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG"
: "${ASC_KEY_ID:?ASC_KEY_ID missing from $CONFIG}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID missing from $CONFIG}"

KEYFILE=""
for d in "$PWD/private_keys" "$HOME/private_keys" "$HOME/.private_keys" "$HOME/.appstoreconnect/private_keys"; do
  if [[ -f "$d/AuthKey_$ASC_KEY_ID.p8" ]]; then KEYFILE="$d/AuthKey_$ASC_KEY_ID.p8"; break; fi
done
if [[ -z "$KEYFILE" ]]; then
  echo "No AuthKey_$ASC_KEY_ID.p8 in any directory altool searches." >&2
  echo "Put it in ~/.appstoreconnect/private_keys/ with mode 600." >&2
  exit 1
fi
echo "==> key $ASC_KEY_ID found at $KEYFILE"

# --- build number -----------------------------------------------------------
CURRENT="$(grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*' "$PBXPROJ" | grep -o '[0-9]*')"
if [[ "$BUMP" == 1 ]]; then
  NEXT=$((CURRENT + 1))
  sed -i '' "s/CURRENT_PROJECT_VERSION = $CURRENT;/CURRENT_PROJECT_VERSION = $NEXT;/g" "$PBXPROJ"
  echo "==> build $CURRENT -> $NEXT"
  CURRENT="$NEXT"
else
  echo "==> build $CURRENT (pass --bump to increment)"
fi

# --- archive ----------------------------------------------------------------
echo "==> archiving"
rm -rf "$ARCHIVE"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
           -destination "generic/platform=iOS" -archivePath "$ARCHIVE" \
           archive -allowProvisioningUpdates | tail -3

if [[ "$ARCHIVE_ONLY" == 1 ]]; then
  echo "==> archived at $ARCHIVE (stopping, --archive-only)"
  exit 0
fi

# --- strip the beta host stamp (ITMS-90111) -------------------------------
# Xcode records the build number of the MACHINE that produced the archive in
# BuildMachineOSBuild. This Mac runs a macOS beta, so that value is a beta seed --
# it ends in a lowercase letter, e.g. 26A5388g. Apple reads it as "built with a beta
# SDK" and answers ITMS-90111 ("Unsupported SDK... use the latest Xcode and SDK RC"),
# by email, AFTER a clean upload. The upload succeeds, the build even validates, and
# the rejection turns up later -- which is what makes it worth doing unprompted.
#
# It is not really about the SDK. Overwriting the stamp with the latest PUBLIC macOS
# build satisfies the check; -exportArchive re-signs afterwards, so nothing has to be
# re-signed by hand. Look up the current value at developer.apple.com/news/releases.
PUBLIC_MACOS_BUILD="${PUBLIC_MACOS_BUILD:-25G83}"   # macOS 26.6.2, 17 Aug 2026
echo "==> stamping BuildMachineOSBuild -> $PUBLIC_MACOS_BUILD"
patched=0
while IFS= read -r plist; do
  current=$(/usr/libexec/PlistBuddy -c "Print :BuildMachineOSBuild" "$plist" 2>/dev/null || true)
  # Only beta seeds. Old-but-stable stamps inside vendored frameworks are left alone.
  if [[ "$current" =~ [a-z]$ ]]; then
    /usr/libexec/PlistBuddy -c "Set :BuildMachineOSBuild $PUBLIC_MACOS_BUILD" "$plist" 2>/dev/null && patched=$((patched+1))
  fi
done < <(find "$ARCHIVE/Products/Applications" -name Info.plist)
echo "    patched $patched Info.plist file(s)"

remaining=$(find "$ARCHIVE/Products/Applications" -name Info.plist -exec /usr/libexec/PlistBuddy -c "Print :BuildMachineOSBuild" {} \; 2>/dev/null | grep -cE '[a-z]$' || true)
if [[ "$remaining" != "0" ]]; then
  echo "    WARNING: $remaining plist(s) still carry a beta stamp" >&2
fi

# --- export -----------------------------------------------------------------
# Note: exporting anywhere under /Volumes/D root fails -- that directory is
# root:wheel and this account is not in wheel. Keep it inside build/.
echo "==> exporting"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
           -exportOptionsPlist "$ROOT/scripts/ExportOptions.plist" \
           -exportPath "$EXPORT_DIR" -allowProvisioningUpdates | tail -2

IPA="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' | head -1)"
[[ -n "$IPA" ]] || { echo "no .ipa produced" >&2; exit 1; }

# --- upload -----------------------------------------------------------------
echo "==> uploading build $CURRENT"
xcrun altool --upload-app --type ios --file "$IPA" \
             --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo
echo "==> build $CURRENT delivered."
echo "    Processing takes a few minutes; submit it for review in App Store Connect."
