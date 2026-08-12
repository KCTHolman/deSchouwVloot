#!/usr/bin/env bash
# check-impact.sh — validator voor de IA-code: de impactanalyse als machine-leesbare metadata.
#
# HERKOMST. Geporteerd uit BiohackOS (PR #2028, 2026-08-12), de eerste consument waar dit
# mechanisme draait. Daar verving het een checklist die alleen toetste of tien kopjes bestonden en
# de vakjes `[x]` stonden — pure self-attestatie: "tien vinkjes zonder echte analyse slagen
# technisch" stond letterlijk zo in de eigen governance-doc. Deze guard maakt van de impactanalyse
# een **vaste vragenlijst met vaste antwoorden**: elk antwoord is een waarde uit een gesloten
# lijst, dus een falsifieerbare bewering. Daardoor kan een script de analyse tegen de ECHTE diff
# houden: `db=geen` terwijl de PR een migratie toevoegt is aantoonbaar onwaar en valt om, zónder
# dat er een mens naar hoeft te kijken — precies het idee achter README §"Groen is geen bewijs".
#
# CONSUMENT-EIGENDOM. Dit script is domeinvrij: de vragenlijst zelf (velden, toegestane
# antwoorden, verboden combinaties, verplichte toelichting, kruiscontrole-regels) leeft in het
# schema-bestand van de AANROEPER, niet hier — zelfde grens als `.fleet.yml` bij pr-label. Zie
# `examples/impact-codes.example.yml` voor een ingevuld voorbeeld en `docs/impactanalyse.md` voor
# de uitleg.
#
# WAT het valideert (in deze volgorde; alle fouten worden verzameld, niet alleen de eerste):
#   1. het codeblok bestaat en heeft de juiste versie;
#   2. elk veld uit het schema is beantwoord, geen onbekende of dubbele velden;
#   3. elk antwoord staat in de gesloten lijst (en `enkel`-velden hebben één waarde);
#   4. verboden antwoorden (bv. `net=nieuw`) → altijd rood, met de reden uit het schema;
#   5. antwoorden die één regel toelichting eisen, hebben die ook;
#   6. KRUISCONTROLE tegen de diff (`--files`): `vereist`/`verbiedt`-regels uit het schema.
# Zonder `--files` slaat stap 6 over (formaatcontrole-modus, bv. lokaal vóór de commit).
#
# GEBRUIK (repo-root van de consument):
#   scripts/check-impact.sh --body <pad|->  [--files <pad|->] [--schema <pad>]
#   scripts/check-impact.sh --sjabloon                # print een leeg, in te vullen codeblok
#   scripts/check-impact.sh --uitleg                  # print de vragen + toegestane antwoorden
#
# UITVOER. Exit 0 = geldig. Exit 1 = één of meer bevindingen; die gaan als `- <regel>` naar stdout
# (de workflow plakt dat 1-op-1 in de sticky comment) en als `::error`-annotatie naar stderr.
# Self-test: scripts/check-impact.test.sh — géén netwerk, géén gh nodig.

set -uo pipefail
# NOGLOB, bewust en scriptbreed: de schema-globs (`scripts/*.test.sh`, `docs/*`) worden hieronder
# ge-word-split op `,` en zouden zonder `set -f` in de repo-root aan PATHNAME-expansie onderhevig
# zijn — dan matcht een regel alleen nog tegen bestanden die NU al bestaan en glipt exact het geval
# door dat de guard moet vangen (een PR die een nieuw bestand toevoegt). `case`-patroonmatching
# hieronder werkt gewoon door; die staat los van pathname-expansie.
set -f

SCHEMA=".github/impact-codes.yml"
BODY=""
FILES=""
MODE="valideer"

while [ $# -gt 0 ]; do
  case "$1" in
    --body)      shift; BODY="${1:-}" ;;
    --files)     shift; FILES="${1:-}" ;;
    --schema)    shift; SCHEMA="${1:-}" ;;
    --sjabloon)  MODE="sjabloon" ;;
    --uitleg)    MODE="uitleg" ;;
    -h|--help)   MODE="help" ;;
    *) echo "✋ check-impact: onbekend argument '$1'" >&2; exit 2 ;;
  esac
  shift
done

die() { echo "::error title=check-impact::$*" >&2; echo "✋ check-impact: $*" >&2; exit 2; }

# ---------------------------------------------------------------------------------------------
# Schema inlezen. Fail-closed: een regel die de grammatica niet matcht is een harde fout, zodat
# een typefout nooit stil een veld of regel laat wegvallen.
# ---------------------------------------------------------------------------------------------
[ -f "$SCHEMA" ] || die "schema '$SCHEMA' bestaat niet."

VERSIE=""
KEYS=(); K_PUNT=(); K_LABEL=(); K_KARD=(); K_WAARDEN=()
FORB_KV=(); FORB_REDEN=()
TOEL=()
RULE_KV=(); RULE_OP=(); RULE_GLOBS=()

sectie=""
regelnr=0
while IFS= read -r line || [ -n "$line" ]; do
  regelnr=$((regelnr + 1))
  trimmed="${line#"${line%%[![:space:]]*}"}"   # strip leidende witruimte
  case "$trimmed" in '#'*|'') continue ;; esac

  case "$line" in
    'versie: "'*'"')
      rest="${line#versie: \"}"; VERSIE="${rest%\"}"; continue ;;
    'velden:'|'verboden:'|'toelichting:'|'regels:')
      sectie="${line%:}"; continue ;;
    '  "'*'": "'*'"')
      rest="${line#  \"}";   k="${rest%%\"*}"
      rest="${rest#*\": \"}"; v="${rest%\"}"
      case "$sectie" in
        velden)
          # "<punt>|<label>|<kardinaliteit>|<waarden>"
          punt="${v%%|*}";        r1="${v#*|}"
          label="${r1%%|*}";      r2="${r1#*|}"
          kard="${r2%%|*}";       waarden="${r2#*|}"
          case "$kard" in enkel|meervoud) ;; *) die "$SCHEMA:$regelnr — veld '$k' heeft kardinaliteit '$kard' (verwacht enkel/meervoud)." ;; esac
          [ -n "$waarden" ] || die "$SCHEMA:$regelnr — veld '$k' heeft geen toegestane waarden."
          KEYS+=("$k"); K_PUNT+=("$punt"); K_LABEL+=("$label"); K_KARD+=("$kard"); K_WAARDEN+=("$waarden") ;;
        verboden)
          FORB_KV+=("$k"); FORB_REDEN+=("$v") ;;
        *) die "$SCHEMA:$regelnr — map-regel buiten een bekende sectie ('$sectie')." ;;
      esac
      continue ;;
    '  - "'*'"')
      rest="${line#  - \"}"; v="${rest%\"}"
      case "$sectie" in
        toelichting) TOEL+=("$v") ;;
        regels)
          kv="${v%% *}"; op_rest="${v#* }"
          op="${op_rest%% *}"; globs="${op_rest#* }"
          case "$op" in vereist|verbiedt) ;; *) die "$SCHEMA:$regelnr — onbekende operator '$op' (verwacht vereist/verbiedt)." ;; esac
          RULE_KV+=("$kv"); RULE_OP+=("$op"); RULE_GLOBS+=("$globs") ;;
        *) die "$SCHEMA:$regelnr — lijst-regel buiten een bekende sectie ('$sectie')." ;;
      esac
      continue ;;
  esac
  die "$SCHEMA:$regelnr — regel matcht de grammatica niet: '$line'"
done < "$SCHEMA"

[ -n "$VERSIE" ]        || die "$SCHEMA bevat geen 'versie:'-regel."
[ "${#KEYS[@]}" -gt 0 ] || die "$SCHEMA bevat geen velden."

# key_index <sleutel> → index in KEYS, of leeg.
key_index() {
  local n="$1" i=0
  for i in "${!KEYS[@]}"; do [ "${KEYS[$i]}" = "$n" ] && { printf '%s' "$i"; return 0; }; done
  return 1
}

# in_csv <naald> <csv> → 0 als naald exact als item in de comma-lijst staat.
in_csv() {
  local naald="$1" csv="$2" item
  local IFS=','
  for item in $csv; do [ "$item" = "$naald" ] && return 0; done
  return 1
}

# ---------------------------------------------------------------------------------------------
# Hulpmodi: --sjabloon en --uitleg genereren allebei UIT het schema, zodat het PR-template en de
# doc niet als tweede waarheid kunnen gaan drift-en.
# ---------------------------------------------------------------------------------------------
if [ "$MODE" = "help" ]; then
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

if [ "$MODE" = "sjabloon" ]; then
  printf '```ia\n%s' "$VERSIE"
  for i in "${!KEYS[@]}"; do printf ' %s=?' "${KEYS[$i]}"; done
  printf '\n```\n'
  exit 0
fi

if [ "$MODE" = "uitleg" ]; then
  printf '| # | Veld | Vraag | Toegestane antwoorden |\n|---|---|---|---|\n'
  for i in "${!KEYS[@]}"; do
    kard=""
    [ "${K_KARD[$i]}" = "meervoud" ] && kard=' *(meerdere, komma-gescheiden)*'
    printf '| %s | `%s` | %s%s | %s |\n' \
      "${K_PUNT[$i]}" "${KEYS[$i]}" "${K_LABEL[$i]}" "$kard" \
      "$(printf '%s' "${K_WAARDEN[$i]}" | sed 's/,/` · `/g; s/^/`/; s/$/`/')"
  done
  exit 0
fi

# ---------------------------------------------------------------------------------------------
# Valideer-modus
# ---------------------------------------------------------------------------------------------
[ -n "$BODY" ] || die "geen --body meegegeven (pad of '-' voor stdin)."

if [ "$BODY" = "-" ]; then
  BODY_TXT="$(cat)"
else
  [ -f "$BODY" ] || die "body-bestand '$BODY' bestaat niet."
  BODY_TXT="$(cat "$BODY")"
fi
BODY_TXT="${BODY_TXT//$'\r'/}"

DIFF_FILES=""
if [ -n "$FILES" ]; then
  if [ "$FILES" = "-" ]; then
    DIFF_FILES="$(cat)"
  else
    [ -f "$FILES" ] || die "bestandenlijst '$FILES' bestaat niet."
    DIFF_FILES="$(cat "$FILES")"
  fi
fi

fails=()
voegtoe() { fails+=("$1"); }

# --- 1. Codeblok uitlezen --------------------------------------------------------------------
BLOK="$(printf '%s\n' "$BODY_TXT" | awk '
  /^[[:space:]]*```[[:space:]]*ia[[:space:]]*$/ { f=1; next }
  f && /^[[:space:]]*```/                       { exit }
  f                                             { print }
')"

if [ -z "${BLOK//[[:space:]]/}" ]; then
  voegtoe "Het \`\`\`ia-codeblok ontbreekt (of is leeg). Plak het blok uit je PR-template in de PR-body — \`bash scripts/check-impact.sh --sjabloon\` print een lege versie."
  printf '%s\n' "${fails[@]}" | sed 's/^/- /'
  echo "::error title=impactanalyse::Het \`\`\`ia-codeblok ontbreekt in de PR-body." >&2
  exit 1
fi

# --- 2/3. Tokens parsen: versie + <sleutel>=<waarde> -----------------------------------------
tokens=()
while IFS= read -r t || [ -n "$t" ]; do [ -n "$t" ] && tokens+=("$t"); done < <(printf '%s' "$BLOK" | tr -s '[:space:]' '\n')

gezien_keys=()
ans_keys=(); ans_vals=()

eerste="${tokens[0]:-}"
if [ "$eerste" != "$VERSIE" ]; then
  voegtoe "Het codeblok begint met \`$eerste\` in plaats van de schema-versie \`$VERSIE\`."
fi

for ((ti = 1; ti < ${#tokens[@]}; ti++)); do
  t="${tokens[$ti]}"
  case "$t" in
    *=*) ;;
    *) voegtoe "Token \`$t\` is geen \`sleutel=waarde\`-paar."; continue ;;
  esac
  k="${t%%=*}"; v="${t#*=}"

  if ! idx="$(key_index "$k")"; then
    voegtoe "Onbekend veld \`$k\` — toegestane velden: ${KEYS[*]}."
    continue
  fi
  if in_csv "$k" "$(IFS=,; printf '%s' "${gezien_keys[*]:-}")"; then
    voegtoe "Veld \`$k\` staat meer dan één keer in het codeblok."
    continue
  fi
  gezien_keys+=("$k")

  if [ -z "$v" ]; then
    voegtoe "Veld \`$k\` heeft geen antwoord."
    continue
  fi

  aantal=0
  ongeldig=()
  oldifs="$IFS"; IFS=','
  for deel in $v; do
    aantal=$((aantal + 1))
    in_csv "$deel" "${K_WAARDEN[$idx]}" || ongeldig+=("$deel")
  done
  IFS="$oldifs"

  for bad in "${ongeldig[@]:-}"; do
    [ -z "$bad" ] && continue
    voegtoe "Veld \`$k\` heeft antwoord \`$bad\`; toegestaan is: \`$(printf '%s' "${K_WAARDEN[$idx]}" | sed 's/,/`, `/g')\`."
  done
  if [ "${K_KARD[$idx]}" = "enkel" ] && [ "$aantal" -gt 1 ]; then
    voegtoe "Veld \`$k\` (${K_LABEL[$idx]}) accepteert één antwoord, niet \`$v\`."
  fi

  ans_keys+=("$k"); ans_vals+=("$v")
done

# Ontbrekende velden.
for i in "${!KEYS[@]}"; do
  k="${KEYS[$i]}"
  in_csv "$k" "$(IFS=,; printf '%s' "${gezien_keys[*]:-}")" || \
    voegtoe "Veld \`$k\` ontbreekt (punt ${K_PUNT[$i]} — ${K_LABEL[$i]}); toegestaan: \`$(printf '%s' "${K_WAARDEN[$i]}" | sed 's/,/`, `/g')\`."
done

# antwoord_paren — elk `<sleutel>=<losse waarde>` uit de code, meervoud uitgeklapt.
antwoord_paren=()
for ((i = 0; i < ${#ans_keys[@]}; i++)); do
  oldifs="$IFS"; IFS=','
  for deel in ${ans_vals[$i]}; do antwoord_paren+=("${ans_keys[$i]}=$deel"); done
  IFS="$oldifs"
done

heeft_antwoord() {
  local p x
  p="$1"
  for x in "${antwoord_paren[@]:-}"; do [ "$x" = "$p" ] && return 0; done
  return 1
}

# --- 4. Verboden antwoorden ------------------------------------------------------------------
for ((i = 0; i < ${#FORB_KV[@]}; i++)); do
  heeft_antwoord "${FORB_KV[$i]}" && \
    voegtoe "Antwoord \`${FORB_KV[$i]}\` is niet toegestaan: ${FORB_REDEN[$i]}"
done

# --- 5. Verplichte toelichting ---------------------------------------------------------------
# Eén bullet in de body: `- **<sleutel>** — <minstens tien tekens toelichting>`.
heeft_toelichting() {
  printf '%s\n' "$BODY_TXT" | grep -qE "^[[:space:]]*[-*][[:space:]]+\*\*$1\*\*[^A-Za-z0-9]*[A-Za-z0-9].{9,}"
}
for p in "${TOEL[@]:-}"; do
  [ -z "$p" ] && continue
  heeft_antwoord "$p" || continue
  k="${p%%=*}"
  heeft_toelichting "$k" || \
    voegtoe "Antwoord \`$p\` vereist één regel toelichting in de PR-body: \`- **$k** — <waarom/wat>\`."
done

# --- 6. Kruiscontrole tegen de diff ----------------------------------------------------------
# matcht <pad> <glob,glob,...> — shell-case-patronen, `*` loopt óók over `/` (zoals area-map.yml).
matcht() {
  local f="$1" g
  local IFS=','
  for g in $2; do
    # shellcheck disable=SC2254  # $g is bewust een glob-patroon uit het schema
    case "$f" in $g) return 0 ;; esac
  done
  return 1
}

kruis=0
if [ -n "$FILES" ]; then
  bestanden=()
  while IFS= read -r f || [ -n "$f" ]; do [ -n "$f" ] && bestanden+=("$f"); done <<< "$DIFF_FILES"

  for ((i = 0; i < ${#RULE_KV[@]}; i++)); do
    heeft_antwoord "${RULE_KV[$i]}" || continue
    kruis=$((kruis + 1))
    globs="${RULE_GLOBS[$i]}"
    treffers=()
    for f in "${bestanden[@]:-}"; do
      [ -z "$f" ] && continue
      matcht "$f" "$globs" && treffers+=("$f")
    done

    if [ "${RULE_OP[$i]}" = "vereist" ] && [ "${#treffers[@]}" -eq 0 ]; then
      voegtoe "\`${RULE_KV[$i]}\` beweert een wijziging in \`$globs\`, maar de diff raakt daar geen enkel bestand."
    elif [ "${RULE_OP[$i]}" = "verbiedt" ] && [ "${#treffers[@]}" -gt 0 ]; then
      voorbeeld="$(printf '%s, ' "${treffers[@]:0:3}")"; voorbeeld="${voorbeeld%, }"
      [ "${#treffers[@]}" -gt 3 ] && voorbeeld="$voorbeeld … (+$(( ${#treffers[@]} - 3 )))"
      voegtoe "\`${RULE_KV[$i]}\` klopt niet met de diff: \`$globs\` wordt wél geraakt — $voorbeeld."
    fi
  done
fi

# --- Rapport ---------------------------------------------------------------------------------
if [ "${#fails[@]}" -gt 0 ]; then
  printf '%s\n' "${fails[@]}" | sed 's/^/- /'
  for f in "${fails[@]}"; do
    schoon="${f//\`/}"
    echo "::error title=impactanalyse::$schoon" >&2
  done
  exit 1
fi

if [ -n "$FILES" ]; then
  echo "✅ IA-code $VERSIE geldig — ${#KEYS[@]} velden beantwoord, $kruis kruiscontrole(s) tegen de diff gehaald."
else
  echo "✅ IA-code $VERSIE geldig — ${#KEYS[@]} velden beantwoord (formaatcontrole; geen diff meegegeven)."
fi
