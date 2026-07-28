#!/usr/bin/env bash
# Tests voor scripts/bump-beslis.sh — de pin-bump-poort (I24).
#
# Het meeste testgewicht ligt op de CANARY-POORT, en niet op de gelukkige route. Een bump die
# onterecht doorgaat zet ongeteste fleet-logica bij een consument neer — precies het risico
# waarvoor pinnen bestaat — en die tak raak je bij handmatig uitproberen nooit per ongeluk.
#
# Lokaal: bash scripts/bump-beslis.test.sh

set -uo pipefail
cd "$(dirname "$0")/.."
BESLIS="$PWD/scripts/bump-beslis.sh"

fail=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fail=1; }

# verwacht <naam> <verwachte-uitkomst> <args...>
verwacht() {
  local naam="$1" want="$2"; shift 2
  local got; got="$(bash "$BESLIS" "$@" 2>/dev/null)"
  [ "$got" = "$want" ] && ok "$naam" || bad "$naam (kreeg '$got', verwacht '$want')"
}

OUD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
NIEUW="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

echo "bump-beslis · de poorten in volgorde:"

verwacht "geen pin => niets te bumpen" niet-gepind \
  --huidig "" --doel "$NIEUW" --canary success
verwacht "pin staat al op het doel" actueel \
  --huidig "$NIEUW" --doel "$NIEUW" --canary success
verwacht "alles open => bump" bump \
  --huidig "$OUD" --doel "$NIEUW" --canary success
verwacht "tak bestaat al => geen dubbele PR" tak-bestaat \
  --huidig "$OUD" --doel "$NIEUW" --canary success --tak-bestaat ja

echo "bump-beslis · canary-poort (fail-closed):"

# ELKE niet-groene toestand houdt tegen. De interessante gevallen zijn niet `failure` maar de
# ONBEKENDE: een lege string, een nog lopende run, een API die niets teruggaf. "We konden het niet
# vaststellen" mag nooit hetzelfde uitpakken als "het was groen".
for c in failure cancelled timed_out skipped neutral action_required startup_failure onbekend null "" in_progress queued; do
  verwacht "canary='${c:-<leeg>}' => geen bump" canary-niet-groen \
    --huidig "$OUD" --doel "$NIEUW" --canary "$c"
done

# En de enige die wél doorlaat, letterlijk.
verwacht "canary='success' => wel bump" bump \
  --huidig "$OUD" --doel "$NIEUW" --canary success
verwacht "canary='Success' (hoofdletter) => geen bump" canary-niet-groen \
  --huidig "$OUD" --doel "$NIEUW" --canary Success

echo "bump-beslis · voorrang tussen de poorten:"

# Een rode canary mag niet worden overstemd doordat de pin toevallig al actueel is of andersom:
# de goedkope uitsluitingen horen vóór de canary, de canary vóór de tak-check.
verwacht "actueel wint van rode canary" actueel \
  --huidig "$NIEUW" --doel "$NIEUW" --canary failure
verwacht "rode canary wint van bestaande tak" canary-niet-groen \
  --huidig "$OUD" --doel "$NIEUW" --canary failure --tak-bestaat ja

echo "bump-beslis · gebruiksfouten:"

bash "$BESLIS" --huidig "$OUD" --canary success >/dev/null 2>&1
[ $? = 2 ] && ok "ontbrekend --doel => exit 2" || bad "ontbrekend --doel zou exit 2 moeten geven"

bash "$BESLIS" --onzin x >/dev/null 2>&1
[ $? = 2 ] && ok "onbekend argument => exit 2" || bad "onbekend argument zou exit 2 moeten geven"

if [ "$fail" = 0 ]; then
  echo "✅ alle bump-beslis-tests groen"
else
  echo "❌ bump-beslis-tests faalden"
fi
exit "$fail"
