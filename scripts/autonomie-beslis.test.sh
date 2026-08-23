#!/usr/bin/env bash
# Tests voor scripts/autonomie-beslis.sh — de autonomieschakelaar.
#
# WAT HIER ECHT WORDT GETOETST. Niet "geeft de schakelaar het antwoord dat erin staat" — dat is de
# makkelijke helft en die zie je meteen als 'ie stuk is. De helft die stil kapot gaat, is de
# VLOER: de gevallen waarin de repo op autonoom staat en er tóch een mens aan te pas moet komen.
# Die gevallen komen in de praktijk zelden voor, en juist daarom merkt niemand het als ze wegvallen
# — tot de ene keer dat het misgaat, en dan is er geen spoor van een beslissing.
#
# De eerste blok hieronder is daarom bewust de KRUISING: elke vloer-poort getoetst mét
# `--override autonomous` erbij. Als een van die regels ooit `autonoom` teruggeeft, is de
# schakelaar geen schakelaar meer maar een schaar door alle remmen.
#
# Lokaal: bash scripts/autonomie-beslis.test.sh

set -uo pipefail
cd "$(dirname "$0")/.."
AUT="$PWD/scripts/autonomie-beslis.sh"

fail=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fail=1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# contract <naam> <autonomy-blok> → pad
contract() {
  local naam="$1"; shift
  printf 'version: 1\n%s' "$*" > "$T/$naam"
  echo "$T/$naam"
}

# verwacht <naam> <verwacht> <args...>
verwacht() {
  local naam="$1" want="$2"; shift 2
  local got; got="$(bash "$AUT" "$@" 2>/dev/null)"
  [ "$got" = "$want" ] && ok "$naam" || bad "$naam (kreeg '$got', verwacht '$want')"
}

# exitcode <naam> <verwachte code> <args...>
exitcode() {
  local naam="$1" want="$2"; shift 2
  bash "$AUT" "$@" >/dev/null 2>&1
  local got=$?
  [ "$got" = "$want" ] && ok "$naam" || bad "$naam (exit $got, verwacht $want)"
}

VOL_AUTONOOM="$(contract vol.yml 'autonomy:
  mode: autonomous
  allow_breaking: false
')"
BREAKING_MAG="$(contract breaking.yml 'autonomy:
  mode: autonomous
  allow_breaking: true
')"
GEMENGD="$(contract gemengd.yml 'autonomy:
  mode: supervised
  stations:
    merge: supervised
')"
GEEN_SECTIE="$(contract geen.yml 'lanes:
  agent: ubuntu-latest
')"
ONZIN="$(contract onzin.yml 'autonomy:
  mode: heel-erg-autonoom
')"
KAPOT="$T/kapot.yml"; printf 'version: 1\nautonomy: [dit is\n  geen: mapping\n' > "$KAPOT"

echo "autonomie · DE VLOER (elke regel staat óók op --override autonomous):"

verwacht "gevoelig pad wint van de schakelaar" mens \
  --station merge --contract "$VOL_AUTONOOM" --override autonomous --sensitive true
verwacht "noodrem FLEET_HALT wint van de schakelaar" mens \
  --station merge --contract "$VOL_AUTONOOM" --override autonomous --halt 1
verwacht "noodrem accepteert elke niet-uit-waarde" mens \
  --station merge --contract "$VOL_AUTONOOM" --override autonomous --halt misschien
verwacht "label needs-human wint van de schakelaar" mens \
  --station merge --contract "$VOL_AUTONOOM" --override autonomous --labels "area: ci needs-human"
verwacht "label no-automerge wint van de schakelaar" mens \
  --station merge --contract "$VOL_AUTONOOM" --override autonomous --labels "no-automerge"
verwacht "breaking wacht op een mens zonder allow_breaking" mens \
  --station merge --contract "$VOL_AUTONOOM" --override autonomous --breaking true

echo
echo "autonomie · de vloer laat door wat er niet onder valt:"

# De keerzijde van de vloer: een poort die te breed sluit, legt de autonome stand stil zonder dat
# iemand doorheeft waaróm. `needs-humanoid` is geen `needs-human`.
verwacht "needs-humanoid is geen needs-human" autonoom \
  --station merge --contract "$VOL_AUTONOOM" --labels "needs-humanoid"
verwacht "FLEET_HALT=0 is geen noodrem" autonoom \
  --station merge --contract "$VOL_AUTONOOM" --halt 0
verwacht "FLEET_HALT leeg is geen noodrem" autonoom \
  --station merge --contract "$VOL_AUTONOOM" --halt ""
verwacht "sensitive=false laat door" autonoom \
  --station merge --contract "$VOL_AUTONOOM" --sensitive false
verwacht "breaking mag mét allow_breaking" autonoom \
  --station merge --contract "$BREAKING_MAG" --breaking true

echo
echo "autonomie · de schakelaar (repo-variabele boven contract):"

verwacht "FLEET_AUTONOMY=autonomous zet een begeleide repo om" autonoom \
  --station merge --contract "$GEMENGD" --override autonomous
verwacht "FLEET_AUTONOMY=supervised zet een autonome repo terug" mens \
  --station merge --contract "$VOL_AUTONOOM" --override supervised
verwacht "nederlandse waarde 'autonoom' telt ook" autonoom \
  --station merge --contract "$GEMENGD" --override autonoom
verwacht "onbekende waarde valt terug op mens, niet op het contract" mens \
  --station merge --contract "$VOL_AUTONOOM" --override jazeker

echo
echo "autonomie · het contract (station boven repo-default):"

# Het station wint van de repo-default, in BEIDE richtingen — dat is de hele functie van
# `stations`. Vandaag is `merge` het enige gewirede beslispunt, dus dat is ook het enige dat hier
# te toetsen valt zonder iets te toetsen wat niemand aanroept.
STATION_AUTONOOM="$(contract station-aut.yml 'autonomy:
  mode: supervised
  stations:
    merge: autonomous
')"
STATION_MENS="$(contract station-mens.yml 'autonomy:
  mode: autonomous
  stations:
    merge: supervised
')"

verwacht "stations.merge=autonomous wint van mode=supervised" autonoom \
  --station merge --contract "$STATION_AUTONOOM"
verwacht "stations.merge=supervised wint van mode=autonomous" mens \
  --station merge --contract "$STATION_MENS"
verwacht "stations.merge=supervised bevestigt de default" mens \
  --station merge --contract "$GEMENGD"
verwacht "mode=autonomous zonder stations-sectie" autonoom \
  --station merge --contract "$VOL_AUTONOOM"

echo
echo "autonomie · fail-closed (niets weten is nooit autonoom):"

verwacht "geen autonomy-sectie => mens" mens \
  --station merge --contract "$GEEN_SECTIE"
verwacht "contract bestaat niet => mens" mens \
  --station merge --contract "$T/bestaat-niet.yml"
verwacht "kapotte YAML => mens" mens \
  --station merge --contract "$KAPOT"
verwacht "onbekende mode-waarde => mens" mens \
  --station merge --contract "$ONZIN"
verwacht "geen autonomy-sectie, ook met een lege override" mens \
  --station merge --contract "$GEEN_SECTIE" --override ""

echo
echo "autonomie · gebruiksfouten (exit 2, geen stilzwijgende beslissing):"

exitcode "onbekend station (typefout)" 2 --station mergen --contract "$VOL_AUTONOOM"
# `triage` is een echt beslispunt in de pijplijn, maar NIET gewired op de resolver. Dat moet een
# harde fout zijn en geen stilzwijgend antwoord: anders zet iemand `stations.triage` en gelooft
# dat het werkt. Zodra triage gewired wordt, verhuist deze regel naar het blok hierboven.
exitcode "nog niet gewired station (triage)" 2 --station triage --contract "$VOL_AUTONOOM"
exitcode "geen station" 2 --contract "$VOL_AUTONOOM"
exitcode "onbekend argument" 2 --station merge --wat-is-dit
exitcode "geldige aanroep" 0 --station merge --contract "$VOL_AUTONOOM"

echo
echo "autonomie · elke beslissing komt met een reden op stderr:"

for geval in \
  "--station merge --contract $VOL_AUTONOOM" \
  "--station merge --contract $VOL_AUTONOOM --sensitive true" \
  "--station merge --contract $GEEN_SECTIE" \
  "--station merge --contract $VOL_AUTONOOM --halt 1"
do
  # shellcheck disable=SC2086
  if bash "$AUT" $geval 2>&1 >/dev/null | grep -q '^reden: '; then
    ok "reden aanwezig: ${geval#--station merge --contract }"
  else
    bad "geen reden op stderr: $geval"
  fi
done

echo
[ "$fail" -eq 0 ] && echo "✅ autonomie-beslis: alle tests groen" || echo "❌ autonomie-beslis: er faalden tests"
exit "$fail"
