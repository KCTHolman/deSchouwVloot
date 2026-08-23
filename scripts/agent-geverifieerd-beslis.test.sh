#!/usr/bin/env bash
# Tests voor scripts/agent-geverifieerd-beslis.sh (BiohackOS#2112).
#
# Drie harde nee's die nooit door provenance overruled mogen worden (breaking, gevoelig pad,
# pauze) plus de provenance-check zelf — dezelfde structuur als plan-goedgekeurd's herkomstcheck.
#
# Lokaal: bash scripts/agent-geverifieerd-beslis.test.sh

set -uo pipefail
cd "$(dirname "$0")/.."
BESLIS="$PWD/scripts/agent-geverifieerd-beslis.sh"

fail=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fail=1; }

# verwacht <naam> <verwacht> <args...>
verwacht() {
  local naam="$1" want="$2"; shift 2
  local got; got="$(bash "$BESLIS" "$@" 2>/dev/null)"
  [ "$got" = "$want" ] && ok "$naam" || bad "$naam (kreeg '$got', verwacht '$want')"
}

echo "agent-geverifieerd · het gewone geval (telt):"

verwacht "vertrouwde bot, niet-breaking, schoon => telt" telt \
  --labels "agent-geverifieerd" --labeler "claude[bot]" --owner "Koen" \
  --breaking false --sensitive false
verwacht "owner zelf als labeler => telt" telt \
  --labels "agent-geverifieerd" --labeler "Koen" --owner "Koen" \
  --breaking false --sensitive false
verwacht "andere trusted bot (defleet-machinerie[bot]) => telt" telt \
  --labels "epic-fase agent-geverifieerd" --labeler "defleet-machinerie[bot]" --owner "Koen" \
  --breaking false --sensitive false

echo "agent-geverifieerd · label ontbreekt:"

verwacht "geen label => telt-niet" telt-niet \
  --labels "plan-goedgekeurd" --labeler "claude[bot]" --owner "Koen" \
  --breaking false --sensitive false

echo "agent-geverifieerd · DE VLOER (poort 1 t/m 4, nooit door provenance te overrulen):"

verwacht "breaking change, vertrouwde bot => telt-niet" telt-niet \
  --labels "agent-geverifieerd" --labeler "claude[bot]" --owner "Koen" \
  --breaking true --sensitive false
verwacht "gevoelig pad, vertrouwde bot => telt-niet" telt-niet \
  --labels "agent-geverifieerd" --labeler "claude[bot]" --owner "Koen" \
  --breaking false --sensitive true
verwacht "breaking ÉN gevoelig, owner zelf als labeler => telt-niet" telt-niet \
  --labels "agent-geverifieerd" --labeler "Koen" --owner "Koen" \
  --breaking true --sensitive true

# --- De noodrem (toegevoegd 2026-08-23) -------------------------------------------------------
# Deze route las FLEET_HALT niet, terwijl autonomie-beslis.sh 'm wél leest én `elif $agent_ok` in
# auto-merge.yml vóór `elif $autonoom` staat. Met de rem om merget de PR dan alsnog — precies de
# knop die je omzet als je nog niet weet wát er mis is.
verwacht "noodrem om (--halt 1) => telt-niet" telt-niet \
  --labels "agent-geverifieerd" --labeler "claude[bot]" --owner "Koen" \
  --breaking false --sensitive false --halt 1
verwacht "noodrem om met willekeurige waarde => telt-niet" telt-niet \
  --labels "agent-geverifieerd" --labeler "claude[bot]" --owner "Koen" \
  --breaking false --sensitive false --halt misschien
verwacht "noodrem expliciet uit (false) => telt" telt \
  --labels "agent-geverifieerd" --labeler "claude[bot]" --owner "Koen" \
  --breaking false --sensitive false --halt false
verwacht "noodrem niet gezet (leeg) => telt" telt \
  --labels "agent-geverifieerd" --labeler "claude[bot]" --owner "Koen" \
  --breaking false --sensitive false --halt ""

# --- De stoplabels (toegevoegd 2026-08-23) ----------------------------------------------------
# `no-automerge` wordt in auto-merge.yml al vroeg afgevangen; `needs-human` niet. Juist die is de
# handgreep waarmee je een PR stopt die het label AL draagt.
verwacht "needs-human erop => telt-niet" telt-niet \
  --labels "needs-human agent-geverifieerd" --labeler "claude[bot]" --owner "Koen" \
  --breaking false --sensitive false
verwacht "no-automerge erop => telt-niet" telt-niet \
  --labels "agent-geverifieerd no-automerge" --labeler "claude[bot]" --owner "Koen" \
  --breaking false --sensitive false
verwacht "stoplabel wint ook van de owner als labeler" telt-niet \
  --labels "agent-geverifieerd needs-human" --labeler "Koen" --owner "Koen" \
  --breaking false --sensitive false

echo "agent-geverifieerd · circuit breaker (BiohackOS#2112 acceptatiecriterium 7):"

verwacht "pauze=true, verder alles schoon => telt-niet" telt-niet \
  --labels "agent-geverifieerd" --labeler "claude[bot]" --owner "Koen" \
  --breaking false --sensitive false --pauze true
verwacht "pauze=false (expliciet) => telt" telt \
  --labels "agent-geverifieerd" --labeler "claude[bot]" --owner "Koen" \
  --breaking false --sensitive false --pauze false

echo "agent-geverifieerd · provenance (zelfde grens als plan-goedgekeurd):"

verwacht "onvertrouwde actor zet het label zelf => telt-niet" telt-niet \
  --labels "agent-geverifieerd" --labeler "random-contributor" --owner "Koen" \
  --breaking false --sensitive false
verwacht "lege labeler (herkomst onbekend) => telt-niet (fail-closed)" telt-niet \
  --labels "agent-geverifieerd" --labeler "" --owner "Koen" \
  --breaking false --sensitive false
verwacht "--trusted override honoreert eigen lijst" telt \
  --labels "agent-geverifieerd" --labeler "eigen-bot[bot]" --owner "Koen" \
  --breaking false --sensitive false --trusted "eigen-bot[bot]"
verwacht "--trusted override negeert de default-trusted-bots" telt-niet \
  --labels "agent-geverifieerd" --labeler "claude[bot]" --owner "Koen" \
  --breaking false --sensitive false --trusted "eigen-bot[bot]"

echo "agent-geverifieerd · de reden staat altijd op stderr:"

uit="$(bash "$BESLIS" --labels "agent-geverifieerd" --labeler "claude[bot]" --owner "Koen" \
  --breaking false --sensitive false 2>&1 >/dev/null)"
printf '%s' "$uit" | grep -q '^reden: ' && ok "reden staat op stderr" || bad "geen reden op stderr (kreeg: $uit)"

# =============================================================================================
# DE KRUISCONTROLE — spreken de twee beslissers dezelfde vloer? (toegevoegd 2026-08-23)
#
# Dit is de test die het oorspronkelijke gat gevonden zou hebben. `agent-geverifieerd` is een EIGEN
# UITGANG naast de autonomiestand, en dat mag — maar "eigen uitgang" mag nooit "eigen vloer"
# betekenen. In auto-merge.yml staat `elif $agent_ok` vóór `elif $autonoom`, dus elke vloer-poort
# die deze route niet leest, is de facto uitgeschakeld voor élke repo.
#
# Getoetst worden de drie poorten die `autonomie-beslis.sh` beantwoordt ZONDER contract (gevoelig
# pad, noodrem, stoplabels). Poort 4 (breaking) blijft hier buiten beeld omdat die `allow_breaking`
# uit .fleet.yml nodig heeft; die staat hierboven al apart getest.
echo "agent-geverifieerd · kruiscontrole met autonomie-beslis.sh (dezelfde vloer):"

AUTONOMIE="$PWD/scripts/autonomie-beslis.sh"

# vloer_eens <naam> <args-voor-agent-geverifieerd...> -- <args-voor-autonomie-beslis...>
vloer_eens() {
  local naam="$1"; shift
  local -a agv=() aut=()
  local in_aut=0
  for a in "$@"; do
    if [ "$a" = "--" ]; then in_aut=1; continue; fi
    if [ "$in_aut" = 1 ]; then aut+=("$a"); else agv+=("$a"); fi
  done
  local got_agv got_aut
  got_agv="$(bash "$BESLIS" "${agv[@]}" 2>/dev/null)"
  got_aut="$(bash "$AUTONOMIE" --station merge "${aut[@]}" 2>/dev/null)"
  # De vloer sluit => beide moeten stoppen: 'telt-niet' hoort bij 'mens'.
  if [ "$got_agv" = "telt-niet" ] && [ "$got_aut" = "mens" ]; then
    ok "$naam (agent-geverifieerd=$got_agv · autonomie=$got_aut)"
  else
    bad "$naam — vloer divergeert: agent-geverifieerd=$got_agv, autonomie=$got_aut"
  fi
}

vloer_eens "gevoelig pad stopt beide" \
  --labels "agent-geverifieerd" --labeler "claude[bot]" --owner "Koen" --breaking false --sensitive true \
  -- --labels "agent-geverifieerd" --sensitive true
vloer_eens "noodrem stopt beide" \
  --labels "agent-geverifieerd" --labeler "claude[bot]" --owner "Koen" --breaking false --sensitive false --halt 1 \
  -- --labels "agent-geverifieerd" --halt 1
vloer_eens "needs-human stopt beide" \
  --labels "needs-human agent-geverifieerd" --labeler "claude[bot]" --owner "Koen" --breaking false --sensitive false \
  -- --labels "needs-human agent-geverifieerd"
vloer_eens "no-automerge stopt beide" \
  --labels "no-automerge agent-geverifieerd" --labeler "claude[bot]" --owner "Koen" --breaking false --sensitive false \
  -- --labels "no-automerge agent-geverifieerd"

echo "agent-geverifieerd · gebruiksfouten:"

bash "$BESLIS" --onzin x >/dev/null 2>&1
[ $? = 2 ] && ok "onbekend argument => exit 2" || bad "onbekend argument zou exit 2 moeten geven"

# Exit is ALTIJD 0 bij een geldige beslissing (ook telt-niet) — dit is een beslissing, geen
# oordeel, zelfde stijl als noodrem-beslis.sh.
bash "$BESLIS" --labels "" --labeler "" --owner "Koen" --breaking false --sensitive false >/dev/null 2>&1
[ $? = 0 ] && ok "telt-niet geeft toch exit 0" || bad "telt-niet zou exit 0 moeten geven (beslissing, geen oordeel)"

if [ "$fail" = 0 ]; then
  echo "✅ alle agent-geverifieerd-beslis-tests groen"
else
  echo "❌ agent-geverifieerd-beslis-tests faalden"
fi
exit "$fail"
