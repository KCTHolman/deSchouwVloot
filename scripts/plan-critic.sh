#!/usr/bin/env bash
# plan-critic.sh — de mechanische helft van de plan-poort (gitflow §3.1, invariant I19).
#
# WAAROM DEZE POORT BESTAAT. Sinds de auto-ontsteking verschoof de mens-poort van het plan naar de
# PR. Daarmee werd trap 2 het ENIGE station zonder enige toets — terwijl een fout plan het duurste
# faalpad is: je betaalt een volledige build, review en herstelronde op het verkeerde fundament.
#
# WAT DIT SCRIPT WEL EN NIET DOET. Het toetst alleen wat MECHANISCH vast te stellen is, en wijst
# alleen af op dingen die zonder oordeel fout zijn. De inhoudelijke vraag ("klopt dit plan?") is
# een tweede, adversariële agent-pass; die krijgt de bevindingen hieronder als startpunt.
#
# Die scheiding is bewust: een criticus die vals-positief afwijst, leert mensen de uitkomst te
# negeren — en dan is de poort erger dan geen poort. Alles waarbij twijfel mogelijk is (bestaat dit
# pad al, of maakt het plan het?) komt er daarom als BEVINDING uit, niet als afwijzing.
#
# Gebruik:
#   scripts/plan-critic.sh --plan-file plan.md [--root .]
#
# Uitvoer op stdout (machine-leesbaar):
#   verdict=akkoord|verworpen
#   reden=<één regel per harde afwijzing>
#   bevinding=<één regel per aandachtspunt voor de agent-pass>
#
# Exit: 0 = akkoord · 1 = verworpen · 2 = gebruiksfout.

set -uo pipefail

plan_file=""
root="."

die() { echo "✋ plan-critic: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --plan-file) shift; plan_file="${1:-}" ;;
    --root)      shift; root="${1:-}" ;;
    *) die "onbekend argument: $1" ;;
  esac
  shift
done

[ -n "$plan_file" ] || die "--plan-file ontbreekt"
[ -f "$plan_file" ] || die "planbestand bestaat niet: $plan_file"

plan="$(cat "$plan_file")"
redenen=()
bevindingen=()

# --- HARDE TOETS 1: heeft het plan concrete stappen? -----------------------------------------
# Een plan zonder stappen is een intentie. De bouwer heeft er niets aan en de review kan er niets
# aan afmeten.
stappen="$(printf '%s\n' "$plan" | grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\S' || true)"
if [ "$stappen" -lt 2 ]; then
  redenen+=("Geen concreet stappenplan: ik tel $stappen stap(pen), minimaal 2 nodig. Zet ze als lijst.")
fi

# --- HARDE TOETS 2: noemt het plan z'n eigen verificatie? ------------------------------------
# Dit is het DoD-contract (gitflow §13.A) op planniveau: wie niet zegt hoe 'ie het gaat bewijzen,
# levert straks een PR waarvan niemand kan vaststellen dat 'ie af is.
if ! printf '%s\n' "$plan" | grep -qiE 'test|verifi|bewij|aantoon|controle|check|assert'; then
  redenen+=("Het plan noemt geen enkele verificatie. Waarmee bewijs je straks dát dit werkt — welke test, welke check?")
fi

# --- BEVINDING: genoemde paden die (nog) niet bestaan ----------------------------------------
# BEWUST GEEN AFWIJZING. Een plan mag bestanden noemen die het zelf gaat maken; mechanisch is het
# verschil tussen "gehallucineerd pad" en "nieuw bestand" niet vast te stellen. De agent-pass kan
# dat wél, en krijgt hier de lijst.
paden="$(printf '%s\n' "$plan" \
  | grep -oE '`[A-Za-z0-9_./-]+\.[A-Za-z0-9]+`' \
  | tr -d '`' | grep '/' | sort -u || true)"
if [ -n "$paden" ]; then
  ontbrekend=()
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -e "$root/$p" ] || ontbrekend+=("$p")
  done <<< "$paden"
  if [ "${#ontbrekend[@]}" -gt 0 ]; then
    bevindingen+=("Genoemde paden bestaan (nog) niet: ${ontbrekend[*]}. Maakt het plan ze aan, of is dit een vergissing?")
  fi
fi

# --- BEVINDING: verwijst het plan naar de bronhiërarchie? ------------------------------------
if ! printf '%s\n' "$plan" | grep -qiE 'constitution|spec|governance|AGENTS'; then
  bevindingen+=("Het plan verwijst naar geen enkel bron-document. Bij een wijziging die architectuur raakt hoort dat wél.")
fi

# --- uitvoer ---------------------------------------------------------------------------------
for b in "${bevindingen[@]:-}"; do [ -n "$b" ] && printf 'bevinding=%s\n' "$b"; done

if [ "${#redenen[@]}" -gt 0 ]; then
  printf 'verdict=verworpen\n'
  for r in "${redenen[@]}"; do printf 'reden=%s\n' "$r"; done
  exit 1
fi

printf 'verdict=akkoord\n'
exit 0
