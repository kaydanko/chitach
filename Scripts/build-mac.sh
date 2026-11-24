#!/bin/zsh
# Збирає Mac-варіант для перевірки й не лишає по собі копії застосунку.
#
# Окремий скрипт, а не `xcodebuild` нашвидкуруч: кожен Chytach.app, що
# лежить на диску, система бере на облік як окремий застосунок, і в
# системних переліках їх набиралося по чотири — поряд із тим, що
# встановлений у «Програми». Тому тека збірки лежить поза проєктом, а
# зібраний застосунок прибирається одразу: від перевірки потрібен вердикт
# збірки, а не копія.
#
# Щоб отримати застосунок для встановлення, беріть `make-dmg.sh`.

source "${0:A:h}/env.sh"

cd "$ROOT"
xcodegen generate --quiet

DERIVED="${TMPDIR:-/tmp/}chytach-mac-build"

xcodebuild build \
  -project Chytach.xcodeproj \
  -scheme "$SCHEME" \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  | grep -E "error:|warning:|BUILD" || true

STATUS=${pipestatus[1]}

# Знімаємо з обліку, а не просто вилучаємо: `xcodebuild` реєструє зібраний
# застосунок у системі ще під час збірки, і сам запис переживає теку —
# в переліках залишається Chytach із перекресленою піктограмою.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

forget_app() {
  [[ -x "$LSREGISTER" ]] && "$LSREGISTER" -u "$1" >/dev/null 2>&1
  rm -rf "$1"
}

# Копію прибираємо завжди, навіть коли збірка впала: недобудований
# застосунок система теж узяла б на облік.
for APP in "$DERIVED"/Build/Products/*/Chytach.app(N); do
  forget_app "$APP"
done

exit $STATUS
