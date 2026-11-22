#!/bin/zsh
# Збирає Mac-варіант і пакує його в DMG для публікації.
#
# Образ містить сам застосунок і посилання на теку «Програми», щоб
# встановлення зводилося до перетягування.
#
# Застосунок підписаний ad-hoc: нотаризація потребує платного Apple Developer
# Program. Тому після завантаження користувачеві треба зняти карантин —
# README описує як.

source "${0:A:h}/env.sh"
cd "$ROOT"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/Info.plist 2>/dev/null || echo 0.1.0)}"
STAGE="$(mktemp -d)"
DMG="$ROOT/dist/Chytach-$VERSION.dmg"

echo "Збірка Mac Catalyst, версія $VERSION…"
xcodegen generate --quiet
xcodebuild build \
  -project Chytach.xcodeproj \
  -scheme "$SCHEME" \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -configuration Release \
  -derivedDataPath build-catalyst \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
  | grep -E "error:|BUILD" || true

APP="$ROOT/build-catalyst/Build/Products/Release-maccatalyst/Chytach.app"
if [[ ! -d "$APP" ]]; then
  echo "error: застосунок не зібрано" >&2
  exit 1
fi

codesign --verify --deep --strict "$APP" || { echo "error: підпис недійсний" >&2; exit 1; }

mkdir -p "$ROOT/dist"
rm -f "$DMG"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Програми"

hdiutil create \
  -volname "Chytach $VERSION" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null

rm -rf "$STAGE"
echo "готово: $DMG ($(du -h "$DMG" | cut -f1))"
