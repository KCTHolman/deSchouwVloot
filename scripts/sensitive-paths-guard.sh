#!/usr/bin/env bash
# sensitive-paths-guard.sh — raakt deze PR iets waar een mens naar moet kijken?
#
# CONTRACT MET auto-merge.yml. Die workflow roept dit script aan als
#
#     bash scripts/sensitive-paths-guard.sh --diff <bestand-met-de-pr-diff>
#
# en leest de beslissing UIT STDOUT, niet uit de exitcode:
#
#     FORCE-APPROVAL: <reden>   → auto-merge eist een expliciete approval van de eigenaar
#     CLEAN: <reden>            → auto-merge mag z'n normale beleid volgen
#
# Alles wat géén van beide oplevert, behandelt auto-merge als FAIL-CLOSED. Dat is de goede kant om
# op te falen, en het is de reden dat dit script altijd met 0 eindigt: een niet-nul exit zou
# hetzelfde effect hebben maar wél als "kapot" ogen, terwijl "ik weet het niet" een geldig oordeel
# is. Invariant I29 in fleet-doctor.sh toetst deze vorm — dat protocol stond tot 2026-08-23 nergens
# opgeschreven, en precies daardoor week InvestingOS' versie ervan af zonder dat iets rood werd.
#
# WAAROM DEFLEET DIT PAS NU HEEFT, EN WAAROM HET NODIG IS.
#
# deFleet's `.fleet.yml` staat sinds 2026-08-23 op `autonomy.mode: autonomous`. Dat was een belofte
# die de repo niet kon waarmaken: zonder dit bestand valt fleet's eigen auto-merge fail-closed terug
# op "mens" bij ELKE PR — het script dat 'ie aanroept bestond hier niet. De retro van diezelfde dag
# zette dat in één regel op tafel: `contract=autonomous · guard=nee · effectief=mens`.
#
# WAT HIER GEVOELIG IS, IS BIJNA ALLES — en dat is geen slordige lijst maar de aard van deze repo.
# Een wijziging hier verandert de machinerie van VIJF repo's tegelijk. De omgekeerde vraag is
# scherper: wat kan hier veranderen zonder dat het ergens anders gedrag verandert? Documentatie, en
# verder eigenlijk niets. Dat is dus precies wat autonoom mag mergen.
#
# Dat lijkt karig, maar het is het meeste dat er te winnen valt: op de dag dat dit geschreven werd
# waren vier van de zeven fleet-PR's documentatie.
#
# VIERDE KOPIE, EN DAT WETEN WE. Dit raamwerk staat nu in Portfolio, BiohackOS, InvestingOS én hier.
# De analyse van 2026-08-23 wees uit dat VERHUIZEN naar fleet niet kan (fleet's stations draaien in
# de werkmap van de aanroeper, dus een fleet-zijdige guard vereist een app-token dat elders al als
# optioneel wordt behandeld — fail-open op een mens-poort), maar PARAMETRISEREN wel. Zolang dat er
# niet is, bewaakt I29 tenminste dat alle vier hetzelfde protocol spreken.
#
# Gebruik:
#   scripts/sensitive-paths-guard.sh --diff <bestand>   een unified diff
#   scripts/sensitive-paths-guard.sh --self-test        ingebouwde asserties (exit 0/1)

set -uo pipefail

diff_file=""

while [ $# -gt 0 ]; do
  case "$1" in
    --diff)      shift; diff_file="${1:-}" ;;
    --self-test) SELFTEST=1 ;;
    -h|--help)   grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)
      # Een onbekende vlag is geen reden om te crashen: de caller leest stdout, dus geef daar een
      # geldig oordeel. Fail-closed, met de reden erbij.
      echo "FORCE-APPROVAL: onbekende optie '$1' — bij twijfel beslist een mens."
      exit 0 ;;
  esac
  shift
done

# --- Wat is gevoelig? -------------------------------------------------------------------------
#
# ALLOWLIST, GEEN BLOCKLIST. Alleen wat hieronder expliciet ongevoelig heet, telt mee voor CLEAN.
# Een nieuw soort pad is per definitie onbekend en gaat dus naar een mens — één keer. Dat is hier
# extra belangrijk omdat een nieuw toplevel-pad in deFleet meestal nieuwe machinerie ís.
classificeer() {
  case "$1" in
    # Ongevoelig: uitsluitend documentatie en voorbeelden.
    docs/*|*.md|LICENSE|.gitignore|.gitattributes) echo schoon; return ;;
    # `examples/` bevat sjablonen die een consument overneemt — geen code die hier draait.
    examples/*) echo schoon; return ;;
  esac
  # Al het overige is machinerie: workflows, scripts, routing, het contract, de tests.
  echo gevoelig
}

verdict() { printf '%s\n' "$*"; exit 0; }

if [ -n "${SELFTEST:-}" ]; then
  fail=0
  proef() { # <verwacht-prefix> <omschrijving> <diff>
    local want="$1" desc="$2" inhoud="$3" tmp uit
    tmp="$(mktemp)"; printf '%s' "$inhoud" > "$tmp"
    uit="$(bash "$0" --diff "$tmp" 2>/dev/null)"; rm -f "$tmp"
    case "$uit" in
      "$want"*) printf '  \xe2\x9c\x85 %s\n' "$desc" ;;
      *) printf '  \xe2\x9d\x8c %s → %s\n' "$desc" "$uit"; fail=1 ;;
    esac
  }
  echo "sensitive-paths-guard (deFleet) --self-test"
  proef "CLEAN:" "alleen documentatie" "diff --git a/docs/gitflow.md b/docs/gitflow.md
"
  proef "CLEAN:" "een README" "diff --git a/README.md b/README.md
"
  proef "CLEAN:" "een voorbeeldbestand" "diff --git a/examples/x.yml b/examples/x.yml
"
  # De kern: alles wat de machinerie raakt wacht op een mens. Een wijziging hier verandert het
  # gedrag van vijf repo's tegelijk.
  proef "FORCE-APPROVAL:" "een workflow" "diff --git a/.github/workflows/auto-merge.yml b/.github/workflows/auto-merge.yml
"
  proef "FORCE-APPROVAL:" "een script" "diff --git a/scripts/autonomie-beslis.sh b/scripts/autonomie-beslis.sh
"
  proef "FORCE-APPROVAL:" "de routing" "diff --git a/routing.yml b/routing.yml
"
  proef "FORCE-APPROVAL:" "het eigen contract" "diff --git a/.fleet.yml b/.fleet.yml
"
  proef "FORCE-APPROVAL:" "deze guard zelf" "diff --git a/scripts/sensitive-paths-guard.sh b/scripts/sensitive-paths-guard.sh
"
  proef "FORCE-APPROVAL:" "onbekend toplevel-pad" "diff --git a/geen-idee.xyz b/geen-idee.xyz
"
  # Gemengd: één gevoelig pad besmet de hele PR. Anders kun je een workflow-wijziging verstoppen
  # achter een documentatiewijziging.
  proef "FORCE-APPROVAL:" "docs + workflow gemengd" "diff --git a/docs/x.md b/docs/x.md
diff --git a/.github/workflows/y.yml b/.github/workflows/y.yml
"
  # Een PURE HERNOEMING heeft geen +++/---regels. Wie daar alleen op leest ziet een lege diff, en
  # een lege diff die CLEAN oplevert is de fail-open waar dit script tegen bestaat (Portfolio#216).
  proef "FORCE-APPROVAL:" "hernoemd naar .github/" "diff --git a/docs/x.md b/.github/workflows/nieuw.yml
similarity index 100%
rename from docs/x.md
rename to .github/workflows/nieuw.yml
"
  proef "FORCE-APPROVAL:" "lege diff" ""
  echo
  [ "$fail" -eq 0 ] && echo "✅ alle asserties groen" || echo "❌ er faalden asserties"
  exit "$fail"
fi

[ -n "$diff_file" ] || verdict "FORCE-APPROVAL: geen --diff meegegeven — bij twijfel beslist een mens."
[ -r "$diff_file" ] || verdict "FORCE-APPROVAL: diff '$diff_file' niet leesbaar — bij twijfel beslist een mens."

# --- Paden uit de diff ------------------------------------------------------------------------
# BEIDE KANTEN van `diff --git a/X b/Y`, plus de rename-regels en de +++/---headers. Een pure
# hernoeming levert alléén de eerste twee op; wie daar niet op leest ziet zo'n diff als leeg.
paden="$(
  {
    grep -E '^diff --git a/' "$diff_file" | sed -E 's#^diff --git a/##; s# b/.*$##'
    grep -E '^diff --git a/' "$diff_file" | sed -E 's#^diff --git .* b/##'
    grep -E '^rename (from|to) ' "$diff_file" | sed -E 's#^rename (from|to) ##'
    grep -E '^(\+\+\+ b/|--- a/)' "$diff_file" | sed -E 's#^(\+\+\+ b/|--- a/)##'
  } 2>/dev/null | grep -v '^/dev/null$' | grep -v '^$' | sort -u
)"

# Een lege padenlijst betekent niet "niets gevoeligs" maar "ik heb deze diff niet begrepen".
[ -n "$paden" ] || verdict "FORCE-APPROVAL: geen bestandspaden uit de diff te lezen — bij twijfel beslist een mens."

geraakt=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  [ "$(classificeer "$p")" = gevoelig ] && { geraakt="$p"; break; }
done <<< "$paden"

aantal="$(printf '%s\n' "$paden" | grep -c .)"
if [ -n "$geraakt" ]; then
  verdict "FORCE-APPROVAL: raakt de machinerie ($geraakt) — een wijziging hier verandert het gedrag van elke consument. ${aantal} bestand(en) beoordeeld."
fi
verdict "CLEAN: uitsluitend documentatie of voorbeelden (${aantal} bestand(en) beoordeeld)."
