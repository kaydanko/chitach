#!/bin/zsh
# Перевіряє ліцензії всіх розв'язаних SPM-залежностей.
#
# Падає, якщо в графі з'явився copyleft або пакет без файлу ліцензії.
# Запускати після кожної зміни залежностей; результат переносити в
# THIRD_PARTY_LICENSES.md вручну — файл містить висновки, а не лише дані.

source "${0:A:h}/env.sh"
cd "$ROOT"

CHECKOUTS="build/SourcePackages/checkouts"
RESOLVED="Chytach.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

if [[ ! -d "$CHECKOUTS" ]]; then
  echo "error: немає $CHECKOUTS — спершу зберіть проєкт (./Scripts/build.sh)" >&2
  exit 1
fi

echo "=== Розв'язані версії ==="
python3 -c "
import json, sys
d = json.load(open('$RESOLVED'))
pins = d.get('pins', d.get('object', {}).get('pins', []))
for p in sorted(pins, key=lambda x: x.get('identity', '')):
    st = p.get('state', {})
    v = st.get('version') or st.get('revision', '')[:10]
    print(f\"  {p.get('identity',''):<22} {v}\")
print(f'  всього: {len(pins)}')
"

echo
echo "=== Ліцензії ==="
fail=0
for dir in "$CHECKOUTS"/*/; do
  name="${${dir%/}:t}"
  lic=$(ls "$dir" 2>/dev/null | grep -iE "^(LICENSE|LICENCE|COPYING)" | head -1 || true)

  if [[ -z "$lic" ]]; then
    echo "  ✗ $name — ФАЙЛ ЛІЦЕНЗІЇ НЕ ЗНАЙДЕНО"
    fail=1
    continue
  fi

  if grep -qiE "GNU GENERAL PUBLIC|GNU LESSER GENERAL PUBLIC|GNU AFFERO" "$dir$lic"; then
    echo "  ✗ $name — COPYLEFT (GPL/LGPL/AGPL), несумісно з App Store"
    fail=1
    continue
  fi

  kind=$(grep -ohiE "MIT License|BSD 3-Clause|BSD 2-Clause|Apache License|Mozilla Public" "$dir$lic" | head -1 || true)
  [[ -z "$kind" ]] && kind="нестандартна — перевірити вручну"
  echo "  ✓ $name — $kind"
done

echo
if (( fail )); then
  echo "РЕЗУЛЬТАТ: є проблеми, див. ✗ вище"
  exit 1
fi
echo "РЕЗУЛЬТАТ: copyleft не виявлено, у всіх пакетів є файл ліцензії"
echo
echo "Нагадування: CryptoSwift вимагає згадки в документації продукту."
echo "Екран «Про програму → Ліцензії» обов'язковий (Фаза 1)."
