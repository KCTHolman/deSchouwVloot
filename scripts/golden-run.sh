#!/usr/bin/env bash
# golden-run.sh — speelt de bevroren gevallen uit tests/golden/ af tegen de huidige
# beslislogica + routeringstabel (gitflow §13.C).
#
# WAAROM DIT NAAST DE UNIT-TESTS STAAT. `intake-decide.test.sh` toetst of de LOGICA klopt met
# verzonnen invoer. Deze run toetst of de CONFIGURATIE nog de bedoelde uitkomst geeft voor werk
# dat er in het echt doorheen komt — dat is een andere vraag. Voeg één te breed trefwoord toe aan
# `routing.yml` en de unit-tests blijven groen terwijl de helft van de issues opeens naar
# `needs-routing` stuitert.
#
# Zodra prompts en routeringsregels data worden, zijn wijzigingen eraan deploys. Deploys zonder
# tests zijn precies het probleem dat deze migratie moet oplossen.
#
# Draaien: bash scripts/golden-run.sh

set -uo pipefail
cd "$(dirname "$0")/.."

DECIDE="scripts/intake-decide.sh"
ROUTING="routing.yml"
GOLDEN="tests/golden"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fail=0; n=0
echo "── golden-run · bevroren gevallen tegen $ROUTING ──"

for case_file in "$GOLDEN"/*.case; do
  [ -f "$case_file" ] || continue
  n=$((n + 1))
  naam="$(basename "$case_file" .case)"

  titel="$(sed -n 's/^titel: //p' "$case_file" | head -1)"
  verwacht="$(sed -n 's/^verwacht: //p' "$case_file" | head -1)"
  # Alles ná de `---`-scheidingsregel is de body.
  sed -n '/^---$/,$p' "$case_file" | tail -n +2 > "$TMP/body.md"

  if [ -z "$titel" ] || [ -z "$verwacht" ]; then
    printf '  ❌ %s — mist `titel:` of `verwacht:`\n' "$naam"; fail=1; continue
  fi

  uit="$(bash "$DECIDE" --title "$titel" --body-file "$TMP/body.md" --routing "$ROUTING" 2>&1)" || {
    printf '  ❌ %s — beslisscript faalde\n' "$naam"; fail=1; continue
  }
  dec="$(printf '%s\n' "$uit" | sed -n 's/^decision=//p')"
  tgt="$(printf '%s\n' "$uit" | sed -n 's/^target=//p')"
  gekregen="$dec${tgt:+ $tgt}"

  if [ "$gekregen" = "$verwacht" ]; then
    printf '  ✅ %-24s %s\n' "$naam" "$gekregen"
  else
    printf '  ❌ %-24s verwacht: %s · kreeg: %s\n' "$naam" "$verwacht" "$gekregen"
    # De reden erbij: bij een routeringswijziging wil je meteen zien wáárom 'ie anders koos.
    printf '       reden: %s\n' "$(printf '%s\n' "$uit" | sed -n 's/^reason=//p')"
    fail=1
  fi
done

echo "──"
if [ "$n" -eq 0 ]; then
  echo "❌ geen gevallen gevonden in $GOLDEN — dat is zelf een fout"
  exit 1
fi
if [ "$fail" = 0 ]; then
  echo "✅ alle $n golden-gevallen geven nog de bedoelde uitkomst"
else
  echo "❌ golden-run: gedrag is veranderd."
  echo "   Is dat de BEDOELING van je wijziging? Werk dan het betreffende .case-bestand bij."
  echo "   Zo niet, dan heeft je wijziging aan routing.yml/intake-decide.sh een bijwerking."
fi
exit "$fail"
