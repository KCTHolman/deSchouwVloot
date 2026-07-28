#!/usr/bin/env bash
# check-no-triggers.test.sh — offline tests voor de trigger-guard.
#
# Een guard die niets vangt is erger dan geen guard: hij geeft dekking die er niet is. Deze suite
# toetst daarom vooral de FAAL-kant — elke triggervorm die publiek gevaarlijk is moet rood geven,
# inclusief de vormen die een naïeve `grep -c workflow_call` zou missen.

set -uo pipefail
cd "$(dirname "$0")/.."

GUARD="scripts/check-no-triggers.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fail=0
ok()  { printf '  ✅ %s\n' "$1"; }
bad() { printf '  ❌ %s\n' "$1"; fail=1; }

# Bouwt een wegwerp-repo met precies één workflowbestand en draait de guard erop.
run_guard() {
  local dir="$1" content="$2"
  rm -rf "$dir"; mkdir -p "$dir/.github/workflows"
  printf '%s' "$content" > "$dir/.github/workflows/w.yml"
  bash "$GUARD" --root "$dir" >/dev/null 2>&1
}

expect_pass() {
  local naam="$1" content="$2"
  if run_guard "$TMP/case" "$content"; then ok "$naam"; else bad "$naam — had moeten slagen"; fi
}

expect_fail() {
  local naam="$1" content="$2"
  if run_guard "$TMP/case" "$content"; then bad "$naam — had moeten falen"; else ok "$naam"; fi
}

echo "check-no-triggers — toegestaan:"

expect_pass "kale workflow_call" \
  "$(printf 'name: a\non:\n  workflow_call: {}\njobs:\n  x:\n    runs-on: ubuntu-latest\n')"

expect_pass "workflow_call met inputs" \
  "$(printf 'name: a\non:\n  workflow_call:\n    inputs:\n      runner:\n        type: string\njobs:\n  x:\n    runs-on: ubuntu-latest\n')"

# De inputs staan vier spaties diep en heten `inputs:`/`outputs:` — die mogen NOOIT als trigger
# geteld worden, anders is elke echte reusable workflow ineens rood.
expect_pass "workflow_call met inputs én outputs" \
  "$(printf 'name: a\non:\n  workflow_call:\n    inputs:\n      x:\n        type: string\n    outputs:\n      y:\n        value: z\njobs:\n  x:\n    runs-on: ubuntu-latest\n')"

echo "check-no-triggers — verboden:"

expect_fail "issues (anonieme voordeur in een publieke repo)" \
  "$(printf 'name: a\non:\n  issues:\n    types: [opened]\njobs:\n  x:\n    runs-on: ubuntu-latest\n')"

expect_fail "pull_request (fork-code op eigen runners)" \
  "$(printf 'name: a\non:\n  pull_request:\n    branches: [main]\njobs:\n  x:\n    runs-on: ubuntu-latest\n')"

expect_fail "schedule" \
  "$(printf 'name: a\non:\n  schedule:\n    - cron: "0 6 * * *"\njobs:\n  x:\n    runs-on: ubuntu-latest\n')"

expect_fail "push" \
  "$(printf 'name: a\non:\n  push:\n    branches: [main]\njobs:\n  x:\n    runs-on: ubuntu-latest\n')"

expect_fail "workflow_dispatch" \
  "$(printf 'name: a\non:\n  workflow_dispatch: {}\njobs:\n  x:\n    runs-on: ubuntu-latest\n')"

# HET GEVAARLIJKSTE GEVAL: een geldige workflow_call MET een verboden trigger ernaast. Wie op de
# aanwezigheid van `workflow_call` controleert in plaats van op de afwezigheid van de rest, laat
# precies dit door.
expect_fail "workflow_call NAAST een verboden trigger" \
  "$(printf 'name: a\non:\n  workflow_call: {}\n  issues:\n    types: [opened]\njobs:\n  x:\n    runs-on: ubuntu-latest\n')"

echo "check-no-triggers — YAML-vormen die een naïeve parser mist:"

# YAML 1.1 leest een kale `on` als de boolean true; daarom quoten sommige tools 'm. De guard moet
# alle drie de schrijfwijzen herkennen, anders sluipt een trigger er ongezien langs.
expect_fail 'gequote "on" met verboden trigger' \
  "$(printf 'name: a\n"on":\n  push:\n    branches: [main]\njobs:\n  x:\n    runs-on: ubuntu-latest\n')"

expect_pass "gequote 'on' met workflow_call" \
  "$(printf "name: a\n'on':\n  workflow_call: {}\njobs:\n  x:\n    runs-on: ubuntu-latest\n")"

expect_fail "inline lijstvorm: on: [push, pull_request]" \
  "$(printf 'name: a\non: [push, pull_request]\njobs:\n  x:\n    runs-on: ubuntu-latest\n')"

expect_pass "inline scalair: on: workflow_call" \
  "$(printf 'name: a\non: workflow_call\njobs:\n  x:\n    runs-on: ubuntu-latest\n')"

# Een workflowbestand zonder `on:` is geen geldige workflow. Stil laten slagen zou betekenen dat
# een typefout in de sleutel (`ons:`) als "veilig" wordt gerapporteerd.
expect_fail "workflow zonder on:-blok" \
  "$(printf 'name: a\njobs:\n  x:\n    runs-on: ubuntu-latest\n')"

echo "check-no-triggers — de echte repo:"

if bash "$GUARD" --root . >/dev/null 2>&1; then
  ok "deze repo is workflow_call-only"
else
  bad "deze repo bevat een workflow die uit zichzelf kan vuren"
  bash "$GUARD" --root . | sed 's/^/       /'
fi

if [ "$fail" = 0 ]; then
  echo "✅ check-no-triggers: alle tests groen"
else
  echo "❌ check-no-triggers: er zijn falende tests"
fi
exit "$fail"
