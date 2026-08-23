#!/usr/bin/env bash
# autonomie-beslis.sh — beslist of één station in één repo zelf door mag, of dat er een mens
# aan te pas hoort te komen.
#
# HET ONTWERP IN ÉÉN ZIN: de stand van de repo bepaalt de DEFAULT, nooit de VLOER.
#
# Waarom dat onderscheid het hele punt is. "Autonoom" is aantrekkelijk zolang je alleen aan de
# gelukkige gevallen denkt: een chore-PR die zichzelf merget, een epic-fase die doorloopt terwijl
# je slaapt. De vraag die een autonomieschakelaar echt moet beantwoorden is een andere — welke
# beslissingen mag hij NIET overnemen, ook niet als iemand de knop bewust omzet? Zonder antwoord
# daarop is "autonoom" een synoniem voor "alle remmen los", en dat is precies de stand waarin één
# verkeerde beslissing niet meer op te merken is.
#
# Vandaar de vorm hieronder: vier poorten die ALTIJD sluiten, en pas daarna de schakelaar.
#
#   1. de gevoelige-paden-guard sloeg aan   → mens (de guard wint van elke stand)
#   2. de noodrem staat om                  → mens (FLEET_HALT, één variabele legt alles plat)
#   3. er staat een stoplabel op            → mens (needs-human / no-automerge)
#   4. het is een breaking change           → mens, tenzij het contract dat expliciet toestaat
#   ── pas hier begint de schakelaar ──
#   5. de repo-variabele FLEET_AUTONOMY     (omzetten zonder PR — een schakelaar die een merge
#                                            nodig heeft, is geen schakelaar)
#   6. autonomy.stations.<station>          (per station, in het contract)
#   7. autonomy.mode                        (de repo-default, in het contract)
#   8. niets van dat alles                  → mens (fail-closed: geen contract, geen autonomie)
#
# Poort 1 t/m 4 zijn de reden dat dit een script is en geen `if` in YAML. In YAML zijn ze
# onbewijsbaar, en de tak die je het hardst nodig hebt (iemand zette de repo op autonoom én de PR
# raakt supabase/migrations/**) is de tak die je bij handmatig proberen nooit raakt. Hier liggen ze
# vast in autonomie-beslis.test.sh.
#
# WAAROM "MENS" GEEN "NEE" IS. De uitkomst `mens` betekent niet dat het werk stopt — het betekent
# dat de beslissing bij de eigenaar ligt in plaats van bij de machine. In beide standen kan een
# mens overal ingrijpen; het verschil is of hij dat MOET om iets te laten gebeuren (mens) of om
# iets te VOORKOMEN (autonoom). De vloer hierboven zorgt dat die tweede stand nooit betekent dat
# ingrijpen onmogelijk is geworden.
#
# Gebruik:
#   scripts/autonomie-beslis.sh --station <naam> [opties]
#
#   --station <naam>     verplicht. Vandaag alleen `merge` — zie STATIONS hieronder.
#   --contract <pad>     pad naar .fleet.yml (default: .fleet.yml in de werkmap).
#   --override <waarde>  de repo-variabele FLEET_AUTONOMY (leeg = niet gezet).
#   --halt <waarde>      de repo-variabele FLEET_HALT (niet-leeg en niet '0'/'false' = noodrem om).
#   --labels "<a b c>"   labels op de PR/het issue, spatiegescheiden.
#   --breaking <bool>    is dit een breaking change? (default false)
#   --sensitive <bool>   sloeg de gevoelige-paden-guard aan? (default false)
#
# Uitkomsten (stdout, precies één woord — altijd exit 0, dit is een beslissing en geen oordeel):
#   autonoom   de machine mag zelf door
#   mens       de eigenaar beslist
#
# Op stderr komt altijd één regel `reden: …`, zodat de aanroepende workflow 'm in de Step Summary
# kan zetten. Een beslissing zonder zichtbare reden is een black box, en een black box wordt
# genegeerd of uitgezet — allebei erger dan de beslissing zelf.
#
# Exit 2 = gebruiksfout (onbekend station, onbekend argument).

set -uo pipefail

# ALLEEN BESLISPUNTEN DIE DE RESOLVER ECHT AANROEPEN. Vandaag is dat er één: `auto-merge.yml`.
#
# De verleiding is om hier vast `triage plan release` bij te zetten "voor straks". Precies dat is
# hoe `gates.feature_approval` ontstond: een sleutel die je invult, die niets doet, en waar niets
# rood van wordt. Deze lijst groeit per gewired station, in dezelfde PR die 'm wiret — samen met
# AUTONOMIE_STATIONS in check-fleet-yml.py, zodat contract en resolver nooit uit elkaar lopen.
STATIONS="merge"

station=""
contract=".fleet.yml"
override=""
halt=""
labels=""
breaking="false"
sensitive="false"

die()   { echo "✋ autonomie-beslis: $*" >&2; exit 2; }
reden() { echo "reden: $*" >&2; }

# Eén plek voor "is dit waar?", zodat `true`/`1`/`ja` overal hetzelfde betekenen. Alles wat niet
# aantoonbaar waar is, is onwaar — behalve bij --halt, waar de vraag omgekeerd staat (zie daar).
waar() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|ja|on|aan) return 0 ;;
    *) return 1 ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --station)   shift; station="${1:-}" ;;
    --contract)  shift; contract="${1:-}" ;;
    --override)  shift; override="${1:-}" ;;
    --halt)      shift; halt="${1:-}" ;;
    --labels)    shift; labels="${1:-}" ;;
    --breaking)  shift; breaking="${1:-}" ;;
    --sensitive) shift; sensitive="${1:-}" ;;
    -h|--help)   grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "onbekend argument: $1" ;;
  esac
  shift
done

[ -n "$station" ] || die "--station ontbreekt (een van: $STATIONS)"
printf ' %s ' "$STATIONS" | grep -q " $station " \
  || die "onbekend station '$station' — bekend: $STATIONS"

# --- POORT 1: de gevoelige-paden-guard ---------------------------------------------------------
# De guard staat bóven de schakelaar, niet ernaast. Wat hij aanwijst (secrets, migraties, de
# pijplijn zelf, een nieuwe externe bestemming) is precies de klasse wijzigingen waarvan een fout
# niet stil terug te draaien is — en dat is de definitie van "beheerst" in het contract. Een
# autonomiestand die dáár overheen kan, maakt de guard tot decoratie.
if waar "$sensitive"; then
  reden "de gevoelige-paden-guard sloeg aan — die wint van elke autonomiestand"
  echo "mens"; exit 0
fi

# --- POORT 2: de noodrem -----------------------------------------------------------------------
# FLEET_HALT is de enkele variabele die een hele repo terugzet naar mens-in-de-lus, zonder PR,
# zonder deploy, zonder iets te hoeven begrijpen van welk station waar staat. Dat is de knop die
# je om wil kunnen zetten op het moment dat je nog niet weet wát er mis is.
#
# Let op de omgekeerde vraag: bij --halt is ELKE waarde de rem, behalve de expliciete
# "uit"-waarden. Zet iemand `FLEET_HALT=misschien`, dan staat de rem om. Dat is met opzet — bij een
# noodrem is de dure fout dat 'ie niet pakt, niet dat 'ie te vaak pakt.
case "$(printf '%s' "$halt" | tr '[:upper:]' '[:lower:]')" in
  ''|0|false|no|nee|off|uit) : ;;
  *)
    reden "noodrem staat om (FLEET_HALT='$halt') — de hele repo terug naar mens-in-de-lus"
    echo "mens"; exit 0 ;;
esac

# --- POORT 3: de stoplabels --------------------------------------------------------------------
# `needs-human` en `no-automerge` zijn de handgrepen die de eigenaar op één issue of één PR legt.
# Ze moeten in élke stand werken, anders is "ik kan overal ingrijpen" niet waar en wordt de
# autonome stand iets dat je alleen nog per ongeluk uitzet.
for stop in needs-human no-automerge; do
  if printf ' %s ' "$labels" | grep -q " $stop "; then
    reden "label '$stop' staat erop — een mens heeft deze bewust stilgezet"
    echo "mens"; exit 0
  fi
done

# --- Contract lezen ----------------------------------------------------------------------------
# Alles hieronder heeft het contract nodig. Kunnen we het niet lezen, dan weten we niets — en
# "ik weet het niet" is hier `mens`, niet `autonoom`. Dezelfde fail-closed-keuze als bij de guard,
# en om dezelfde reden: de dure fout is doorlaten, niet wachten.
#
# WAAROM DIT NIET DE NOODREM-LOGICA VAN noodrem-beslis.sh VOLGT. Daar is een storing juist géén
# rem ("een flaky review mag de pijplijn niet stilleggen"). Het verschil is wat er gebeurt bij
# twijfel: daar leidt remmen tot een PR die op een mens wacht terwijl er niets aan de hand is;
# hier leidt doorlaten tot een merge die niemand heeft gezien. Ongelijke fouten, ongelijke bias.
mode_uit_contract=""
station_uit_contract=""
allow_breaking="false"
contract_fout=""

if [ ! -r "$contract" ]; then
  contract_fout="contract '$contract' niet leesbaar"
elif ! command -v python3 >/dev/null 2>&1; then
  contract_fout="python3 ontbreekt om het contract te lezen"
else
  gelezen="$(python3 - "$contract" "$station" <<'PY' 2>/dev/null
import sys

try:
    import yaml
except ImportError:
    print("FOUT|PyYAML ontbreekt om het contract te lezen")
    raise SystemExit(0)

pad, station = sys.argv[1], sys.argv[2]

try:
    with open(pad, encoding="utf-8") as fh:
        data = yaml.safe_load(fh)
except Exception as exc:  # onleesbaar/ongeldig = niets weten
    print(f"FOUT|{pad} is geen geldige YAML ({exc.__class__.__name__})")
    raise SystemExit(0)

if not isinstance(data, dict):
    print(f"FOUT|{pad} levert geen mapping op")
    raise SystemExit(0)

aut = data.get("autonomy")
if aut is None:
    # Geen sectie = de consument heeft de keuze nooit gemaakt. Dat is geen impliciete "ja".
    print("OK||")
    raise SystemExit(0)
if not isinstance(aut, dict):
    print("FOUT|`autonomy` is geen mapping")
    raise SystemExit(0)

mode = aut.get("mode") or ""
stations = aut.get("stations") if isinstance(aut.get("stations"), dict) else {}
per_station = stations.get(station) or ""
breaking_ok = "true" if aut.get("allow_breaking") is True else "false"

print(f"OK|{mode}|{per_station}|{breaking_ok}")
PY
)"

  case "$gelezen" in
    OK*)
      IFS='|' read -r _ mode_uit_contract station_uit_contract allow_breaking <<EOF
$gelezen
EOF
      allow_breaking="${allow_breaking:-false}"
      ;;
    FOUT*) contract_fout="${gelezen#FOUT|}" ;;
    *)     contract_fout="het contract leverde geen bruikbaar antwoord op" ;;
  esac
fi

if [ -n "$contract_fout" ]; then
  reden "$contract_fout — bij twijfel beslist een mens (fail-closed)"
  echo "mens"; exit 0
fi

# --- POORT 4: breaking changes -----------------------------------------------------------------
# Bewust NIET met de repo-variabele mee te schakelen. `allow_breaking` staat alleen in het
# contract, en dat wijzig je met een PR — precies de mate van wrijving die past bij "dit mag
# zonder mens doorbreken wat er is". De schakelaar verandert de dagelijkse stand; deze sleutel
# verandert het plafond.
if waar "$breaking" && ! waar "$allow_breaking"; then
  reden "breaking change en autonomy.allow_breaking staat niet aan — die grens ligt in het contract, niet in de schakelaar"
  echo "mens"; exit 0
fi

# --- POORT 5: de repo-variabele ----------------------------------------------------------------
# Hoogste stem ONDER de vloer. Hiermee zet je een repo om zonder iets te committen: één
# `gh variable set FLEET_AUTONOMY` en de volgende run draait in de nieuwe stand.
#
# Een onbekende waarde is nadrukkelijk GEEN "dan maar het contract". Iemand die `FLEET_AUTONOMY`
# op `autonoom!` of `yes` zet, bedoelde iets — en het stilzwijgend terugvallen op de bestandsstand
# is precies de faalvorm waar de contract-validator ook voor bestaat: een typefout die niets doet.
# Fail-closed én zichtbaar.
if [ -n "$override" ]; then
  case "$(printf '%s' "$override" | tr '[:upper:]' '[:lower:]')" in
    autonomous|autonoom)
      reden "repo-variabele FLEET_AUTONOMY='$override' — schakelaar staat op autonoom"
      echo "autonoom"; exit 0 ;;
    supervised|mens|begeleid)
      reden "repo-variabele FLEET_AUTONOMY='$override' — schakelaar staat op mens-in-de-lus"
      echo "mens"; exit 0 ;;
    *)
      echo "::warning::FLEET_AUTONOMY='$override' is geen geldige waarde (autonomous|supervised) — teruggevallen op mens." >&2
      reden "FLEET_AUTONOMY='$override' is onbekend — een onbegrepen schakelaarstand is nooit autonoom"
      echo "mens"; exit 0 ;;
  esac
fi

# --- POORT 6 & 7: het contract -----------------------------------------------------------------
# Eerst het station, dan de repo-default. Zo kan een consument zeggen: "triëren doet de machine,
# mergen doe ik" — zonder twee schakelaars te hoeven onthouden.
for kandidaat in "$station_uit_contract:station" "$mode_uit_contract:mode"; do
  waarde="${kandidaat%:*}"; bron="${kandidaat##*:}"
  [ -n "$waarde" ] || continue
  case "$(printf '%s' "$waarde" | tr '[:upper:]' '[:lower:]')" in
    autonomous|autonoom)
      if [ "$bron" = station ]; then
        reden "contract: autonomy.stations.$station=$waarde"
      else
        reden "contract: autonomy.mode=$waarde"
      fi
      echo "autonoom"; exit 0 ;;
    supervised|mens|begeleid)
      if [ "$bron" = station ]; then
        reden "contract: autonomy.stations.$station=$waarde"
      else
        reden "contract: autonomy.mode=$waarde"
      fi
      echo "mens"; exit 0 ;;
    *)
      echo "::warning::autonomy.$bron='$waarde' is geen geldige waarde — teruggevallen op mens." >&2
      reden "autonomy.$bron='$waarde' is onbekend — een onbegrepen stand is nooit autonoom"
      echo "mens"; exit 0 ;;
  esac
done

# --- POORT 8: niets gezegd ---------------------------------------------------------------------
# Een consument zonder `autonomy`-sectie draait zoals hij vóór deze schakelaar draaide. Dat is de
# hele migratiestrategie: de sectie toevoegen is de bewuste keuze, niet het weglaten ervan.
reden "geen autonomy-sectie in $contract — de stand is nooit gekozen, dus mens-in-de-lus"
echo "mens"
