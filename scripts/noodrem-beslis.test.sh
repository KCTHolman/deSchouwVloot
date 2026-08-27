#!/usr/bin/env bash
# Tests voor scripts/noodrem-beslis.sh — de review-noodrem (I20).
#
# De twee helften van I20 trekken in TEGENGESTELDE richting, en beide moeten hard vastliggen:
#
#   1. inhoud      → een bewijsbare blocker MOET remmen (anders merget een datalek vanzelf);
#   2. storing     → een omgevallen review mag NOOIT remmen (anders legt één flaky run alles stil).
#
# Het gevaarlijkste geval is de kruising: een verdict mét blockers terwijl de review-run zelf
# faalde. Daar moet punt 2 winnen — dat is letterlijk wat I20 voorschrijft, en het is precies het
# geval dat je bij handmatig proberen nooit tegenkomt.
#
# Lokaal: bash scripts/noodrem-beslis.test.sh

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REM="$PWD/scripts/noodrem-beslis.sh"

fail=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fail=1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# schrijf <naam> <inhoud> → pad
schrijf() { printf '%s' "$2" > "$T/$1"; echo "$T/$1"; }

# verwacht <naam> <verwacht> <args...>
verwacht() {
  local naam="$1" want="$2"; shift 2
  local got; got="$(bash "$REM" "$@" 2>/dev/null)"
  [ "$got" = "$want" ] && ok "$naam" || bad "$naam (kreeg '$got', verwacht '$want')"
}

BLOCKER='{"advies":[],"blockers":[{"wat":"token in log","faal_scenario":"PR-body met secret komt in de run-log en is publiek leesbaar"}]}'
SCHOON='{"advies":[{"wat":"naamgeving"},{"wat":"nit"}],"blockers":[]}'

echo "noodrem · inhoud (een bewijsbare blocker moet remmen):"

verwacht "blocker met faal_scenario => blokkeer" blokkeer \
  --verdict "$(schrijf b1.json "$BLOCKER")"
verwacht "twee blockers => blokkeer" blokkeer \
  --verdict "$(schrijf b2.json '{"blockers":[{"wat":"a","faal_scenario":"x"},{"wat":"b","faal_scenario":"y"}]}')"
verwacht "advies naast blocker => blokkeer" blokkeer \
  --verdict "$(schrijf b3.json '{"advies":[{"wat":"nit"}],"blockers":[{"wat":"crash","faal_scenario":"null-deref bij lege lijst"}]}')"

echo "noodrem · advies blijft advies:"

verwacht "alleen advies => vrij" vrij --verdict "$(schrijf a1.json "$SCHOON")"
verwacht "veel advies, nul blockers => vrij" vrij \
  --verdict "$(schrijf a2.json '{"advies":[{"wat":"1"},{"wat":"2"},{"wat":"3"},{"wat":"4"},{"wat":"5"}],"blockers":[]}')"
verwacht "blockers-veld ontbreekt => vrij" vrij \
  --verdict "$(schrijf a3.json '{"advies":[{"wat":"nit"}]}')"

echo "noodrem · storing trekt NOOIT aan de rem (I20, tweede helft):"

# HET KRUISPUNT: er staan blockers in, maar de review-run zelf is omgevallen. Dan weet je niets
# over de betrouwbaarheid van dat verdict, en I20 kiest expliciet voor doorlaten.
for st in failure cancelled timed_out skipped startup_failure ""; do
  verwacht "review-status='${st:-<leeg>}' MÉT blockers => vrij" vrij \
    --verdict "$(schrijf "s-${st:-leeg}.json" "$BLOCKER")" --review-status "$st"
done

verwacht "verdict-bestand ontbreekt => vrij" vrij --verdict "$T/bestaat-niet.json"
verwacht "leeg verdict-bestand => vrij" vrij --verdict "$(schrijf leeg.json '')"
verwacht "geen --verdict meegegeven => vrij" vrij
verwacht "onparseerbare JSON => vrij" vrij \
  --verdict "$(schrijf stuk.json '{dit is geen json')"
verwacht "verdict is een lijst i.p.v. object => vrij" vrij \
  --verdict "$(schrijf lijst.json '[{"wat":"a"}]')"
verwacht "blockers is geen lijst => vrij" vrij \
  --verdict "$(schrijf raar.json '{"blockers":"er is iets mis"}')"

echo "noodrem · onvolledige blocker (half alarm negeren is de dure fout):"

verwacht "blocker zonder faal_scenario => tóch blokkeer" blokkeer \
  --verdict "$(schrijf o1.json '{"blockers":[{"wat":"iets"}]}')"
verwacht "blocker met leeg faal_scenario => tóch blokkeer" blokkeer \
  --verdict "$(schrijf o2.json '{"blockers":[{"wat":"iets","faal_scenario":"   "}]}')"
verwacht "blocker die geen object is => tóch blokkeer" blokkeer \
  --verdict "$(schrijf o3.json '{"blockers":["losse tekst"]}')"

# De reden moet altijd op stderr staan: zonder toelichting is een rem niet te weerleggen, en juist
# bij een noodrem moet een mens in één regel kunnen zien waaróm 'ie eraan hing.
uit="$(bash "$REM" --verdict "$(schrijf r1.json "$BLOCKER")" 2>&1 >/dev/null)"
printf '%s' "$uit" | grep -q '^reden: ' && ok "reden staat op stderr" || bad "geen reden op stderr (kreeg: $uit)"

uit="$(bash "$REM" --verdict "$(schrijf r2.json "$BLOCKER")" --review-status failure 2>&1 >/dev/null)"
printf '%s' "$uit" | grep -q 'I20' && ok "storing-reden noemt de invariant" || bad "storing-reden noemt I20 niet"

echo "noodrem · gebruiksfouten:"
bash "$REM" --onzin x >/dev/null 2>&1
[ $? = 2 ] && ok "onbekend argument => exit 2" || bad "onbekend argument zou exit 2 moeten geven"

if [ "$fail" = 0 ]; then
  echo "✅ alle noodrem-tests groen"
else
  echo "❌ noodrem-tests faalden"
fi
exit "$fail"
