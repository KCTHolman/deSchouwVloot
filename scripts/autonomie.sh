#!/usr/bin/env bash
# autonomie.sh — de schakelaar zelf: laat zien in welke stand elke consument staat, en zet 'm om.
#
# WAAROM DIT EEN SCRIPT IS EN GEEN REGEL IN DE DOCUMENTATIE. Omzetten is technisch één commando
# (`gh variable set FLEET_AUTONOMY autonomous --repo …`). Het probleem is niet het zetten maar het
# WETEN: een repo-variabele is onzichtbaar tenzij je 'm opzoekt, en een stand die je niet kunt
# opzoeken is een stand waarvan je aanneemt dat 'ie klopt. Precies zo raakt een repo maandenlang
# in een modus die niemand koos.
#
# `status` is daarom de hoofdfunctie en `set` de bijzaak. Eén blik laat zien: welke repo staat op
# autonoom, welke staat aan de noodrem, en waar wijkt de variabele af van wat het contract zegt.
#
# Gebruik:
#   scripts/autonomie.sh status [repo...]          stand van alle consumenten (of van deze lijst)
#   scripts/autonomie.sh set <repo|alle> <stand>   stand = autonomous | supervised | contract
#   scripts/autonomie.sh halt <repo|alle>          noodrem om (terug naar mens-in-de-lus)
#   scripts/autonomie.sh vrij <repo|alle>          noodrem eraf
#
# `alle` staat er omdat de vraag zelden over één repo gaat. Je zet de vloot om omdat je een week
# weg bent, of je trekt aan de rem omdat er íets misgaat en je nog niet weet waar — in allebei de
# gevallen is "drie commando's, en hopen dat je er niet één vergeet" het verkeerde gereedschap.
# Precies die vergeten derde is hoe een repo in een stand blijft staan die niemand koos.
#
# `set … contract` VERWIJDERT de variabele, waarna `.fleet.yml` weer beslist. Dat is iets anders
# dan `set … supervised` (die zet de repo actief op begeleid, óók als het contract autonoom zegt) —
# en dat verschil is precies waarom "uitzetten" hier drie woorden kent in plaats van een vinkje.
#
# Vereist: `gh` met rechten op de repo's (variabelen zijn admin-scope — de GITHUB_TOKEN van een
# workflow kan ze niet zetten, en dat is maar goed ook: dan kon de machinerie zichzelf omzetten).
#
# Exit: 0 = gelukt · 1 = een repo faalde · 2 = gebruiksfout.

set -uo pipefail

CONSUMENTEN=(
  KCTHolman/fleet
  KCTHolman/BiohackOS
  KCTHolman/InvestingOS
)

die() { echo "✋ autonomie: $*" >&2; exit 2; }

command -v gh >/dev/null 2>&1 || die "gh ontbreekt — zonder GitHub-CLI is er niets te schakelen"

# lees_var <repo> <naam> → waarde of lege string
lees_var() {
  gh variable list --repo "$1" --json name,value \
    --jq ".[] | select(.name==\"$2\") | .value" 2>/dev/null || true
}

# lees_contract <repo> → "mode|allow_breaking" uit .fleet.yml op de default branch
lees_contract() {
  local ruw
  ruw="$(gh api "repos/$1/contents/.fleet.yml" --jq '.content' 2>/dev/null | tr -d '\n' | base64 -d 2>/dev/null || true)"
  [ -n "$ruw" ] || { echo "?|?"; return; }
  printf '%s' "$ruw" | python3 -c '
import sys, yaml
try:
    d = yaml.safe_load(sys.stdin.read()) or {}
except Exception:
    print("?|?"); raise SystemExit(0)
a = d.get("autonomy") or {}
if not isinstance(a, dict):
    print("?|?"); raise SystemExit(0)
mode = a.get("mode") or "-"
stations = a.get("stations") if isinstance(a.get("stations"), dict) else {}
if stations:
    mode += " (" + ", ".join(f"{k}:{v}" for k, v in sorted(stations.items())) + ")"
# Geen backslash-escape in de f-string-expressie: dat is pas geldig vanaf Python 3.12, en dit
# script draait ook op een werkstation met een oudere interpreter.
breaking = "ja" if a.get("allow_breaking") is True else "nee"
print(mode + "|" + breaking)
' 2>/dev/null || echo "?|?"
}

status() {
  local repos=("$@")
  [ "${#repos[@]}" -gt 0 ] || repos=("${CONSUMENTEN[@]}")

  printf '%-28s  %-12s  %-6s  %-34s  %s\n' REPO VARIABELE NOODREM "CONTRACT (.fleet.yml)" BREAKING
  printf '%-28s  %-12s  %-6s  %-34s  %s\n' "$(printf '%.0s─' {1..28})" "$(printf '%.0s─' {1..12})" \
    "$(printf '%.0s─' {1..6})" "$(printf '%.0s─' {1..34})" "────────"

  local repo var halt contract mode breaking
  for repo in "${repos[@]}"; do
    var="$(lees_var "$repo" FLEET_AUTONOMY)"
    halt="$(lees_var "$repo" FLEET_HALT)"
    contract="$(lees_contract "$repo")"
    mode="${contract%%|*}"; breaking="${contract##*|}"

    case "$(printf '%s' "$halt" | tr '[:upper:]' '[:lower:]')" in
      ''|0|false|no|nee|off|uit) halt="-" ;;
      *) halt="OM!" ;;
    esac

    printf '%-28s  %-12s  %-6s  %-34s  %s\n' \
      "$repo" "${var:--}" "$halt" "$mode" "$breaking"
  done

  echo
  echo "VARIABELE overschrijft CONTRACT · NOODREM overschrijft allebei."
  echo "Leeg (-) betekent: niet gezet, dus het contract beslist."
  echo
  echo "In élke stand blijven werken: label needs-human, label no-automerge,"
  echo "CHANGES_REQUESTED, en de gevoelige-paden-guard (secrets/migraties/pijplijn)."
}

zet() {
  local repo="$1" stand="$2"
  case "$stand" in
    autonomous|autonoom)
      gh variable set FLEET_AUTONOMY --repo "$repo" --body autonomous \
        && echo "✅ $repo → autonomous (de machine merget groene features zelf)" ;;
    supervised|mens|begeleid)
      gh variable set FLEET_AUTONOMY --repo "$repo" --body supervised \
        && echo "✅ $repo → supervised (features wachten op jou)" ;;
    contract)
      # `|| true`: een variabele die niet bestaat verwijderen is geen fout maar de gewenste
      # eindtoestand. Anders faalt precies het commando waarmee je iets wil OPRUIMEN.
      gh variable delete FLEET_AUTONOMY --repo "$repo" >/dev/null 2>&1 || true
      echo "✅ $repo → variabele weg; .fleet.yml beslist weer" ;;
    *) die "onbekende stand '$stand' — gebruik: autonomous | supervised | contract" ;;
  esac
}

# doelen <repo|alle> → schrijft de repo's naar stdout, één per regel
doelen() {
  if [ "$1" = alle ]; then printf '%s\n' "${CONSUMENTEN[@]}"; else printf '%s\n' "$1"; fi
}

rem_om()  { gh variable set FLEET_HALT --repo "$1" --body 1 \
              && echo "⛔ $1 → noodrem OM. Elke beslissing ligt weer bij jou, ongeacht de stand."; }
rem_af()  { gh variable delete FLEET_HALT --repo "$1" >/dev/null 2>&1 || true
            echo "✅ $1 → noodrem eraf; de stand uit variabele/contract geldt weer."; }

hoofd() {
  local cmd="${1:-status}"; shift || true
  local rc=0 r
  case "$cmd" in
    status) status "$@" ;;
    set)
      [ $# -ge 2 ] || die "gebruik: autonomie.sh set <repo|alle> <autonomous|supervised|contract>"
      # De stand VÓÓR de lus valideren, niet erin: anders zet 'ie de eerste twee repo's om en
      # struikelt dan over de typefout — een halve vloot in een andere stand is erger dan geen.
      case "$2" in
        autonomous|autonoom|supervised|mens|begeleid|contract) : ;;
        *) die "onbekende stand '$2' — gebruik: autonomous | supervised | contract" ;;
      esac
      while read -r r; do zet "$r" "$2" || rc=1; done < <(doelen "$1")
      return "$rc" ;;
    halt)
      [ $# -ge 1 ] || die "gebruik: autonomie.sh halt <repo|alle>"
      while read -r r; do rem_om "$r" || rc=1; done < <(doelen "$1")
      return "$rc" ;;
    vrij)
      [ $# -ge 1 ] || die "gebruik: autonomie.sh vrij <repo|alle>"
      while read -r r; do rem_af "$r" || rc=1; done < <(doelen "$1")
      return "$rc" ;;
    -h|--help|help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//' ;;
    *) die "onbekend commando '$cmd' — gebruik: status | set | halt | vrij" ;;
  esac
}

hoofd "$@"
