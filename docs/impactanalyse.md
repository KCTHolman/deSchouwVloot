# Impactanalyse als code — de IA-code

**Status:** actief · geport uit BiohackOS (PR #2028/#2031, 2026-08-12) — de eerste consument waar
dit mechanisme draait en waar het is bewezen. Dit document is de mensvriendelijke uitleg van de
Fleet-machinerie; de mechanica zelf staat in
[`scripts/check-impact.sh`](../scripts/check-impact.sh) en wordt aangeroepen door
[`.github/workflows/feature-governance.yml`](../.github/workflows/feature-governance.yml) als de
required check **`impactanalyse`**. Zie ook [`docs/gitflow.md` §3.2](gitflow.md) (het station in de
PR-flow) en [`docs/architectuur.md` §3](architectuur.md) (het station in de stationstabel).

## Waarom een code in plaats van tien alinea's

De oorspronkelijke checklist in BiohackOS toetste alleen of tien kopjes bestonden en de vakjes
`[x]` stonden — pure self-attestatie. Tien vinkjes zonder échte analyse slaagden technisch, en dat
werd daar met zoveel woorden erkend als bewust restrisico. Drie problemen:

1. **Niet toetsbaar.** Vrije tekst kan alles beweren; een script kan er niets mee.
2. **Duur in tokens en aandacht.** Tien alinea's proza per PR, waarvan de meeste "n.v.t." zeggen.
3. **Drift.** Kopjes in het template, kopjes in de workflow en kopjes in de doc liepen uit elkaar
   zonder dat iets dat merkte — exact het patroon dat README §"Groen is geen bewijs" beschrijft:
   een check die altijd hetzelfde antwoordt, is van buiten niet te onderscheiden van een check die
   werkt.

Met vaste antwoorden wordt elk veld een **falsifieerbare bewering** die tegen de daadwerkelijke
diff gehouden kan worden. `db=geen` in een PR die een migratie toevoegt is aantoonbaar onwaar, en
valt om zonder dat er een mens naar hoeft te kijken. Wat overblijft aan proza is precies het deel
dat een mens wél moet lezen: één regel toelichting bij de antwoorden die om context vragen.

## Consument-eigendom — wat waar leeft

Zelfde grens als `.fleet.yml` bij `pr-label`: de **vragenlijst** (velden, waarden, verboden
combinaties, verplichte toelichting, kruiscontrole-regels) is domeinkennis en leeft in het schema
van de consument, niet in Fleet.

| Onderdeel | Eigenaar | Bestand |
|---|---|---|
| Parser + validator + kruiscontrole | Fleet | `scripts/check-impact.sh` |
| De required check `impactanalyse` | Fleet | `.github/workflows/feature-governance.yml` (`workflow_call`) |
| De vragenlijst zelf | **consument** | `.github/impact-codes.yml` in de consument-repo |
| Voorbeeld om vanaf te starten | Fleet | [`examples/impact-codes.example.yml`](../examples/impact-codes.example.yml) |

Het script is zelf domeinvrij: geen enkele veldnaam of padregel staat hardgecodeerd in
`check-impact.sh`. Kopieer het voorbeeldschema naar `.github/impact-codes.yml` in je eigen repo en
pas het aan op je eigen mappenindeling — de velden hieronder (Next.js/Python/Supabase) zijn
illustratief, geen vaste vocabulaire.

## Het formaat

Eén fenced blok met de info-string `ia`, ergens in de PR-body. Eerste token is de schema-versie,
daarna `sleutel=waarde`-paren, gescheiden door witruimte — regeleindes tellen als witruimte, dus je
mag afbreken.

```ia
v1 arch=conform net=geen ux=nvt plek=ci db=geen api=geen frontend=geen services=geen
   herbruik=uitgebreid risico=laag test=zelftest docs=nieuw
```

Velden met *(meerdere)* accepteren een komma-lijst zonder spaties: `test=unit,integratie`.

De tabel hieronder is **gegenereerd** uit [`examples/impact-codes.example.yml`](../examples/impact-codes.example.yml)
met `bash scripts/check-impact.sh --schema examples/impact-codes.example.yml --uitleg`; de
zelftest (`scripts/check-impact.test.sh`) bewaakt dat dit blok gelijk blijft aan dat schema. Je
eigen `.github/impact-codes.yml` genereert je eigen tabel op dezelfde manier.

<!-- UITLEG:START -->
| # | Veld | Vraag | Toegestane antwoorden |
|---|---|---|---|
| 1 | `arch` | Architectuur & richtlijnen | `conform` · `uitbreiding` · `amendement` |
| 1b | `net` | Netwerk-bestemming | `geen` · `bestaand` · `nieuw` |
| 2 | `ux` | Design & UX | `nvt` · `bestaand` · `nieuw-patroon` |
| 3 | `plek` | Waar leeft de wijziging | `web` · `python` · `beide` · `ci` · `data` |
| 4 | `db` | Databasewijzigingen | `geen` · `migratie` · `breaking` |
| 5 | `api` | Backend/API | `geen` · `intern` · `edge-function` · `extern` |
| 6 | `frontend` | Next.js-frontend | `geen` · `component` · `pagina` · `nieuwe-pagina` |
| 7 | `services` | Python-services | `geen` · `logica` · `endpoint` · `nieuwe-service` |
| 8 | `herbruik` | Herbruikbaarheid | `nvt` · `hergebruikt` · `uitgebreid` · `nieuw` |
| 9 | `risico` | Security / performance / schaalbaarheid *(meerdere, komma-gescheiden)* | `laag` · `privacy` · `performance` · `schaal` · `hoog` |
| 10a | `test` | Tests *(meerdere, komma-gescheiden)* | `geen` · `unit` · `integratie` · `zelftest` |
| 10b | `docs` | Documentatie | `geen` · `bijgewerkt` · `nieuw` |
<!-- UITLEG:END -->

Twee velden staan bewust los van de rest:

- **`net` (1b) is losgetrokken uit `arch`.** De netwerk-bestemming is meestal de strengste
  onwrikbare grens van een project en verdient een eigen, toetsbaar veld in plaats van een zin
  binnen een alinea over architectuur.
- **Tests en documentatie zijn gesplitst (10a/10b).** Twee losse beweringen zijn allebei tegen de
  diff te toetsen; één gecombineerd veld niet.

## De kruiscontrole tegen de diff

Dit is de laag die de IA-code onderscheidt van een checklist. `feature-governance.yml` haalt de
bestandenlijst van de PR op (`gh api repos/…/pulls/<n>/files`) en `check-impact.sh` toetst elke
`vereist`/`verbiedt`-regel uit het schema:

- **`vereist`** — het antwoord claimt een wijziging in een gebied; raakt de diff daar niets, dan is
  de claim onwaar. Bv. `db=migratie` zonder een bestand onder `supabase/migrations/`.
- **`verbiedt`** — het antwoord claimt géén impact in een gebied; raakt de diff dat gebied tóch,
  dan is de claim onwaar. Bv. `frontend=geen` terwijl `web/app/page.tsx` verandert.

**Bewust restrisico** (overgenomen van de bronrepo, geldt hier onverkort): de kruiscontrole toetst
*paden*, niet *inhoud*. `risico=laag` en `herbruik=hergebruikt` blijven beweringen die alleen een
reviewer kan wegen, en `net=bestaand` toetst op het aanraken van je eigen sanctioned-hosts-bestand,
niet op een rauwe URL ergens in de code. Dat is een kleiner restrisico dan de oude tien vinkjes,
maar geen nul — de review (mens) blijft de inhoudelijke poort.

## Lokaal draaien

```sh
# Formaat + beleid, zonder diff-kruiscontrole (snel, terwijl je de body schrijft):
bash scripts/check-impact.sh --body pr-body.md

# Inclusief kruiscontrole tegen wat je daadwerkelijk gaat pushen:
git diff --name-only origin/main...HEAD > /tmp/ia-files.txt
bash scripts/check-impact.sh --body pr-body.md --files /tmp/ia-files.txt

bash scripts/check-impact.sh --sjabloon   # leeg codeblok om in te vullen
bash scripts/check-impact.sh --uitleg     # de veldtabel van JOUW schema
```

Standaard leest `check-impact.sh` `.github/impact-codes.yml` in de repo-root; geef `--schema <pad>`
mee om tegen een ander schema te draaien (zoals de zelftest tegen het voorbeeld doet).

## Aan de haak hangen in je eigen consument

1. Kopieer [`examples/impact-codes.example.yml`](../examples/impact-codes.example.yml) naar
   `.github/impact-codes.yml` en pas velden/waarden/`regels:` aan op je eigen mappenindeling.
2. Roep de reusable workflow aan vanuit je eigen `pull_request`-caller:
   ```yaml
   jobs:
     feature-governance:
       uses: KCTHolman/fleet/.github/workflows/feature-governance.yml@main
       secrets: inherit
   ```
3. Zet **`impactanalyse`** als required status check op je `main`-ruleset.
4. Zet het `\`\`\`ia`-blok (uit `--sjabloon`) in je eigen PR-template.

## Een veld of antwoord wijzigen (in je eigen schema)

1. Wijzig **alleen** je eigen `.github/impact-codes.yml` — velden, waarden, verboden combinaties,
   verplichte toelichting en diff-regels staan daar allemaal.
2. Genereer je eigen veldtabel opnieuw met `bash scripts/check-impact.sh --uitleg` en zet die in je
   eigen documentatie, zodat die niet als tweede waarheid kan gaan drift-en.
3. Verhoog `versie:` alleen bij een **breaking** wijziging (veld verwijderd/hernoemd, betekenis van
   een bestaand antwoord veranderd). Een veld of waarde tóevoegen is niet breaking — behalve als het
   veld verplicht wordt, want dan faalt elke openstaande PR-body; doe dat bewust.
