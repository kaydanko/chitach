#!/bin/zsh
# Спільне оточення для всіх скриптів збірки.

set -euo pipefail

# Беремо те, що обрано в системі, і лише якщо там CommandLineTools (без
# xcodebuild і SDK) — шукаємо Xcode самі.
#
# Раніше тут був зашитий шлях до Xcode-beta: `xcode-select` вказував на
# CommandLineTools, а змінити це без пароля неможливо. Зашитий шлях пережив
# себе — щойно Xcode замінили, збірка впала б на неіснуючій теці.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  SELECTED="$(xcode-select -p 2>/dev/null || true)"

  if [[ -x "$SELECTED/usr/bin/xcodebuild" ]]; then
    export DEVELOPER_DIR="$SELECTED"
  else
    for CANDIDATE in /Applications/Xcode.app /Applications/Xcode-beta.app; do
      if [[ -x "$CANDIDATE/Contents/Developer/usr/bin/xcodebuild" ]]; then
        export DEVELOPER_DIR="$CANDIDATE/Contents/Developer"
        break
      fi
    done
  fi
fi

if [[ -z "${DEVELOPER_DIR:-}" || ! -d "$DEVELOPER_DIR" ]]; then
  echo "error: не знайдено Xcode." >&2
  echo "       Встановіть його або задайте DEVELOPER_DIR вручну." >&2
  exit 1
fi

ROOT="${0:A:h:h}"
export ROOT

SCHEME="Chytach"
export SCHEME

# Симулятор за замовчуванням: перший доступний iPhone, за його
# ідентифікатором.
#
# Не за іменем і не за версією системи: і те, і те вже ламалося. Ім'я без
# версії xcodebuild не розпізнає, коли той самий пристрій існує для кількох
# runtime, а зашита версія живе рівно до наступного оновлення Xcode.
if [[ -z "${DESTINATION:-}" ]]; then
  SIMULATOR_ID="$(
    xcrun simctl list devices available -j 2>/dev/null | /usr/bin/python3 -I -c "
import json, sys
devices = json.load(sys.stdin)['devices']
for runtime in sorted(devices, reverse=True):
    if 'iOS' not in runtime:
        continue
    for device in devices[runtime]:
        if device['name'].startswith('iPhone'):
            print(device['udid'])
            raise SystemExit
" || true
  )"

  if [[ -z "$SIMULATOR_ID" ]]; then
    echo "error: не знайдено жодного симулятора iPhone." >&2
    exit 1
  fi

  export DESTINATION="platform=iOS Simulator,id=$SIMULATOR_ID"
fi
