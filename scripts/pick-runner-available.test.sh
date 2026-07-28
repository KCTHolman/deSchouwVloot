#!/usr/bin/env bash
# Zelf-test voor de "beschikbare self-hosted runner"-jq-filter uit
# .github/workflows/pick-runner.yml (stap "Beschikbaarheid self-hosted runner opvragen").
#
# Waarom hier en niet als workflow-selftest: pick-runner.yml zit onder .github/workflows/** en kan
# door de Claude-Action-token (mist `workflows`-scope) niet gepusht worden — de workflow-wijziging
# zelf loopt via het interne draaiboek (epic #985 fase 3). Deze test staat onder
# scripts/ (wél pushbaar) en bewaakt de kern van de busy-fix: een BUSY self-hosted runner telt NIET
# meer als beschikbaar, zodat pick-runner terugvalt op ubuntu-latest i.p.v. de job op de bezette,
# gedeelde OAuth-sessie te laten stapelen (#776/#778-collision).
#
# Draai lokaal: `bash scripts/pick-runner-available.test.sh` (alleen jq nodig, geen netwerk/gh).
#
# SYNC-VERPLICHTING: FILTER hieronder is een 1-op-1 SPIEGEL van de jq-expressie in
# pick-runner.yml. Wijzig je die filter daar, pas 'm hier mee aan (en omgekeerd).

set -u

# JQ-VOORWAARDE, EXPLICIET AFGEHANDELD. Zonder deze guard faalt elke assertie los met
# "jq: command not found" — zeven rode regels die eruitzien als zeven kapotte gevallen terwijl er
# alleen gereedschap ontbreekt. Dat is net zo misleidend als een vals groen vinkje, en op een
# Windows-werkstation is het de normale toestand.
#
# In CI ligt het andersom: daar MOET jq er zijn, en stilletjes overslaan zou dekking laten
# verdampen zonder dat iemand het merkt. Vandaar: lokaal luid overslaan, in CI hard falen.
if ! command -v jq >/dev/null 2>&1; then
  if [ "${CI:-}" = "true" ]; then
    printf '  \xe2\x9d\x8c jq ontbreekt op deze runner — deze suite kan niet draaien en wordt NIET overgeslagen in CI\n'
    exit 1
  fi
  printf '  \xe2\x9a\xa0\xef\xb8\x8f  jq niet gevonden — suite overgeslagen (geen bevinding, alleen ontbrekend gereedschap).\n'
  printf '     Installeer jq om deze suite lokaal te draaien; in CI is jq aanwezig en draait ze sowieso.\n'
  exit 0
fi

# --- De gespiegelde filter (moet byte-identiek zijn aan pick-runner.yml) ---
FILTER='[.runners[]? | select(.status == "online") | select(.busy == false) | select([.labels[]?.name] | index($label) != null)] | length'

LABEL="biohack-local"
fail=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fail=1; }

# count <json> -> aantal beschikbare runners volgens FILTER
count() { printf '%s' "$1" | jq -r --arg label "$LABEL" "$FILTER"; }

# expect <desc> <verwacht> <json>
expect() {
  local desc="$1" want="$2" json="$3"
  local got; got="$(count "$json")"
  if [ "$got" = "$want" ]; then ok "$desc (=$got)"; else bad "$desc (verwacht $want, kreeg $got)"; fi
}

echo "pick-runner beschikbaarheids-filter (busy-fix, epic #985 fase 3):"

# 1. online + idle + juist label -> beschikbaar (1)
expect "online + idle + label => beschikbaar" 1 \
  '{"runners":[{"status":"online","busy":false,"labels":[{"name":"self-hosted"},{"name":"biohack-local"}]}]}'

# 2. online + BUSY + juist label -> NIET beschikbaar (0)  <-- de kern van de busy-fix
expect "online + BUSY + label => NIET beschikbaar" 0 \
  '{"runners":[{"status":"online","busy":true,"labels":[{"name":"self-hosted"},{"name":"biohack-local"}]}]}'

# 3. offline + juist label -> NIET beschikbaar (0)
expect "offline + label => NIET beschikbaar" 0 \
  '{"runners":[{"status":"offline","busy":false,"labels":[{"name":"biohack-local"}]}]}'

# 4. online + idle maar ander label -> NIET beschikbaar (0)
expect "online + idle + ander label => NIET beschikbaar" 0 \
  '{"runners":[{"status":"online","busy":false,"labels":[{"name":"biohack-fast"}]}]}'

# 5. drie registraties, allemaal busy -> NIET beschikbaar (0) => fallback ubuntu-latest
expect "3x online+busy => NIET beschikbaar (fallback)" 0 \
  '{"runners":[
     {"status":"online","busy":true,"labels":[{"name":"biohack-local"}]},
     {"status":"online","busy":true,"labels":[{"name":"biohack-local"}]},
     {"status":"online","busy":true,"labels":[{"name":"biohack-local"}]}]}'

# 6. drie registraties, twee busy + één idle -> beschikbaar (1)
expect "2x busy + 1x idle => beschikbaar" 1 \
  '{"runners":[
     {"status":"online","busy":true,"labels":[{"name":"biohack-local"}]},
     {"status":"online","busy":true,"labels":[{"name":"biohack-local"}]},
     {"status":"online","busy":false,"labels":[{"name":"biohack-local"}]}]}'

# 7. lege runners-lijst -> NIET beschikbaar (0)
expect "geen runners => NIET beschikbaar" 0 '{"runners":[]}'

# --- Guard: de filter MOET byte-identiek zijn aan pick-runner.yml -----------------------------
# Deze test verhuisde mee met pick-runner naar de fleet (2026-07-28). In BiohackOS was de guard
# hol geworden: daar bestaat pick-runner.yml sinds #1712 niet meer, dus de check meldde alleen nog
# "overgeslagen" en de gespiegelde filter kon ongemerkt uit sync lopen. Hier staat de workflow
# ernaast, dus de guard doet weer wat 'ie hoort te doen — en dat is precies waarom een test bij
# z'n onderwerp hoort te wonen.
WF=".github/workflows/pick-runner.yml"
if [ ! -f "$WF" ]; then
  bad "pick-runner.yml ontbreekt in deze repo — deze test hoort naast de workflow te staan"
elif grep -qF "$FILTER" "$WF"; then
  ok "filter byte-identiek aan pick-runner.yml"
else
  bad "filter WIJKT AF van pick-runner.yml — pas beide aan of geen van beide"
fi

if [ "$fail" = 0 ]; then echo "✅ alle pick-runner-available-tests groen"; else echo "❌ pick-runner-available-tests faalden"; fi
exit "$fail"
