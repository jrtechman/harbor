#!/bin/bash
# Builds Harbor and packages it for sharing: a disk image and a zip in ./dist.
# The app is ad-hoc signed (no Apple Developer ID), so people who receive it have to approve it
# once the first time it opens. The disk image includes a short note explaining how.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Harbor.app/Contents/Info.plist)
OUT="dist"
STAGE="$(mktemp -d)/Harbor"
mkdir -p "$OUT" "$STAGE"

ditto build/Harbor.app "$STAGE/Harbor.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read me first.txt" <<'TXT'
HARBOR: FIRST LAUNCH

Harbor lets you use several Claude accounts at the same time on one Mac.
It needs macOS 14 or later and the Claude desktop app in /Applications
(download it from claude.ai/download).

1. Drag Harbor into your Applications folder.

2. Open it. Harbor isn't signed with an Apple Developer ID, so macOS shows a warning
   the first time. This is normal for apps shared outside the App Store.

   Right-click (or Control-click) Harbor, choose Open, then click Open.

   If macOS only offers "Done" or "Move to Trash":
   open System Settings > Privacy & Security, scroll down to the message about Harbor,
   click "Open Anyway", then open Harbor again.

   Terminal alternative:
       xattr -dr com.apple.quarantine /Applications/Harbor.app

3. Harbor shows a short guide the first time it opens. You can view it again from
   Settings > Help.

Harbor is an independent app and is not affiliated with Anthropic.
TXT

rm -f "$OUT/Harbor-$VERSION.dmg" "$OUT/Harbor-$VERSION.zip"
hdiutil create -volname "Harbor $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$OUT/Harbor-$VERSION.dmg" >/dev/null
ditto -c -k --keepParent build/Harbor.app "$OUT/Harbor-$VERSION.zip"
(cd "$OUT" && shasum -a 256 "Harbor-$VERSION.dmg" "Harbor-$VERSION.zip" > "Harbor-$VERSION.sha256")
rm -rf "$(dirname "$STAGE")"

echo
echo "Packaged:"
ls -lh "$OUT" | grep "Harbor-$VERSION"
