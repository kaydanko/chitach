#!/bin/zsh
source "${0:A:h}/env.sh"

cd "$ROOT"
xcodegen generate --quiet

xcodebuild build \
  -project Chytach.xcodeproj \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  | grep -E "error:|warning:|BUILD|Compiling|Linking" || true

exit ${pipestatus[1]}
