#!/usr/bin/env python3
"""fleet-yml-areas.py — leest de `areas`-sectie uit een `.fleet.yml` en emit TSV.

GEEN AFHANKELIJKHEDEN. Niet PyYAML, niet `yq`, niets dat geïnstalleerd moet worden.

Dat is een geleerde les, geen voorkeur: de eerste versie deed `pip install pyyaml` in de workflow
en viel om op de self-hosted light-lane, waar de systeem-Python extern beheerd is (PEP 668). Een
station dat stilvalt omdat een installatie faalt is erger dan een station dat niet
geparametriseerd is — en een pip-install in een CI-stap is sowieso een netwerkafhankelijkheid die
je niet nodig hebt voor het lezen van vijf regels configuratie.

De `areas:`-sectie heeft een vaste, platte vorm (zie docs/architectuur.md §4), dus een kleine
handmatige parser volstaat. Zelfde afweging als in intake-decide.sh, dat routing.yml met awk leest.

Uitvoer, één regel per gebied:
    label<TAB>paths<TAB>color<TAB>description

Ontbreekt het bestand of de sectie, dan is de uitvoer LEEG en de exit-code 0 — een consument
zonder gebieden-config is geldig (die krijgt gewoon geen `area:`-labels). De aanroeper hoort dat
zichtbaar te maken; stil overslaan mag, stil doen alsof er gebieden waren niet.

Gebruik:
    python3 scripts/fleet-yml-areas.py [pad/naar/.fleet.yml]
"""

import sys

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):  # pragma: no cover
        pass

VELDEN = ("label", "paths", "color", "description")


def ontquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v


def lees_areas(regels):
    """Parseert de `areas:`-lijst. Stopt bij de eerste kolom-0-sleutel erna."""
    uit, huidig, in_areas = [], None, False

    for ruwe in regels:
        regel = ruwe.rstrip("\n")
        kaal = regel.strip()

        # Commentaar- en lege regels overslaan; een `#` middenin een waarde laten we staan,
        # want een regex mag er een bevatten.
        if not kaal or kaal.startswith("#"):
            continue

        if not in_areas:
            if regel.startswith("areas:"):
                in_areas = True
            continue

        # Terug op kolom 0 = volgende sectie; areas is klaar.
        if not regel[0].isspace():
            break

        if kaal.startswith("- "):
            if huidig:
                uit.append(huidig)
            huidig = {}
            kaal = kaal[2:].strip()  # `- label: x` → `label: x`
            if not kaal:
                continue

        if huidig is None:
            continue

        if ":" in kaal:
            sleutel, _, waarde = kaal.partition(":")
            sleutel = sleutel.strip()
            if sleutel in VELDEN:
                huidig[sleutel] = ontquote(waarde)

    if huidig:
        uit.append(huidig)
    return uit


def main():
    pad = sys.argv[1] if len(sys.argv) > 1 else ".fleet.yml"
    try:
        with open(pad, encoding="utf-8") as fh:
            regels = fh.readlines()
    except FileNotFoundError:
        return 0  # geen contract = geen gebieden; geldig

    for a in lees_areas(regels):
        label = a.get("label", "").strip()
        paths = a.get("paths", "").strip()
        if not label or not paths:
            continue
        # Tabs in een veld zouden de TSV slopen; ze horen er niet in en worden weggehaald i.p.v.
        # de hele regel te laten ontsporen.
        kleur = a.get("color", "").strip() or "C5DEF5"
        oms = a.get("description", "").strip()
        print("\t".join(x.replace("\t", " ") for x in (label, paths, kleur, oms)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
