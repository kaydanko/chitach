#!/bin/zsh
# Перевірки розбірника FB2 без симулятора. Див. коментар у
# Tests/Standalone/FB2ParserChecks.swift.
source "${0:A:h}/env.sh"

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

FIXTURE="$ROOT/Tests/Fixtures/ukrainian-sample.fb2"

# Копія у windows-1251: та сама книга, інше кодування й декларація. Саме так
# лежать старі FB2 з бібліотек, і XMLParser має перекодувати їх сам.
sed 's/encoding="UTF-8"/encoding="windows-1251"/' "$FIXTURE" | iconv -f UTF-8 -t WINDOWS-1251 > "$OUT/cp1251.fb2"

# Архіви: стиснутий (так їх роздають бібліотеки) і нестиснутий.
cp "$FIXTURE" "$OUT/book.fb2"
(cd "$OUT" && zip -q -9 deflate.fb2.zip book.fb2 && zip -q -0 stored.fb2.zip book.fb2)

xcrun swiftc -O \
  "$ROOT/Sources/Formats/EPUBBuilder.swift" \
  "$ROOT/Sources/Formats/FB2/FB2Parser.swift" \
  "$ROOT/Sources/Formats/FB2/FB2ZipExtractor.swift" \
  "$ROOT/Sources/Formats/FB2/FB2ToEPUBConverter.swift" \
  "$ROOT/Tests/Standalone/FB2ParserChecks.swift" \
  -o "$OUT/checks"

"$OUT/checks" "$FIXTURE" "$OUT/cp1251.fb2" "$OUT/deflate.fb2.zip" "$OUT/stored.fb2.zip"
