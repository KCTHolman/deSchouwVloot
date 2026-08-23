#!/usr/bin/env bash
# agent-geverifieerd-beslis.sh — telt het label `agent-geverifieerd` mee als merge-voorwaarde?
#
# HERKOMST: BiohackOS#2112 ("agent-geverifieerd label — onafhankelijke zelfgoedkeuring in
# auto-merge.yml"). Naast de bestaande routes (Koens eigen approval, `plan-goedgekeurd`) mag een
# niet-breaking feature-/epic-fase-PR ook mergen op een `agent-geverifieerd`-label — gezet door een
# ONAFHANKELIJKE verificatie-run (agent-verify.yml), niet door de bouwer zelf.
#
# ONTWERP IN ÉÉN ZIN: net als `plan-goedgekeurd` telt dit label alleen als een VERTROUWDE actor 'm
# zette (provenance) — en NOOIT wanneer een van de vier vloer-poorten sluit, ongeacht wie het label
# zette.
#
# DE VLOER LIGT HIER ÓÓK (2026-08-23). Deze route is een EIGEN UITGANG naast de autonomiestand:
# `agent-geverifieerd` is bewijs over ÉÉN PR, `autonomy.mode` is staand beleid over de hele repo.
# Die twee horen niet op één hoop — een repo op `supervised` mag best profiteren van een
# onafhankelijke verificatie, want dat is precies hoe een agent vertrouwen verdient.
#
# Maar "eigen uitgang" mag nooit "eigen vloer" betekenen. Tot deze wijziging las deze route de
# noodrem en de stoplabels niet, terwijl `autonomie-beslis.sh` ze wél leest — en in auto-merge.yml
# staat `elif $agent_ok` vóór `elif $autonoom`. Gevolg, gemeten:
#
#     FLEET_HALT=1 + label agent-geverifieerd  →  autonomie-beslis: mens · deze route: telt
#     needs-human  + label agent-geverifieerd  →  autonomie-beslis: mens · deze route: telt
#
# Dat maakt twee beloftes onwaar die elders hard staan opgeschreven: `autonomie-beslis.sh` §POORT 3
# ("Ze moeten in élke stand werken, anders is 'ik kan overal ingrijpen' niet waar") en het
# consumentcontract van Portfolio ("`FLEET_HALT` is het commando waarmee je 'm stopt zonder eerst
# iets te hoeven begrijpen"). Het realistische scenario is niet exotisch: het label staat er al,
# jij plakt `needs-human` erop om de PR te stoppen, en de volgende run merget 'm alsnog.
#
# Vandaar de vorm hieronder: de vloer staat als één aaneengesloten blok in DEZELFDE VOLGORDE als
# poort 1 t/m 4 van `autonomie-beslis.sh`. Wie de twee scripts naast elkaar legt, ziet meteen of ze
# nog hetzelfde zeggen — divergentie is dan een leesbare diff en niet een stil gat.
#
# De PAUZE-knop blijft daarnaast bestaan (circuit breaker, BiohackOS#2112 acceptatiecriterium 7):
# die stopt alléén deze route, terwijl `FLEET_HALT` de hele repo stopt. Een teruggedraaide
# zelfgoedgekeurde merge is een signaal dat de route zelf niet te vertrouwen was op dat moment —
# dus stopt de HELE route tot Koen 'm expliciet weer aanzet. Dat is bewust géén automatisch
# herstel: de fout zat in het OORDEEL van de verificatie, en dat repareert zichzelf niet door nog
# een keer te oordelen.
#
# Gebruik:
#   scripts/agent-geverifieerd-beslis.sh --labels "<space-separated>" --labeler <login> \
#     --owner <owner-login> --breaking true|false --sensitive true|false \
#     [--halt <waarde>] [--pauze true|false] [--trusted "login1 login2 ..."]
#
# Uitvoer op stdout: telt | telt-niet
# Reden altijd op stderr (zodat de workflow 'm in de Step Summary kan zetten).
# Exit: altijd 0 — dit is een beslissing, geen oordeel (zelfde stijl als noodrem-beslis.sh).
#       2 = gebruiksfout.

set -uo pipefail

labels=""
labeler=""
owner=""
breaking="false"
sensitive="false"
halt=""
pauze="false"
trusted=""

die() { echo "✋ agent-geverifieerd-beslis: $*" >&2; exit 2; }
reden() { echo "reden: $*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --labels)    shift; labels="${1:-}" ;;
    --labeler)   shift; labeler="${1:-}" ;;
    --owner)     shift; owner="${1:-}" ;;
    --breaking)  shift; breaking="${1:-}" ;;
    --sensitive) shift; sensitive="${1:-}" ;;
    --halt)      shift; halt="${1:-}" ;;
    --pauze)     shift; pauze="${1:-}" ;;
    --trusted)   shift; trusted="${1:-}" ;;
    -h|--help)   grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "onbekend argument: $1" ;;
  esac
  shift
done

has_label() { printf ' %s ' "$labels" | grep -q " agent-geverifieerd "; }

# --- POORT 0: circuit breaker ---------------------------------------------------------------
# Vóór alles: staat de route gepauzeerd, dan is de rest van deze beslissing irrelevant. Dit is de
# ROUTE-EIGEN rem — hij stopt agent-geverifieerd en verder niets. De vloer hieronder stopt meer.
if [ "$pauze" = "true" ]; then
  reden "route gepauzeerd (circuit breaker) — Koen moet 'm expliciet weer aanzetten"
  echo "telt-niet"; exit 0
fi

if ! has_label; then
  reden "label agent-geverifieerd niet aanwezig"
  echo "telt-niet"; exit 0
fi

# =============================================================================================
# DE VLOER — poort 1 t/m 4, in dezelfde volgorde als scripts/autonomie-beslis.sh.
#
# Geen van deze vier is door provenance te overrulen, en geen van de vier kijkt naar wie of wat
# het label zette. Een gecompromitteerde of vergissende vertrouwde actor mag hier nooit langs.
# =============================================================================================

# --- POORT 1: nooit op een gevoelig pad -------------------------------------------------------
# De gevoelige-paden-guard wijst precies de klasse wijzigingen aan waarvan een fout niet stil terug
# te draaien is. Een route die daaroverheen kan, maakt de guard tot decoratie.
if [ "$sensitive" = "true" ]; then
  reden "gevoelig pad (sensitive-paths-guard) — alleen Koens eigen approval telt hier, net als bij plan-goedgekeurd/ai_approved"
  echo "telt-niet"; exit 0
fi

# --- POORT 2: de noodrem ----------------------------------------------------------------------
# FLEET_HALT zet een hele repo in één keer terug naar mens-in-de-lus, zonder PR en zonder dat je
# eerst hoeft te begrijpen wélk station waar staat. Een uitgang die daar niet naar luistert maakt
# die knop onbetrouwbaar op precies het moment dat je 'm nodig hebt.
#
# Let op de omgekeerde vraag, letterlijk overgenomen uit autonomie-beslis.sh: bij --halt is ELKE
# waarde de rem, behalve de expliciete "uit"-waarden. Bij een noodrem is de dure fout dat 'ie niet
# pakt, niet dat 'ie te vaak pakt.
case "$(printf '%s' "$halt" | tr '[:upper:]' '[:lower:]')" in
  ''|0|false|no|nee|off|uit) : ;;
  *)
    reden "noodrem staat om (FLEET_HALT='$halt') — de hele repo terug naar mens-in-de-lus"
    echo "telt-niet"; exit 0 ;;
esac

# --- POORT 3: de stoplabels -------------------------------------------------------------------
# `needs-human` en `no-automerge` zijn de handgrepen die de eigenaar op één PR legt. `no-automerge`
# wordt in auto-merge.yml al vroeg afgevangen, maar `needs-human` niet — en juist die is de knop
# waarmee je een PR stopt die al een `agent-geverifieerd`-label draagt.
for stop in needs-human no-automerge; do
  if printf ' %s ' "$labels" | grep -q " $stop "; then
    reden "label '$stop' staat erop — een mens heeft deze bewust stilgezet"
    echo "telt-niet"; exit 0
  fi
done

# --- POORT 4: nooit op een breaking change ----------------------------------------------------
if [ "$breaking" = "true" ]; then
  reden "breaking change — agent-geverifieerd telt hier nooit mee (acceptatiecriterium BiohackOS#2112)"
  echo "telt-niet"; exit 0
fi

# =============================================================================================
# ROUTE-EIGEN: provenance
# =============================================================================================

# --- POORT 5: alleen een vertrouwde actor mag het label laten TELLEN --------------------------
# Zelfde reden als bij plan-goedgekeurd: zonder deze check kan een willekeurige actor met
# label-rechten de merge-poort omzeilen door het label zelf te zetten i.p.v. de verificatie-run
# het te laten verdienen.
default_trusted="claude[bot] github-actions[bot] defleet-machinerie[bot]"
trusted_set="${trusted:-$default_trusted}"
[ -n "$owner" ] && trusted_set="$trusted_set $owner"

is_trusted=false
for actor in $trusted_set; do
  [ "$labeler" = "$actor" ] && is_trusted=true && break
done

if [ -z "$labeler" ]; then
  reden "kon herkomst van agent-geverifieerd niet bepalen — niet als geverifieerd behandeld (fail-closed, zelfde als plan-goedgekeurd)"
  echo "telt-niet"; exit 0
fi

if ! $is_trusted; then
  reden "label gezet door onvertrouwde actor '$labeler' — genegeerd"
  echo "telt-niet"; exit 0
fi

reden "agent-geverifieerd door vertrouwde actor '$labeler', niet-breaking, geen gevoelig pad, noodrem uit, geen stoplabel, route niet gepauzeerd"
echo "telt"
exit 0
