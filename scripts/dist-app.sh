#!/usr/bin/env bash
# Sign, notarize and package Illogical.app into a DMG.
#
# The install story this produces: download the DMG, open it, drag the app to
# Applications, launch it. No Gatekeeper dialog, no right-click-Open, no
# `xattr -dr com.apple.security.quarantine`, and no daemon to install first --
# the app carries `illogicald` and starts one when there is none.
#
# Everything below exists to make that true, and every step is skippable only
# in the sense that skipping it breaks a different part of it.
#
#
# ## Signing is conditional, deliberately
#
# Developer ID signing needs a certificate that cannot live in the repo, so
# every step that needs one is guarded on the secrets being present. Without
# them this still builds a DMG -- ad-hoc signed, exactly what `just app`
# produces -- so the packaging path is exercised on every fork and every PR
# rather than only on the one machine that holds the cert. That DMG will be
# refused by Gatekeeper on any Mac that did not build it, and the script says
# so rather than leaving it to be discovered on a download.
#
# Set all four to sign:
#
#   MACOS_CERTIFICATE       base64 of the Developer ID Application .p12
#   MACOS_CERTIFICATE_PWD   its export password
#   MACOS_CERTIFICATE_NAME  the identity, "Developer ID Application: X (TEAM)"
#   MACOS_KEYCHAIN_PWD      any password; names the throwaway keychain
#
# ...and all three of these to notarize, an App Store Connect API key with the
# "Developer ID" or "Admin" role (App Store Connect -> Users and Access ->
# Integrations -> App Store Connect API):
#
#   APPLE_API_ISSUER        the issuer UUID
#   APPLE_API_KEY_ID        the key id
#   APPLE_API_KEY           base64 of the AuthKey_<id>.p8
#
# A key rather than an Apple ID and app-specific password because notarytool's
# password path prompts and stores in the keychain; a key is three strings and
# no state.
#
#
# ## Why two notarization submissions
#
# The app is notarized and stapled, and *then* the DMG is built, notarized and
# stapled. One submission of the DMG would notarize the app inside it too --
# notarization covers nested code -- but stapling is per-artifact: a ticket is
# fetched by the cdhash of the thing being stapled. Staple only the DMG and the
# app a user drags to Applications carries no ticket, so its first launch needs
# Apple's servers to answer. That works, until it is the first launch on a
# plane or behind a firewall that eats OCSP, and then it is a dialog saying the
# app cannot be verified.
#
# So: submit the app, staple it, build the DMG around the stapled app, submit
# that, staple it. Two waits, and nothing about the result depends on the
# network afterwards.
#
# Usage: scripts/dist-app.sh [version]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

version="${1:-}"
if [ -z "$version" ]; then
  version="$(git describe --tags --always --dirty 2>/dev/null || echo 0.0.0-dev)"
fi
version="${version#v}"

app="$root/clients/macos/.build/xcode-release/Build/Products/Release/Illogical.app"
dist="$root/dist"
work="$(mktemp -d "${TMPDIR:-/tmp}/illogical-app.XXXXXX")"

[ -d "$app" ] || {
  echo "error: $app is not there. Run \`just app-release\` first." >&2
  exit 1
}

# The keychain and the decoded secrets are the things that must not outlive
# this script even on a failure. A CI runner is thrown away, but this also runs
# on a developer's Mac, where a leftover unlocked keychain holding a Developer
# ID key is a real one.
cleanup() {
  rm -rf "$work"
  if [ -n "${keychain:-}" ]; then
    security delete-keychain "$keychain" 2>/dev/null || true
  fi
}
trap cleanup EXIT

mkdir -p "$dist"

sign=false
notarize=false
if [ -n "${MACOS_CERTIFICATE:-}" ] && [ -n "${MACOS_CERTIFICATE_PWD:-}" ] &&
  [ -n "${MACOS_CERTIFICATE_NAME:-}" ] && [ -n "${MACOS_KEYCHAIN_PWD:-}" ]; then
  sign=true
fi
if [ -n "${APPLE_API_ISSUER:-}" ] && [ -n "${APPLE_API_KEY_ID:-}" ] &&
  [ -n "${APPLE_API_KEY:-}" ]; then
  notarize=true
fi

# Notarization without signing is not a thing -- the submission is rejected for
# an unsigned binary -- and quietly doing half of it produces a DMG that looks
# releasable and is not.
if [ "$notarize" = true ] && [ "$sign" = false ]; then
  echo "error: notarization secrets are set but signing secrets are not." >&2
  echo "       Notarization requires a Developer ID signature." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Sign
# ---------------------------------------------------------------------------

if [ "$sign" = true ]; then
  keychain="illogical-dist-$$.keychain"
  echo "==> importing the Developer ID certificate into $keychain"

  # A keychain of its own rather than the login one: importing into login
  # prompts for its password, and on a CI runner there is nobody to answer. It
  # is added to the search list rather than made default, so this does not
  # change what the rest of the machine signs with.
  security create-keychain -p "$MACOS_KEYCHAIN_PWD" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"
  security unlock-keychain -p "$MACOS_KEYCHAIN_PWD" "$keychain"
  security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')

  echo "$MACOS_CERTIFICATE" | base64 --decode >"$work/certificate.p12"
  security import "$work/certificate.p12" -k "$keychain" \
    -P "$MACOS_CERTIFICATE_PWD" -T /usr/bin/codesign

  # Without this codesign blocks on a GUI prompt for permission to use the key
  # it was just handed, which on a runner is a job that hangs until it is
  # cancelled rather than one that fails.
  security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$MACOS_KEYCHAIN_PWD" "$keychain" >/dev/null

  identity="$MACOS_CERTIFICATE_NAME"
else
  echo "==> no Developer ID secrets; leaving the ad-hoc signature in place"
  identity=""
fi

if [ "$sign" = true ]; then
  echo "==> signing $app"

  # Inner code first, then the bundle. A signature covers everything nested
  # inside it, so signing the app and *then* replacing a binary in it
  # invalidates the outer seal -- codesign checks this and refuses, but only
  # after the fact.
  #
  # illogicald is the one nested executable. `--options runtime` on it as well
  # as on the app: notarization requires the hardened runtime on every Mach-O
  # in the bundle, and a nested binary without it fails the submission with
  # "The executable does not have the hardened runtime enabled" naming a path
  # most people have to go looking for.
  #
  # No entitlements here. The app's disable-sandbox entitlement is about the
  # app's own container; the daemon is exec'd as a separate process and
  # inherits nothing from it.
  while IFS= read -r -d '' binary; do
    echo "    $binary"
    codesign --force --timestamp --options runtime \
      --keychain "$keychain" --sign "$identity" "$binary"
  done < <(find "$app/Contents/MacOS" "$app/Contents/Frameworks" \
    -type f -perm -u+x -not -name "Illogical" -print0 2>/dev/null)

  # `--timestamp` is a hard requirement for notarization: a signature without a
  # secure timestamp is rejected, and the failure names neither the timestamp
  # nor the flag.
  echo "    $app"
  codesign --force --timestamp --options runtime \
    --entitlements "$root/clients/macos/Illogical/Supporting/Illogical.entitlements" \
    --keychain "$keychain" --sign "$identity" "$app"

  # `--deep` on *verify* only. Deep signing is deprecated and gets nested code
  # wrong; deep verification is still how you check that it was signed right.
  codesign --verify --deep --strict --verbose=2 "$app"
fi

# ---------------------------------------------------------------------------
# Notarize the app, and staple the ticket to it
# ---------------------------------------------------------------------------

if [ "$notarize" = true ]; then
  echo "$APPLE_API_KEY" | base64 --decode >"$work/api-key.p8"
  notary_args=(
    --key "$work/api-key.p8"
    --key-id "$APPLE_API_KEY_ID"
    --issuer "$APPLE_API_ISSUER"
  )

  # notarytool takes a zip, a dmg or a pkg -- never a bare .app. `ditto
  # -c -k --keepParent` is the only zip Apple documents for this; `zip -r`
  # loses symlinks and extended attributes and the submission is rejected for
  # a malformed bundle.
  echo "==> notarizing the app (this waits on Apple, typically a few minutes)"
  ditto -c -k --keepParent "$app" "$work/Illogical.zip"
  xcrun notarytool submit "$work/Illogical.zip" "${notary_args[@]}" --wait

  echo "==> stapling the app"
  xcrun stapler staple "$app"
fi

# ---------------------------------------------------------------------------
# The DMG
# ---------------------------------------------------------------------------

echo "==> building the disk image"

# A staging directory with the app and a symlink to /Applications: the
# drag-to-install layout every Mac user already knows. The symlink is what
# makes the gesture possible at all -- without it the window is a single icon
# and no hint about where it goes.
stage="$work/dmg"
mkdir -p "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"

dmg="$dist/Illogical.dmg"
rm -f "$dmg"

# UDZO is the compressed read-only format; a read-write image would be
# writable by whoever mounted it, which is not what a download should be.
# The volume name is what shows in Finder's sidebar when it is mounted.
hdiutil create \
  -volname "Illogical" \
  -srcfolder "$stage" \
  -ov \
  -format UDZO \
  "$dmg"

if [ "$sign" = true ]; then
  echo "==> signing the disk image"
  codesign --force --timestamp --keychain "$keychain" --sign "$identity" "$dmg"
fi

if [ "$notarize" = true ]; then
  echo "==> notarizing the disk image"
  xcrun notarytool submit "$dmg" "${notary_args[@]}" --wait
  xcrun stapler staple "$dmg"

  # What a user's Mac will actually decide, asked the same way Gatekeeper asks
  # it. The steps above can all report success and still leave an image that is
  # refused -- an unstapled ticket, a signature without a timestamp -- and this
  # is the only check that covers the whole chain at once.
  echo "==> verifying as Gatekeeper would"
  spctl --assess --type open --context context:primary-signature -vv "$dmg"
  xcrun stapler validate "$dmg"
fi

# Rewritten over whatever is in dist/, so one file covers the DMG and any
# daemon tarballs built beside it. Bare names, because `shasum -c` compares the
# path as written and `./x` fails for anyone who downloaded `x`.
(cd "$dist" && shasum -a 256 -- *.tar.gz *.dmg 2>/dev/null >SHA256SUMS || true)

echo
echo "==> $dmg"
if [ "$sign" = false ]; then
  echo
  echo "    UNSIGNED. Gatekeeper will refuse this on any Mac but this one."
  echo "    To open it anyway: right-click the app -> Open, once."
  echo "    To sign for real, set the secrets documented at the top of this file."
elif [ "$notarize" = false ]; then
  echo
  echo "    Signed but NOT notarized. Gatekeeper still refuses a downloaded"
  echo "    copy; notarization is the part that clears quarantine."
fi
