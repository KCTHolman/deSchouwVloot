#!/usr/bin/env bash
# Tests voor scripts/fleet-doctor.sh, module `consistentie` (I1/I2/I5/I7).
#
# Alleen de bestandsgebaseerde module is offline testbaar; `spine` en `runners` bevragen de
# GitHub-API en worden in CI op de echte repo's gedraaid. Elke test bouwt een wegwerp-repo in
# /tmp met precies één afwijking, zodat een fout ondubbelzinnig aan één invariant hangt.
#
# Lokaal: bash scripts/fleet-doctor.test.sh

set -uo pipefail
cd "$(dirname "$0")/.."
DOCTOR="$PWD/scripts/fleet-doctor.sh"

fail=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fail=1; }

# mkrepo <dir> <is_fleet 0|1> — kaal repo-skelet
mkrepo() {
  local d="$1" fleet="$2"
  mkdir -p "$d/.github/workflows"
  if [ "$fleet" = 1 ]; then
    mkdir -p "$d/docs"; : > "$d/docs/architectuur.md"; : > "$d/routing.yml"
  fi
}

# run <dir> → print uitvoer, zet $rc
run() { out="$(bash "$DOCTOR" --module consistentie --root "$1" 2>&1)"; rc=$?; }

# verwacht_schoon <naam> <dir>
verwacht_schoon() {
  run "$2"
  if [ "$rc" = 0 ]; then ok "$1"; else bad "$1 (verwacht exit 0, kreeg $rc)"; printf '%s\n' "$out" | sed 's/^/      /'; fi
}

# verwacht_fout <naam> <dir> <patroon>
verwacht_fout() {
  run "$2"
  if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "$3"; then
    ok "$1"
  else
    bad "$1 (verwacht exit!=0 met /$3/, kreeg $rc)"; printf '%s\n' "$out" | sed 's/^/      /'
  fi
}

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

echo "fleet-doctor · I1 (alleen workflow_call in fleet):"

mkrepo "$T/i1ok" 1
printf 'name: "[fleet] x"\non:\n  workflow_call:\n    inputs: {}\njobs: {}\n' > "$T/i1ok/.github/workflows/x.yml"
printf 'name: "[fleet] Intake"\non:\n  issues:\n    types: [opened]\njobs: {}\n' > "$T/i1ok/.github/workflows/intake.yml"
verwacht_schoon "workflow_call + intake-uitzondering => schoon" "$T/i1ok"

mkrepo "$T/i1bad" 1
printf 'name: "[fleet] y"\non:\n  schedule:\n    - cron: "0 5 * * *"\njobs:\n  werk:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hoi\n' > "$T/i1bad/.github/workflows/y.yml"
verwacht_fout "eigen LOGICA met eigen trigger in fleet => I1-fout" "$T/i1bad" "I1:"

mkrepo "$T/i1cons" 0
printf 'name: "PR check"\non:\n  pull_request:\n    branches: [main]\njobs: {}\n' > "$T/i1cons/.github/workflows/pr.yml"
verwacht_schoon "consument mag eigen triggers => geen I1" "$T/i1cons"

# deFleet is z'n eigen consument: dunne CALLERS met eigen triggers zijn juist de bedoeling.
# Alleen eigen LOGICA (steps/runs-on) met een eigen trigger is fout.
mkrepo "$T/i1caller" 1
printf 'name: "[fleet] doctor (caller)"\non:\n  schedule:\n    - cron: "0 6 * * *"\njobs:\n  d:\n    uses: KCTHolman/fleet/.github/workflows/doctor.yml@main\n' > "$T/i1caller/.github/workflows/dc.yml"
printf 'name: "[fleet] doctor"\non:\n  workflow_call: {}\njobs: {}\n' > "$T/i1caller/.github/workflows/doctor.yml"
verwacht_schoon "pure caller in fleet met eigen trigger => geen I1" "$T/i1caller"

echo "fleet-doctor · I2 (fleet-verwijzing wijst naar bestaand pad):"

mkrepo "$T/i2ok" 1
printf 'name: "[fleet] pick"\non:\n  workflow_call: {}\njobs: {}\n' > "$T/i2ok/.github/workflows/pick-runner.yml"
printf 'name: "[fleet] caller"\non:\n  workflow_call: {}\njobs:\n  p:\n    uses: KCTHolman/fleet/.github/workflows/pick-runner.yml@main\n' > "$T/i2ok/.github/workflows/c.yml"
verwacht_schoon "verwijzing naar bestaand pad => schoon" "$T/i2ok"

mkrepo "$T/i2bad" 1
printf 'name: "[fleet] caller"\non:\n  workflow_call: {}\njobs:\n  p:\n    uses: KCTHolman/fleet/.github/workflows/bestaat-niet.yml@main\n' > "$T/i2bad/.github/workflows/c.yml"
verwacht_fout "verwijzing naar ontbrekend pad => I2-fout" "$T/i2bad" "I2:"

echo "fleet-doctor · I5 (geen geneste container op de agent-lane):"

mkrepo "$T/i5ok" 0
printf 'name: "review"\non:\n  pull_request: {}\njobs:\n  r:\n    runs-on: biohack-agent\n    steps: []\n' > "$T/i5ok/.github/workflows/r.yml"
verwacht_schoon "agent-lane zonder container => schoon" "$T/i5ok"

mkrepo "$T/i5bad" 0
printf 'name: "review"\non:\n  pull_request: {}\njobs:\n  r:\n    runs-on: biohack-agent\n    container:\n      image: ubuntu:24.04\n    steps: []\n' > "$T/i5bad/.github/workflows/r.yml"
verwacht_fout "agent-lane MET container => I5-fout" "$T/i5bad" "I5:"

# De twee vals-positieven die de eerste echte run opleverde (pr-check.yml / analysis-ci.yml):
# `biohack-agent` staat er alleen in een COMMENT die uitlegt dat die lane juist niet gebruikt
# wordt, en de container zit in een ANDERE job. Per bestand checken vlagt dit; per job niet.
mkrepo "$T/i5fp" 0
printf 'name: "check"\non:\n  pull_request: {}\njobs:\n  licht:\n    # NIET biohack-agent: die lane is de sessie-mutex\n    runs-on: biohack-light\n    container:\n      image: ubuntu:24.04\n    steps: []\n  agent:\n    runs-on: biohack-agent\n    steps: []\n' > "$T/i5fp/.github/workflows/c.yml"
verwacht_schoon "comment + container in ANDERE job => geen I5 (vals-positief)" "$T/i5fp"

mkrepo "$T/i5ov" 0
printf 'name: "review"\non:\n  pull_request: {}\njobs:\n  r:\n    runs-on: ${{ vars.RUNNER_OVERRIDE_AGENT || needs.pick.outputs.runner }}\n    container:\n      image: ubuntu:24.04\n    steps: []\n' > "$T/i5ov/.github/workflows/r.yml"
verwacht_fout "agent-lane via override-variabele MET container => I5-fout" "$T/i5ov" "I5:"

echo "fleet-doctor · I7 (workflow_run-patronen bestaan én matchen):"

# Zonder metatekens is patroon == naam; niets te escapen.
mkrepo "$T/i7plain" 0
printf 'name: "PR check"\non:\n  pull_request: {}\njobs: {}\n' > "$T/i7plain/.github/workflows/pr-check.yml"
printf 'name: "Auto-merge"\non:\n  workflow_run:\n    workflows: ["PR check"]\njobs: {}\n' > "$T/i7plain/.github/workflows/am.yml"
verwacht_schoon "naam zonder metatekens => schoon" "$T/i7plain"

# DE ECHTE BUG (2026-07-27 21:22 UTC → 10 uur stille spine). Byte-voor-byte dezelfde naam, en
# tóch nul triggers: `[shared]` is een character class, geen letterlijke tekst.
mkrepo "$T/i7glob" 0
printf 'name: "[shared] PR check"\non:\n  pull_request: {}\njobs: {}\n' > "$T/i7glob/.github/workflows/pr-check.yml"
printf 'name: "[fleet] Auto-merge"\non:\n  workflow_run:\n    workflows: ["[shared] PR check"]\njobs: {}\n' > "$T/i7glob/.github/workflows/am.yml"
verwacht_fout "ongeëscapete blokhaken => I7-fout (matcht nooit)" "$T/i7glob" "I7:"

# Geëscaped in ENKELE quotes: dit is de vorm die wél matcht.
mkrepo "$T/i7esc" 0
printf 'name: "[shared] PR check"\non:\n  pull_request: {}\njobs: {}\n' > "$T/i7esc/.github/workflows/pr-check.yml"
printf "name: \"[fleet] Auto-merge\"\non:\n  workflow_run:\n    workflows: ['\\\\[shared\\\\] PR check']\njobs: {}\n" > "$T/i7esc/.github/workflows/am.yml"
verwacht_schoon "geëscapete blokhaken => schoon" "$T/i7esc"

# Andere metatekens uit dezelfde glob-familie mogen niet door de mazen glippen.
mkrepo "$T/i7star" 0
printf 'name: "Deploy * prod"\non:\n  pull_request: {}\njobs: {}\n' > "$T/i7star/.github/workflows/d.yml"
printf 'name: "Na-deploy"\non:\n  workflow_run:\n    workflows: ["Deploy * prod"]\njobs: {}\n' > "$T/i7star/.github/workflows/n.yml"
verwacht_fout "ongeëscapete asterisk => I7-fout" "$T/i7star" "I7:"

mkrepo "$T/i7bad" 0
printf 'name: "[shared] PR check"\non:\n  pull_request: {}\njobs: {}\n' > "$T/i7bad/.github/workflows/pr-check.yml"
printf "name: \"[fleet] Auto-merge\"\non:\n  workflow_run:\n    workflows: ['\\\\[oud\\\\] PR check']\njobs: {}\n" > "$T/i7bad/.github/workflows/am.yml"
verwacht_fout "workflow_run-naam na rename => I7-fout" "$T/i7bad" "I7:"

echo "fleet-doctor · contract (.fleet.yml):"

runc() { out="$(bash "$DOCTOR" --module contract --root "$1" 2>&1)"; rc=$?; }

mkrepo "$T/cgeen" 0
runc "$T/cgeen"
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "geen .fleet.yml"; then
  ok "geen .fleet.yml => waarschuwing, geen harde fout"
else
  bad "geen .fleet.yml (verwacht exit 0 + waarschuwing, kreeg $rc)"
fi

mkrepo "$T/cgoed" 0
cp .fleet.yml "$T/cgoed/.fleet.yml"
runc "$T/cgoed"
[ "$rc" = 0 ] && ok "geldig contract => schoon" || { bad "geldig contract (exit $rc)"; printf '%s\n' "$out" | sed 's/^/      /'; }

mkrepo "$T/cfout" 0
sed 's/^lanes:/lanez:/' .fleet.yml > "$T/cfout/.fleet.yml"
runc "$T/cfout"
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "contract:"; then
  ok "typefout in contract => harde fout"
else
  bad "typefout in contract (verwacht exit!=0, kreeg $rc)"; printf '%s\n' "$out" | sed 's/^/      /'
fi

echo "fleet-doctor · I27 (liveness — reageert de luisteraar op z'n bron?):"

# De pure beslisser draait zonder netwerk en zonder klok: bron-epoch, luisteraar-epoch, speling.
oordeel() { bash "$DOCTOR" --module liveness-oordeel --repo "$1 $2 $3" 2>/dev/null | head -1; }
verwacht_oordeel() {
  local naam="$1" got; got="$(oordeel "$2" "$3" "$4")"
  [ "$got" = "$5" ] && ok "$naam" || bad "$naam (kreeg '$got', verwacht '$5')"
}

# DE ECHTE CASUS: PR check liep om 07:21, auto-merge had z'n laatste workflow_run-run de avond
# ervoor om 21:06. Tien uur ertussen — een absolute ouderdomsdrempel van dagen ziet dit niet.
verwacht_oordeel "bron 10u na laatste reactie => verouderd" 1000000 964000 1800 verouderd
verwacht_oordeel "luisteraar reageerde => levend"       1000000 999100 1800 levend
# Bron NET klaar, luisteraar nog niet begonnen: dat is normaal en mag geen vals alarm geven.
verwacht_oordeel "bron binnen de speling => levend"     1000000 999000 1800 levend
verwacht_oordeel "net buiten de speling => verouderd"   1000000 998100 1800 verouderd
# Vers toegevoegde luisteraar: zichtbaar maken, niet blokkeren (zie de rationale in het script).
verwacht_oordeel "nog nooit gedraaid => zacht, niet hard" 1000000 0 1800 nooit
verwacht_oordeel "bron heeft nooit gedraaid => geen oordeel" 0 0 1800 geen-bron

# De pure beslisser dekt de RÉKENREGEL, niet de bedrading eromheen: het uitlezen van de
# workflow_run-lijst, het unescapen, en het terugvertalen van een naam naar een bestandspad. Die
# keten heeft z'n eigen faalmodi, dus draait 'ie hier één keer echt — tegen een nagemaakte `gh`,
# zodat de test offline blijft.
echo "fleet-doctor · I27 (bedrading, met nagemaakte gh):"

# De nagemaakte `gh` past de meegegeven `--jq` met de ECHTE jq toe (zie hieronder). `gh` heeft z'n
# eigen jq ingebouwd, dus de doctor zélf heeft de binary niet nodig — deze test wel. Ontbreekt-ie,
# dan overslaan i.p.v. falen: zelfde regel als bij de andere gereedschap-guards, ontbrekend
# gereedschap is geen bevinding. Op ubuntu-latest (waar CI draait) staat jq voorgeïnstalleerd.
if ! command -v jq >/dev/null 2>&1; then
  printf '  \xe2\x9a\xa0\xef\xb8\x8f  overgeslagen: jq ontbreekt (alleen de bedradingstests, niet de rekenregel hierboven)\n'
else

mkrepo "$T/i27" 0
printf 'name: "[shared] PR check"\non:\n  pull_request: {}\njobs: {}\n' > "$T/i27/.github/workflows/pr-check.yml"
printf "name: \"[fleet] Auto-merge\"\non:\n  workflow_run:\n    workflows: ['\\\\[shared\\\\] PR check']\njobs: {}\n" > "$T/i27/.github/workflows/auto-merge.yml"

mkdir -p "$T/i27bin"
# De nagemaakte `gh` geeft een fixture-JSON terug en past de meegegeven `--jq` er ECHT op toe (met
# de echte jq). Zo staat de jq-expressie uit het script zélf onder test — niet alleen de bedrading
# eromheen. Dat is precies wat nodig is voor de actor-filter hieronder: die zit in de jq.
cat > "$T/i27bin/gh" <<'STUB'
#!/usr/bin/env bash
q=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) q="$2"; shift 2 ;;
    api)  shift ;;
    *)    url="$1"; shift ;;
  esac
done
case "$url" in
  *"workflows/pr-check.yml/runs"*)   printf '%s' "$BRON_JSON"       | jq -r "$q" ;;
  *"workflows/auto-merge.yml/runs"*) printf '%s' "$LUISTERAAR_JSON" | jq -r "$q" ;;
esac
exit 0
STUB
chmod +x "$T/i27bin/gh"

# Standaard-bron: één voltooide run, door een mens aangezwengeld — die kán dus een event afgeven.
BRON_STD='{"workflow_runs":[{"created_at":"2026-07-28T07:21:00Z","actor":{"login":"KCTHolman"}}]}'

# i27run <laatste-workflow_run-run-van-de-luisteraar> [bron-json] → zet $out en $rc
i27run() {
  local ljson='{"workflow_runs":[]}'
  [ -n "$1" ] && ljson="$(printf '{"workflow_runs":[{"created_at":"%s"}]}' "$1")"
  out="$(PATH="$T/i27bin:$PATH" BRON_JSON="${2:-$BRON_STD}" LUISTERAAR_JSON="$ljson" \
         bash "$DOCTOR" --module liveness --repo x/y --root "$T/i27" 2>&1)"
  rc=$?
}

# DE ECHTE CASUS: PR check liep vanochtend, auto-merge reageerde voor het laatst tien dagen terug.
i27run "2026-07-18T14:10:00Z"
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "NIET gereageerd"; then
  ok "bron liep, luisteraar niet => harde bevinding"
else
  bad "dode trigger niet gevangen (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/      /'
fi

i27run "2026-07-28T07:23:00Z"
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "alle 1"; then
  ok "luisteraar reageerde => schoon"
else
  bad "gezonde trigger als kapot gelezen (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/      /'
fi

# Vers toegevoegd: zichtbaar, maar niet blokkerend — en de slotregel mag z'n eigen ⚠️ niet
# tegenspreken met "alle luisteraars reageren".
i27run ""
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "nog NOOIT" && printf '%s' "$out" | grep -q "0 van 1"; then
  ok "nog nooit gedraaid => ⚠️ en een slotregel die dat niet tegenspreekt"
else
  bad "verse luisteraar verkeerd gerapporteerd (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/      /'
fi

# EEN GESMOORDE BRON-RUN IS GEEN BRON. GitHub's recursie-slot laat een run die met de GITHUB_TOKEN
# is aangezwengeld (actor `github-actions[bot]`) géén vervolg-events afgeven; de luisteraar kán daar
# dus niet op reageren. Nieuwste run is zo'n gesmoorde dispatch, daarvóór een echte waar de
# luisteraar wél op reageerde => levend, geen vals alarm. Dit is de storing die I27 permanent hard
# rood zette in BiohackOS (2026-08-01) en zo de merge-poort dichthield.
i27run "2026-07-28T07:23:00Z" '{"workflow_runs":[
  {"created_at":"2026-07-29T09:00:00Z","actor":{"login":"github-actions[bot]"}},
  {"created_at":"2026-07-28T07:21:00Z","actor":{"login":"claude[bot]"}}]}'
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "alle 1"; then
  ok "GITHUB_TOKEN-dispatch telt niet als bron => geen vals alarm"
else
  bad "vals alarm op een bron-run die geen event kón afgeven (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/      /'
fi

# De keerzijde: de filter mag een ECHTE dode trigger niet wegpoetsen. Nieuwste bruikbare bron-run
# is door een mens gestart en de luisteraar zweeg => nog steeds hard rood.
i27run "2026-07-18T14:10:00Z" '{"workflow_runs":[
  {"created_at":"2026-07-29T09:00:00Z","actor":{"login":"github-actions[bot]"}},
  {"created_at":"2026-07-28T07:21:00Z","actor":{"login":"KCTHolman"}}]}'
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "NIET gereageerd"; then
  ok "filter poetst een echte dode trigger niet weg"
else
  bad "dode trigger gemist door de actor-filter (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/      /'
fi

# EEN BRON-RUN DIE NÉT IS AFGEROND TELT NOG NIET. De reactie kan dan nog in de maak zijn, en die
# stilte als dode trigger lezen is vals alarm — gemeten 2026-08-01: twee seconden tussen het
# afronden van feature-governance en het ontstaan van de auto-merge-run erop. Nieuwste run rondde
# zojuist af (valt af), de oudere bron eronder telt en dáár reageerde de luisteraar op.
vers="$(date -u -d '-10 seconds' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
i27run "2026-07-28T07:23:00Z" "$(printf '{"workflow_runs":[
  {"created_at":"%s","updated_at":"%s","actor":{"login":"KCTHolman"}},
  {"created_at":"2026-07-28T07:21:00Z","updated_at":"2026-07-28T07:21:30Z","actor":{"login":"KCTHolman"}}]}' "$vers" "$vers")"
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "alle 1"; then
  ok "net afgeronde bron-run telt nog niet => geen vals alarm op de race"
else
  bad "vals alarm op een bron-run die net klaar was (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/      /'
fi

fi # einde jq-guard (I27-bedrading)

echo "fleet-doctor · I28 (consument-side afhankelijkheden van een station):"

# Een fleet-station draait in de werkmap van de CONSUMENT. Roept het daar `scripts/foo.sh` aan,
# dan is dat een harde eis aan die consument die nergens als eis opgeschreven staat. Met één
# consument valt dat nooit op. Gevonden 2026-07-28: `auto-merge` eist
# `scripts/sensitive-paths-guard.sh`, en InvestingOS heeft dat niet — het station zou daar netjes
# fail-closed draaien en dus NOOIT mergen, zonder dat er iets rood wordt. Een station dat per
# constructie altijd hetzelfde antwoord geeft, ziet er van buiten uit als een werkende check.
mkrepo "$T/i28fleet" 1
printf 'name: "[fleet] station"\non:\n  workflow_call: {}\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bash scripts/nodig.sh --diff d\n' > "$T/i28fleet/.github/workflows/station.yml"

mkrepo "$T/i28mis" 0
printf 'name: caller\non:\n  pull_request: {}\njobs:\n  c:\n    uses: KCTHolman/fleet/.github/workflows/station.yml@main\n' > "$T/i28mis/.github/workflows/c.yml"

out="$(bash "$DOCTOR" --module afhankelijkheden --root "$T/i28mis" --fleet-root "$T/i28fleet" 2>&1)"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "I28"; then
  ok "station eist een script dat de consument mist => harde bevinding"
else
  bad "ontbrekend consument-script niet gevangen (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/      /'
fi

mkdir -p "$T/i28mis/scripts"; : > "$T/i28mis/scripts/nodig.sh"
out="$(bash "$DOCTOR" --module afhankelijkheden --root "$T/i28mis" --fleet-root "$T/i28fleet" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then ok "script aanwezig => schoon"; else bad "vals-positief (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/      /'; fi

# De fleet-checkout van het station zelf (`.fleet-doctor/scripts/...`) is GEEN eis aan de
# consument. Zonder die uitzondering zou elke doctor-caller vals alarm geven.
mkrepo "$T/i28eigen" 1
printf 'name: "[fleet] d"\non:\n  workflow_call: {}\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bash .fleet-doctor/scripts/fleet-doctor.sh --module consistentie\n' > "$T/i28eigen/.github/workflows/d.yml"
mkrepo "$T/i28c2" 0
printf 'name: caller\non:\n  schedule:\n    - cron: "0 6 * * *"\njobs:\n  c:\n    uses: KCTHolman/fleet/.github/workflows/d.yml@main\n' > "$T/i28c2/.github/workflows/c.yml"
bash "$DOCTOR" --module afhankelijkheden --root "$T/i28c2" --fleet-root "$T/i28eigen" >/dev/null 2>&1
if [ $? = 0 ]; then ok "fleet's eigen checkout telt niet als consument-eis"; else bad "vals-positief op .fleet-doctor/-pad"; fi

# Zonder fleet-checkout kun je de eis niet lezen: waarschuwen, niet hard falen — anders wordt een
# ontbrekend gereedschap als een bevinding gelezen (zelfde regel als bij de jq-guard).
bash "$DOCTOR" --module afhankelijkheden --root "$T/i28mis" >/dev/null 2>&1
if [ $? = 0 ]; then ok "geen --fleet-root => waarschuwing, geen harde fout"; else bad "ontbrekende fleet-root zou zacht moeten zijn"; fi

echo "fleet-doctor · I30 (bestaan de contractlabels echt?):"

# `.fleet.yml` heeft een VERPLICHTE `labels:`-sectie die tot 2026-08-23 door geen enkel station
# werd gelezen: gevalideerd, afgedwongen, decoratief. De sectie draagt wel een echte belofte —
# labels reizen niet mee bij een issue-transfer, dus de doelrepo moet ze zelf hebben. Die garantie
# hing aan `ensure-labels.sh`, dat in één van de vijf consumenten bestaat met nul aanroepers.
#
# Zonder `--repo` is er niets te zien: dan waarschuwen, niet falen (zelfde regel als I28 zonder
# --fleet-root). Alleen die tak is offline testbaar; de API-tak draait in CI op de echte repo's.
mkrepo "$T/i30" 0
printf 'version: 1\nlanes:\n  agent: ubuntu-latest\n  heavy: ubuntu-latest\n  light: ubuntu-latest\n  fallback: ubuntu-latest\ngates:\n  feature_approval: false\nbudgets:\n  default_model: claude-sonnet-5\n  max_turns:\n    triage: 20\nlabels:\n  task: fleet-task\n  human: needs-human\n' > "$T/i30/.fleet.yml"
out="$(bash "$DOCTOR" --module contract --root "$T/i30" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "I30.*geen --repo"; then
  ok "geen --repo => waarschuwing, geen harde fout"
else
  bad "I30 zonder --repo zou zacht moeten zijn (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/      /'
fi

# Een contract zonder labels-sectie is (nog) geldig voor de validator noch voor I30 een onderwerp:
# de contractcheck klaagt daar zelf al over, en I30 hoort daar niet overheen te roepen.
mkrepo "$T/i30geen" 0
printf 'version: 1\n' > "$T/i30geen/.fleet.yml"
out="$(bash "$DOCTOR" --module contract --root "$T/i30geen" --repo KCTHolman/bestaat-niet 2>&1)"
if ! printf '%s' "$out" | grep -q "I30"; then
  ok "geen labels-sectie => I30 zwijgt (dat is de contractcheck z'n vraag)"
else
  bad "I30 klaagt over een contract zonder labels-sectie"; printf '%s\n' "$out" | sed 's/^/      /'
fi

echo "fleet-doctor · I29 (spreekt de guard de taal die het station leest?):"

# I28 toetst of het bestand BESTAAT. Dat bleek niet genoeg. InvestingOS' guard bestond, was 282
# regels, had een eigen self-test — en zou tóch nooit een CLEAN opleveren, want hij kende `--diff`
# niet en printte de KALE woorden terwijl auto-merge op `^CLEAN:` grept. Fail-closed dus veilig,
# maar stil en permanent: elke PR wacht op een mens terwijl de machine er werkend uitziet.
#
# Deze tests toetsen de VORM van het oordeel, nooit welk oordeel. Wélke paden gevoelig zijn is
# domeinkennis van de consument; dát er een leesbaar oordeel uit komt, is dat niet.

# guardrepo <map> <regel-die-het-script-print> [--kent-diff]
guardrepo() {
  local d="$1" regel="$2" kent="${3:-}"
  mkrepo "$d" 0
  # I29 hangt onder I28, en die stapt eruit als de repo geen enkel fleet-station aanroept. Een
  # consument zónder callers heeft ook geen station dat z'n guard leest, dus die vraag is daar
  # terecht niet aan de orde. De fixture heeft dus een caller nodig om realistisch te zijn.
  printf 'name: caller\non:\n  pull_request: {}\njobs:\n  c:\n    uses: KCTHolman/fleet/.github/workflows/station.yml@main\n' > "$d/.github/workflows/c.yml"
  mkdir -p "$d/scripts"
  : > "$d/scripts/nodig.sh"   # het script dat het station uit i28fleet eist (I28 zelf schoon houden)
  {
    printf '#!/usr/bin/env bash\n'
    if [ "$kent" = "--kent-diff" ]; then
      printf 'while [ $# -gt 0 ]; do case "$1" in --diff) shift ;; esac; shift; done\n'
    else
      printf 'case "${1:-}" in --diff) echo "onbekende optie --diff" >&2; echo "FORCE-APPROVAL"; exit 0 ;; esac\n'
    fi
    printf '%s\n' "$regel"
  } > "$d/scripts/sensitive-paths-guard.sh"
}

guardrepo "$T/i29goed" 'echo "CLEAN: niets gevoeligs"' --kent-diff
out="$(bash "$DOCTOR" --module afhankelijkheden --root "$T/i29goed" --fleet-root "$T/i28fleet" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "I29.*leesbaar oordeel"; then
  ok "guard die het protocol spreekt => schoon"
else
  bad "vals-positief op een correcte guard (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/      /'
fi

# De echte InvestingOS-vorm: kale woorden zonder dubbele punt.
guardrepo "$T/i29kaal" 'echo "CLEAN"' --kent-diff
out="$(bash "$DOCTOR" --module afhankelijkheden --root "$T/i29kaal" --fleet-root "$T/i28fleet" 2>&1)"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "I29"; then
  ok "kaal 'CLEAN' zonder dubbele punt => harde bevinding"
else
  bad "kale verdict-vorm niet gevangen (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/      /'
fi

# De tweede helft van diezelfde bug: de vlag die het station gebruikt bestaat niet.
guardrepo "$T/i29geendiff" 'echo "CLEAN: niets gevoeligs"'
out="$(bash "$DOCTOR" --module afhankelijkheden --root "$T/i29geendiff" --fleet-root "$T/i28fleet" 2>&1)"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "I29"; then
  ok "guard die --diff niet kent => harde bevinding"
else
  bad "onbekende --diff-vlag niet gevangen (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/      /'
fi

# Een guard die alleen op `+++`/`---` leest, ziet een PURE hernoeming als een lege diff. Eén
# consument gaf daar CLEAN op — je kon er elk bestand ongezien de workflowmap mee in verplaatsen. Deze test
# houdt vast dat een guard óók op die vorm een oordeel moet vellen.
guardrepo "$T/i29ren" 'if grep -q "^+++" "$2" 2>/dev/null; then echo "CLEAN: gezien"; else exit 0; fi' --kent-diff
out="$(bash "$DOCTOR" --module afhankelijkheden --root "$T/i29ren" --fleet-root "$T/i28fleet" 2>&1)"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "pure hernoeming"; then
  ok "guard die stil blijft op een pure hernoeming => harde bevinding"
else
  bad "hernoemings-blindheid niet gevangen (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/      /'
fi

# Geen guard in de repo => I29 zegt niets. Of die er hoort te zijn, is I28's vraag.
mkrepo "$T/i29geen" 0
printf 'name: caller
on:
  pull_request: {}
jobs:
  c:
    uses: KCTHolman/fleet/.github/workflows/station.yml@main
' > "$T/i29geen/.github/workflows/c.yml"
mkdir -p "$T/i29geen/scripts"; : > "$T/i29geen/scripts/nodig.sh"
bash "$DOCTOR" --module afhankelijkheden --root "$T/i29geen" --fleet-root "$T/i28fleet" >/dev/null 2>&1
if [ $? = 0 ]; then ok "geen guard => I29 zwijgt (dat is I28's vraag)"; else bad "I29 klaagt over een repo zonder guard"; fi

# --- I1-REGRESSIE: grote bestanden werden stil overgeslagen -----------------------------------
# `grep -q` sluit de pijp bij de eerste treffer; `sed` krijgt SIGPIPE en onder `set -o pipefail`
# leest de pijplijn dan als "geen match". Bij kleine bestanden is sed al klaar vóór grep afsluit,
# dus de fout was onzichtbaar — juist de GROOTSTE fleet-workflows (auto-merge: 547 regels) glipten
# erdoor. Een I1 die precies de zwaarste stations niet toetst, is een groen vinkje dat niets dekt.
# Vandaar een testbestand met veel regels ná de `runs-on:`-treffer.
mkrepo "$T/i1groot" 1
{
  printf 'name: "[fleet] groot"\non:\n  schedule:\n    - cron: "0 6 * * *"\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hoi\n'
  for i in $(seq 1 800); do printf '      # vulregel %s\n' "$i"; done
} > "$T/i1groot/.github/workflows/groot.yml"
verwacht_fout "I1 ziet ook een GROOT bestand met eigen trigger (SIGPIPE-regressie)" "$T/i1groot" "I1:"

echo "fleet-doctor · pin-oordeel (I24, offline beslisser):"

# po <naam> <verwacht> <gepind> <hoofd> <drempel> <n_refs>
po() {
  local naam="$1" want="$2"; shift 2
  local got; got="$(bash "$DOCTOR" --module pin-oordeel --repo "$*" 2>/dev/null | head -1)"
  if [ "$got" = "$want" ]; then ok "$naam"; else bad "$naam (verwacht '$want', kreeg '$got')"; fi
}

# 1700000000 = referentiemoment; +6 dagen blijft binnen de drempel van 7, +30 niet.
po "verse pin => actueel"                 actueel   1700000000 1700518400 7 1
po "pin van 30 dagen oud => verouderd"    verouderd 1700000000 1702592000 7 1
po "precies op de drempel => actueel"     actueel   1700000000 1700604800 7 1
po "twee verschillende pins => verdeeld"  verdeeld  1700000000 1700100000 7 2
po "verdeeld wint van vers"               verdeeld  1700518400 1700518400 7 3
po "geen pin => ongepind"                 ongepind  0 1700000000 7 0
po "datum onbekend => onbekend"           onbekend  0 1700000000 7 1
po "eigen drempel (60 dagen)"             actueel   1700000000 1702592000 60 1

echo "fleet-doctor · pin-module op bestandsniveau:"

# De kanarie (deFleet zelf) hóórt @main te volgen — daar iets van vinden zou I24 omdraaien.
mkrepo "$T/pinfleet" 1
printf 'name: c\non:\n  push: {}\njobs:\n  c:\n    uses: KCTHolman/fleet/.github/workflows/checks.yml@main\n' > "$T/pinfleet/.github/workflows/c.yml"
out="$(bash "$DOCTOR" --module pin --root "$T/pinfleet" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "kanarie" && printf '%s' "$out" | grep -qF '`@main`'; then
  ok "de kanarie zelf krijgt geen pin-bevinding"
else
  bad "kanarie (rc=$rc): $(printf '%s' "$out" | tr '\n' ' ')"
fi

# Twee verschillende SHA's in één consument = half gelukte bump. Dat is een bestandsfeit, dus
# offline toetsbaar — geen API nodig om te zien dat het er twee zijn.
mkrepo "$T/pinsplit" 0
printf 'jobs:\n  a:\n    uses: KCTHolman/fleet/.github/workflows/x.yml@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$T/pinsplit/.github/workflows/a.yml"
printf 'jobs:\n  b:\n    uses: KCTHolman/fleet/.github/workflows/y.yml@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' > "$T/pinsplit/.github/workflows/b.yml"
out="$(bash "$DOCTOR" --module pin --root "$T/pinsplit" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "VERSCHILLENDE fleet-pins"; then
  ok "twee verschillende pins in één consument => rood"
else
  bad "verdeelde pins (rc=$rc): $(printf '%s' "$out" | tr '\n' ' ')"
fi

# Een consument die geen enkele fleet-workflow aanroept heeft niets te pinnen.
mkrepo "$T/pinleeg" 0
printf 'jobs:\n  a:\n    runs-on: ubuntu-latest\n' > "$T/pinleeg/.github/workflows/a.yml"
out="$(bash "$DOCTOR" --module pin --root "$T/pinleeg" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "niets te pinnen"; then
  ok "geen fleet-aanroepen => niets te melden"
else
  bad "lege consument (rc=$rc): $(printf '%s' "$out" | tr '\n' ' ')"
fi

echo "fleet-doctor · echte repo's:"

run "."
if [ "$rc" = 0 ]; then ok "deze fleet-repo is schoon"; else bad "deze fleet-repo heeft bevindingen"; printf '%s\n' "$out" | sed 's/^/      /'; fi

if [ "$fail" = 0 ]; then
  echo "✅ alle fleet-doctor-tests groen"
else
  echo "❌ fleet-doctor-tests faalden"
fi
exit "$fail"
