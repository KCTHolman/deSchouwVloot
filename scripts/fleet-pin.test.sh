#!/usr/bin/env bash
# Tests voor scripts/fleet-pin.sh — lezen en herschrijven van de fleet-pin (I24).
#
# De gevaarlijkste fout die dit script kan maken is niet "te weinig herschrijven" maar "te veel":
# een sed die ook het PAD raakt, of die de bump-workflow zelf pint en daarmee z'n eigen reparatie
# blokkeert. Daar ligt hier dus het meeste testgewicht.
#
# Lokaal: bash scripts/fleet-pin.test.sh

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PIN="$PWD/scripts/fleet-pin.sh"

fail=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fail=1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

mkconsument() {
  local d="$1" ref="$2"
  mkdir -p "$d/.github/workflows"
  printf 'name: a\non:\n  pull_request: {}\njobs:\n  x:\n    uses: KCTHolman/fleet/.github/workflows/pr-label.yml@%s\n' "$ref" > "$d/.github/workflows/a.yml"
  printf 'name: b\non:\n  schedule:\n    - cron: "0 5 * * *"\njobs:\n  y:\n    uses: KCTHolman/fleet/.github/workflows/doctor.yml@%s\n' "$ref" > "$d/.github/workflows/b.yml"
  printf 'name: bump\non:\n  schedule:\n    - cron: "0 3 * * *"\njobs:\n  z:\n    uses: KCTHolman/fleet/.github/workflows/bump-pin.yml@main\n' > "$d/.github/workflows/bump-pin.yml"
}

echo "fleet-pin · current:"

mkconsument "$T/c1" "main"
out="$(bash "$PIN" current --root "$T/c1" 2>/dev/null)"
[ "$(printf '%s' "$out" | sort -u | tr '\n' ' ')" = "main " ] \
  && ok "leest @main" || bad "leest @main (kreeg: $out)"

mkconsument "$T/c2" "abc1234"
out="$(bash "$PIN" current --root "$T/c2" 2>/dev/null | sort -u | tr '\n' ' ')"
[ "$out" = "abc1234 main " ] \
  && ok "leest gemengde refs (pin + de bump-baan op main)" || bad "gemengde refs (kreeg: $out)"

mkdir -p "$T/leeg/.github/workflows"
bash "$PIN" current --root "$T/leeg" >/dev/null 2>&1
[ $? -ne 0 ] && ok "geen verwijzingen => exit != 0" || bad "geen verwijzingen zou moeten falen"

echo "fleet-pin · rewrite:"

mkconsument "$T/r1" "main"
bash "$PIN" rewrite --root "$T/r1" --to "deadbee" >/dev/null 2>&1
grep -q "pr-label.yml@deadbee" "$T/r1/.github/workflows/a.yml" \
  && grep -q "doctor.yml@deadbee" "$T/r1/.github/workflows/b.yml" \
  && ok "herschrijft alle verwijzingen" || bad "herschrijven onvolledig"

# HET PAD MAG NOOIT MEEVERANDEREN — een te gulzige sed sloopt hier de hele aanroep.
grep -q "KCTHolman/fleet/.github/workflows/pr-label.yml@" "$T/r1/.github/workflows/a.yml" \
  && ok "pad blijft ongemoeid, alleen de ref wijzigt" || bad "PAD BESCHADIGD door de rewrite"

mkconsument "$T/r2" "main"
bash "$PIN" rewrite --root "$T/r2" --to "cafe123" --keep bump-pin.yml >/dev/null 2>&1
grep -q "bump-pin.yml@main" "$T/r2/.github/workflows/bump-pin.yml" \
  && ok "--keep laat de bump-baan op @main staan" || bad "--keep werkte niet"
grep -q "pr-label.yml@cafe123" "$T/r2/.github/workflows/a.yml" \
  && ok "--keep raakt de andere bestanden wél" || bad "--keep sloeg te veel over"

# --keep ALS LIJST. Nodig zodra een repo z'n eigen geneste refs pint: dan is er meer dan één
# uitzondering (de ontpin-knop plus de canary-callers). Zonder deze test zou de lijstvorm de eerste
# naam pakken en de rest stilzwijgend tóch herschrijven — een uitzondering die niet uitzondert.
mkconsument "$T/r4" "main"
bash "$PIN" rewrite --root "$T/r4" --to "beef456" --keep "bump-pin.yml, b.yml" >/dev/null 2>&1
if grep -q "bump-pin.yml@main" "$T/r4/.github/workflows/bump-pin.yml" \
   && grep -q "doctor.yml@main" "$T/r4/.github/workflows/b.yml" \
   && grep -q "pr-label.yml@beef456" "$T/r4/.github/workflows/a.yml"; then
  ok "--keep als komma-lijst spaart elk genoemd bestand (spaties toegestaan)"
else
  bad "--keep-lijst werkte niet: $(grep -ho '@[A-Za-z0-9]*' "$T"/r4/.github/workflows/*.yml | tr '\n' ' ')"
fi

mkdir -p "$T/r3/.github/workflows"
printf 'name: zonder\non:\n  push: {}\njobs: {}\n' > "$T/r3/.github/workflows/x.yml"
bash "$PIN" rewrite --root "$T/r3" --to "abc" >/dev/null 2>&1
[ $? -ne 0 ] && ok "niets te herschrijven => exit != 0" || bad "lege rewrite zou moeten falen"

echo "fleet-pin · marker-vorm (Fleet-scripts ophalen, geen workflow_call):"

mkscriptconsument() {
  local d="$1" ref="$2"
  mkdir -p "$d/.github/workflows"
  printf 'name: apply\non:\n  issues: {}\njobs:\n  x:\n    steps:\n      - uses: actions/checkout@v7\n        with:\n          repository: KCTHolman/fleet\n          ref: %s # KCTHolman/fleet-pin\n          path: .fleet-lib\n' "$ref" > "$d/.github/workflows/apply.yml"
}

mkscriptconsument "$T/m1" "oldsha1"
out="$(bash "$PIN" current --root "$T/m1" 2>/dev/null)"
[ "$out" = "oldsha1" ] && ok "leest de marker-ref" || bad "leest de marker-ref (kreeg: $out)"

bash "$PIN" rewrite --root "$T/m1" --to "newsha2" >/dev/null 2>&1
grep -q "ref: newsha2 # KCTHolman/fleet-pin" "$T/m1/.github/workflows/apply.yml" \
  && ok "herschrijft de marker-ref, marker blijft staan" || bad "marker-rewrite mislukt"

# Gemengd: een repo met zowel een workflow_call-pin als een marker-pin (bv. auto-merge.yml ÉN
# een issue-decision-apply-checkout) moet BEIDE meekrijgen bij één rewrite-aanroep.
mkconsument "$T/m2" "oud"
mkscriptconsument "$T/m2" "oud"
mv "$T/m2/.github/workflows/apply.yml" "$T/m2/.github/workflows/c.yml"
bash "$PIN" rewrite --root "$T/m2" --to "vers" >/dev/null 2>&1
grep -q "pr-label.yml@vers" "$T/m2/.github/workflows/a.yml" \
  && grep -q "ref: vers # KCTHolman/fleet-pin" "$T/m2/.github/workflows/c.yml" \
  && ok "workflow_call- én marker-pin allebei bijgewerkt in één run" \
  || bad "gemengde rewrite onvolledig"

# Een `ref:` ZONDER de marker mag nooit meebewegen — dat zou een willekeurige git-ref in een
# willekeurige andere checkout-stap kunnen raken.
mkdir -p "$T/m3/.github/workflows"
printf 'name: x\non:\n  push: {}\njobs:\n  y:\n    steps:\n      - uses: actions/checkout@v7\n        with:\n          repository: someone/other-repo\n          ref: main\n' > "$T/m3/.github/workflows/x.yml"
bash "$PIN" rewrite --root "$T/m3" --to "abc" >/dev/null 2>&1
grep -q "ref: main" "$T/m3/.github/workflows/x.yml" \
  && ok "een ref: zonder marker blijft ongemoeid" || bad "een niet-gemarkeerde ref: werd toch geraakt"

echo "fleet-pin · idempotent:"
mkconsument "$T/i1" "main"
bash "$PIN" rewrite --root "$T/i1" --to "aaa111" >/dev/null 2>&1
before="$(cat "$T/i1/.github/workflows/a.yml")"
bash "$PIN" rewrite --root "$T/i1" --to "aaa111" >/dev/null 2>&1
[ "$before" = "$(cat "$T/i1/.github/workflows/a.yml")" ] \
  && ok "tweemaal dezelfde ref schrijven verandert niets" || bad "niet idempotent"

if [ "$fail" = 0 ]; then
  echo "✅ alle fleet-pin-tests groen"
else
  echo "❌ fleet-pin-tests faalden"
fi
exit "$fail"
