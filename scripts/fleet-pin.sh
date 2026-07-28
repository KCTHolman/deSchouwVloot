#!/usr/bin/env bash
# fleet-pin.sh — leest en herschrijft de fleet-ref waarop een consument gepind staat (I24).
#
# WAAROM PINNEN. Volgt een consument `@main`, dan landt elke fleet-wijziging er ongetest. Pin je op
# een SHA, dan beweegt 'ie alleen wanneer iemand dat besluit — maar dan moet dat besluit wél
# geautomatiseerd zijn, anders verstart de boel en loopt de consument maanden achter.
#
# Vandaar het canary-model (gitflow §13.D): deFleet volgt zichzelf op `@main` en is daarmee de
# kanarie; consumenten staan op een SHA en krijgen een bump-PR zodra die kanarie groen is op een
# nieuwere commit. Zo is verse logica binnen een dag beschikbaar, maar nooit ongetest.
#
# Gebruik:
#   scripts/fleet-pin.sh current --root <consument>          # print de gepinde ref(s), één per regel
#   scripts/fleet-pin.sh rewrite --root <consument> --to <ref> [--keep <bestand>]
#
# `--keep` slaat een bestand over bij het herschrijven. Bedoeld voor de bump-workflow zelf: die
# moet `@main` blijven volgen, anders kan een kapotte pin z'n eigen reparatie blokkeren.
#
# Exit: 0 = klaar · 1 = niets gevonden om te doen · 2 = gebruiksfout.

set -uo pipefail

cmd="${1:-}"; shift || true
root="."
to=""
keep=""

die() { echo "✋ fleet-pin: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --root) shift; root="${1:-}" ;;
    --to)   shift; to="${1:-}" ;;
    --keep) shift; keep="${1:-}" ;;
    *) die "onbekend argument: $1" ;;
  esac
  shift
done

wf_dir="$root/.github/workflows"
[ -d "$wf_dir" ] || die "geen $wf_dir"

# Elke verwijzing naar een fleet-workflow, met z'n ref erachter.
PAT='KCTHolman/fleet/\.github/workflows/[A-Za-z0-9_.-]+\.yml@[A-Za-z0-9_.:/-]+'

case "$cmd" in
  current)
    refs="$(grep -rhoE "$PAT" "$wf_dir" 2>/dev/null | sed -E 's/.*@//' | sort -u)"
    [ -n "$refs" ] || { echo "geen fleet-verwijzingen gevonden" >&2; exit 1; }
    printf '%s\n' "$refs"
    ;;

  rewrite)
    [ -n "$to" ] || die "--to <ref> ontbreekt"
    n=0
    for f in "$wf_dir"/*.yml; do
      [ -f "$f" ] || continue
      base="$(basename "$f")"
      # De bump-workflow zelf blijft bewust op z'n eigen ref staan (zie kop).
      [ -n "$keep" ] && [ "$base" = "$keep" ] && continue
      grep -qE "$PAT" "$f" || continue
      # Alleen de ref ná de @ vervangen; het pad blijft ongemoeid.
      sed -i -E "s|(KCTHolman/fleet/\.github/workflows/[A-Za-z0-9_.-]+\.yml)@[A-Za-z0-9_.:/-]+|\1@${to}|g" "$f"
      n=$((n + 1))
      echo "  bijgewerkt: $base"
    done
    [ "$n" -gt 0 ] || { echo "niets te herschrijven" >&2; exit 1; }
    echo "$n bestand(en) op ref ${to}"
    ;;

  ""|-h|--help)
    grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
    [ -z "$cmd" ] && exit 2 || exit 0
    ;;

  *) die "onbekend subcommando '$cmd' (verwacht: current | rewrite)" ;;
esac
