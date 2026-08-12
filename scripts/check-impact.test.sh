#!/usr/bin/env bash
# Zelf-test voor scripts/check-impact.sh — de IA-code-validator.
#
# Bewaakt de drie lagen die de guard z'n waarde geven: (1) FORMAAT (blok aanwezig, versie, alle
# velden, gesloten antwoordlijst, kardinaliteit), (2) BELEID (verboden antwoorden + verplichte
# toelichting), en (3) KRUISCONTROLE tegen de diff — de laag die van de impactanalyse een
# falsifieerbare bewering maakt i.p.v. self-attestatie. Plus de fail-closed schema-parser: een
# kapotte schema-regel moet LUID falen, nooit stil een veld laten wegvallen.
#
# De GELDIG-code en diffs hieronder zijn gebaseerd op `examples/impact-codes.example.yml` (het
# tweede-consument-scenario: Python-services + Next.js, geen mobiele app) — niet op een schema van
# déze repo zelf, want deFleet levert machinerie, geen domeincode om impact op te meten.
#
# Draai lokaal (geen netwerk, geen gh):
#   bash scripts/check-impact.test.sh

set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root" || exit 1
CHECK="bash $here/check-impact.sh"
SCHEMA="$root/examples/impact-codes.example.yml"
fail=0

ok()  { printf '  ✅ %s\n' "$1"; }
bad() { printf '  ❌ %s\n' "$1"; fail=1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Een geldige, complete code — de basis waar de meeste cases één veld van afwijken.
GELDIG='v1 arch=conform net=geen ux=nvt plek=ci db=geen api=geen frontend=geen services=geen herbruik=uitgebreid risico=laag test=zelftest docs=nieuw'

# mk_body <bestand> <code-regel> [extra-regel...] — schrijf een PR-body met een ```ia-blok.
mk_body() {
  local file="$1" code="$2"; shift 2
  {
    printf '## Samenvatting\nIets.\n\n'
    printf '```ia\n%s\n```\n' "$code"
    local l
    for l in "$@"; do printf '%s\n' "$l"; done
  } > "$file"
}

# mk_files <bestand> <pad...> — schrijf een diff-bestandenlijst.
mk_files() {
  local file="$1"; shift
  printf '%s\n' "$@" > "$file"
}

# De diff die bij $GELDIG hoort: ci-only, zelftest, docs, geen web/services/db.
mk_files "$tmp/diff-ok.txt" \
  ".github/impact-codes.yml" "scripts/check-impact.sh" "scripts/check-impact.test.sh" \
  "docs/impactanalyse.md"

# case <desc> <verwachte-exit> <needle-of-leeg> <code> [--files <lijst>] [extra body-regels...]
case_code() {
  local desc="$1" want="$2" needle="$3" code="$4"; shift 4
  local files=""
  if [ "${1:-}" = "--files" ]; then files="$2"; shift 2; fi
  local body="$tmp/body.$$.md"
  mk_body "$body" "$code" "$@"
  local out rc args
  args=(--schema "$SCHEMA" --body "$body")
  [ -n "$files" ] && args+=(--files "$files")
  out="$($CHECK "${args[@]}" 2>&1)"; rc=$?
  rm -f "$body"
  if [ "$rc" != "$want" ]; then bad "$desc (exit $rc, verwacht $want; out: $out)"; return; fi
  if [ -n "$needle" ] && ! printf '%s' "$out" | grep -qF "$needle"; then
    bad "$desc (miste '$needle' in: $out)"; return
  fi
  ok "$desc"
}

echo "check-impact.sh — formaat:"
case_code "complete, geldige code zonder diff → exit 0" 0 "geldig" "$GELDIG"
case_code "complete code + kloppende diff → exit 0" 0 "kruiscontrole" "$GELDIG" --files "$tmp/diff-ok.txt"
case_code "verkeerde versie → exit 1" 1 "schema-versie" "${GELDIG/v1 /v0 }"
case_code "ontbrekend veld → exit 1 + veldnaam" 1 "\`docs\` ontbreekt" "${GELDIG/ docs=nieuw/}"
case_code "onbekend veld → exit 1" 1 "Onbekend veld" "$GELDIG kleur=blauw"
case_code "dubbel veld → exit 1" 1 "meer dan één keer" "$GELDIG db=migratie"
case_code "antwoord buiten de gesloten lijst → exit 1" 1 "heeft antwoord" "${GELDIG/db=geen/db=misschien}"
case_code "los token zonder = → exit 1" 1 "geen \`sleutel=waarde\`" "$GELDIG losse-tekst"
case_code "meervoud op een enkel-veld → exit 1" 1 "accepteert één antwoord" "${GELDIG/db=geen/db=geen,migratie}"
case_code "meervoud op een meervoud-veld → exit 0" 0 "geldig" "${GELDIG/test=zelftest/test=zelftest,unit}"

# Ontbrekend blok: geen ```ia in de body.
printf '## Samenvatting\nGeen codeblok hier.\n' > "$tmp/body-leeg.md"
out="$($CHECK --schema "$SCHEMA" --body "$tmp/body-leeg.md" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -qF "codeblok ontbreekt"; then
  ok "ontbrekend \`\`\`ia-blok → exit 1 met vindbare melding"
else
  bad "ontbrekend blok gaf exit $rc / out: $out"
fi

# CRLF (GitHub levert de body met \r\n) mag het blok niet breken.
printf '## S\r\n\r\n```ia\r\n%s\r\n```\r\n' "$GELDIG" > "$tmp/body-crlf.md"
if $CHECK --schema "$SCHEMA" --body "$tmp/body-crlf.md" >/dev/null 2>&1; then
  ok "CRLF-body wordt genormaliseerd → exit 0"
else
  bad "CRLF-body faalde terwijl de code geldig is"
fi

echo "check-impact.sh — beleid (verboden + toelichting):"
case_code "net=nieuw → altijd exit 1 (grondwetswijziging)" 1 "grondwetswijziging" \
  "${GELDIG/net=geen/net=nieuw}" "- **net** — nieuwe bestemming foo.example."
mk_files "$tmp/diff-mig.txt" "supabase/migrations/0070_x.sql" "scripts/check-impact.test.sh" "docs/x.md"
case_code "db=migratie zonder toelichting → exit 1" 1 "vereist één regel toelichting" \
  "${GELDIG/db=geen/db=migratie}" --files "$tmp/diff-mig.txt"
case_code "db=migratie mét toelichting + migratie in de diff → exit 0" 0 "geldig" \
  "${GELDIG/db=geen/db=migratie}" --files "$tmp/diff-mig.txt" \
  "- **db** — nieuwe migratie 0070_x.sql, NULL-safe en terugwaarts compatibel."
case_code "te korte toelichting telt niet → exit 1" 1 "vereist één regel toelichting" \
  "${GELDIG/db=geen/db=migratie}" --files "$tmp/diff-mig.txt" "- **db** — kort."

echo "check-impact.sh — kruiscontrole tegen de diff:"
mk_files "$tmp/diff-services.txt" "services/food/domain.py" "services/tests/domain_test.py" "docs/x.md"
case_code "db=geen terwijl de diff een migratie toevoegt → exit 1" 1 "klopt niet met de diff" \
  "$GELDIG" --files "$tmp/diff-mig.txt"
case_code "services=geen terwijl de diff services/ raakt → exit 1" 1 "\`services=geen\` klopt niet" \
  "$GELDIG" --files "$tmp/diff-services.txt"
case_code "db=migratie zonder migratie in de diff → exit 1" 1 "maar de diff raakt daar geen enkel bestand" \
  "${GELDIG/db=geen/db=migratie}" --files "$tmp/diff-services.txt" \
  "- **db** — nieuwe migratie 0070_x.sql, NULL-safe en terugwaarts compatibel."
case_code "test=zelftest zonder scripts/*.test.sh in de diff → exit 1" 1 "scripts/*.test.sh" \
  "$GELDIG" --files "$tmp/diff-services.txt"
mk_files "$tmp/diff-beide.txt" "services/x.py" "services/tests/x_test.py" "docs/x.md"
case_code "plek=beide met alleen services-bestanden → exit 1 (web-helft ontbreekt)" 1 "plek=beide" \
  "${GELDIG/plek=ci/plek=beide}" --files "$tmp/diff-beide.txt"
case_code "een liegende code ZONDER --files → exit 0 (formaatcontrole-modus)" 0 "formaatcontrole" \
  "$GELDIG"

# Een nieuw bestand dat nog niet op schijf staat moet gewoon matchen (regressie: zonder `set -f`
# expandeerde de schema-glob tegen de wérkelijke repo-inhoud i.p.v. tegen de diff-lijst).
mk_files "$tmp/diff-nieuw.txt" "scripts/bestaat-nog-niet.test.sh" "docs/nog-niet.md" \
  ".github/impact-codes.yml"
case_code "nog niet bestaande paden in de diff matchen de globs → exit 0" 0 "geldig" \
  "$GELDIG" --files "$tmp/diff-nieuw.txt"

echo "check-impact.sh — schema fail-closed:"
schema_bad="$tmp/schema-kapot.yml"
{ printf 'versie: "v1"\nvelden:\n  "arch": "1|A|enkel|conform"\nrommel zonder grammatica\n'; } > "$schema_bad"
if $CHECK --schema "$schema_bad" --body "$tmp/body-leeg.md" >/dev/null 2>&1; then
  bad "een schema-regel buiten de grammatica hoort hard te falen"
else
  ok "onbekende schema-regel → harde fout (fail-closed)"
fi

schema_op="$tmp/schema-op.yml"
{ printf 'versie: "v1"\nvelden:\n  "arch": "1|A|enkel|conform"\nregels:\n  - "arch=conform mag services/*"\n'; } > "$schema_op"
if $CHECK --schema "$schema_op" --body "$tmp/body-leeg.md" >/dev/null 2>&1; then
  bad "een onbekende regel-operator hoort hard te falen"
else
  ok "onbekende operator (niet vereist/verbiedt) → harde fout"
fi

if $CHECK --schema "$tmp/bestaat-niet.yml" --body "$tmp/body-leeg.md" >/dev/null 2>&1; then
  bad "een ontbrekend schema hoort hard te falen"
else
  ok "ontbrekend schema-bestand → harde fout"
fi

echo "check-impact.sh — hulpmodi + het echte voorbeeldschema:"
sjabloon="$($CHECK --schema "$SCHEMA" --sjabloon 2>&1)"
mist=""
for k in arch net ux plek db api frontend services herbruik risico test docs; do
  printf '%s' "$sjabloon" | grep -qF "$k=?" || mist="$mist $k"
done
if [ -z "$mist" ] && printf '%s' "$sjabloon" | grep -qF '```ia'; then
  ok "--sjabloon print een codeblok met elk schema-veld"
else
  bad "--sjabloon mist velden:$mist (out: $sjabloon)"
fi

if $CHECK --schema "$SCHEMA" --uitleg 2>&1 | grep -qF '| `risico` |'; then
  ok "--uitleg genereert de veldtabel uit het schema"
else
  bad "--uitleg gaf geen bruikbare tabel"
fi

# Regressie-vangnet: het voorbeeldschema in de repo moet parsen (anders is het voorbeeld dat
# consumenten kopiëren zelf al kapot).
if $CHECK --schema "$SCHEMA" --uitleg >/dev/null 2>&1; then
  ok "examples/impact-codes.example.yml parseert schoon"
else
  bad "het voorbeeldschema parseert niet — kopieer het niet zo naar een consument"
fi

# Default-schema-pad: zonder --schema zoekt het script naar .github/impact-codes.yml. Deze repo
# heeft er bewust geen (deFleet levert machinerie, geen domeincode om impact op te meten) — dat
# hoort een nette fail-closed foutmelding te geven, geen crash.
if [ ! -f "$root/.github/impact-codes.yml" ]; then
  if $CHECK --body "$tmp/body-leeg.md" 2>&1 | grep -qF "bestaat niet"; then
    ok "geen .github/impact-codes.yml in deze repo → nette fail-closed foutmelding"
  else
    bad "ontbrekend default-schema gaf geen herkenbare foutmelding"
  fi
else
  ok "(deze repo heeft z'n eigen .github/impact-codes.yml — default-pad-check overgeslagen)"
fi

# DRY-vangnet: de veldtabel in de doc is GEGENEREERD uit het voorbeeldschema. Loopt 'ie uit de
# pas, dan leest een lezer een verouderde antwoordlijst — exact de drift die de oude
# checklist-in-drie-kopieën in BiohackOS kenmerkte, en die dit mechanisme juist moest dichten.
doc="docs/impactanalyse.md"
if [ -f "$doc" ]; then
  awk '/UITLEG:START/{f=1;next} /UITLEG:END/{f=0} f' "$doc" | grep -v '^ *$' > "$tmp/doc-tabel.md"
  $CHECK --schema "$SCHEMA" --uitleg > "$tmp/schema-tabel.md" 2>/dev/null
  if diff -q "$tmp/doc-tabel.md" "$tmp/schema-tabel.md" >/dev/null 2>&1; then
    ok "UITLEG-blok in $doc is gelijk aan examples/impact-codes.example.yml"
  else
    bad "UITLEG-blok in $doc loopt uit de pas met het voorbeeldschema — herstel met: bash scripts/check-impact.sh --schema examples/impact-codes.example.yml --uitleg"
    diff "$tmp/doc-tabel.md" "$tmp/schema-tabel.md" | sed 's/^/      /'
  fi
fi

if [ "$fail" = 0 ]; then echo "✅ alle check-impact-tests groen"; else echo "❌ check-impact-tests faalden"; fi
exit "$fail"
