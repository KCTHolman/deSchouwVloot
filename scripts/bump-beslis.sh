#!/usr/bin/env bash
# bump-beslis.sh — beslist of de fleet-pin van een consument vooruit mag (I24, gitflow §13.D).
#
# WAAROM APART. Deze beslissing stond als losse shell in `bump-pin.yml` en was daarmee onbewijsbaar:
# je kunt 'm alleen uitproberen door een échte bump-run te laten draaien, en juist de tak die je wilt
# vertrouwen — "de canary is ROOD, dus schuif niets op" — is de tak die je nooit per ongeluk raakt.
# Een pin-bump die ten onrechte doorgaat, zet ongeteste logica bij een consument neer; dat is precies
# het risico waarvoor pinnen bestaat. Zulke logica hoort in een script met tests, niet in YAML.
#
# Zelfde patroon als intake-decide.sh en de liveness-beslisser: geen netwerk, geen klok, geen
# git-state. Alles komt als argument binnen, de uitkomst is één woord op stdout.
#
# Gebruik:
#   scripts/bump-beslis.sh --huidig <sha|""> --doel <sha> --canary <conclusion> [--tak-bestaat ja|nee]
#
# Uitkomsten (altijd exit 0 — dit is een beslissing, geen oordeel):
#   niet-gepind        de consument volgt een branch; er is geen pin om te bumpen
#   actueel            de pin staat al op het doel
#   canary-niet-groen  deFleet's eigen CI is niet `success` op de doel-commit → niets opschuiven
#   tak-bestaat        er staat al een bump-tak voor deze commit → geen dubbele PR
#   bump               alle poorten open: herschrijven en een chore-PR openen
#
# Exit 2 = gebruiksfout.

set -uo pipefail

huidig=""
doel=""
canary=""
tak_bestaat="nee"

die() { echo "✋ bump-beslis: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --huidig)      shift; huidig="${1:-}" ;;
    --doel)        shift; doel="${1:-}" ;;
    --canary)      shift; canary="${1:-}" ;;
    --tak-bestaat) shift; tak_bestaat="${1:-nee}" ;;
    -h|--help)     grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "onbekend argument: $1" ;;
  esac
  shift
done

[ -n "$doel" ] || die "--doel <sha> ontbreekt"

# VOLGORDE IS BETEKENISVOL. De goedkoopste en meest onomkeerbare uitsluitingen eerst, zodat een
# consument zonder pin of een al-actuele pin nooit onnodig de canary bevraagt.
if [ -z "$huidig" ]; then
  echo "niet-gepind"; exit 0
fi

if [ "$huidig" = "$doel" ]; then
  echo "actueel"; exit 0
fi

# DE CANARY-POORT. Alles behalve een letterlijke `success` houdt de pin tegen — ook `""`,
# `onbekend`, `null` of een nog lopende run. Fail-closed is hier het enige verdedigbare gedrag:
# "we konden het niet vaststellen" mag nooit hetzelfde uitpakken als "het was groen".
if [ "$canary" != "success" ]; then
  echo "canary-niet-groen"; exit 0
fi

if [ "$tak_bestaat" = "ja" ]; then
  echo "tak-bestaat"; exit 0
fi

echo "bump"
