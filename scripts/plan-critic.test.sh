#!/usr/bin/env bash
# Tests voor scripts/plan-critic.sh — de mechanische plan-poort (I19).
#
# De belangrijkste tests zijn niet de afwijzingen maar de NIET-afwijzingen: een criticus die
# vals-positief blokkeert leert mensen de uitkomst te negeren, en dan is de poort erger dan geen
# poort. Elk geval waarin twijfel mogelijk is (nieuw bestand, korte maar volledige plannen) hoort
# er als bevinding uit te komen en niet als reden.
#
# Lokaal: bash scripts/plan-critic.test.sh

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
CRITIC="scripts/plan-critic.sh"

fail=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fail=1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# verwacht <naam> <akkoord|verworpen> <plan> [patroon]
verwacht() {
  local naam="$1" wil="$2" plan="$3" patroon="${4:-}"
  printf '%s' "$plan" > "$T/plan.md"
  local uit rc verdict
  uit="$(bash "$CRITIC" --plan-file "$T/plan.md" --root . 2>&1)"; rc=$?
  verdict="$(printf '%s\n' "$uit" | sed -n 's/^verdict=//p')"
  if [ "$verdict" = "$wil" ] && { [ -z "$patroon" ] || printf '%s' "$uit" | grep -q "$patroon"; }; then
    ok "$naam"
  else
    bad "$naam (verwacht $wil${patroon:+ met /$patroon/}, kreeg $verdict, exit $rc)"
    printf '%s\n' "$uit" | sed 's/^/      /'
  fi
}

GOED_PLAN='## Plan

1. Voeg een index toe op de datumkolom in `supabase/migrations/0100_index.sql`
2. Werk de spec bij in `docs/spec/voeding.md` zodat de index gedocumenteerd staat

## Verificatie
De pgTAP-test in `supabase/tests/voeding.sql` bewijst dat de query onder de drempel blijft.
Zie ook constitution.md voor de datagrenzen.'

echo "plan-critic · akkoord (mag NIET vals-positief afwijzen):"

verwacht "volledig plan met stappen en verificatie" akkoord "$GOED_PLAN"

verwacht "kort maar volledig plan" akkoord \
"- Pas de drempel aan in het script
- Werk de bijbehorende test bij zodat de nieuwe drempel gecontroleerd wordt"

verwacht "genummerde stappen tellen ook" akkoord \
"1. Eerste stap die iets concreets doet
2. Tweede stap
Verificatie: de bestaande suite dekt dit af."

echo "plan-critic · verworpen (harde, oordeelloze fouten):"

verwacht "geen stappen" verworpen \
"Ik ga dit gewoon even oplossen, komt goed. We testen het daarna." "Geen concreet stappenplan"

verwacht "één stap is te weinig" verworpen \
"- Alleen deze ene stap, verder niets. Test volgt." "minimaal 2"

verwacht "geen verificatie genoemd" verworpen \
"1. Wijzig het ene bestand
2. Wijzig het andere bestand
3. Klaar" "geen enkele verificatie"

echo "plan-critic · bevindingen (advies, GEEN afwijzing):"

verwacht "niet-bestaand pad => bevinding, geen afwijzing" akkoord \
"1. Maak een nieuw bestand \`scripts/nog-niet-bestaand.sh\` aan
2. Roep het aan vanuit de bestaande flow
Verificatie: nieuwe test in de suite." "bevinding=Genoemde paden bestaan"

verwacht "bestaand pad => geen bevinding erover" akkoord \
"1. Pas \`scripts/plan-critic.sh\` aan
2. Werk de bijbehorende tests bij
Verificatie: de testsuite. Zie AGENTS.md." "verdict=akkoord"

verwacht "geen bronverwijzing => bevinding" akkoord \
"- Eerste stap
- Tweede stap
Verificatie: handmatige check." "geen enkel bron-document"

if [ "$fail" = 0 ]; then
  echo "✅ alle plan-critic-tests groen"
else
  echo "❌ plan-critic-tests faalden"
fi
exit "$fail"
