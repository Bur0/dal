#!/bin/bash
# Builds, signs and publishes a new Dal release.
#
#   scripts/release.sh 0.2.0 "- Tab groups
#   - Faster graph"
#
# The source repo (Bur0/dal) is private. Binaries and the Sparkle feed live in the public
# Bur0/dal-releases repo so installed copies can update without GitHub credentials:
#   - the zip is attached to a GitHub release there,
#   - appcast.xml is committed there (the app reads it from raw.githubusercontent.com).
#
# Needs: xcodegen, gh (logged in with push access to both repos), and the Sparkle EdDSA
# private key in this Mac's login keychain (created once with Sparkle's `generate_keys`).
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version> [notes]}"
NOTES="${2:-Bug fixes and improvements.}"
RELEASES_REPO="Bur0/dal-releases"
cd "$(dirname "$0")/.."
RELEASES_DIR="${DAL_RELEASES_DIR:-$(cd .. && pwd)/dal-releases}"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree isn't clean; commit or stash first." >&2
  exit 1
fi
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
  echo "Tag v$VERSION already exists." >&2
  exit 1
fi
if [[ ! -d "$RELEASES_DIR/.git" ]]; then
  gh repo clone "$RELEASES_REPO" "$RELEASES_DIR"
fi
git -C "$RELEASES_DIR" pull -q --ff-only

BUILD=$(( $(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml | head -1) + 1 ))
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml

echo "▸ Building Dal $VERSION ($BUILD)"
xcodegen generate >/dev/null
xcodebuild -project Dal.xcodeproj -scheme Dal -configuration Release \
  -derivedDataPath build/dist clean build | tail -3

APP="build/dist/Build/Products/Release/Dal.app"
codesign --force --deep --sign - "$APP"   # ad-hoc; see README for Gatekeeper notes
ZIP="build/Dal-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

SIGN_UPDATE=$(find build -type f -path '*Sparkle/bin/sign_update' | head -1)
SIGNATURE=$("$SIGN_UPDATE" "$ZIP")
echo "▸ Signed update: $SIGNATURE"

git add project.yml Dal/Info.plist
git commit -qm "Release $VERSION"
git tag "v$VERSION"
git push -q origin HEAD "v$VERSION"

echo "▸ Publishing the download to $RELEASES_REPO"
gh release create "v$VERSION" "$ZIP" --repo "$RELEASES_REPO" --title "Dal $VERSION" --notes "$NOTES"

# Publish the feed only after the download exists.
URL="https://github.com/$RELEASES_REPO/releases/download/v$VERSION/Dal-$VERSION.zip"
python3 scripts/appcast.py "$RELEASES_DIR/appcast.xml" "$VERSION" "$BUILD" "$URL" "$SIGNATURE" "$NOTES"
# The feed itself is EdDSA-signed (apps require it: SURequireSignedFeed), so nobody who gets
# write access to the releases repo can serve a crafted feed.
"$SIGN_UPDATE" "$RELEASES_DIR/appcast.xml"
"$SIGN_UPDATE" --verify "$RELEASES_DIR/appcast.xml"
git -C "$RELEASES_DIR" add appcast.xml
git -C "$RELEASES_DIR" commit -qm "Dal $VERSION"
git -C "$RELEASES_DIR" push -q origin HEAD
echo "✓ Dal $VERSION is out. Installed copies will see it on their next update check."
