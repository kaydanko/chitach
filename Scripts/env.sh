#!/bin/zsh
# Спільне оточення для всіх скриптів збірки.
#
# На цій машині `xcode-select` вказує на CommandLineTools, де немає ні
# xcodebuild, ні iOS SDK. Перемикання потребує sudo, тому кожен виклик
# xcodebuild іде через DEVELOPER_DIR. Не прибирати без перевірки
# `xcode-select -p`.

set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "error: DEVELOPER_DIR не існує: $DEVELOPER_DIR" >&2
  echo "       Встановіть Xcode або задайте DEVELOPER_DIR вручну." >&2
  exit 1
fi

ROOT="${0:A:h:h}"
export ROOT

SCHEME="Chytach"
export SCHEME

# Симулятор за замовчуванням. Перевизначається змінною DESTINATION.
export DESTINATION="${DESTINATION:-platform=iOS Simulator,name=iPhone 16 Pro,OS=18.5}"
