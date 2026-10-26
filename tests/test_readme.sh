#!/bin/zsh
# Structure and hygiene checks for README.md (and, below, the issue templates).
#   zsh tests/test_readme.sh
PUB=${0:A:h:h}
R=$PUB/README.md
fail() { echo "FAIL: $1"; exit 1; }

[[ -f $R ]] || fail "missing: ## Что это (no README.md)"
for s in "## Что это" "## Зачем устройству китайский IP" "## Почему точка доступа телефона не помогает" \
         "## Что нужно" "## Предупреждения" "## Шаги" "## Как понять, что работает" "## Что не так" \
         "## Режим с ключом" "## Проверено на" "## Как это устроено" "## Лицензия"; do
  grep -q "^$s" $R || fail "missing: $s"
done
grep -q "route-to" $R      || fail "warning must name route-to"
grep -q "kernel panic" $R  || fail "warning must say kernel panic"
grep -q "используйте на свой риск" $R || fail "disclaimer 1"
grep -q "соблюдайте условия вашего VPN-провайдера и законы своей страны" $R || fail "disclaimer 2"
grep -q "Voyah Free+" $R   || fail "tested-on row: device"
grep -q "2026-10-26" $R    || fail "tested-on row: date"
grep -q "не проверено" $R  || fail "key mode label"
grep -q "Share from" $R    || fail "Internet Sharing field name"
grep -q "iPhone USB" $R    || fail "Internet Sharing source"
grep -qE "t\.me/|@[a-zA-Z0-9_]{4,}" $R && fail "forbidden link/username"
grep -qE "ss://[A-Za-z0-9+/=]{20,}" $R && fail "looks like a real key"
grep -q "LDP95" $R && fail "VIN leaked"
echo README-OK

# --- issue templates
D=$PUB/.github/ISSUE_TEMPLATE
grep -q "blank_issues_enabled: false" $D/config.yml 2>/dev/null || fail "config.yml: blank issues must be off"
for f in tested-on problem; do
  head -1 $D/$f.md 2>/dev/null | grep -q '^---$' || fail "$f.md: front matter"
  grep -q "^name:" $D/$f.md   || fail "$f.md: name"
  grep -q "^labels:" $D/$f.md || fail "$f.md: labels"
  grep -q "Не вставляйте ключи, VIN и идентификаторы аккаунта" $D/$f.md || fail "$f.md: privacy warning"
  grep -q "zsh car-vpn.sh check" $D/$f.md || fail "$f.md: asks for check output"
done
grep -q "Проверил на" $D/tested-on.md      || fail "tested-on.md: title"
grep -q "inbound/redirect" $D/tested-on.md || fail "tested-on.md: asks for redirect lines"
grep -q "На каком шаге" $D/problem.md      || fail "problem.md: asks which step"
grep -q "20 строк" $D/problem.md           || fail "problem.md: asks for log tail"
echo TEMPLATES-OK
