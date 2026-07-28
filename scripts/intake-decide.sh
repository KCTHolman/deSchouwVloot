#!/usr/bin/env bash
# intake-decide.sh — de beslislogica van de poort (docs/architectuur.md §3b).
#
# PURE FUNCTIE: leest een issue-titel + -body en de routeringstabel, en print één beslissing.
# Doet zelf GEEN GitHub-calls — daardoor is 'ie offline testbaar (intake-decide.test.sh) en kan de
# workflow eromheen dom blijven. Dit is bewust de enige plek waar de poort "nadenkt".
#
# Gebruik:
#   scripts/intake-decide.sh --title "..." --body-file body.md [--routing routing.yml]
#
# Uitvoer op stdout, machine-leesbaar (key=value per regel):
#   decision=detail|routing|transfer
#   target=<owner/repo>        (alleen bij decision=transfer)
#   reason=<één regel, mensleesbaar — wordt de comment in deFleet>
#
# DE DRIE UITKOMSTEN
#   detail    → te vaag om te routeren of te plannen. Stuitert met ÉÉN concrete wedervraag.
#               Goedkoopste moment om scherpte af te dwingen (gitflow §13.A).
#   routing   → doelproject niet eenduidig. Mens kiest. Nooit gokken: een verkeerd geplaatst
#               issue kost meer dan een seconde van de eigenaar.
#   transfer  → eenduidig. De workflow doet de native transfer (nooit kopiëren).
#
# Exit-code is altijd 0 bij een geldige beslissing; niet-0 alleen bij een gebruiksfout.

set -euo pipefail

title=""
body_file=""
routing="routing.yml"

die() { echo "✋ intake-decide: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --title)     shift; title="${1:-}" ;;
    --body-file) shift; body_file="${1:-}" ;;
    --routing)   shift; routing="${1:-}" ;;
    *) die "onbekend argument: $1" ;;
  esac
  shift
done

[ -n "$title" ]      || die "--title ontbreekt"
[ -n "$body_file" ]  || die "--body-file ontbreekt"
[ -f "$body_file" ]  || die "body-bestand bestaat niet: $body_file"
[ -f "$routing" ]    || die "routeringstabel bestaat niet: $routing"

body="$(cat "$body_file")"

emit() {
  printf 'decision=%s\n' "$1"
  [ -n "${2:-}" ] && printf 'target=%s\n' "$2"
  printf 'reason=%s\n' "$3"
  exit 0
}

# --- 1. Kwaliteitspoort ---------------------------------------------------------------------
# Structureel, niet semantisch: we toetsen of de indiener de sjabloonvelden invulde. Een model is
# hier niet nodig en zou alleen maar variabel zijn. De sjablonen (.github/ISSUE_TEMPLATE) leveren
# deze secties kant-en-klaar, dus een sjabloon-issue passeert per definitie; alleen vrij getypte
# losse flodders stuiteren — precies de bedoeling.

# Doel-sectie: minstens 20 tekens inhoud ná de kop.
doel_body="$(printf '%s' "$body" | awk '
  tolower($0) ~ /^#+[[:space:]]*doel/ { grab=1; next }
  /^#+[[:space:]]/ { grab=0 }
  grab { print }
')"
doel_len="$(printf '%s' "$doel_body" | tr -d '[:space:]' | wc -c | tr -d ' ')"

if [ "$doel_len" -lt 20 ]; then
  emit detail "" "Ik kan hier nog geen project of plan uit afleiden. Wat moet er ná deze wijziging anders zijn dan nu — in één of twee zinnen onder een kop \`## Doel\`?"
fi

# Acceptatiecriteria: minstens twee INGEVULDE checkbox-regels. Dit is het DoD-contract
# (gitflow §13.A) dat door de hele keten meereist: de plan-critic toetst erop, de review meet
# bewijs eraan af.
#
# LET OP de inhoudseis (≥10 tekens ná het vakje). De sjablonen leveren lege `- [ ]`-regels als
# steiger; zonder deze eis zou een indiener die de steiger laat staan de poort passeren met nul
# echte criteria — en dan is het DoD-contract een lege huls voor élk volgend station.
crit_count="$(printf '%s' "$body" | grep -cE '^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*[^[:space:]].{9,}' || true)"
if [ "$crit_count" -lt 2 ]; then
  emit detail "" "Er staan nog geen toetsbare acceptatiecriteria in (ik tel er $crit_count, minimaal 2 nodig). Waaraan zie je straks objectief dát dit af is? Zet ze als \`- [ ]\`-regels onder \`## Acceptatiecriteria\`."
fi

# --- 2. Routering ---------------------------------------------------------------------------
# Trefwoord-telling per consument uit routing.yml. Strikt hoogste score wint; gelijkspel of nul
# → `needs-routing`. Zie de kop van routing.yml voor waarom dit bewust dom is.

haystack="$(printf '%s\n%s' "$title" "$body" | tr '[:upper:]' '[:lower:]')"

# routing.yml → "repo<TAB>keyword"-paren. Kleine awk-parser i.p.v. yq: het bestand heeft een vaste,
# platte vorm en yq is geen garantie op een kale runner.
pairs="$(awk '
  /^[[:space:]]*-[[:space:]]*repo:[[:space:]]*/ {
    sub(/^[[:space:]]*-[[:space:]]*repo:[[:space:]]*/, ""); gsub(/[[:space:]]+$/, "");
    repo=$0; inkw=0; next
  }
  /^[[:space:]]*keywords:[[:space:]]*$/ { inkw=1; next }
  /^[[:space:]]*[a-z_]+:[[:space:]]*/ { if ($0 !~ /^[[:space:]]*-/) inkw=0 }
  inkw && /^[[:space:]]*-[[:space:]]*/ {
    sub(/^[[:space:]]*-[[:space:]]*/, "");
    # Inline commentaar eraf. YAML leest `- dashboard   # reden` als de waarde `dashboard`; deze
    # parser nam eerder de HELE staart mee, dus het trefwoord werd `dashboard   # reden` en matchte
    # daarna nooit meer als heel woord. Gevolg: wie netjes een reden bij z n trefwoord zette, kreeg
    # een STIL genegeerd trefwoord — geen fout, geen waarschuwing, gewoon geen effect.
    # Gevonden 2026-07-28 doordat een sabotage-demo van de golden-run niets deed: niet omdat de
    # golden-set te zwak was, maar omdat de sabotage zelf werd weggeparsed.
    # De whitespace-eis vóór # is bewust: zo blijft een `#` middenin een woord gewoon deel ervan.
    sub(/[[:space:]]+#.*$/, "");
    gsub(/[[:space:]]+$/, "");
    if (length($0) > 0 && repo != "") print repo "\t" $0
  }
' "$routing")"

[ -n "$pairs" ] || die "geen consument/trefwoord-paren gevonden in $routing"

repos="$(printf '%s\n' "$pairs" | cut -f1 | awk '!seen[$0]++')"

best_repo=""; best_score=0; runner_up=0
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  score=0
  while IFS= read -r kw; do
    [ -n "$kw" ] || continue
    if printf '%s' "$haystack" | grep -qwF -- "$kw"; then
      score=$((score + 1))
    fi
  done <<EOF
$(printf '%s\n' "$pairs" | awk -F'\t' -v r="$repo" '$1==r {print $2}')
EOF
  if [ "$score" -gt "$best_score" ]; then
    runner_up="$best_score"; best_score="$score"; best_repo="$repo"
  elif [ "$score" -gt "$runner_up" ]; then
    runner_up="$score"
  fi
done <<EOF
$repos
EOF

if [ "$best_score" -eq 0 ]; then
  emit routing "" "Geen enkel trefwoord uit \`routing.yml\` herkend, dus ik weet niet bij welk project dit hoort. Kies het doelproject (of vul \`routing.yml\` aan als dit een terugkerend onderwerp is)."
fi

if [ "$best_score" -eq "$runner_up" ]; then
  emit routing "" "Meerdere projecten passen even goed (score $best_score gelijk) — ik gok niet. Kies zelf het doelproject."
fi

emit transfer "$best_repo" "Eenduidig gerouteerd naar \`$best_repo\` (score $best_score tegen $runner_up)."
