#!/bin/zsh
# Перевірки розбірника картинок RTF без симулятора. Див. коментар у
# Tests/Standalone/RTFPictureExtractorChecks.swift.
source "${0:A:h}/env.sh"

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

xcrun swiftc -O \
  "$ROOT/Sources/Formats/RTF/RTFPictureExtractor.swift" \
  "$ROOT/Tests/Standalone/RTFPictureExtractorChecks.swift" \
  -o "$OUT/checks"

"$OUT/checks"
