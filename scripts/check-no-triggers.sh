#!/usr/bin/env bash
# check-no-triggers.sh — bewijst dat GEEN ENKELE workflow in deze repo uit zichzelf kan vuren.
#
# WAAROM DIT BESTAAT. Dit is een publieke showcase-repo. In de privé-productieversie mag een
# workflow best een `schedule`, `push` of `issues`-trigger hebben: daar kan alleen de eigenaar
# een event veroorzaken. Publiek verandert diezelfde trigger van karakter — `issues` wordt een
# anonieme voordeur die iedere GitHub-gebruiker kan aftrappen, en `pull_request` laat een
# wildvreemde fork-code uitvoeren op de runners van deze repo.
#
# DE REGEL DIE DEZE GUARD HANDHAAFT: het enige toegestane `on:`-sleutelwoord is `workflow_call`.
#
# Waarom dat veilig is, en niet slechts "minder onveilig": een reusable workflow start NOOIT
# vanzelf. Hij draait alleen als een andere workflow 'm expliciet aanroept, en dan in de context
# van díé aanroeper — op diens runners, met diens secrets, tegen diens repo. Roept een vreemde
# een workflow uit deze repo cross-repo aan, dan betaalt en draait hij dat volledig zelf; de
# eigenaar van deze repo stelt daar niets voor bloot. Er is dus geen pad van "publiek internet"
# naar "compute of secrets van de eigenaar".
#
# Deze guard is expres een DOM tekstueel script en geen YAML-parser: hij moet ook draaien op een
# kale machine zonder python/yq, en hij moet leesbaar genoeg zijn dat je 'm gelooft zonder 'm te
# hoeven vertrouwen.
#
# Draaien: bash scripts/check-no-triggers.sh [--root .]

set -uo pipefail

root="."
while [ $# -gt 0 ]; do
  case "$1" in
    --root) shift; root="${1:-.}" ;;
    *) echo "✋ onbekend argument: $1" >&2; exit 2 ;;
  esac
  shift
done

wf_dir="$root/.github/workflows"

if [ ! -d "$wf_dir" ]; then
  echo "✅ geen .github/workflows/ — niets dat kan vuren"
  exit 0
fi

fail=0
n=0

echo "── check-no-triggers · alleen \`workflow_call\` toegestaan ──"

for f in "$wf_dir"/*.yml "$wf_dir"/*.yaml; do
  [ -f "$f" ] || continue
  n=$((n + 1))
  naam="$(basename "$f")"

  # De triggersleutels onder `on:` verzamelen. `on` mag in YAML ook gequote staan ("on"/'on') —
  # dat is geen theorie maar de bekende Norway/YAML-1.1-valkuil, dus we vangen alle drie.
  # Alles wat één niveau diep onder `on:` staat is een trigger; de blok-inhoud daaronder niet.
  triggers="$(awk '
    # Start van het on-blok, blokvorm: `on:` op kolom 1 zonder waarde erachter.
    /^["'"'"']?on["'"'"']?:[[:space:]]*(#.*)?$/ { inon=1; next }
    # Inline vorm: `on: workflow_call` of `on: [push, pull_request]` — waarde staat op dezelfde regel.
    /^["'"'"']?on["'"'"']?:[[:space:]]*[^[:space:]#]/ {
      line=$0
      sub(/^["'"'"']?on["'"'"']?:[[:space:]]*/, "", line)
      gsub(/[][,]/, " ", line)
      nf=split(line, parts, /[[:space:]]+/)
      for (i = 1; i <= nf; i++) if (parts[i] != "") print parts[i]
      next
    }
    # Buiten het on-blok: een nieuwe sleutel op kolom 1 sluit het blok.
    inon && /^[^[:space:]#]/ { inon=0 }
    # Binnen het blok: precies twee spaties diep = een triggernaam.
    inon && /^  [A-Za-z_][A-Za-z0-9_]*:/ {
      key=$0
      sub(/^  /, "", key)
      sub(/:.*$/, "", key)
      print key
    }
  ' "$f")"

  if [ -z "$triggers" ]; then
    printf '  ❌ %-32s geen `on:`-blok gevonden — dit hoort niet te kunnen\n' "$naam"
    fail=1
    continue
  fi

  bad="$(printf '%s\n' "$triggers" | grep -vx 'workflow_call' || true)"

  if [ -n "$bad" ]; then
    printf '  ❌ %-32s verboden trigger(s): %s\n' "$naam" "$(printf '%s' "$bad" | tr '\n' ' ')"
    fail=1
  else
    printf '  ✅ %-32s workflow_call\n' "$naam"
  fi
done

echo "──"

if [ "$n" -eq 0 ]; then
  echo "✅ geen workflowbestanden gevonden — niets dat kan vuren"
  exit 0
fi

if [ "$fail" = 0 ]; then
  echo "✅ alle $n workflows zijn \`workflow_call\`-only — niets in deze repo vuurt uit zichzelf"
else
  echo "❌ er staat een workflow in die WEL uit zichzelf kan vuren."
  echo "   In een publieke repo is dat een anonieme trigger: haal 'm weg of maak er een"
  echo "   \`workflow_call\` van, met de trigger in de privé-consument die 'm aanroept."
fi

exit "$fail"
