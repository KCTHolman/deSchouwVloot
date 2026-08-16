#!/usr/bin/env bash
# intake-decide.sh — de beslislogica van de poort (docs/architectuur.md §3b).
#
# PURE FUNCTIE: leest een issue-titel + -body en de routeringstabel, en print één beslissing.
# Doet zelf GEEN GitHub-calls — daardoor is 'ie offline testbaar (intake-decide.test.sh) en kan de
# workflow eromheen dom blijven. Dit is bewust de enige plek waar de poort "nadenkt".
#
# Gebruik:
#   scripts/intake-decide.sh --title "..." --body-file body.md [--routing routing.yml]
#                            [--paths-file gepeild.tsv] [--path-weight 5]
#   scripts/intake-decide.sh --print-paths --title "..." --body-file body.md
#
# `--print-paths` drukt de bestandspaden af die in de tekst genoemd worden, één per regel, en stopt
# daarna. Dat is bewust een aparte aanroep: WELKE paden genoemd worden is puur tekstwerk en dus
# hier testbaar; of ze ergens BESTAAN is een API-vraag en hoort in de workflow. Die peilt ze en
# geeft het resultaat als `--paths-file` terug (regels `owner/repo<TAB>pad`). Zelfde splitsing als
# bij `liveness-oordeel` in fleet-doctor.sh: de workflow verzamelt, het script beslist.
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
paths_file=""
print_paths=0
# Hoeveel een genoemd bestandspad weegt tegenover één trefwoord. Zie de uitleg bij stap 2b.
path_weight=5
# Hoeveel padkandidaten we maximaal aanbieden. De peiling erbuiten kost een API-call per pad per
# consument; vijf paden dekt elk realistisch issue en houdt dat begrensd.
max_paths=5

die() { echo "✋ intake-decide: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --title)       shift; title="${1:-}" ;;
    --body-file)   shift; body_file="${1:-}" ;;
    --routing)     shift; routing="${1:-}" ;;
    --paths-file)  shift; paths_file="${1:-}" ;;
    --path-weight) shift; path_weight="${1:-}" ;;
    --print-paths) print_paths=1 ;;
    *) die "onbekend argument: $1" ;;
  esac
  shift
done

[ -n "$title" ]      || die "--title ontbreekt"
[ -n "$body_file" ]  || die "--body-file ontbreekt"
[ -f "$body_file" ]  || die "body-bestand bestaat niet: $body_file"

body="$(cat "$body_file")"

# --- 0. Padkandidaten uit de tekst ------------------------------------------------------------
# Een bestandspad is veel specifieker bewijs dan een los woord: wie `.github/workflows/pr-check.yml`
# noemt, weet al in welke repo 'ie zit. Alleen paden MET een map-scheiding én een extensie tellen —
# `README` of `de/te` zijn geen bewijs, `lib/features/x.dart` wel.
#
# URL's gaan er eerst uit: `https://github.com/<owner>/<repo>/blob/main/lib/x.dart` zou anders als
# vijf losse "paden" binnenkomen.
#
# GEEN `..`-SEGMENTEN. De uitkomst hiervan is niet-vertrouwde tekst: iedereen met een GitHub-account
# kan een issue openen, en de workflow plakt elk pad hieruit in `gh api repos/<repo>/contents/<pad>`.
# Een pad als `../../../etc/shadow.yml` haalt de tekenklasse hieronder moeiteloos (punt en slash
# zitten erin) en laat de peiling dan buiten `contents/` klimmen. Er is geen enkele legitieme reden
# dat een issue naar een pad búiten de repo wijst, dus die gaan er hier uit — bij de bron, zodat
# elke aanroeper van dit script de grens erft in plaats van 'm zelf te moeten leggen.
paden="$(printf '%s\n%s' "$title" "$body" \
  | sed -E 's#https?://[^[:space:])"]*##g' \
  | grep -oE '[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+' \
  | grep -E '/[A-Za-z0-9_.-]+\.[A-Za-z0-9]+$' \
  | sed -E 's#^\./##' \
  | grep -vE '(^|/)\.\.(/|$)' \
  | sort -u | head -"$max_paths" || true)"
# `|| true` is hier geen slordigheid: `grep` geeft exit 1 als er niets matcht, en dit script draait
# met `set -e -o pipefail`. Zonder die vangnet-clausule zou ELK issue zónder bestandspad — verreweg
# de meeste — het script laten sterven vóór de routering, en de poort geeft dan geen beslissing meer.

if [ "$print_paths" = 1 ]; then
  [ -n "$paden" ] && printf '%s\n' "$paden"
  exit 0
fi

# Pas hierna, zodat `--print-paths` geen routeringstabel nodig heeft: die aanroep doet puur tekstwerk.
[ -f "$routing" ]    || die "routeringstabel bestaat niet: $routing"

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

best_repo=""; best_score=0; runner_up=0; best_paden=0
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

  # --- 2b. Bestandspaden wegen zwaarder dan losse trefwoorden ---------------------------------
  # AANLEIDING, gemeten. Een issue over een wijziging aan de éígen `pr-check.yml` van de
  # productconsument werd op trefwoordscore 6-2 naar de infra-repo zelf gerouteerd, omdat woorden
  # als "workflow" en "runner" nu eenmaal infra-woorden zijn. Daar gebeurde vervolgens niets: die
  # repo heeft geen raket, dus het issue lag 20+ minuten stil zonder label of signaal en moest
  # handmatig verhuizen.
  #
  # Het bewijs lág in het issue: de infra-repo HEEFT geen `pr-check.yml`, de consument wel. Losse
  # woorden zeggen alleen iets over het ONDERWERP; een bestandspad zegt iets over de PLAATS.
  # Vandaar dat een treffer hier zwaarder telt dan welk trefwoord dan ook — maar niet absoluut:
  # overweldigend trefwoordbewijs kan 'm nog steeds verslaan, en een gelijkspel blijft gewoon
  # `needs-routing`.
  #
  # PER DISTINCT PAD, niet één bonus per repo. Een pad dat in álle repo's bestaat (`docs/x.md`)
  # verhoogt iedereen even hard en beslist dus niets — precies goed. Noemt een issue twee paden
  # waarvan er één maar in één repo staat, dan hoort díé repo voor te komen.
  #
  # Geen peiling meegekregen (of de peiling was onbetrouwbaar) → deze stap doet niets en het
  # gedrag is byte-voor-byte het oude. De workflow laat het bestand dan bewust weg.
  pad_treffers=0
  if [ -n "$paths_file" ] && [ -f "$paths_file" ]; then
    pad_treffers="$(awk -F'\t' -v r="$repo" '$1==r && $2 != "" {print $2}' "$paths_file" \
      | sort -u | grep -c . || true)"
    score=$((score + pad_treffers * path_weight))
  fi

  if [ "$score" -gt "$best_score" ]; then
    runner_up="$best_score"; best_score="$score"; best_repo="$repo"; best_paden="$pad_treffers"
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

pad_uitleg=""
if [ "$best_paden" -gt 0 ]; then
  pad_uitleg=" — waarvan $((best_paden * path_weight)) punt(en) uit $best_paden genoemd bestandspad(en) die daar écht bestaan"
fi
emit transfer "$best_repo" "Eenduidig gerouteerd naar \`$best_repo\` (score $best_score tegen $runner_up)$pad_uitleg."
