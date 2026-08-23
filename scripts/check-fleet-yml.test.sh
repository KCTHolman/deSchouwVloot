#!/usr/bin/env bash
# Tests voor scripts/check-fleet-yml.py — de validator van het consumer-contract.
#
# De kernwaarde van die validator is dat 'ie ONBEKENDE SLEUTELS tegenhoudt: een typefout in
# `.fleet.yml` doet anders gewoon niets, en dan draait een station op een default die niemand
# koos. Die gevallen krijgen hier dus de meeste dekking.
#
# Lokaal: bash scripts/check-fleet-yml.test.sh

set -uo pipefail
cd "$(dirname "$0")/.."
V="scripts/check-fleet-yml.py"

fail=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fail=1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# geldig_contract [extra-yaml]
geldig_contract() {
  cat <<EOF
version: 1
lanes:
  agent: biohack-agent
  heavy: biohack-heavy
  light: biohack-light
  fallback: ubuntu-latest
gates:
  feature_approval: true
  release_environment: production
budgets:
  default_model: claude-sonnet-5
  max_turns:
    triage: 30
    build: 80
labels:
  task: claude-task
  human: needs-human
${1:-}
EOF
}

# verwacht <naam> <geldig|ongeldig> <yaml> [patroon]
verwacht() {
  local naam="$1" wil="$2" yml="$3" patroon="${4:-}"
  printf '%s' "$yml" > "$T/f.yml"
  local out rc
  out="$(python "$V" "$T/f.yml" 2>&1)"; rc=$?
  if [ "$wil" = "geldig" ]; then
    [ "$rc" = 0 ] && ok "$naam" || { bad "$naam (verwacht geldig, exit $rc)"; printf '%s\n' "$out" | sed 's/^/      /'; }
  else
    if [ "$rc" != 0 ] && { [ -z "$patroon" ] || printf '%s' "$out" | grep -q "$patroon"; }; then
      ok "$naam"
    else
      bad "$naam (verwacht ongeldig${patroon:+ met /$patroon/}, exit $rc)"; printf '%s\n' "$out" | sed 's/^/      /'
    fi
  fi
}

echo "check-fleet-yml · geldige contracten:"

verwacht "minimaal volledig contract" geldig "$(geldig_contract)"
verwacht "met optionele secties" geldig "$(geldig_contract "$(printf 'spine:\n  - auto-merge.yml\nprompts:\n  partials_dir: .fleet/prompts')")"
verwacht "consument zonder self-hosted lanes" geldig "$(printf 'version: 1\nlanes:\n  agent: ubuntu-latest\n  heavy: ubuntu-latest\n  light: ubuntu-latest\n  fallback: ubuntu-latest\ngates:\n  feature_approval: false\n  release_environment: null\nbudgets:\n  default_model: claude-sonnet-5\n  max_turns:\n    triage: 20\nlabels:\n  task: fleet-task\n  human: needs-human\n')"

echo "check-fleet-yml · typefouten (de hoofdreden dat dit bestaat):"

verwacht "typefout in een SECTIE" ongeldig \
  "$(geldig_contract | sed 's/^lanes:/lanez:/')" "onbekende sectie"

verwacht "typefout in een SLEUTEL" ongeldig \
  "$(geldig_contract | sed 's/  fallback:/  falback:/')" "onbekende sleutel"

verwacht "budget voor onbekend station" ongeldig \
  "$(geldig_contract | sed 's/    triage: 30/    triagee: 30/')" "onbekend station"

echo "check-fleet-yml · ontbrekende of foute waarden:"

verwacht "verplichte sectie weg" ongeldig \
  "$(geldig_contract | sed '/^labels:/,+2d')" "verplichte sectie .labels."

verwacht "verplichte sleutel weg" ongeldig \
  "$(geldig_contract | sed '/^  human:/d')" "verplichte sleutel .labels.human."

verwacht "feature_approval als string" ongeldig \
  "$(geldig_contract | sed 's/  feature_approval: true/  feature_approval: "ja"/')" "moet bool"

verwacht "max_turns negatief" ongeldig \
  "$(geldig_contract | sed 's/    triage: 30/    triage: -5/')" "positief geheel getal"

verwacht "lege lane" ongeldig \
  "$(geldig_contract | sed 's/  heavy: biohack-heavy/  heavy: ""/')" "is leeg"

verwacht "spine met iets dat geen workflow is" ongeldig \
  "$(geldig_contract "$(printf 'spine:\n  - auto-merge')")" "workflow-bestandsnamen"

verwacht "onbekende versie" ongeldig \
  "$(geldig_contract | sed 's/^version: 1/version: 2/')" "alleen 1 bestaat"

echo "check-fleet-yml · areas (de M6-pilot-config):"

AREAS_OK="$(printf 'areas:\n  - label: "area: web"\n    paths: "^web/"\n    color: C5DEF5\n    description: webfrontend\n  - label: "area: ci"\n    paths: "^\\\\.github/"\n')"
verwacht "geldige areas-lijst" geldig "$(geldig_contract "$AREAS_OK")"

verwacht "areas met onbekende sleutel" ongeldig \
  "$(geldig_contract "$(printf 'areas:\n  - label: "area: web"\n    paths: "^web/"\n    kleur: rood\n')")" "onbekende sleutel .areas\[0\].kleur."

verwacht "areas zonder paths" ongeldig \
  "$(geldig_contract "$(printf 'areas:\n  - label: "area: web"\n')")" "areas\[0\].paths. ontbreekt"

verwacht "areas met kapotte regex" ongeldig \
  "$(geldig_contract "$(printf 'areas:\n  - label: "area: web"\n    paths: "^web/[unclosed"\n')")" "geen geldige regex"

verwacht "areas met foute kleur" ongeldig \
  "$(geldig_contract "$(printf 'areas:\n  - label: "area: web"\n    paths: "^web/"\n    color: "#C5DEF5"\n')")" "6 hex-tekens"

echo "check-fleet-yml · autonomy (de stand van de repo):"

# WAAROM DEZE SECTIE ZWAARDER GETOETST WORDT DAN Z'N OMVANG SUGGEREERT. Een fout in `lanes` merk
# je binnen één run (de job vindt geen runner). Een fout in `autonomy` merk je NOOIT: de resolver
# valt bij twijfel terug op `mens`, dus een verkeerd gespelde stand ziet eruit als een repo die
# gewoon nog begeleid draait. Precies de klasse stilte waar deze validator voor bestaat.

verwacht "geen autonomy-sectie is geldig (migratiepad)" geldig "$(geldig_contract)"

verwacht "mode supervised" geldig \
  "$(geldig_contract "$(printf 'autonomy:\n  mode: supervised\n')")"
verwacht "mode autonomous met stations en allow_breaking" geldig \
  "$(geldig_contract "$(printf 'autonomy:\n  mode: autonomous\n  allow_breaking: true\n  stations:\n    merge: supervised\n')")"
verwacht "nederlandse standen" geldig \
  "$(geldig_contract "$(printf 'autonomy:\n  mode: autonoom\n  stations:\n    merge: mens\n')")"

verwacht "autonomy zonder mode" ongeldig \
  "$(geldig_contract "$(printf 'autonomy:\n  allow_breaking: true\n')")" "verplichte sleutel .autonomy.mode."
verwacht "onbekende sleutel in autonomy" ongeldig \
  "$(geldig_contract "$(printf 'autonomy:\n  mode: supervised\n  modus: autonomous\n')")" "onbekende sleutel .autonomy.modus."
verwacht "mode met een waarde die geen stand is" ongeldig \
  "$(geldig_contract "$(printf 'autonomy:\n  mode: full\n')")" "geldig: supervised"
verwacht "onbekend beslispunt" ongeldig \
  "$(geldig_contract "$(printf 'autonomy:\n  mode: supervised\n  stations:\n    build: autonomous\n')")" "onbekend beslispunt .autonomy.stations.build."

# `triage` IS een beslispunt in de pijplijn — maar nog niet gewired op de resolver. Dat moet rood
# zijn, niet stilzwijgend geaccepteerd: anders zet iemand `stations.triage: autonomous` en gelooft
# dat het werkt, precies de faalvorm van `gates.feature_approval` die deze sectie repareert.
# Zodra triage gewired wordt, verhuist deze regel naar de geldige gevallen hierboven.
verwacht "beslispunt dat nog niet gewired is (triage)" ongeldig \
  "$(geldig_contract "$(printf 'autonomy:\n  mode: supervised\n  stations:\n    triage: autonomous\n')")" "onbekend beslispunt .autonomy.stations.triage."
verwacht "beslispunt met onzin-stand" ongeldig \
  "$(geldig_contract "$(printf 'autonomy:\n  mode: supervised\n  stations:\n    merge: soms\n')")" "geldig: supervised of autonomous"
verwacht "allow_breaking als string" ongeldig \
  "$(geldig_contract "$(printf 'autonomy:\n  mode: supervised\n  allow_breaking: "ja"\n')")" "moet bool"
verwacht "stations als lijst i.p.v. mapping" ongeldig \
  "$(geldig_contract "$(printf 'autonomy:\n  mode: supervised\n  stations:\n    - merge\n')")" "moet een mapping zijn"

echo "check-fleet-yml · het echte contract van deze repo:"
out="$(python "$V" .fleet.yml 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "deFleet's eigen .fleet.yml is geldig" || { bad "deFleet's eigen .fleet.yml"; printf '%s\n' "$out" | sed 's/^/      /'; }

if [ "$fail" = 0 ]; then
  echo "✅ alle check-fleet-yml-tests groen"
else
  echo "❌ check-fleet-yml-tests faalden"
fi
exit "$fail"
