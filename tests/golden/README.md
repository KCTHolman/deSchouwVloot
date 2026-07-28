# Golden-taskset — CI voor de configuratie die géén code is

Zodra prompts en routeringsregels **data** worden (fase 3), zijn wijzigingen eraan **deploys**.
En deploys zonder tests waren nou precies het probleem dat deze hele migratie moet oplossen.

Een gewone unit-test dekt dat niet: `intake-decide.test.sh` toetst of de *logica* klopt met
verzonnen invoer, maar niet of `routing.yml` nog steeds de *bedoelde uitkomst* geeft voor werk dat
er in het echt doorheen komt. Voeg één te breed trefwoord toe en de logica blijft groen terwijl
de helft van de issues opeens naar `needs-routing` stuitert.

Deze map bevriest daarom een set **echte gevallen met een bekende-goede uitkomst**. Wijzig je
`routing.yml` of de beslislogica, dan zegt de golden-run direct wat er van gedrag verandert —
in plaats van dat je het weken later merkt aan issues die op de verkeerde plek liggen.

## Vorm

Eén `.case`-bestand per geval:

```
titel: <de issue-titel>
verwacht: transfer KCTHolman/BiohackOS   # of: routing  |  detail
---
<de issue-body>
```

## Draaien

```bash
bash scripts/golden-run.sh
```

Draait mee in `checks.yml`, dus elke push aan `routing.yml` of `intake-decide.sh` wordt getoetst.

## Een geval toevoegen

Doe dat bij élke routeringsverrassing: kwam een issue op de verkeerde plek terecht, of stuiterde
er één onterecht, dan hoort dat geval hier vóór je de regels aanpast. Zo groeit de set precies
langs de randen waar 'ie fout ging, en niet met bedachte gevallen die nooit voorkomen.

## Grensgevallen (08–10) — waarom een golden-set van duidelijke gevallen niets bewaakt

Gevallen 01–07 winnen allemaal met **2-0 of 3-0**: de verliezende consument scoort steevast nul.
Dat leest als een gezonde set, maar het betekent dat één te breed trefwoord hoogstens één punt
toevoegt en dus **nooit een uitkomst kan kantelen**. Zo'n set slaagt voor altijd — precies wat een
regressietest niet moet doen.

Gemeten op 2026-07-28: een bewust te breed trefwoord toevoegen liet alle zeven gevallen groen
(exit 0). Met de drie gevallen hieronder erbij wordt datzelfde trefwoord wél gevangen (exit 1).

| # | Vorm | Bewaakt |
|---|---|---|
| 08 | domein wint met **2-1** | een infrastructuurwoord dat te breed wordt, kantelt dit geval |
| 09 | infrastructuur wint met **2-1** | spiegelbeeld: een domeinwoord dat te breed wordt |
| 10 | **gelijkspel** | dat onbeslist ook echt `routing` blijft. Geval 05 dekt alleen *nul* treffers; dit dekt de andere manier om onbeslist te zijn |

**Houd de body's trefwoord-arm.** De acceptatiecriteria in 08–10 zijn bewust generiek geformuleerd
en de toelichting staat hier in plaats van in het `.case`-bestand: woorden als *poort*, *workflow*
en *lane* staan zélf in `routing.yml` en zouden de score van hun eigen testgeval vervuilen.

Voeg je een geval toe, noteer dan de marge. Een nieuw geval dat met 3-0 wint voegt dekking toe voor
de logica, maar niets voor randverschuiving.
