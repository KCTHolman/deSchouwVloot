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
spine_list="auto-merge.yml,pr-check.yml,epic-orchestrator.yml,reconciler-cron.yml"
# Speling tussen "de bron is klaar" en "de luisteraar is begonnen". Ruim genoeg dat een run die
# NET voltooide geen vals alarm geeft, krap genoeg dat een dode trigger binnen het uur opvalt.
grace_min=30

die() { echo "✋ fleet-doctor: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --module)     shift; module="${1:-}" ;;
    --root)       shift; root="${1:-}" ;;
    --repo)       shift; repo="${1:-}" ;;
    --fleet-repo) shift; fleet_repo="${1:-}" ;;
    --spine)      shift; spine_list="${1:-}" ;;
    --grace-min)  shift; grace_min="${1:-}" ;;
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
      if sed -E 's/(^|[[:space:]])#.*$//' "$f" | grep -qE '^\s{4}(steps:|runs-on:)'; then
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
    local b_epoch=0 b_naam="" pad b_iso e
    while IFS= read -r nm; do
      [ -n "$nm" ] || continue
      pad="$(printf '%s' "$naar_pad" | grep -F "$nm	" | head -1 | cut -f2)"
      [ -n "$pad" ] || continue
      b_iso="$(gh api "repos/$repo/actions/workflows/$pad/runs?status=completed&per_page=1" \
        --jq '.workflow_runs[0].created_at // ""' 2>/dev/null)" || b_iso=""
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
liveness"

case "$module" in
  consistentie) echo "── fleet-doctor · consistentie (I1/I2/I5/I7) ──"; module_consistentie ;;
  permissies)   echo "── fleet-doctor · permissies (I26) ──";           module_permissies ;;
  spine)        echo "── fleet-doctor · spine (I25) ──";                module_spine ;;
  runners)      echo "── fleet-doctor · runners (I10/I11) ──";          module_runners ;;
  contract)     echo "── fleet-doctor · contract (.fleet.yml) ──";      module_contract ;;
  liveness)     echo "── fleet-doctor · liveness (I27) ──";             module_liveness ;;
  # Verborgen haak: laat de test de PURE beslisser aanroepen zonder netwerk of klok.
  #   --module liveness-oordeel --repo "<bron_epoch> <luisteraar_epoch> <grace_sec>"
  liveness-oordeel) liveness_oordeel $repo ;;
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
