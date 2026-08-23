#!/usr/bin/env bash
# Tests voor scripts/sensitive-paths-guard.sh — de mens-poort van deFleet's eigen auto-merge.
#
# De asserties zelf staan in het script (`--self-test`), zodat ze óók meelopen als iemand de guard
# los aanroept. Dit bestand is de haak waarmee `checks.yml` ze oppikt: die draait
# `for suite in scripts/*.test.sh`, en een testsuite die daar niet in valt, draait nergens.
set -uo pipefail
cd "$(dirname "$0")/.."
exec bash scripts/sensitive-paths-guard.sh --self-test
