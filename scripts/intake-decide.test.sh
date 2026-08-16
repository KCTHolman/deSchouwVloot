#!/usr/bin/env bash
# Tests voor scripts/intake-decide.sh — de beslislogica van de poort.
#
# Draait offline: geen netwerk, geen gh, geen secrets. Dat is precies waarom de beslislogica
# los van de workflow staat (docs/architectuur.md §3b) — de poort is het eerste station dat
# ELK idee raakt, dus een stille regressie hier vergiftigt de hele keten.
#
# Lokaal: bash scripts/intake-decide.test.sh

set -uo pipefail
cd "$(dirname "$0")/.."

DECIDE="scripts/intake-decide.sh"
ROUTING="routing.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fail=1; }

# expect <naam> <verwachte-decision> <verwacht-target|-> <titel> <body>
expect() {
  local naam="$1" want_dec="$2" want_tgt="$3" titel="$4" body="$5"
  printf '%s' "$body" > "$TMP/body.md"
  local out dec tgt
  out="$(bash "$DECIDE" --title "$titel" --body-file "$TMP/body.md" --routing "$ROUTING" 2>/dev/null)" || {
    bad "$naam (script exit != 0)"; return
  }
  dec="$(printf '%s\n' "$out" | sed -n 's/^decision=//p')"
  tgt="$(printf '%s\n' "$out" | sed -n 's/^target=//p')"
  [ -z "$tgt" ] && tgt="-"
  if [ "$dec" = "$want_dec" ] && [ "$tgt" = "$want_tgt" ]; then
    ok "$naam"
  else
    bad "$naam (verwacht $want_dec/$want_tgt, kreeg $dec/$tgt)"
  fi
}

# Een body die de kwaliteitspoort haalt; de routering hangt dan puur op de trefwoorden.
goed_body() {
  cat <<EOF
## Doel
$1

## Acceptatiecriteria
- [ ] eerste toetsbare criterium dat objectief te meten is
- [ ] tweede toetsbare criterium
EOF
}

echo "intake-decide — kwaliteitspoort:"

expect "lege body => detail" detail - \
  "Iets met de app" ""

expect "alleen een kreet => detail" detail - \
  "flutter kapot" "kan iemand hiernaar kijken"

expect "doel te kort => detail" detail - \
  "DNA-scanner" "$(printf '## Doel\nsneller\n\n## Acceptatiecriteria\n- [ ] a\n- [ ] b\n')"

expect "doel goed maar 0 criteria => detail" detail - \
  "DNA-scanner sneller maken" "$(printf '## Doel\nDe DNA-scanner moet merkbaar sneller worden voor grote bestanden.\n')"

expect "doel goed maar 1 criterium => detail" detail - \
  "DNA-scanner sneller maken" "$(printf '## Doel\nDe DNA-scanner moet merkbaar sneller worden voor grote bestanden.\n\n## Acceptatiecriteria\n- [ ] alleen dit ene\n')"

expect "lege sjabloon-checkboxes tellen niet => detail" detail - \
  "DNA-scanner sneller maken" \
  "$(printf '## Doel\nDe DNA-scanner moet merkbaar sneller worden voor grote bestanden.\n\n## Acceptatiecriteria\n- [ ] \n- [ ] \n')"

expect "te korte criteria tellen niet => detail" detail - \
  "DNA-scanner sneller maken" \
  "$(printf '## Doel\nDe DNA-scanner moet merkbaar sneller worden voor grote bestanden.\n\n## Acceptatiecriteria\n- [ ] snel\n- [ ] af\n')"

echo "intake-decide — routering:"

expect "duidelijk BiohackOS" transfer KCTHolman/BiohackOS \
  "Voorraadlijst in de app sorteren" \
  "$(goed_body 'De pantry-lijst in de flutter-app moet op houdbaarheidsdatum kunnen sorteren.')"

expect "duidelijk deFleet" transfer KCTHolman/fleet \
  "Runner-lane splitsen" \
  "$(goed_body 'De heavy lane heeft een eigen runner-user nodig in de pijplijn, net als de agent-lane.')"

expect "geen trefwoord => routing" routing - \
  "Iets algemeens regelen" \
  "$(goed_body 'Er moet een generieke oplossing komen voor het probleem dat we gisteren bespraken.')"

expect "gelijkspel => routing (nooit gokken)" routing - \
  "app en workflow" \
  "$(goed_body 'Dit raakt zowel de kant van het onderwerp A als het onderwerp B, precies even sterk.')"

echo "intake-decide — randgevallen:"

expect "trefwoord in de TITEL telt mee" transfer KCTHolman/fleet \
  "gitflow-doctor faalt op de invarianten" \
  "$(goed_body 'Sinds gisteren komt hier een melding uit die niemand begrijpt en die niet klopt.')"

expect "hoofdletters maken niet uit" transfer KCTHolman/BiohackOS \
  "SUPABASE-migratie" \
  "$(goed_body 'De Supabase-migratie moet opnieuw draaien omdat de vorige halverwege afbrak.')"

expect "koppelteken-trefwoord (auto-merge) matcht" transfer KCTHolman/fleet \
  "auto-merge staat uit" \
  "$(goed_body 'De auto-merge is handmatig uitgezet en niemand weet meer waarom dat gebeurd is.')"

echo "intake-decide · trefwoord met inline commentaar:"

# YAML leest `- dashboard   # reden` als de waarde `dashboard`. Deze parser nam eerder de hele
# staart mee, waardoor zo n trefwoord STIL werd genegeerd — geen fout, geen effect. Gevonden
# 2026-07-28 doordat een sabotage-demo van de golden-run niets deed: niet omdat de golden-set te
# zwak was, maar omdat de sabotage zelf werd weggeparsed. Precies het faalpatroon van deze hele
# dag: iets dat er goed uitziet en niets doet.
R="$TMP/routing-comment.yml"
{
  echo "version: 1"
  echo "consumers:"
  echo "  - repo: KCTHolman/BiohackOS"
  echo "    keywords:"
  echo "      - flutter   # het app-framework"
  echo "  - repo: KCTHolman/fleet"
  echo "    keywords:"
  echo "      - runner"
} > "$R"
B="$TMP/body-comment.md"
{
  echo "## Doel"
  echo "De flutter-kant moet anders werken dan nu het geval is."
  echo ""
  echo "## Acceptatiecriteria"
  echo "- [ ] De gewijzigde situatie is zichtbaar en meetbaar na de wijziging"
  echo "- [ ] Er is een test die precies dat geval afdekt en faalt zonder de fix"
} > "$B"
uit="$(bash "$DECIDE" --title "Iets aanpassen" --body-file "$B" --routing "$R" 2>/dev/null)"
if printf '%s' "$uit" | grep -q "target=KCTHolman/BiohackOS"; then
  ok "trefwoord met inline commentaar telt gewoon mee"
else
  bad "trefwoord met inline commentaar werd genegeerd (kreeg: $(printf '%s' "$uit" | tr '
' ' '))"
fi


# --- BESTANDSPADEN ----------------------------------------------------------------------------
# Zie de uitleg bij stap 0 en 2b in het script. Twee helften, apart getest: WELKE paden staan er in
# de tekst (puur tekstwerk), en WAT doet een peiling met de uitkomst.
echo "intake-decide · bestandspaden:"

paden_body="$TMP/paden.md"
{
  echo "## Doel"
  echo "De workflow \`.github/workflows/pr-check.yml\` shardt de tests niet, en"
  echo "\`lib/features/voeding/dag.dart\` laadt daardoor traag. Zie ook"
  echo "https://github.com/KCTHolman/BiohackOS/blob/main/docs/plan.md voor de context."
  echo "Losse woorden als lib/ of README tellen niet mee, net als de/te."
  echo ""
  echo "## Acceptatiecriteria"
  echo "- [ ] De gewijzigde situatie is zichtbaar en meetbaar na de wijziging"
  echo "- [ ] Er is een test die precies dat geval afdekt en faalt zonder de fix"
} > "$paden_body"

gevonden="$(bash "$DECIDE" --print-paths --title "Sharden" --body-file "$paden_body" | sort | tr '\n' ' ')"
verwacht_paden=".github/workflows/pr-check.yml lib/features/voeding/dag.dart "
if [ "$gevonden" = "$verwacht_paden" ]; then
  ok "padextractie: alleen echte paden, URL's eruit"
else
  bad "padextractie (verwacht '$verwacht_paden', kreeg '$gevonden')"
fi

# NIET-VERTROUWDE INVOER. Een issue kan door iedereen geopend worden en de peilstap plakt elk pad
# hieruit in een `gh api repos/<repo>/contents/<pad>`-call. Een `..`-segment laat die peiling buiten
# de repo klimmen; er is geen legitiem issue dat zo'n pad noemt.
trav_body="$TMP/traversal.md"
{
  echo "Zie ../../../etc/shadow.yml en ook ../../secrets.env.yml voor context."
  echo "Het echte bestand is lib/app.dart en dat moet gewoon overblijven."
} > "$trav_body"
gevonden="$(bash "$DECIDE" --print-paths --title "x" --body-file "$trav_body" | tr '\n' ' ')"
if [ "$gevonden" = "lib/app.dart " ]; then
  ok "padextractie weigert \`..\`-segmenten"
else
  bad "traversal-pad kwam er doorheen (kreeg '$gevonden')"
fi

# HET GEVAL WAARVOOR DE PAD-WEGING BESTAAT. Een wijziging aan de éígen pr-check.yml van de
# productconsument, beschreven met infra-woorden. Zonder peiling wint de infra-repo op
# trefwoordscore; met peiling wint de repo waar het genoemde bestand écht staat.
R14="$TMP/routing-paden.yml"
{
  echo "consumers:"
  echo "  - repo: KCTHolman/BiohackOS"
  echo "    keywords:"
  echo "      - flutter"
  echo "  - repo: KCTHolman/fleet"
  echo "    keywords:"
  echo "      - workflow"
  echo "      - runner"
  echo "      - pijplijn"
} > "$R14"
B14="$TMP/body-paden.md"
{
  echo "## Doel"
  echo "De workflow \`.github/workflows/pr-check.yml\` draait de flutter-tests in één keer,"
  echo "waardoor de pijplijn traag is. De runner staat het grootste deel van de tijd te wachten."
  echo ""
  echo "## Acceptatiecriteria"
  echo "- [ ] De gewijzigde situatie is zichtbaar en meetbaar na de wijziging"
  echo "- [ ] Er is een test die precies dat geval afdekt en faalt zonder de fix"
} > "$B14"

beslis_met_paden() { # $1 = paths-file (of leeg) → print de target
  local pf="${1:-}" args=()
  [ -n "$pf" ] && args=(--paths-file "$pf")
  bash "$DECIDE" --title "Tests sharden in de pr-check" --body-file "$B14" \
    --routing "$R14" "${args[@]}" 2>/dev/null | sed -n 's/^target=//p'
}

got="$(beslis_met_paden "")"
[ "$got" = "KCTHolman/fleet" ] \
  && ok "zonder peiling onveranderd: trefwoorden winnen" \
  || bad "zonder peiling (verwacht KCTHolman/fleet, kreeg ${got:--})"

P14="$TMP/paths-hit.tsv"
printf 'KCTHolman/BiohackOS\t.github/workflows/pr-check.yml\n' > "$P14"
got="$(beslis_met_paden "$P14")"
[ "$got" = "KCTHolman/BiohackOS" ] \
  && ok "pad dat alleen bij de consument bestaat verslaat drie infra-trefwoorden" \
  || bad "pad-weging (verwacht KCTHolman/BiohackOS, kreeg ${got:--})"

# Een pad dat in BEIDE repo's bestaat is geen bewijs vóór één van de twee: iedereen krijgt
# dezelfde bonus, dus de trefwoorden geven weer de doorslag.
P14b="$TMP/paths-beide.tsv"
printf 'KCTHolman/BiohackOS\t.github/workflows/pr-check.yml\nKCTHolman/fleet\t.github/workflows/pr-check.yml\n' > "$P14b"
got="$(beslis_met_paden "$P14b")"
[ "$got" = "KCTHolman/fleet" ] \
  && ok "pad dat overal bestaat beslist niets" \
  || bad "pad in beide repo's (verwacht KCTHolman/fleet, kreeg ${got:--})"

# Lege peiling (geen enkel pad gevonden, of de peiling was onbetrouwbaar) → oud gedrag.
P14c="$TMP/paths-leeg.tsv"
: > "$P14c"
got="$(beslis_met_paden "$P14c")"
[ "$got" = "KCTHolman/fleet" ] \
  && ok "lege peiling valt terug op het oude gedrag" \
  || bad "lege peiling (verwacht KCTHolman/fleet, kreeg ${got:--})"

# Gelijkspel blijft gelijkspel, óók als de paden het veroorzaken: de poort gokt nooit.
R14b="$TMP/routing-gelijk.yml"
{
  echo "consumers:"
  echo "  - repo: KCTHolman/BiohackOS"
  echo "    keywords:"
  echo "      - flutter"
  echo "  - repo: KCTHolman/fleet"
  echo "    keywords:"
  echo "      - flutter"
} > "$R14b"
P14d="$TMP/paths-gelijk.tsv"
printf 'KCTHolman/BiohackOS\tx/a.yml\nKCTHolman/fleet\tx/a.yml\n' > "$P14d"
uit="$(bash "$DECIDE" --title "Iets met flutter" --body-file "$B14" --routing "$R14b" \
        --paths-file "$P14d" 2>/dev/null)"
if printf '%s' "$uit" | grep -q '^decision=routing'; then
  ok "gelijkspel mét paden blijft needs-routing"
else
  bad "gelijkspel mét paden (kreeg: $(printf '%s' "$uit" | tr '\n' ' '))"
fi

if [ "$fail" = 0 ]; then
  echo "✅ alle intake-decide-tests groen"
else
  echo "❌ intake-decide-tests faalden"
fi
exit "$fail"
