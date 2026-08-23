#!/usr/bin/env python3
"""check-fleet-yml.py — validator voor het consumer-contract `.fleet.yml`.

Het contract uit docs/architectuur.md §4: alles wat een fleet-workflow van een consument moet
weten, staat in één bestand. Zonder validator is dat bestand een stille faalbron — een typefout
in een sleutel doet gewoon *niets*, en dan draait een station maandenlang op een default die
niemand koos.

Daarom is deze validator STRIKT OP ONBEKENDE SLEUTELS. Dat is z'n belangrijkste functie: niet
controleren of `lanes.agent` een string is (dat merk je vanzelf), maar `lanez:` of `max_turn:`
tegenhouden vóórdat het gedrag ongemerkt verschuift.

Gebruik:
    python3 scripts/check-fleet-yml.py [pad/naar/.fleet.yml]

Exit: 0 = geldig · 1 = fouten gevonden · 2 = gebruiksfout (bestand weg/onleesbaar).
"""

import sys

# Uitvoer expliciet op UTF-8. Deze guard draait zowel in CI (Linux, UTF-8) als lokaal op een
# Windows-werkstation, waar de console standaard cp1252 is en de kaderlijntjes/emoji hieronder een
# UnicodeEncodeError geven — een guard die crasht op z'n eigen opmaak is nutteloos.
for stream in (sys.stdout, sys.stderr):
    try:
        stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):  # pragma: no cover — al UTF-8 of niet herconfigureerbaar
        pass

try:
    import yaml
except ImportError:  # pragma: no cover
    print("✋ check-fleet-yml: PyYAML ontbreekt (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

# De stations die een turn-budget mogen dragen. Bewust een gesloten lijst: een budget voor een
# station dat niet bestaat is altijd een typefout, nooit vooruitziendheid.
STATIONS = {"triage", "plan", "build", "review", "autofix", "conflict"}

# De BESLISPUNTEN die een eigen autonomiestand mogen dragen. Bewust een ANDERE lijst dan STATIONS
# hierboven, en dat verschil is inhoudelijk: `budgets.max_turns` gaat over wat er DRAAIT (een agent
# die turns verbruikt), `autonomy.stations` over wie er BESLIST. `build` heeft daarom geen
# autonomiestand (een bouwstap beslist niets, die voert uit) en `merge` geen turn-budget (daar
# draait geen agent, daar valt een besluit).
#
# DEZE LIJST BEVAT ALLEEN WAT ÉCHT WORDT GELEZEN, en dat is de hele reden dat de sectie `autonomy`
# bestaat. `gates.feature_approval` stond twee jaar in elk contract zonder dat één workflow 'm las:
# je zette 'm, er gebeurde niets, en niets werd rood. Zou hier `triage` of `release` staan terwijl
# alleen `auto-merge.yml` de resolver aanroept, dan bouwden we diezelfde stille faalvorm meteen
# opnieuw — nu met het argument "die wiren we later".
#
# De lijst groeit dus PER GEWIRED STATION, in dezelfde PR die 'm wiret. Eén regel hier, één regel
# in autonomie-beslis.sh. Zet iemand nu een station dat er niet in staat, dan is dat rood in CI en
# niet stil in productie.
AUTONOMIE_STATIONS = {"merge"}

# De twee standen, met hun Nederlandse synoniemen. De schakelaar wordt ook met de hand gezet
# (`gh variable set FLEET_AUTONOMY`), en dan is `autonoom` de waarde die je intikt.
AUTONOMIE_WAARDEN = {"supervised", "autonomous", "mens", "begeleid", "autonoom"}

SCHEMA = {
    "version": {"type": int, "required": True},
    "lanes": {
        "type": dict,
        "required": True,
        "keys": {
            "agent": {"type": str, "required": True},
            "heavy": {"type": str, "required": True},
            "light": {"type": str, "required": True},
            "fallback": {"type": str, "required": True},
        },
    },
    "gates": {
        "type": dict,
        "required": True,
        "keys": {
            "feature_approval": {"type": bool, "required": True},
            "release_environment": {"type": (str, type(None)), "required": False},
        },
    },
    "budgets": {
        "type": dict,
        "required": True,
        "keys": {
            "default_model": {"type": str, "required": True},
            "escalation_model": {"type": str, "required": False},
            "max_turns": {"type": dict, "required": True},
        },
    },
    "labels": {
        "type": dict,
        "required": True,
        "keys": {
            "task": {"type": str, "required": True},
            "human": {"type": str, "required": True},
            "epic": {"type": str, "required": False},
        },
    },
    # `autonomy` — de stand van de repo: beslist de machine zelf, of hoort er een mens aan te pas?
    #
    # OPTIONEEL, en dat is een migratiekeuze, geen slordigheid. Een consument zonder deze sectie
    # draait zoals hij vóór de schakelaar draaide (autonomie-beslis.sh valt dan terug op `mens`).
    # De sectie TOEVOEGEN is dus de bewuste keuze; hem weglaten verandert niets. Zou deze sectie
    # verplicht zijn, dan was elke bestaande consument van de ene op de andere dag rood — en dan
    # wordt 'ie ingevuld om het rood weg te krijgen, niet omdat iemand de stand koos.
    "autonomy": {
        "type": dict,
        "required": False,
        "keys": {
            "mode": {"type": str, "required": True},
            "stations": {"type": dict, "required": False},
            "allow_breaking": {"type": bool, "required": False},
        },
    },
    "spine": {"type": list, "required": False},
    # `areas` is de eerste geparametriseerde stationsconfig (M6-pilot, pr-label). Het label-schema
    # `type:`/`size:`/`breaking` is generiek — elk project gebruikt conventional commits en heeft
    # een diff-omvang. De PADEN naar gebieden zijn dat niet: `lib/` is Flutter, `web/` is Next.js,
    # en een ander project heeft weer wat anders. Precies die grens hoort in het contract.
    "areas": {"type": list, "required": False},
    "prompts": {
        "type": dict,
        "required": False,
        "keys": {"partials_dir": {"type": str, "required": True}},
    },
}


def typenaam(t):
    if isinstance(t, tuple):
        return " of ".join(x.__name__ for x in t)
    return t.__name__


def check_section(naam, waarde, spec, fouten):
    """Controleert één sectie tegen z'n schema: type, verplichte en onbekende sleutels."""
    if not isinstance(waarde, spec["type"]):
        fouten.append(f"`{naam}` moet {typenaam(spec['type'])} zijn, is {type(waarde).__name__}")
        return

    if "keys" not in spec:
        return

    toegestaan = set(spec["keys"])
    for k in waarde:
        if k not in toegestaan:
            # De hele reden dat deze validator bestaat.
            hint = ", ".join(sorted(toegestaan))
            fouten.append(f"onbekende sleutel `{naam}.{k}` — toegestaan: {hint}")

    for k, ks in spec["keys"].items():
        if k not in waarde:
            if ks["required"]:
                fouten.append(f"verplichte sleutel `{naam}.{k}` ontbreekt")
            continue
        v = waarde[k]
        if not isinstance(v, ks["type"]) or (ks["type"] is str and isinstance(v, bool)):
            fouten.append(
                f"`{naam}.{k}` moet {typenaam(ks['type'])} zijn, is {type(v).__name__}"
            )


def main():
    pad = sys.argv[1] if len(sys.argv) > 1 else ".fleet.yml"

    try:
        with open(pad, encoding="utf-8") as fh:
            data = yaml.safe_load(fh)
    except FileNotFoundError:
        print(f"✋ check-fleet-yml: {pad} bestaat niet", file=sys.stderr)
        return 2
    except yaml.YAMLError as exc:
        print(f"✋ check-fleet-yml: {pad} is geen geldige YAML — {exc}", file=sys.stderr)
        return 2

    print(f"── .fleet.yml-contract · {pad} ──")

    if not isinstance(data, dict):
        print("  ❌ het bestand levert geen mapping op (leeg?)")
        return 1

    fouten = []

    for k in data:
        if k not in SCHEMA:
            hint = ", ".join(sorted(SCHEMA))
            fouten.append(f"onbekende sectie `{k}` — toegestaan: {hint}")

    for naam, spec in SCHEMA.items():
        if naam not in data:
            if spec["required"]:
                fouten.append(f"verplichte sectie `{naam}` ontbreekt")
            continue
        check_section(naam, data[naam], spec, fouten)

    # --- verdiepende regels die het schema zelf niet uitdrukt ---------------------------------

    if data.get("version") not in (None, 1):
        fouten.append(f"`version` is {data['version']}, maar alleen 1 bestaat")

    budgets = data.get("budgets")
    if isinstance(budgets, dict) and isinstance(budgets.get("max_turns"), dict):
        for station, waarde in budgets["max_turns"].items():
            if station not in STATIONS:
                fouten.append(
                    f"onbekend station `budgets.max_turns.{station}` — "
                    f"bekend: {', '.join(sorted(STATIONS))}"
                )
            elif not isinstance(waarde, int) or isinstance(waarde, bool) or waarde <= 0:
                fouten.append(f"`budgets.max_turns.{station}` moet een positief geheel getal zijn")

    autonomy = data.get("autonomy")
    if isinstance(autonomy, dict):
        # Een onbekende WAARDE is hier net zo gevaarlijk als een onbekende SLEUTEL elders in dit
        # bestand, en om dezelfde reden. `mode: auto` of `mode: full` leest voor een mens als
        # "autonoom", maar autonomie-beslis.sh kent die waarden niet en valt terug op `mens` —
        # de repo staat dan in een stand die niemand koos, en niets is er rood van.
        mode = autonomy.get("mode")
        if isinstance(mode, str) and mode.lower() not in AUTONOMIE_WAARDEN:
            fouten.append(
                f"`autonomy.mode` is {mode!r} — geldig: supervised (mens/begeleid) of "
                f"autonomous (autonoom)"
            )

        stations = autonomy.get("stations")
        if stations is not None and not isinstance(stations, dict):
            fouten.append("`autonomy.stations` moet een mapping zijn van station → stand")
        elif isinstance(stations, dict):
            for station, stand in stations.items():
                if station not in AUTONOMIE_STATIONS:
                    fouten.append(
                        f"onbekend beslispunt `autonomy.stations.{station}` — "
                        f"bekend: {', '.join(sorted(AUTONOMIE_STATIONS))}"
                    )
                if not isinstance(stand, str) or stand.lower() not in AUTONOMIE_WAARDEN:
                    fouten.append(
                        f"`autonomy.stations.{station}` is {stand!r} — geldig: supervised of autonomous"
                    )

    spine = data.get("spine")
    if isinstance(spine, list):
        for item in spine:
            if not isinstance(item, str) or not item.endswith(".yml"):
                fouten.append(f"`spine` moet workflow-bestandsnamen bevatten (*.yml), niet {item!r}")

    areas = data.get("areas")
    if isinstance(areas, list):
        import re as _re

        toegestaan = {"label", "paths", "color", "description"}
        for i, a in enumerate(areas):
            waar = f"areas[{i}]"
            if not isinstance(a, dict):
                fouten.append(f"`{waar}` moet een mapping zijn met `label` en `paths`")
                continue
            for k in a:
                if k not in toegestaan:
                    fouten.append(
                        f"onbekende sleutel `{waar}.{k}` — toegestaan: {', '.join(sorted(toegestaan))}"
                    )
            for verplicht in ("label", "paths"):
                if not isinstance(a.get(verplicht), str) or not a[verplicht].strip():
                    fouten.append(f"`{waar}.{verplicht}` ontbreekt of is leeg")
            # Een kapotte regex zou pas in CI opvallen, en dan als een stille mislabeling —
            # het station valt er niet over, het kent gewoon geen enkel gebied meer toe.
            if isinstance(a.get("paths"), str):
                try:
                    _re.compile(a["paths"])
                except _re.error as exc:
                    fouten.append(f"`{waar}.paths` is geen geldige regex: {exc}")
            kleur = a.get("color")
            if kleur is not None and not _re.fullmatch(r"[0-9A-Fa-f]{6}", str(kleur)):
                fouten.append(f"`{waar}.color` moet 6 hex-tekens zijn (zonder #), is {kleur!r}")

    lanes = data.get("lanes")
    if isinstance(lanes, dict):
        # Een consument zonder self-hosted runners (InvestingOS-model) zet alle lanes op de
        # fallback. Dat is geldig — maar een lane die LEEG is, is dat nooit.
        for k, v in lanes.items():
            if isinstance(v, str) and not v.strip():
                fouten.append(f"`lanes.{k}` is leeg — gebruik de fallback-runner als er geen lane is")

    if fouten:
        for f in fouten:
            print(f"  ❌ {f}")
        print("──")
        print(f"❌ {len(fouten)} fout(en) in {pad}")
        return 1

    print("  ✅ alle secties aanwezig, geen onbekende sleutels")
    print("──")
    print("✅ contract geldig")
    return 0


if __name__ == "__main__":
    sys.exit(main())
