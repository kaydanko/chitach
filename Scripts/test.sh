#!/bin/zsh
source "${0:A:h}/env.sh"

cd "$ROOT"
xcodegen generate --quiet

xcodebuild test \
  -project Chytach.xcodeproj \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  | grep -E "error:|failed|passed|Test Suite|Executed|BUILD|TEST" || true

exit ${pipestatus[1]}
