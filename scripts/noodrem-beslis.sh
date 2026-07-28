#!/usr/bin/env bash
# noodrem-beslis.sh — beslist of een PR-review aan de noodrem trekt (I20, gitflow §3.2).
#
# HET ONTWERP IN ÉÉN ZIN: advies blijft advies, maar een bewijsbare blocker zet de PR op het
# mens-pad — en een STORING in de review trekt nooit aan de rem.
#
# Die laatste helft is waarom dit een script is en geen `if` in YAML. De twee foutrichtingen zijn
# namelijk niet gelijkwaardig:
#
#   • ten onrechte remmen  → een chore-PR wacht op een mens. Vervelend, verder onschadelijk.
#   • ten onrechte doorlaten → code met een aantoonbaar dataverlies-/security-pad merget vanzelf.
#
# Op INHOUD hoort de weegschaal dus naar remmen door te slaan. Maar op INFRASTRUCTUUR precies
# andersom: als de review-workflow zelf omvalt (timeout, geannuleerd, geen verdict, geen python),
# dan weet je niets — en "ik weet het niet" mag geen rem worden, want dan legt één flaky run de hele
# pijplijn stil. Dat staat expliciet in I20: *review-storing zet nooit een blocker*.
#
# Zo'n regel met twee tegengestelde biassen is precies wat je niet in een workflow-`if` wilt hebben:
# daar is 'ie onbewijsbaar, en de tak die je het hardst nodig hebt (er is écht iets mis) is de tak
# die je bij handmatig proberen nooit raakt. Vandaar hier, met tests.
#
# Gebruik:
#   scripts/noodrem-beslis.sh --verdict <bestand> [--review-status success|failure|...]
#
# Verdict-vorm (gestructureerde data, geen proza — gitflow §3.2):
#   {"advies": [ {...} ], "blockers": [ {"wat": "...", "faal_scenario": "..."} ]}
#
# Uitkomsten (altijd exit 0 — dit is een beslissing, geen oordeel):
#   blokkeer   label `review-blocker` zetten; de merge-machine behandelt de PR als feature
#   vrij       geen rem (ook: er was een storing en we weten dus niets)
#
# Op stderr komt altijd één regel met de REDEN, zodat de workflow 'm in de Step Summary kan zetten.
# Exit 2 = gebruiksfout.

set -uo pipefail

verdict=""
review_status="success"

die() { echo "✋ noodrem-beslis: $*" >&2; exit 2; }
reden() { echo "reden: $*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --verdict)       shift; verdict="${1:-}" ;;
    --review-status) shift; review_status="${1:-}" ;;
    -h|--help)       grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "onbekend argument: $1" ;;
  esac
  shift
done

# --- POORT 1: is de review überhaupt goed afgelopen? -------------------------------------------
# Alles wat geen `success` is, is een storing. Niet remmen — zie de kop.
if [ "$review_status" != "success" ]; then
  reden "review-status is '$review_status', geen 'success' — storing trekt nooit aan de rem (I20)"
  echo "vrij"; exit 0
fi

# --- POORT 2: is er een leesbaar verdict? ------------------------------------------------------
if [ -z "$verdict" ] || [ ! -s "$verdict" ]; then
  reden "geen of leeg verdict-bestand — de review leverde niets op, dus geen bewijsbare blocker"
  echo "vrij"; exit 0
fi

# python3 is stdlib-only (json), dus geen pip en geen PEP 668-probleem. Ontbreekt 'ie tóch, dan is
# dat óók een storing en geldt dezelfde regel: niet remmen.
if ! command -v python3 >/dev/null 2>&1; then
  reden "python3 niet beschikbaar om het verdict te lezen — storing, dus geen rem"
  echo "vrij"; exit 0
fi

uitslag="$(python3 - "$verdict" <<'PY' 2>/dev/null
import json, sys

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    print("onleesbaar|verdict is geen geldige JSON")
    raise SystemExit

if not isinstance(data, dict):
    print("onleesbaar|verdict is geen object")
    raise SystemExit

blockers = data.get("blockers", [])
if not isinstance(blockers, list):
    # Een blockers-veld dat geen lijst is, is een kapot verdict. Niet interpreteren: we kunnen
    # geen BEWIJSBARE blocker vaststellen, en de rem is per ontwerp alleen voor bewijsbare dingen.
    print("onleesbaar|blockers is geen lijst")
    raise SystemExit

if not blockers:
    print("vrij|geen blockers; advies blijft advies")
    raise SystemExit

# Er IS minstens één blocker. Vanaf hier remmen we — ook als de vorm rammelt. Een half ingevuld
# alarm negeren is de dure foutrichting; een mens laten kijken de goedkope.
zonder = [
    i for i, b in enumerate(blockers)
    if not (isinstance(b, dict) and str(b.get("faal_scenario", "")).strip())
]
if zonder:
    print(f"blokkeer|{len(blockers)} blocker(s), waarvan {len(zonder)} zonder faal_scenario "
          f"(onvolledig, maar een half alarm negeren is duurder dan een mens laten kijken)")
else:
    print(f"blokkeer|{len(blockers)} bewijsbare blocker(s) met faal_scenario")
PY
)"

# Lege uitslag = python viel om op iets onverwachts. Zelfde regel als elke andere storing.
if [ -z "$uitslag" ]; then
  reden "verdict kon niet gelezen worden (onverwachte fout) — storing, dus geen rem"
  echo "vrij"; exit 0
fi

besluit="${uitslag%%|*}"
toelichting="${uitslag#*|}"

case "$besluit" in
  blokkeer)
    reden "$toelichting"
    echo "blokkeer" ;;
  vrij)
    reden "$toelichting"
    echo "vrij" ;;
  onleesbaar)
    reden "$toelichting — storing, dus geen rem (I20)"
    echo "vrij" ;;
  *)
    reden "onverwachte uitslag '$besluit' — behandeld als storing, dus geen rem"
    echo "vrij" ;;
esac
