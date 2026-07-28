#!/usr/bin/env python3
"""check-caller-permissions.py — invariant I26.

Een reusable workflow kan NOOIT meer rechten krijgen dan de caller verleent. Verleent de caller te
weinig, dan faalt de run met `startup_failure`: de job start niet eens, er is geen log, en de
foutmelding noemt de oorzaak niet.

Dat is precies hoe het op 2026-07-28 misging: alle callers uit M5/M6 kregen `contents: read` mee,
terwijl zeven van de tien fleet-workflows schrijfrechten nodig hadden. Het viel pas op doordat de
M6-pilot geen labels zette op z'n eigen PR.

Deze check vergelijkt per caller wat de callee NODIG heeft (union van workflow- en job-permissies)
met wat de caller VERLEENT.

Gebruik:
    python3 scripts/check-caller-permissions.py --root <consument> --fleet <pad-naar-fleet-checkout>

Exit: 0 = alles gedekt · 1 = minstens één tekort · 2 = gebruiksfout.
"""

import argparse
import os
import re
import sys

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):  # pragma: no cover
        pass

try:
    import yaml
except ImportError:  # pragma: no cover
    print("✋ check-caller-permissions: PyYAML ontbreekt", file=sys.stderr)
    sys.exit(2)

RANG = {"none": 0, "read": 1, "write": 2}
USES = re.compile(r"([\w.-]+/[\w.-]+)/\.github/workflows/([\w.-]+\.yml)@")


def perms_union(doc):
    """Union van workflow- en job-permissies; `write` wint van `read`."""
    uit = {}
    bronnen = [doc.get("permissions")]
    bronnen += [j.get("permissions") for j in (doc.get("jobs") or {}).values()]
    for p in bronnen:
        if not isinstance(p, dict):
            continue
        for k, v in p.items():
            if RANG.get(str(v), 0) > RANG.get(str(uit.get(k, "none")), 0):
                uit[k] = str(v)
    return uit


def laad(pad):
    with open(pad, encoding="utf-8") as fh:
        return yaml.safe_load(fh) or {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--fleet", required=True)
    a = ap.parse_args()

    wf_dir = os.path.join(a.root, ".github", "workflows")
    fleet_dir = os.path.join(a.fleet, ".github", "workflows")
    if not os.path.isdir(wf_dir):
        print(f"  ⚠️  geen {wf_dir} — niets te controleren")
        return 0
    if not os.path.isdir(fleet_dir):
        print(f"  ⚠️  fleet-checkout niet gevonden op {a.fleet} — check overgeslagen")
        return 0

    tekorten = 0
    gecontroleerd = 0

    for naam in sorted(os.listdir(wf_dir)):
        if not naam.endswith((".yml", ".yaml")):
            continue
        pad = os.path.join(wf_dir, naam)
        try:
            caller = laad(pad)
        except yaml.YAMLError:
            continue

        verleend = perms_union(caller)

        for job in (caller.get("jobs") or {}).values():
            uses = job.get("uses")
            if not isinstance(uses, str):
                continue
            m = USES.search(uses)
            if not m:
                continue
            doelbestand = os.path.join(fleet_dir, m.group(2))
            if not os.path.isfile(doelbestand):
                # I2 dekt ontbrekende paden; hier alleen overslaan.
                continue
            try:
                callee = laad(doelbestand)
            except yaml.YAMLError:
                continue

            gecontroleerd += 1
            nodig = perms_union(callee)
            mist = []
            for k, v in sorted(nodig.items()):
                if RANG.get(v, 0) > RANG.get(verleend.get(k, "none"), 0):
                    mist.append(f"{k}: {v} (caller geeft {verleend.get(k, 'niets')})")
            if mist:
                tekorten += 1
                print(f"  ❌ I26: {naam} verleent te weinig voor {m.group(2)} — mist {', '.join(mist)}")

    if gecontroleerd == 0:
        print("  ✅ I26: geen fleet-callers in deze repo")
        return 0
    if tekorten == 0:
        print(f"  ✅ I26: alle {gecontroleerd} caller(s) verlenen wat hun fleet-workflow nodig heeft")
        return 0
    print(f"     → een tekort geeft `startup_failure`: de run start niet en de fout noemt de oorzaak niet.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
