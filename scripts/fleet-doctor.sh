#!/usr/bin/env bash
# fleet-doctor.sh — machine-checkbare invarianten uit docs/gitflow.md §11.
#
# HARD RAPPORTEREN, NOOIT MUTEREN. Mutaties horen bij de watchdog (repo-scope) of bij de eigenaar
# (host/settings). Deze doctor stelt alleen vast en zegt het luid — dat is precies wat er ontbrak
# toen `auto-merge` tien dagen uitgeschakeld bleek zonder dat iets het meldde (I25).
#
# Gebruik:
#   scripts/fleet-doctor.sh --module consistentie [--root .] [--fleet-repo KCTHolman/fleet]
#   scripts/fleet-doctor.sh --module spine        --repo <owner/naam> [--spine "a.yml,b.yml"]
#   scripts/fleet-doctor.sh --module runners      --repo <owner/naam>
#   scripts/fleet-doctor.sh --module liveness     --repo <owner/naam> [--grace-min 30]
#   scripts/fleet-doctor.sh --module pin          [--root .] [--pin-drempel-dagen 7]
#
# `consistentie` is puur bestandsgebaseerd → offline testbaar (fleet-doctor.test.sh). `spine`,
# `runners` en `liveness` bevragen de GitHub-API en hebben `gh` + GH_TOKEN nodig; van `liveness`
# is de beslislogica wél offline getest via de verborgen module `liveness-oordeel`.
#
# Exit-code: 0 = geen harde bevindingen · 1 = minstens één ❌ · 2 = gebruiksfout.
# ⚠️-regels zijn advies en beïnvloeden de exit-code NIET (les uit runner-maintenance.sh: een
# healthy host mag nooit als kapot lezen).

set -uo pipefail

module=""
root="."
repo=""
fleet_repo="KCTHolman/fleet"
fleet_root=""
spine_list="auto-merge.yml,pr-check.yml,epic-orchestrator.yml,reconciler-cron.yml"
# Speling tussen "de bron is klaar" en "de luisteraar is begonnen". Ruim genoeg dat een run die
# NET voltooide geen vals alarm geeft, krap genoeg dat een dode trigger binnen het uur opvalt.
grace_min=30
# Hoeveel dagen een consument-pin achter fleet's hoofd mag lopen vóór het een harde bevinding is
# (I24). Bewust ruim: de bump-baan opent per nieuwe groene canary-commit een PR, dus zeven dagen
# achterstand betekent niet "er is iets nieuwers" maar "die baan komt er al een week niet doorheen".
pin_drempel=7

die() { echo "✋ fleet-doctor: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --module)     shift; module="${1:-}" ;;
    --root)       shift; root="${1:-}" ;;
    --repo)       shift; repo="${1:-}" ;;
    --fleet-repo) shift; fleet_repo="${1:-}" ;;
    --spine)      shift; spine_list="${1:-}" ;;
    --grace-min)  shift; grace_min="${1:-}" ;;
    --pin-drempel-dagen) shift; pin_drempel="${1:-}" ;;
    # Pad naar een checkout van de fleet-repo (I28 leest de eisen uit de stationsdefinities zelf,
    # zodat er geen handmatige lijst is die achterloopt). In doctor.yml is dat `.fleet-doctor`.
    --fleet-root) shift; fleet_root="${1:-}" ;;
    *) die "onbekend argument: $1" ;;
  esac
  shift
done

hard=0
ok()   { printf '  ✅ %s\n' "$1"; }
warn() { printf '  ⚠️  %s\n' "$1"; }
bad()  { printf '  ❌ %s\n' "$1"; hard=$((hard + 1)); }

wf_dir="$root/.github/workflows"

# ---------------------------------------------------------------------------------------------
# MODULE consistentie — I1, I2, I5, I7. Bestandsgebaseerd, geen netwerk.
# ---------------------------------------------------------------------------------------------
module_consistentie() {
  [ -d "$wf_dir" ] || { warn "geen $wf_dir — niets te controleren"; return; }

  local is_fleet=0
  # De fleet-repo herken je aan z'n eigen kaartdocument, niet aan een naam die kan wijzigen.
  [ -f "$root/docs/architectuur.md" ] && [ -f "$root/routing.yml" ] && is_fleet=1

  # --- I1: fleet-workflows hebben uitsluitend workflow_call ---------------------------------
  # Eén benoemde uitzondering: intake.yml (de poort hoort in deFleet's eigen context te draaien;
  # er is per definitie geen consument om als caller op te treden). Elke ANDERE eigen trigger in
  # fleet betekent dat er logica draait die geen consument ziet — bijna altijd een fout.
  #
  # LOGICA vs. CALLER. Sinds deFleet z'n eigen eerste extra consument is (architectuur §3b) staan
  # hier óók dunne callers, en die hóren juist eigen triggers te hebben. De regel gaat dus over
  # LOGICA: een workflow die zelf stappen uitvoert (`steps:`/`runs-on:`) mag in fleet alleen via
  # workflow_call binnenkomen. Een pure caller — alle jobs zijn `uses:`-jobs — is vrij.
  if [ "$is_fleet" = 1 ]; then
    local i1=0
    for f in "$wf_dir"/*.yml; do
      [ -f "$f" ] || continue
      local base; base="$(basename "$f")"
      [ "$base" = "intake.yml" ] && continue

      local triggers; triggers="$(awk '/^on:/{grab=1; next} /^[a-z_]+:/{grab=0} grab' "$f" \
        | grep -oE '^\s{2}[a-z_]+:' | tr -d ' :' | sort -u | tr '\n' ' ')"
      [ -n "$triggers" ] || continue
      [ "$(printf '%s' "$triggers" | tr -d ' ')" = "workflow_call" ] && continue

      # Eigen trigger gevonden — draagt dit bestand eigen logica of is het een pure caller?
      #
      # `grep -c` EN NIET `grep -q` (gevonden 2026-08-16). `-q` stopt bij de eerste treffer en
      # sluit de pijp; `sed` krijgt dan SIGPIPE en de pijplijn eindigt onder `set -o pipefail` op
      # 141 — ook al wás er een match. Het gevolg hier was een I1 die precies bij de GROOTSTE
      # bestanden niets zag: daar heeft sed nog werk liggen als grep al klaar is, bij kleine
      # bestanden niet. Een fleet-workflow met eigen logica én een eigen trigger kon zo groen
      # passeren, en dat is exact de storing die I1 moet vangen. Gevonden doordat een nieuwe check
      # met hetzelfde patroon auto-merge/gitflow-doctor/pr-label oversloeg.
      local heeft_logica
      heeft_logica="$(sed -E 's/(^|[[:space:]])#.*$//' "$f" | grep -cE '^\s{4}(steps:|runs-on:)' || true)"
      if [ "${heeft_logica:-0}" -gt 0 ]; then
        bad "I1: $base draagt eigen logica MÉT eigen trigger ($triggers) — fleet-logica mag alleen workflow_call"
        i1=1
      fi
    done
    [ "$i1" = 0 ] && ok "I1: geen fleet-logica met eigen trigger (callers en intake.yml zijn vrij)"
  fi

  # --- I2: elke fleet-caller wijst naar een bestaand pad -------------------------------------
  # Alleen het PAD wordt hier getoetst (bestandsniveau); of de ref bestaat is een API-vraag en
  # hoort bij de spine-/CI-module. Een typefout in het pad is de vaakst gemaakte fout en faalt
  # anders pas op het moment dat de workflow écht moet draaien.
  local refs i2=0
  refs="$(grep -rhoE "uses:\s*${fleet_repo}/\.github/workflows/[A-Za-z0-9_.-]+\.yml@[A-Za-z0-9_.:/-]+" \
    "$wf_dir" 2>/dev/null | sed -E 's/uses:\s*//' | sort -u)"
  if [ -n "$refs" ]; then
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      local path="${r#*/.github/workflows/}"; path="${path%@*}"
      if [ "$is_fleet" = 1 ] && [ ! -f "$wf_dir/$path" ]; then
        bad "I2: caller wijst naar $path in $fleet_repo, maar dat bestand bestaat daar niet"
        i2=1
      fi
    done <<< "$refs"
    [ "$i2" = 0 ] && ok "I2: alle fleet-verwijzingen ($(printf '%s\n' "$refs" | wc -l | tr -d ' ')) wijzen naar een bestaand pad"
  else
    ok "I2: geen fleet-verwijzingen in deze repo"
  fi

  # --- I5: geen job-level container: op agent-lane-jobs --------------------------------------
  # De agent-lane draait al in z'n eigen wegwerp-container zonder docker-daemon; een geneste
  # container vereist docker-in-docker en faalt hard in "Set up job" (geverifieerd 2026-07-27,
  # runs 30299332620 / 30302579462). Dit is de duurste storing om te herkennen, want de fout
  # noemt de oorzaak niet.
  #
  # PER JOB, NIET PER BESTAND — en met commentaar eruit. Deze fout is hier al eens gemaakt
  # (zie de "WAAROM PER JOB"-kop in check-fleet-config.sh van de consument) en meteen weer bij
  # de eerste echte run van deze doctor: `pr-check.yml` en `analysis-ci.yml` noemen
  # `biohack-agent` uitsluitend in een comment die uitlegt dat ze die lane juist NIET gebruiken,
  # terwijl hun `container:` in een heel andere job zit. Bestandsniveau geeft daar twee
  # vals-positieven; een vals-positief in een harde check is erger dan geen check, want het
  # leert mensen de uitkomst te negeren.
  local i5=0 i5_out
  for f in "$wf_dir"/*.yml; do
    [ -f "$f" ] || continue
    i5_out="$(sed -E 's/(^|[[:space:]])#.*$//' "$f" | awk '
      # Job-sleutels staan op 2 spaties, job-eigenschappen op 4.
      /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
        if (job != "" && agent && container) print job
        job=$0; sub(/^  /, "", job); sub(/:[[:space:]]*$/, "", job)
        agent=0; container=0; next
      }
      /^    container:/ { container=1 }
      # Agent-lane-signaal in de job ZELF: expliciet label of de agent-override-variabele.
      /^    runs-on:.*(biohack-agent|RUNNER_OVERRIDE_AGENT)/ { agent=1 }
      /^      runner_label:[[:space:]]*biohack-agent/ { agent=1 }
      END { if (job != "" && agent && container) print job }
    ')"
    if [ -n "$i5_out" ]; then
      while IFS= read -r j; do
        [ -n "$j" ] && bad "I5: $(basename "$f") · job '$j' draait op de agent-lane MÉT job-level container:"
      done <<< "$i5_out"
      i5=1
    fi
  done
  [ "$i5" = 0 ] && ok "I5: geen geneste container: op agent-lane-jobs"

  # --- I7: elke naam in een workflow_run-lijst BESTAAT én MATCHT ------------------------------
  # workflow_run matcht op NAAM. Een rename elders breekt de trigger stil — precies wat de
  # prefix-migratie van 2026-07-27 had kunnen doen als de lijsten niet mee waren gegaan.
  #
  # ...en precies wat er op 2026-07-27 21:22 UTC wél gebeurde, op een manier die de eerste versie
  # van deze check niet zag. De lijsten gíngen mee: `workflows: ["[shared] PR check"]` was
  # byte-voor-byte gelijk aan de geregistreerde naam, dus "de naam bestaat" was waar en I7 stond
  # groen. Toch vuurde de hele spine 10 uur lang niet, zonder één foutmelding.
  #
  # De reden: dit veld is geen letterlijke string maar een FILTERPATROON, met dezelfde glob-syntax
  # als `branches:`. `[shared]` is daarin een character class — één teken uit {s,h,a,r,e,d}. Het
  # patroon matcht dus namen als "s PR check" en nooit de naam die er letterlijk staat. Voor een
  # letterlijke match moet elk speciaal teken (`[ ] * ? + !`) met `\` geëscaped worden, en dat
  # moet in YAML in ENKELE quotes staan — in dubbele quotes is `\[` een ongeldige escape.
  #
  # Vandaar twee toetsen per patroon: bestaat de naam (na het weghalen van de escapes), en blijft
  # er een ONgeëscaped metateken over dat de match stilletjes sloopt.
  local names i7=0
  names="$(grep -hoE '^name:\s*.*' "$wf_dir"/*.yml 2>/dev/null | sed -E 's/^name:\s*//; s/^"//; s/"$//' | sort -u)"
  local listed
  listed="$(grep -rhoE '^\s*workflows:\s*\[.*\]' "$wf_dir" 2>/dev/null \
    | sed -E 's/^\s*workflows:\s*\[//; s/\]\s*$//' \
    | tr ',' '\n' | sed -E "s/^\s*//; s/\s*$//; s/^[\"']//; s/[\"']$//" | grep -v '^$' | sort -u)"
  if [ -n "$listed" ]; then
    local lit rest
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      # De letterlijke naam achter het patroon: haal de escapes eruit (`\[` → `[`).
      lit="$(printf '%s' "$n" | sed -E 's/\\(.)/\1/g')"
      if ! printf '%s\n' "$names" | grep -qxF "$lit"; then
        bad "I7: workflow_run verwijst naar \"$lit\", maar geen enkele workflow heet zo"
        i7=1
        continue
      fi
      # Wat overblijft ná het wegstrepen van alle `\X`-paren zijn de ONgeëscapete tekens.
      rest="$(printf '%s' "$n" | sed -E 's/\\(.)//g')"
      case "$rest" in
        *[][*?+!]*)
          bad "I7: workflow_run-patroon \"$n\" bevat een ongeëscaped glob-teken — dit matcht NOOIT de workflow \"$lit\"; escape ze ('\\[shared\\] …', enkele quotes)"
          i7=1
          ;;
      esac
    done <<< "$listed"
    [ "$i7" = 0 ] && ok "I7: alle workflow_run-patronen ($(printf '%s\n' "$listed" | wc -l | tr -d ' ')) bestaan én matchen letterlijk"
  else
    ok "I7: geen workflow_run-naamlijsten in deze repo"
  fi
}

# ---------------------------------------------------------------------------------------------
# MODULE spine — I25. Een uitgezette motor moet luid melden.
# ---------------------------------------------------------------------------------------------
module_spine() {
  [ -n "$repo" ] || die "--repo is verplicht voor module spine"
  command -v gh >/dev/null || die "gh niet gevonden"

  local states
  states="$(gh api "repos/$repo/actions/workflows" --paginate \
    --jq '.workflows[] | "\(.path)\t\(.state)\t\(.name)"' 2>/dev/null)" \
    || { warn "kon de workflow-lijst van $repo niet ophalen — check overgeslagen"; return; }

  local found=0
  IFS=',' read -ra want <<< "$spine_list"
  for w in "${want[@]}"; do
    w="$(printf '%s' "$w" | tr -d ' ')"
    [ -n "$w" ] || continue
    local line; line="$(printf '%s\n' "$states" | grep -F ".github/workflows/$w	" || true)"
    if [ -z "$line" ]; then
      warn "I25: $w bestaat niet in $repo (verhuisd of hernoemd?)"
      continue
    fi
    found=$((found + 1))
    local state name
    state="$(printf '%s' "$line" | cut -f2)"
    name="$(printf '%s' "$line" | cut -f3)"
    if [ "$state" != "active" ]; then
      bad "I25: \"$name\" ($w) staat $state — de spine draait dus NIET; merges gaan handmatig"
    fi
  done
  [ "$hard" = 0 ] && [ "$found" -gt 0 ] && ok "I25: alle $found gecontroleerde spine-workflows staan actief"
}

# ---------------------------------------------------------------------------------------------
# MODULE afhankelijkheden — I28. Roept een station een script aan dat de consument niet heeft?
# ---------------------------------------------------------------------------------------------
#
# Een fleet-station draait in de werkmap van de CONSUMENT. Roept het daar `scripts/foo.sh` aan, dan
# is dat een harde eis aan die consument — maar nergens staat opgeschreven dát het een eis is. Met
# één consument valt dat nooit op, want daar staat het script gewoon.
#
# Gevonden 2026-07-28 bij InvestingOS: `auto-merge` roept `scripts/sensitive-paths-guard.sh` aan en
# dat bestaat daar niet. Het gedrag is netjes fail-closed (elke PR wacht dan op een mens), en juist
# dáárom is het gevaarlijk: er wordt niets rood, de spine "werkt", en niemand merkt dat 'ie per
# constructie nooit meer merget. Zelfde faalvorm die I23 bij de golden-set afkeurde — een uitkomst
# die altijd hetzelfde is, ziet er van buiten uit als een werkende check.
#
# Deze module leest de eis uit de stationsdefinitie zelf (dus geen handmatig bijgehouden lijst die
# achterloopt) en toetst 'm tegen de consument. Vereist een checkout van fleet naast die van de
# consument — in doctor.yml staat die in `.fleet-doctor`.
module_afhankelijkheden() {
  [ -d "$wf_dir" ] || { warn "geen $wf_dir — niets te controleren"; return; }
  if [ -z "$fleet_root" ] || [ ! -d "$fleet_root/.github/workflows" ]; then
    warn "I28: geen fleet-checkout meegegeven (--fleet-root) — afhankelijkheden ongetoetst"
    return
  fi

  local refs
  refs="$(grep -rhoE "KCTHolman/fleet/\.github/workflows/[A-Za-z0-9_.-]+\.yml@" "$wf_dir" 2>/dev/null \
    | sed -E 's|.*/||; s|@$||' | sort -u)"
  if [ -z "$refs" ]; then
    ok "I28: deze repo roept geen fleet-stations aan"
    return
  fi

  local getoetst=0 i28=0 station nodig s
  while IFS= read -r station; do
    [ -n "$station" ] || continue
    [ -f "$fleet_root/.github/workflows/$station" ] || continue
    # `bash scripts/x.sh` met een SPATIE ervoor: zo vallen `.fleet-doctor/scripts/...` en
    # `.fleet-lib/scripts/...` er automatisch buiten — dat zijn fleet's eigen checkouts in de
    # werkmap van de consument, geen eis aan de consument.
    nodig="$(grep -ohE '(bash|sh) scripts/[A-Za-z0-9_.-]+\.sh' "$fleet_root/.github/workflows/$station" 2>/dev/null \
      | sed -E 's/^(bash|sh) //' | sort -u)"
    [ -n "$nodig" ] || continue
    getoetst=$((getoetst + 1))
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      if [ ! -f "$root/$s" ]; then
        bad "I28: station $station roept \`$s\` aan in deze repo, maar dat bestand bestaat hier niet — het station draait dan op z'n faalpad zonder dat iets rood wordt"
        i28=1
      fi
    done <<< "$nodig"
  done <<< "$refs"

  if [ "$getoetst" = 0 ]; then
    ok "I28: geen van de aangeroepen stations eist een script uit deze repo"
  elif [ "$i28" = 0 ]; then
    ok "I28: alle scripts die de $getoetst aangeroepen stations nodig hebben, staan er"
  fi

  module_verdictprotocol
}

# ---------------------------------------------------------------------------------------------
# I29 — spreekt de guard de taal die het station leest?
# ---------------------------------------------------------------------------------------------
#
# I28 toetst of het bestand BESTAAT. Dat is niet genoeg, en dat is gemeten.
#
# InvestingOS' `sensitive-paths-guard.sh` bestond, was 282 regels lang, had een eigen self-test en
# was strenger dan die van de andere twee consumenten — en tóch zou `auto-merge` er nooit een
# CLEAN uit gelezen hebben. Twee redenen: het script kende de vlag `--diff` niet (het station geeft
# een unified diff mee, geen padlijst), en het printte de KALE woorden terwijl het station op
# `^CLEAN:` en `^FORCE-APPROVAL:` grept — mét dubbele punt.
#
# De uitkomst was fail-closed, dus veilig. Maar ook stil, en permanent: elke PR zou op een mens
# wachten terwijl de merge-machine er groen en werkend uitziet. Exact de faalvorm die I28 zelf
# beschrijft ("een uitkomst die altijd hetzelfde is, ziet er van buiten uit als een werkende
# check") — alleen één laag dieper, en daar keek niets.
#
# HET CONTRACT DAT HIER GETOETST WORDT is geen nieuwe afspraak maar wat auto-merge.yml al doet:
#
#     guard_out="$(bash scripts/sensitive-paths-guard.sh --diff "$diff_file" 2>&1 || true)"
#     grep -q '^FORCE-APPROVAL:'  → gevoelig
#     grep -q '^CLEAN:'           → schoon
#     anders                      → fail-closed
#
# We toetsen alleen de VORM, nooit het oordeel. Wélke paden gevoelig zijn is per definitie
# domeinkennis van de consument (dat is de hele reden dat dit script daar staat en niet hier);
# dát er een leesbaar oordeel uit komt, is dat niet.
module_verdictprotocol() {
  local guard="$root/scripts/sensitive-paths-guard.sh"
  [ -f "$guard" ] || return 0   # I28 heeft hier al over geklaagd als een station 'm nodig had

  command -v bash >/dev/null 2>&1 || { warn "I29: geen bash om de guard te proeven"; return; }

  local tmp uit fout=0
  tmp="$(mktemp)"

  # Twee vormen, allebei uit de echte praktijk. De tweede is een PURE hernoeming: die produceert
  # géén `+++`/`---`-regels, en een guard die alleen daarop leest ziet 'm als een lege diff.
  # Eén consument's guard gaf daar CLEAN op — je kon er elk bestand ongezien de workflowmap mee in
  # verplaatsen (gerepareerd 2026-08-23).
  local -a vormen=(
    "gewone wijziging|diff --git a/README.md b/README.md
--- a/README.md
+++ b/README.md
@@ -1 +1,2 @@
 x
+y
"
    "pure hernoeming|diff --git a/README.md b/.github/workflows/x.yml
similarity index 100%
rename from README.md
rename to .github/workflows/x.yml
"
  )

  local paar naam inhoud
  for paar in "${vormen[@]}"; do
    naam="${paar%%|*}"; inhoud="${paar#*|}"
    printf '%s' "$inhoud" > "$tmp"
    # Zelfde aanroepvorm als het station, inclusief het lege GITHUB_OUTPUT en de `|| true`.
    uit="$(GITHUB_OUTPUT='' bash "$guard" --diff "$tmp" 2>&1 || true)"
    if printf '%s' "$uit" | grep -qE '^(FORCE-APPROVAL|CLEAN):'; then
      ok "I29: guard geeft een leesbaar oordeel op een $naam"
    else
      bad "I29: guard geeft GEEN leesbaar oordeel op een $naam — auto-merge valt hier fail-closed terug op een mens, permanent en zonder dat iets rood wordt. Verwacht een regel die met \`CLEAN:\` of \`FORCE-APPROVAL:\` begint (mét dubbele punt); kreeg: $(printf '%s' "$uit" | head -1)"
      fout=1
    fi
  done

  rm -f "$tmp"
  [ "$fout" = 0 ] || true
}

# ---------------------------------------------------------------------------------------------
# MODULE liveness — I27. De enige faalklasse die alle andere modules missen: STILLE NON-ACTIE.
# ---------------------------------------------------------------------------------------------
#
# Elke andere invariant kijkt naar wat er STÁÁT (een state, een pad, een naam, een permissie). Op
# 2026-07-27 stond alles goed en gebeurde er tóch niets: de glob-val in `workflow_run.workflows`
# legde de complete spine tien uur plat terwijl elke check groen bleef. I7 is daarop aangescherpt,
# maar dat dekt alleen díe oorzaak — een trigger kan om tien andere redenen stilvallen.
#
# Daarom meet deze module GEDRAG in plaats van configuratie, en wel relatief: liep de BRON, en
# reageerde de LUISTERAAR daarop? Absolute ouderdom ("geen run in 3 dagen") zou hier nutteloos zijn
# geweest — na tien uur was die drempel nog lang niet gehaald.
#
# Per luisteraar wordt de nieuwste run MET event=workflow_run vergeleken, want een workflow met óók
# `schedule:`/`issues:` (epic-orchestrator) heeft anders een recente run die de dode route maskeert.

# Pure beslisser: geen netwerk, geen klok — alles komt als argument binnen, zodat de test 'm offline
# kan vastpinnen (zelfde patroon als intake-decide.sh).
liveness_oordeel() {
  local bron="$1" luisteraar="$2" grace="$3"
  [ -n "$bron" ] && [ "$bron" != "0" ] || { echo "geen-bron"; return; }
  # NOOIT gereageerd is bewust GEEN harde bevinding. Een luisteraar die vandaag is toegevoegd
  # heeft nog geen run, en tussen "gemerged" en "de bron liep voor het eerst daarna" zit een
  # gat waarin hard rood puur vals alarm is. Dat is dezelfde val als bij I5 (vals-positief in
  # een harde check leert mensen de uitkomst negeren) en de doctor kiest hier consequent voor
  # zichtbaar-maar-niet-blokkerend. De storing die er écht toe doet — een trigger die WERKTE en
  # stilviel — heeft per definitie oudere runs en valt dus wél onder `verouderd`.
  [ -n "$luisteraar" ] && [ "$luisteraar" != "0" ] || { echo "nooit"; return; }
  if [ "$bron" -gt $((luisteraar + grace)) ]; then echo "verouderd"; else echo "levend"; fi
}

module_liveness() {
  [ -n "$repo" ] || die "--repo is verplicht voor module liveness"
  command -v gh >/dev/null || die "gh niet gevonden"
  [ -d "$wf_dir" ] || die "geen $wf_dir"

  local grace=$((grace_min * 60))

  # naam → bestandsnaam, om een geluisterde naam terug te vertalen naar een workflow-pad.
  local naar_pad=""
  local f base nm
  for f in "$wf_dir"/*.yml; do
    [ -f "$f" ] || continue
    nm="$(grep -m1 -E '^name:' "$f" 2>/dev/null | sed -E 's/^name:\s*//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')"
    [ -n "$nm" ] && naar_pad="$naar_pad$nm	$(basename "$f")
"
  done

  # `bewezen` telt alleen luisteraars die AANTOONBAAR reageerden. Een ⚠️-geval meetellen zou de
  # slotregel z'n eigen waarschuwing laten tegenspreken — en een groen vinkje dat naast een
  # waarschuwing staat is precies hoe deze storing tien uur onzichtbaar bleef.
  local gecontroleerd=0 bewezen=0
  for f in "$wf_dir"/*.yml; do
    [ -f "$f" ] || continue
    grep -qE '^\s*workflow_run:' "$f" || continue
    base="$(basename "$f")"

    local bronnen
    bronnen="$(grep -hoE '^\s*workflows:\s*\[.*\]' "$f" 2>/dev/null \
      | sed -E 's/^\s*workflows:\s*\[//; s/\]\s*$//' \
      | tr ',' '\n' | sed -E "s/^\s*//; s/\s*$//; s/^[\"']//; s/[\"']$//" \
      | sed -E 's/\\(.)/\1/g' | grep -v '^$')"
    [ -n "$bronnen" ] || continue

    # Nieuwste run van deze luisteraar die ECHT via de workflow_run-route kwam.
    local l_iso l_epoch
    l_iso="$(gh api "repos/$repo/actions/workflows/$base/runs?event=workflow_run&per_page=1" \
      --jq '.workflow_runs[0].created_at // ""' 2>/dev/null)" || l_iso=""
    l_epoch=0; [ -n "$l_iso" ] && l_epoch="$(date -u -d "$l_iso" +%s 2>/dev/null || echo 0)"

    # Nieuwste voltooide run over álle bronnen samen: reageren hóórt op elk van hen.
    #
    # MAAR: niet elke bron-run KÁN een workflow_run-event afgeven. GitHub's recursie-slot smoort de
    # vervolg-events van een run die met de GITHUB_TOKEN is aangezwengeld ("events triggered by the
    # GITHUB_TOKEN will not create a new workflow run") — in de praktijk een `workflow_dispatch`
    # vanuit een andere workflow, herkenbaar aan actor `github-actions[bot]`. De luisteraar kán op
    # zo'n run niet reageren, dus 'm afrekenen op die stilte is per constructie vals alarm.
    #
    # Geverifieerd in BiohackOS (2026-08-01): claude.yml-runs via `issues` (actor `claude[bot]` of
    # een mens) gaven élke keer een reconciler-cron-run; drie opeenvolgende `workflow_dispatch`-runs
    # door `github-actions[bot]` géén enkele. Omdat juist de raket die dispatch-route continu
    # gebruikt, wás de nieuwste bron-run bijna altijd zo'n gesmoorde — I27 stond daardoor permanent
    # hard rood, en via de fail-teller van auto-merge hield dat de complete merge-poort dicht.
    #
    # EN: een bron-run die NÉT is afgerond kan nog geen reactie hebben. De speling hieronder vangt
    # dat alleen als de luisteraar kórt vóór de bron draaide; stond z'n vorige run langer terug —
    # volkomen normaal, er liep in de tussentijd simpelweg geen bron — dan las I27 een reactie die
    # nog in de maak was als een dode trigger. Gemeten 2026-08-01: feature-governance rondde af om
    # 09:17:09, de auto-merge-run erop ontstond om 09:17:11, en de doctor las de luisteraarslijst
    # net dáárvoor → hard rood op een keten die perfect werkte.
    #
    # Daarom tellen alleen bron-runs mee die minstens één speling geleden AFRONDDEN (`updated_at`).
    # Samen met de actor-filter: de nieuwste voltooide bron-run die het event WÉL kón afgeven én
    # lang genoeg geleden is om een reactie te verwachten. Blijft er niets over, dan blijft $b_iso
    # leeg → oordeel `geen-bron` (zacht), niet hard rood.
    local b_epoch=0 b_naam="" pad b_iso e nu
    nu="$(date -u +%s)"
    while IFS= read -r nm; do
      [ -n "$nm" ] || continue
      pad="$(printf '%s' "$naar_pad" | grep -F "$nm	" | head -1 | cut -f2)"
      [ -n "$pad" ] || continue
      b_iso="$(gh api "repos/$repo/actions/workflows/$pad/runs?status=completed&per_page=50" \
        --jq '.workflow_runs[]? | select((.actor.login // "") != "github-actions[bot]")
              | "\(.created_at)\t\(.updated_at // .created_at)"' 2>/dev/null \
        | while IFS="$(printf '\t')" read -r b_c b_u; do
            [ -n "$b_u" ] || continue
            ue="$(date -u -d "$b_u" +%s 2>/dev/null || echo 0)"
            [ "$ue" -gt 0 ] || continue
            if [ "$((nu - ue))" -ge "$grace" ]; then printf '%s\n' "$b_c"; break; fi
          done)" || b_iso=""
      [ -n "$b_iso" ] || continue
      e="$(date -u -d "$b_iso" +%s 2>/dev/null || echo 0)"
      [ "$e" -gt "$b_epoch" ] && { b_epoch="$e"; b_naam="$nm"; }
    done <<< "$bronnen"

    gecontroleerd=$((gecontroleerd + 1))
    case "$(liveness_oordeel "$b_epoch" "$l_epoch" "$grace")" in
      geen-bron)
        warn "I27: $base — geen enkele bron heeft ooit voltooid; niets te concluderen" ;;
      nooit)
        warn "I27: $base heeft nog NOOIT via workflow_run gedraaid terwijl \"$b_naam\" wel liep — vers toegevoegd, of de trigger heeft nooit gewerkt. Bevestig 'm met één bron-run" ;;
      verouderd)
        bad "I27: $base heeft NIET gereageerd op \"$b_naam\" (bron liep $(( (b_epoch - l_epoch) / 3600 ))u ná de laatste workflow_run-run van $base, ${l_iso}) — de trigger vuurt niet, terwijl niets rood wordt" ;;
      levend)
        bewezen=$((bewezen + 1)) ;;
    esac
  done

  if [ "$gecontroleerd" = 0 ]; then
    ok "I27: geen workflow_run-luisteraars in deze repo"
  elif [ "$bewezen" = "$gecontroleerd" ]; then
    ok "I27: alle $gecontroleerd workflow_run-luisteraars reageren op hun bron"
  elif [ "$hard" = 0 ]; then
    ok "I27: $bewezen van $gecontroleerd luisteraars bewezen; de rest staat hierboven als ⚠️"
  fi
}

# ---------------------------------------------------------------------------------------------
# MODULE pin — I24. Een pin die niet meer opschuift is verstarring, niet veiligheid.
# ---------------------------------------------------------------------------------------------
#
# WAAROM DIT ER NIET WAS EN WEL MOEST KOMEN. I24 stond in gitflow.md toegewezen aan
# `doctor:consistentie`, maar die module toetst alleen het PÁD van een verwijzing — niet de ref
# erachter. Niets merkte dus dat een consument maanden op dezelfde fleet-commit stond. Erger: een
# achterlopende pin degradeert naar GROEN, want doctor.yml slaat een module die de gepinde doctor
# nog niet kent netjes over met een ⚠️. Dat is de juiste behandeling voor scheefstand, maar zonder
# tegenhanger betekent het dat "meer achterstand" leidt tot "minder harde bevindingen".
#
# Twee dingen worden hier hard:
#   • ACHTERSTAND — de gepinde commit is ouder dan de drempel t.o.v. fleet's hoofd. Niet "er is een
#     nieuwere commit" (dan zou élke fleet-push elke consument rood zetten), maar "de bump-baan is
#     er al dagen niet in geslaagd 'm door te schuiven", en dát is een storing in de baan zelf.
#   • VERDEELDHEID — meer dan één distinct SHA in dezelfde repo. Dat is een half gelukte bump: de
#     ene helft van de callers roept nieuwe logica aan, de andere oude. Dat is geen achterstand
#     maar inconsistentie, en die is per definitie ongetest.

# Pure beslisser, zelfde patroon als liveness_oordeel: geen netwerk, geen klok, alles als argument.
#   $1 = epoch van de gepinde commit (0 = onbekend)
#   $2 = epoch van fleet's hoofdcommit (0 = onbekend)
#   $3 = drempel in dagen
#   $4 = aantal distinct SHA-refs in de repo
pin_oordeel() {
  local gepind="${1:-0}" hoofd="${2:-0}" drempel="${3:-7}" n_refs="${4:-0}"
  [ "$n_refs" -gt 1 ] && { echo "verdeeld"; return; }
  [ "$n_refs" -eq 0 ] && { echo "ongepind"; return; }
  # Niet kunnen meten is geen bevinding. Een SHA die de API niet teruggeeft (force-push, ander
  # repo) moet zichtbaar zijn als "onbekend", niet als "verouderd" — anders is de eerste keer dat
  # deze module iets zegt meteen een vals alarm.
  { [ "$gepind" -eq 0 ] || [ "$hoofd" -eq 0 ]; } && { echo "onbekend"; return; }
  if [ "$((hoofd - gepind))" -gt "$((drempel * 86400))" ]; then echo "verouderd"; else echo "actueel"; fi
}

module_pin() {
  [ -d "$wf_dir" ] || { warn "geen $wf_dir — niets te controleren"; return; }

  # GEEN `gh`-guard hier, bewust. Het grootste deel van deze module is BESTANDSWERK (is dit de
  # kanarie? staan er twee verschillende pins?) en dat hoort ook zonder netwerk een uitspraak te
  # geven. Alleen de ouderdomsvraag heeft de API nodig; die degradeert verderop naar `onbekend`.
  # Andersom — vooraf afbreken op een ontbrekende `gh` — zou de verdeeldheidscheck, de enige die
  # een half gelukte bump ziet, uitzetten op precies de machine waar je 'm offline wilt draaien.
  local is_fleet=0
  [ -f "$root/docs/architectuur.md" ] && [ -f "$root/routing.yml" ] && is_fleet=1
  if [ "$is_fleet" = 1 ]; then
    # deFleet is de KANARIE (gitflow §13.D): die hóórt zichzelf op `@main` te volgen, anders test
    # 'ie niet de nieuwste commit maar zichzelf. Hier iets van vinden zou de invariant omdraaien.
    ok "I24: deze repo is de kanarie — volgt \`@main\` en heeft per ontwerp geen pin"
    return
  fi

  local alle refs branches
  alle="$(grep -rhoE "KCTHolman/fleet/\.github/workflows/[A-Za-z0-9_.-]+\.yml@[A-Za-z0-9_.:/-]+" \
    "$wf_dir" 2>/dev/null | sed -E 's/.*@//' | sort -u)"
  if [ -z "$alle" ]; then
    ok "I24: deze repo roept geen fleet-workflows aan — niets te pinnen"
    return
  fi
  # SHA's scheiden van branch-/tagnamen: alleen een volle 40-hex is een echte pin.
  refs="$(printf '%s\n' "$alle" | grep -xE '[0-9a-f]{40}' || true)"
  branches="$(printf '%s\n' "$alle" | grep -vxE '[0-9a-f]{40}' || true)"

  local n_refs=0
  [ -n "$refs" ] && n_refs="$(printf '%s\n' "$refs" | grep -c . || true)"

  # De bump-baan (`bump-pin.yml`) volgt bewust `@main` — dat is de ontpin-knop, geen scheefstand.
  # Elke ándere branch-ref is er wel één: die caller beweegt mee met elke fleet-push.
  if [ -n "$branches" ]; then
    local losse
    losse="$(grep -rlE "KCTHolman/fleet/\.github/workflows/[A-Za-z0-9_.-]+\.yml@(main|master)" "$wf_dir" 2>/dev/null \
      | xargs -r -n1 basename | grep -v '^bump-pin\.yml$' | tr '\n' ' ' || true)"
    [ -n "$(printf '%s' "$losse" | tr -d ' ')" ] \
      && warn "I24: deze caller(s) volgen een branch i.p.v. een SHA: $losse — elke fleet-push landt daar ongetest"
  fi

  # Datums ophalen. De fleet-repo is privé, dus dit vraagt de app-token; die staat als FLEET_TOKEN
  # in de omgeving (doctor.yml zet 'm). Zonder token is dit niet meetbaar — en dat zeggen we.
  local tok="${FLEET_TOKEN:-${GH_TOKEN:-}}"
  local gepind_sha hoofd_sha="" gepind_iso="" hoofd_iso="" gepind_e=0 hoofd_e=0
  gepind_sha="$(printf '%s\n' "$refs" | head -1)"
  if command -v gh >/dev/null && [ -n "$gepind_sha" ]; then
    gepind_iso="$(GH_TOKEN="$tok" gh api "repos/$fleet_repo/commits/${gepind_sha}" \
      --jq '.commit.committer.date // ""' 2>/dev/null || true)"
    hoofd_iso="$(GH_TOKEN="$tok" gh api "repos/$fleet_repo/commits/main" \
      --jq '.commit.committer.date // ""' 2>/dev/null || true)"
    hoofd_sha="$(GH_TOKEN="$tok" gh api "repos/$fleet_repo/commits/main" --jq '.sha // ""' 2>/dev/null || true)"
  fi
  [ -n "$gepind_iso" ] && gepind_e="$(date -u -d "$gepind_iso" +%s 2>/dev/null || echo 0)"
  [ -n "$hoofd_iso" ]  && hoofd_e="$(date -u -d "$hoofd_iso" +%s 2>/dev/null || echo 0)"

  local dagen=0
  [ "$gepind_e" -gt 0 ] && [ "$hoofd_e" -gt 0 ] && dagen=$(( (hoofd_e - gepind_e) / 86400 ))

  case "$(pin_oordeel "$gepind_e" "$hoofd_e" "$pin_drempel" "$n_refs")" in
    ongepind)
      warn "I24: geen enkele SHA-pin gevonden — deze consument volgt een branch. Pinnen is de eis; de bump-baan schuift 'm daarna vanzelf door" ;;
    verdeeld)
      bad "I24: $n_refs VERSCHILLENDE fleet-pins in dezelfde repo ($(printf '%s' "$refs" | tr '\n' ' ')) — een half gelukte bump. De ene helft van de callers draait andere logica dan de andere, en die combinatie is nooit als geheel getest" ;;
    onbekend)
      warn "I24: kon de datum van pin \`${gepind_sha:0:7}\` of van fleet's hoofdcommit niet ophalen — achterstand ongetoetst (token/rechten?)" ;;
    verouderd)
      bad "I24: de pin \`${gepind_sha:0:7}\` is $dagen dagen ouder dan fleet's hoofd \`${hoofd_sha:0:7}\` (drempel $pin_drempel). Niet 'er is iets nieuwers' — de bump-baan had dit al lang moeten doorschuiven, dus die baan is zelf stuk of staat uit" ;;
    actueel)
      ok "I24: pin \`${gepind_sha:0:7}\` loopt $dagen dag(en) achter op fleet's hoofd — binnen de drempel van $pin_drempel" ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# MODULE runners — I10, I11. Override-modus is een geldige keuze, maar nooit stilzwijgend.
# ---------------------------------------------------------------------------------------------
module_runners() {
  [ -n "$repo" ] || die "--repo is verplicht voor module runners"
  command -v gh >/dev/null || die "gh niet gevonden"

  local vars overrides
  vars="$(gh api "repos/$repo/actions/variables" --paginate --jq '.variables[] | "\(.name)=\(.value)"' 2>/dev/null || true)"
  overrides="$(printf '%s\n' "$vars" | grep -E '^RUNNER_OVERRIDE' | grep -v '=$' || true)"

  if [ -n "$overrides" ]; then
    # I10: de override-modus mag actief zijn, maar dan moet 'ie ZICHTBAAR zijn. In deze modus
    # is de trusted-context-gate van de picker uitgeschakeld en queuet een offline lane
    # onzichtbaar i.p.v. terug te vallen — daarom hangt I11 eraan vast.
    warn "I10: override-modus ACTIEF ($(printf '%s' "$overrides" | tr '\n' ' ')) — picker + fallback staan uit"

    local runners
    runners="$(gh api "repos/$repo/actions/runners" --paginate \
      --jq '.runners[] | select(.status=="online") | .labels[].name' 2>/dev/null | sort -u || true)"
    if [ -z "$runners" ]; then
      bad "I11: override-modus actief maar GEEN online runner zichtbaar — jobs queuen onzichtbaar"
      return
    fi
    local missing=0
    while IFS= read -r ov; do
      [ -n "$ov" ] || continue
      local lbl="${ov#*=}"
      if ! printf '%s\n' "$runners" | grep -qxF "$lbl"; then
        bad "I11: override wijst naar lane '$lbl', maar geen enkele online runner draagt dat label"
        missing=1
      fi
    done <<< "$overrides"
    [ "$missing" = 0 ] && ok "I11: elke override-lane heeft een online runner"
  else
    ok "I10: geen override actief — de picker doet z'n werk (met fallback)"
  fi
}

# ---------------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------------
# MODULE contract — het `.fleet.yml`-consumer-contract (architectuur §4).
# ---------------------------------------------------------------------------------------------
module_contract() {
  local f="$root/.fleet.yml"
  if [ ! -f "$f" ]; then
    # Geen contract is (nog) geen fout: consumenten krijgen 'm pas bij fase 3. Wél zichtbaar,
    # want zonder contract draait elk station op ingebakken defaults.
    warn "geen .fleet.yml in deze repo — stations draaien op defaults i.p.v. op een contract"
    return
  fi
  local py; py="$(command -v python3 || command -v python || true)"
  [ -n "$py" ] || { warn "python niet gevonden — contractcheck overgeslagen"; return; }

  local out; out="$("$py" "$(dirname "$0")/check-fleet-yml.py" "$f" 2>&1)"
  if [ $? -eq 0 ]; then
    ok "contract: .fleet.yml is geldig"
  else
    printf '%s\n' "$out" | sed -n 's/^  ❌ //p' | while IFS= read -r r; do
      printf '  ❌ contract: %s\n' "$r"
    done
    hard=$((hard + 1))
  fi

  module_labelwoordenboek "$f" "$py"
}

# ---------------------------------------------------------------------------------------------
# I30 — bestaan de labels uit het contract ook echt in de repo?
# ---------------------------------------------------------------------------------------------
#
# `.fleet.yml` heeft een VERPLICHTE sectie `labels:` met `task`, `human` en (optioneel) `epic`.
# Elke consument moet 'm invullen. En tot vandaag las geen enkel station 'm: gevalideerd,
# afgedwongen, en volledig decoratief.
#
# Dat is niet onschuldig, want de sectie draagt een echte belofte. Het commentaar in élk contract
# zegt het zo: "Labels reizen NIET mee bij een issue-transfer — alleen namen die in de doelrepo al
# bestaan overleven de verhuizing. Deze drie moet elke consument garanderen." Fleet's `intake.yml`
# verhuist issues tussen repo's; een label dat in de doelrepo niet bestaat, valt daar stil weg.
# De belofte was dus dat die drie er zijn — en niets controleerde dat.
#
# De garantie hing aan `scripts/ensure-labels.sh`, en die bestaat in precies één van de
# consumenten, met NUL aanroepers. De belofte was fictie.
#
# Deze check maakt 'm waar: hij leest de drie namen uit het contract en kijkt of ze bestaan.
# Daarmee is `labels:` geen decoratie meer maar een gecontroleerde afspraak — dezelfde beweging
# als I29 bij het verdictprotocol.
#
# ZACHT ZONDER `--repo`. De labels zijn alleen via de API te zien; zonder repo weet je niets, en
# "ik weet het niet" mag hier geen bevinding worden (zelfde regel als I28 zonder `--fleet-root`).
module_labelwoordenboek() {
  local f="$1" py="$2"

  local namen
  namen="$("$py" - "$f" <<'PY' 2>/dev/null
import sys
try:
    import yaml
    d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
except Exception:
    raise SystemExit(0)
lab = d.get("labels")
if isinstance(lab, dict):
    for sleutel in ("task", "human", "epic"):
        naam = lab.get(sleutel)
        if isinstance(naam, str) and naam.strip():
            # GETRIMD doorgeven, niet ruw. Een `.fleet.yml` met CRLF-regeleindes (een checkout op
            # Windows is genoeg) levert anders een naam die op `\r` eindigt, en dan meldt deze
            # check dat élk contractlabel ontbreekt terwijl ze alle drie bestaan. Vier repo's
            # tegelijk rood om een reden die niets met labels te maken heeft — precies het soort
            # vals alarm dat een check ongeloofwaardig maakt.
            print(f"{sleutel}\t{naam.strip()}")
PY
)"
  [ -n "$namen" ] || return 0

  if [ -z "$repo" ]; then
    warn "I30: geen --repo meegegeven — of de contractlabels bestaan is ongetoetst"
    return
  fi
  command -v gh >/dev/null 2>&1 || { warn "I30: gh ontbreekt — labels ongetoetst"; return; }

  local bestaand
  bestaand="$(gh label list --repo "$repo" --limit 200 --json name --jq '.[].name' 2>/dev/null || true)"
  if [ -z "$bestaand" ]; then
    warn "I30: kon de labels van $repo niet ophalen — ongetoetst"
    return
  fi

  local mist=0 sleutel naam
  while IFS=$'\t' read -r sleutel naam; do
    # `\r` eraf. Python's stdout vertaalt op Windows elke `\n` naar `\r\n`, en `read` haalt alleen
    # de `\n` weg — de naam eindigt dan op een carriage return en matcht nooit. Grillig genoeg
    # ontsnapt de LAATSTE regel eraan (die heeft geen newline), dus de check meldde netjes dat
    # `epic` bestond en de andere twee niet. Een fout die zich voordoet als een echte bevinding,
    # en die in CI (Linux) onzichtbaar zou blijven tot iemand 'm lokaal draait.
    naam="${naam%$'\r'}"; sleutel="${sleutel%$'\r'}"
    [ -n "$naam" ] || continue
    if printf '%s\n' "$bestaand" | grep -qxF "$naam"; then
      ok "I30: contractlabel $sleutel = '$naam' bestaat"
    else
      bad "I30: contractlabel $sleutel = '$naam' bestaat NIET in $repo — een issue dat hierheen wordt verhuisd verliest dat label stilzwijgend, en een station dat erop wacht blijft wachten"
      mist=1
    fi
  done <<< "$namen"
  [ "$mist" = 0 ] || true
}

# ---------------------------------------------------------------------------------------------
# MODULE permissies — I26. Een caller moet minstens verlenen wat z'n fleet-workflow nodig heeft.
# ---------------------------------------------------------------------------------------------
module_permissies() {
  local py; py="$(command -v python3 || command -v python || true)"
  [ -n "$py" ] || { warn "python niet gevonden — I26 overgeslagen"; return; }

  # Het script hiernaast doet het werk: YAML-permissies uitrekenen vraagt om een echte parser.
  local fleet_root; fleet_root="$(cd "$(dirname "$0")/.." && pwd)"
  local out
  out="$("$py" "$(dirname "$0")/check-caller-permissions.py" --root "$root" --fleet "$fleet_root" 2>&1)"
  local rc=$?
  printf '%s\n' "$out"
  [ "$rc" -ne 0 ] && hard=$((hard + 1))
  return 0
}

# De modules die DEZE versie kent, opvraagbaar via `--module modules`.
#
# WAAROM DAT NODIG IS. Consumenten pinnen op een fleet-SHA (I24). Voeg je hier een module toe, dan
# vraagt een caller die 'm al aanzet iets van een gepinde doctor die 'm nog niet heeft — en dan
# stond hier `onbekende module`, hard rood, met een melding die naar een TYPEFOUT wijst terwijl het
# pin-scheefstand is. Van binnenuit zien die twee er identiek uit; van buitenaf niet, want de
# aanroeper kan nu vragen wat deze versie kent en dat onderscheid zelf maken.
BEKENDE_MODULES="consistentie
permissies
spine
runners
contract
liveness
afhankelijkheden
pin"

case "$module" in
  consistentie) echo "── fleet-doctor · consistentie (I1/I2/I5/I7) ──"; module_consistentie ;;
  permissies)   echo "── fleet-doctor · permissies (I26) ──";           module_permissies ;;
  spine)        echo "── fleet-doctor · spine (I25) ──";                module_spine ;;
  runners)      echo "── fleet-doctor · runners (I10/I11) ──";          module_runners ;;
  contract)     echo "── fleet-doctor · contract (.fleet.yml) ──";      module_contract ;;
  liveness)     echo "── fleet-doctor · liveness (I27) ──";             module_liveness ;;
  afhankelijkheden) echo "── fleet-doctor · afhankelijkheden (I28) ──";  module_afhankelijkheden ;;
  pin)          echo "── fleet-doctor · pin (I24) ──";                 module_pin ;;
  # Verborgen haak: laat de test de PURE beslisser aanroepen zonder netwerk of klok.
  #   --module liveness-oordeel --repo "<bron_epoch> <luisteraar_epoch> <grace_sec>"
  liveness-oordeel) liveness_oordeel $repo ;;
  # Zelfde verborgen haak voor de pin-beslisser:
  #   --module pin-oordeel --repo "<gepind_epoch> <hoofd_epoch> <drempel_dagen> <aantal_refs>"
  pin-oordeel)  pin_oordeel $repo ;;
  # Laat de aanroeper vragen WAT deze versie kent. Zonder dit kan een gepinde consument het
  # verschil niet zien tussen een typefout en pin-scheefstand — zie de kop van dit blok.
  modules)      printf '%s
' "$BEKENDE_MODULES"; exit 0 ;;   # kale lijst: geen kop, geen eindoordeel
  "")           die "geef een module: $(printf '%s' "$BEKENDE_MODULES" | tr '
' ' ')" ;;
  *)            die "onbekende module '$module' (deze versie kent: $(printf '%s' "$BEKENDE_MODULES" | tr '
' ' '))" ;;
esac

echo "──"
if [ "$hard" = 0 ]; then
  echo "✅ geen harde bevindingen"
  exit 0
fi
echo "❌ $hard harde bevinding(en) — zie de ❌-regels hierboven"
exit 1
