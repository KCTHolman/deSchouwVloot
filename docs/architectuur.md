# deFleet-architectuur — de autonome projectbouwer

**Status:** ontwerp v1 (2026-07-27), bijgewerkt (2026-08-04) · geschreven na het bewijs van fase 2
(probe groen op `ubuntu-latest` + `biohack-light`, pick-runner verhuisd, 38 callers live
cross-repo) · fase 4 (tweede consument) is inmiddels gestart, zie §9.
**Scope:** puur de workflow-/runner-machinerie. Wat een consument inhoudelijk bouwt (app, web,
data) is hier bewust een black box achter een contract.

---

## 1. Wat "AI-native" hier betekent

Niet "een CI met een AI-stap erin", maar een systeem waarin **agents de primaire operators zijn**
en mensen alleen verschijnen op echte beslispunten. Zes principes, elk terug te voeren op een
gemeten pijnpunt uit BiohackOS:

| # | Principe | Waarom (gemeten aanleiding) |
|---|---|---|
| P1 | **Elke poort is machine-checkbaar** | Auto-merge draait al maandenlang op 100% success — poorten die een mens *niet* nodig hebben, mogen hem ook nooit vragen |
| P2 | **Menselijke aandacht is de schaarste** | ~⅔ van de merges bleek CI-onderhoud; het doel is dat de eigenaar alleen features/architectuur approvet |
| P3 | **De pijplijn repareert zichzelf** | De watchdog (reconciler-cron) + conflict-solver + autofix bestaan al; het ontwerp maakt zelf-herstel de norm, escalatie (`needs-human`) de uitzondering |
| P4 | **Kosten zijn een routeringsinput** | Sonnet-per-default, override-vars om GitHub-minuten te sparen, 1-slot-wachtrij tot 78 min — model-, runner- en turn-budget horen per taaktype geconfigureerd, niet per incident |
| P5 | **Het systeem meet zichzelf en leert — en meldt zichzelf** | agent-retro/borg-review-lessen bestaan al; elke structurele fix hier begon met een nulmeting (6,2 denials/run, 18,4% max-turns, 30,8% dubbele builds). Een KPI die alleen in een artifact staat, wordt door niemand gelezen — daarom opent de pijplijn nu zelf een issue zodra de denial-ratio van een run de drempel overschrijdt: van passief meten naar actief melden. |
| P6 | **Verhuizen ≠ verbeteren, en één bron van waarheid** | De 4 gedrifte kopieën bij de tweede consument zijn het schrikbeeld; logica leeft één keer, in deze repo |

## 2. Systeemoverzicht — vier lagen

```mermaid
flowchart TB
    subgraph L3["L3 · Controle & leren (fleet)"]
        WD[watchdog] --- MET[metrics/KPI] --- RETRO[retro-loop]
    end
    subgraph L2["L2 · Consumer-contract (per project-repo)"]
        FY[".fleet.yml"] --- PP["prompt-partials/"] --- TC["dunne callers (~15 regels)"]
        CON["constitution · AGENTS.md · spec (blijft per repo)"]
    end
    subgraph L1["L1 · Fleet-core (workflow_call-logica)"]
        RAKET["intake → plan → build"] --- PRF["PR-flow: check/review/autofix/conflict"] --- GF["gitflow: merge/promote/janitor"] --- INV["invarianten: fleet-doctor"]
    end
    subgraph L0["L0 · Substraat"]
        SELFHOSTED["self-hosted lanes: agent (container) · heavy · light"] --- GHR["ubuntu-latest (fallback/untrusted)"]
    end
    L3 --> L1
    L2 -->|"callers roepen aan met secrets: inherit"| L1
    L1 -->|"runs-on resolvet in caller-context"| L0
```

Het dragende mechanisme is fase-2-bewezen: een reusable workflow draait in de **context van de
aanroeper** — diens runners, diens `github.repository`, diens secrets. deFleet levert logica,
consumenten leveren hardware, secrets en domeinkennis.

**De hardste ontwerpregel die daaruit volgt:** fleet-**logica** — een workflow met een eigen
`steps:`/`runs-on:` — heeft **uitsluitend `workflow_call`-triggers** (I1). Elke
`schedule`/`pull_request`/`issues`/`workflow_run`-trigger leeft in een **dunne caller** in de
consument; een trigger op de logica zelf zou in de context van de infra-repo draaien en geen enkele
consument zien. Elke verhuizing is dus een **splitsing**: logica → fleet, trigger-blok → caller.

Twee uitzonderingen, en die zijn het benoemen waard omdat ze eerder in drie documenten met drie
verschillende omschrijvingen stonden:

1. **`intake.yml`** — de poort hóórt in de eigen context van de infra-repo te draaien. Er is per
   definitie geen consument die 'm als caller kan aftrappen: een idee wéét nog niet bij welk project
   het hoort, dat is nou juist wat de poort bepaalt. De doctor kent deze uitzondering bij naam.
2. **Pure callers** — een bestand waarvan álle jobs `uses:`-jobs zijn. Die hóren juist wél een eigen
   trigger te dragen; een caller zonder trigger draait nooit. De doctor leidt dat af uit het bestand
   zelf (heeft het eigen `steps:`/`runs-on:`?) en niet uit een handmatige lijst, want zo'n lijst
   loopt achter zonder dat iets dat meldt.

*In déze publieke kopie zijn beide uitzonderingen onzichtbaar: de callers zijn eruit gecureerd en
`intake.yml` is hier `workflow_call`-only gemaakt. De invariant staat er wél volledig, want de
regel is onderdeel van het ontwerp — zie [README §Beveiliging](../README.md).*

## 3. De pijplijn end-to-end — stations en poorten

De RAKET veralgemeniseerd. Per station: wie 'm aftrapt (altijd een caller in de consument), welke
lane, en of er een mens in zit.

| Station | Fleet-workflow (doel) | Trigger (in caller) | Lane | Mens-poort |
|---|---|---|---|---|
| **Intake** | `issue-triage` | issue met takenlabel | agent | nee — labelt, dedupt, escaleert alleen bij twijfel |
| **Plan** | `issue-plan` | triage-akkoord | agent | nee (sinds auto-ontsteking ligt de poort op de PR, niet op het plan) |
| **Build** | `agent-run` (het huidige `claude.yml`) | plan-akkoord / dispatch | agent | nee |
| **PR-hygiëne** | `pr-label`, `pr-check` | pull_request | light | nee |
| **Review** | `pr-review` (scope-classifier + agent-review) | PR-events + `needs-review`-label | light→agent | nee — review is advies, geen poort |
| **Governance** | `feature-governance` | pull_request | light | indirect: `impactanalyse` is required check |
| **Herstel** | `pr-autofix`, `pr-conflict-solver` | workflow_run failure / conflict | agent | nee |
| **Merge** | `auto-merge` | workflow_run groen + review-events | light | **ja, alleen features**: de eigenaar z'n PR-approval; fix/chore/docs/ci mergen op groen |
| **Epic-cadans** | `epic-orchestrator`, `next-ticket-picker` | meerdere aanjagers | light | nee — de fase-PR's dragen de poort |
| **Release** | `promote-release` | dispatch / issue-zijspoor | light | **ja**: production-Environment met required reviewer |
| **Zelfherstel** | `pipeline-watchdog` | schedule (caller) | light | nee — escaleert via `needs-human` |
| **Leren** | `agent-retro`, `review-lessen` | schedule (caller) | agent | nee — output is issues/lessen, geen mutaties |

Drie menselijke poorten in het hele systeem: **feature-approval, release-approval, en
`needs-human`-escalaties**. Al het andere is doorstroom. Dat is de definitie van "autonoom" hier —
niet mensloos, maar mens-op-de-juiste-plek.

## 3b. De poort — vanuit deFleet werken (centrale intake)

**Toevoeging v1.1 (2026-07-27, na de eigenaar z'n verfijning).** deFleet is niet alleen bibliotheek maar ook
**de voordeur**: ideeën, issues en epics schiet je in deFleet in, ongeacht voor welk project ze
zijn. Dit is bewust de éne stations-klasse die in deFleet's **eigen** context draait — intake heeft
per definitie nog geen domeincontext nodig, en deFleet's eigen jobs draaien op `ubuntu-latest`
(repo-scoped runners van consumenten zijn hier onbereikbaar, en dat hoort ook zo).

```mermaid
flowchart LR
    IDEE["idee / issue / epic\n(één inbox: deFleet)"] --> RT["fleet-intake\n(licht, klein model):\nwelk project? duplicaat?\ngoed geformuleerd?"]
    RT -->|"eenduidig"| TR["native issue-TRANSFER\nnaar doelrepo"]
    RT -->|"ambigu"| NH["needs-routing\n(mens kiest, dan transfer)"]
    TR --> RAKET["raket van het doelproject:\ntriage → plan → build → PR"]
    RAKET -->|"logica via workflow_call"| FLEET["deFleet (bibliotheek)"]
```

**De ontwerpregel die de kwaliteit bewaakt: plaats vroeg, werk uit in context.** De verleiding is
om centraal ook te *plannen* — maar een plan zonder constitution/spec/codebase van het doelproject
is per definitie oppervlakkig. Intake doet daarom uitsluitend: (1) doelproject bepalen (klein
routeringsbestand `routing.yml` met per consument trefwoorden/gebieden; bij twijfel
`needs-routing`, nooit gokken), (2) **dedupliceren tegen het doelproject** vóór transfer, (3)
formaat normaliseren (issue- vs epic-sjabloon), (4) **native transfer** — nooit kopiëren, dus geen
dubbele waarheid; GitHub's redirect houdt de historie intact. Uitwerken (trap 2, het plan) gebeurt
daarna in het doelproject, waar de kennis woont.

**Gebouwd en bewezen (M2, 2026-07-28).** De poort draait: `.github/workflows/intake.yml` (uitvoerder,
`ubuntu-latest`), `scripts/intake-decide.sh` (de beslislogica als pure functie, 23 offline tests) en
`routing.yml` (trefwoordtabel). Vier paden live geverifieerd — stuiteren op te vaag (`needs-detail`),
niet-gokken bij ambiguïteit (`needs-routing`), native transfer naar de consument, en zelf-routering
van fleet-infrawerk. Latency 14–21 s. Twee ontwerpkeuzes wijken bewust af van de tekst hieronder:

- **Dedupe is informatief, niet blokkerend.** Stap (2) hieronder blijft staan als intentie, maar de
  poort *blokkeert* er niet op: trap 1 van het doelproject dedupt al mét domeinkennis. Een
  blokkerende dubbel-check op het állereerste station, zónder die kennis, levert vooral
  vals-positieve wrijving op het moment dat een idee nog vaart moet krijgen. De poort zet de
  kandidaten in z'n comment, zodat triage een vliegende start heeft.
- **Zelf-routering doet geen transfer.** Fleet-infrawerk routeert naar deFleet zelf; een
  `gh issue transfer` naar de eigen repo faalt hard. Dat pad eindigt dus met een comment en het
  issue blijft staan.

Eén meevaller: **de bord-hersync bleek gratis.** Een transfer laat bordkoppelingen vallen, maar de
`project-sync` van de consument vuurt op het binnenkomende issue en zet 'm er zelf weer op —
gemeten: `transferred` → `added_to_project_v2` binnen dezelfde seconde. Er is dus geen aparte
sync-stap in de poort nodig.

**Randvoorwaarden en valkuilen die hier expliciet zijn opgevangen:**

- **Label-taxonomie reist niet mee bij transfer** — alleen labels die in de doelrepo bestaan
  overleven. Daarom is de `labels:`-sectie van `.fleet.yml` (§4) niet optioneel maar het
  gedeelde woordenboek: intake labelt uitsluitend met namen die elke consument garandeert.
- **Epics** transferen als het epic-issue; de fase-mechaniek (orchestrator, fase-PR's) is en
  blijft per-repo — de poort raakt die niet aan.
- **Fleet-infra-werk routeert naar deFleet zelf.** Daarmee wordt deFleet z'n éigen eerste extra
  consument (zie roadmap): de eigen issues lopen door dezelfde raket-logica via callers op
  `ubuntu-latest`. Dat is het goedkoopste, veiligste proefkonijn voor het `.fleet.yml`-contract
  dat er bestaat — nul domeinrisico, en het migratiewerk zelf krijgt er de volledige pijplijn
  door.
- **De app is de sleutel.** Transfer + issue-write op meerdere repo's vereist één identiteit die
  op álle betrokken repo's geïnstalleerd is — precies besluit #1 (GitHub App). Zonder de app geen
  poort; dit maakt dat besluit van "aanbevolen" tot **voorwaarde**.
- **Kwaliteitsfilter aan de deur:** een idee dat te vaag is om te routeren of te plannen stuitert
  bij intake — label `needs-detail` + één concrete wedervraag als comment in deFleet. Zo ontvangen
  de rakets van de consumenten uitsluitend welgevormd werk, en ligt de verduidelijkingslus bij de
  poort (goedkoop) in plaats van bij trap 2 (duur).
- **Latency-doel:** intake is secondenwerk (klein model, geen checkout van consumenten) — een idee
  hoort binnen een minuut in de juiste repo te liggen.

**De poort krijgt een stuur: het fleet-cockpit-bord.** Een Projects-v2-bord op user-niveau kan
items uit álle repo's van de eigenaar bevatten — het bestaande BiohackOS-bord ís al user-scoped.
Dat bord wordt het fleet-brede cockpit: elk getransfereerd issue wordt er (opnieuw — transfer laat
bordkoppelingen vallen, dat vangt de sync af) aan toegevoegd door de project-sync van de
consument, en de bestaande Kanban-drive-mechaniek (Status → actie) generaliseert zó dat een
kaart die naar "Nu" schuift de raket van het **eigen** doelproject aftrapt. Vanuit deFleet werken
betekent dan concreet: één inbox (deFleet-issues), één overzicht (het bord, alle projecten), één
stuur (slepen = dispatchen), terwijl elke uitvoering in z'n eigen repo-context blijft. Let op de
al-bekende org-haak: bij een latere org-migratie moet dit bord als org-project opnieuw worden
opgebouwd (open beslissing).

## 3c. Extra ingang op de Build-poort — interactief `/pickup` (ontwerp, 2026-08-06)

**Status:** ontwerp goedgekeurd, wacht op spec-review + implementatieplan. Nog niet gebouwd — dit
is de tegenhanger van §3b hierboven, maar dan op het **Build**-station (RAKET-trap 3) in plaats van
op intake.

**Aanleiding.** De `agent-run`/`claude.yml`-workflow is nu de enige manier waarop trap 3 (branch →
PR) gebeurt. Interactieve, native Claude Code-sessies werken merkbaar beter dan de Actions-runner
voor ditzelfde bouwwerk. Het ontwerp voegt daarom een tweede front-deur toe op precies dezelfde
poort: additief, niet vervangend — `claude.yml`, `epic-orchestrator.yml` en de overige autonome
workflows blijven ongewijzigd draaien voor achtergrond- en afwezigheidswerk. `/pickup #<issue>` is
een ander startpunt voor dezelfde poort, geen kortere weg eromheen.

```mermaid
flowchart LR
    KOEN["eigenaar (chat)\n/pickup #123"] --> GATE["RAKET-gate check\n(zelfde poort als claude.yml)"]
    ACTIE["claude.yml / epic-orchestrator.yml\n(autonoom, ongewijzigd)"] --> GATE
    GATE --> CLAIM["claim: label claude-code-sessie\n+ read-after-write"]
    CLAIM --> BUILD["subagent bouwt in worktree:\npreflight --strict → analyze/test → PR"]
    BUILD --> PR["PR open, label af"]
```

**De drie ontwerppunten die het verschil maken tussen "extra ingang" en "sluipweg":**

1. **Dezelfde RAKET-gate, vóór er iets wordt aangeraakt.** Governance/impactanalyse moet al
   goedgekeurd zijn (features), pure `fix`/`chore`/`docs`/`ci` mag direct — identiek aan wat
   `claude.yml` nu afdwingt. Bij een epic-fase-issue geldt bovendien dezelfde "bouw op de
   realiteit, niet alleen op het plan"-check: de vorige fase moet groen/gemerged zijn.
2. **Eén claim, geen dubbele build.** Label `claude-code-sessie` + read-after-write-bevestiging
   voorkomt dat een interactieve sessie en de autonome Action hetzelfde issue tegelijk oppakken.
   Het race-venster zat 'm niet in het label zelf maar in het moment van checken: de her-check
   hoort niet vooraan in een run, maar vlak vóór de daadwerkelijke dispatch — in `claude.yml`'s
   `implement`-job direct na `needs: pick`, en in `epic-orchestrator.yml`'s `advance_milestone()`
   direct vóór de dispatch-call. Zo krimpt het venster van "hele run-duur" terug tot vrijwel nul.
3. **Bot-identiteit, niet eigenaar-identiteit.** Commits en PR's uit een interactieve sessie
   verschijnen onder dezelfde GitHub App-identiteit die `claude.yml` al gebruikt (token gemint per
   sessie, nooit een los `.pem`-bestand op schijf) — niet als Koen zelf. Daarmee blijft de
   bestaande code-owner-approval-gate (§3, "Merge") betekenisvol, ongeacht via welke ingang de PR
   is geopend.

Uitdrukkelijk **buiten scope** voor dit ontwerp: een loop die meerdere epic-fasen achter elkaar
afwerkt in één sessie (blijft één fase per aanroep), en het vervangen van review/triage/andere
autonome stations door een interactief pad — die blijven op de Action. Zie ook §3 hierboven: de
drie mens-poorten (feature-approval, release-approval, `needs-human`) veranderen door dit ontwerp
niet — `/pickup` voegt een ingang toe, geen poort.

## 4. Het consumer-contract

Wat een project-repo levert om "op de fleet" te draaien:

**`.fleet.yml`** (gevalideerd door de fleet-config-check, met defaults zodat een minimale
consument ~10 regels heeft):

```yaml
# schets — het schema is fase-3-werk
lanes:
  agent: biohack-agent      # label van de agent-lane in DEZE repo
  heavy: biohack-heavy
  light: biohack-light
  fallback: ubuntu-latest
gates:
  feature_approval: true    # BESCHRIJFT sinds 2026-08-23 (zie §4b) — sturend is `autonomy` hieronder
  release_environment: production
autonomy:                   # §4b — de stand van de repo
  mode: supervised          # of: autonomous
  allow_breaking: false     # ook op autonoom wacht een breaking change op een mens
budgets:
  default_model: claude-sonnet-5
  escalation_model: claude-opus-5   # architectuur-/epic-planwerk
  max_turns: {triage: 30, plan: 50, build: 80, review: 40}
labels:                     # de takentaxonomie van deze consument
  task: claude-task
  human: needs-human
```

**`prompt-partials/`** — de domeinkennis die nu hardgecodeerd in de `[shared]`-workflows zit
(bron-hiërarchie, verboden paden, toolchain-aanwijzingen). Fleet-logica checkt de **caller** uit en
leest deze bestanden; fleet levert de skeletten ("je bent de triage-agent, doe X"), de consument
levert het domein ("in dit project geldt constitution.md > spec.md, raak nooit pad Y aan").

**Dunne callers** — één per station: triggers + `uses: KCTHolman/fleet/...@<sha>` +
`secrets: inherit`. Een caller is 20 tot ~100 regels, afhankelijk van hoeveel inputs het station
kent; het model is "trigger-blok plus doorgeefluik", niet "vaste vijftien regels".

Twee verduidelijkingen, omdat de schets hierboven compacter is dan de praktijk:

- **Een caller staat naast, niet in plaats van, het domein.** De consument houdt bewust z'n eigen
  domein-workflows (deploys, release-builds, domein-crons) — die dragen productkennis en horen daar
  thuis. De migratie verplaatst alleen de *machinerie*; wat er per repo overblijft is precies wat
  per repo hoort te verschillen.
- **De ref is een SHA, geen `@main`.** Zie [gitflow §13.D](gitflow.md) en I24: alleen de canary
  volgt `@main`. Codevoorbeelden in deze repo tonen `@main` omdat dat leesbaarder is; in een echte
  consument staat daar een volle 40-teken-SHA, bijgewerkt door de bump-baan en bewaakt door
  `doctor:pin`.

**Blijft volledig per repo:** constitution, AGENTS.md, spec, domein-workflows (`[biohack]`-bucket:
deploys, domein-crons, release-builds) en de guard-scripts die domeinkennis dragen
(consistency-doctor, spec-drift). Fleet raakt die nooit aan.

**Secrets-contract:** fleet declareert secrets uitsluitend `required: false` met gedocumenteerde
degradatie (het pick-runner-patroon: geen `RUNNER_CHECK_TOKEN` → fallback, nooit stil falen).
Consument geeft alles door via `secrets: inherit`. Fleet-repo zelf bevat **nul** secrets.

## 4b. De autonomiestand

Tot 2026-08-23 was autonomie in de Vloot een **eigenschap**, geen keuze: welke beslissingen een
mens moest nemen lag verspreid over een stuk of tien `if`-takken in `auto-merge.yml`, een handvol
labels, en een contractsleutel (`gates.feature_approval`) die *geen enkele workflow las*. Je kon
niet opzoeken in welke stand een repo stond, en je kon 'm niet omzetten zonder de merge-machine te
bewerken.

De sectie `autonomy` maakt er één schakelaar van, met één resolver eronder:
[`scripts/autonomie-beslis.sh`](../scripts/autonomie-beslis.sh).

### De twee standen

| | wat de machine doet | wat jij doet |
|---|---|---|
| `supervised` | kleine niet-brekende PR's mergen op groen; een feature/breaking PR wacht | je grijpt in om iets te **laten gebeuren** (approval, `plan-goedgekeurd`) |
| `autonomous` | ook een groene feature-PR merget zichzelf | je grijpt in om iets te **voorkomen** (`needs-human`, `no-automerge`, `FLEET_HALT`) |

Dat is het hele verschil, en het is expres klein: in **beide** standen kan een mens overal
ingrijpen. Alleen de richting van de default draait om.

### De vloer — wat nooit meeschakelt

Vier poorten liggen in de resolver vóór de schakelaar. Ze sluiten ongeacht de stand:

1. **de gevoelige-paden-guard** — secrets, migraties, de pijplijn zelf, een nieuwe externe
   bestemming. Daar telt uitsluitend een echte owner-approval. Een consument **zonder**
   `scripts/sensitive-paths-guard.sh` merget daarom nooit autonoom: de guard valt fail-closed en de
   PR telt als gevoelig. Dat is geen bug maar de toegangseis — autonomie zonder guard is alleen
   snelheid zonder rem.
2. **de noodrem** — repo-variabele `FLEET_HALT`. Elke waarde behalve `0`/`false`/leeg zet de hele
   repo terug naar mens-in-de-lus. Bewust omgekeerd streng: bij een noodrem is de dure fout dat 'ie
   niet pakt.
3. **de stoplabels** — `needs-human` op een issue, `no-automerge` op een PR.
4. **breaking changes** — die wachten, tenzij het contract expliciet `allow_breaking: true` zegt.
   Die sleutel staat bewust **alleen** in `.fleet.yml` en niet in de repo-variabele: de dagelijkse
   stand mag je zonder wrijving omzetten, het plafond niet.

### De volgorde

```
gevoelig pad → noodrem → stoplabel → breaking
   → FLEET_AUTONOMY (repo-variabele)
   → autonomy.stations.<station>
   → autonomy.mode
   → geen sectie? mens.
```

Alles wat niet aantoonbaar autonoom mag, is `mens`. Een onleesbaar contract, een ontbrekende
PyYAML, een spelfout in de stand: allemaal `mens`, met een reden op stderr. Dat is de omgekeerde
bias van `noodrem-beslis.sh` (waar een storing juist nóóit remt), en het verschil is de kostbare
fout: daar is dat een PR die onnodig wacht, hier is dat een merge die niemand heeft gezien.

### Omzetten

Zonder PR, met [`scripts/autonomie.sh`](../scripts/autonomie.sh):

```bash
bash scripts/autonomie.sh status              # de stand van alle consumenten
bash scripts/autonomie.sh set KCTHolman/Portfolio autonomous
bash scripts/autonomie.sh halt KCTHolman/BiohackOS    # noodrem om
```

### Beslispunten ≠ stations

`autonomy.stations` is een andere lijst dan `budgets.max_turns` (`triage`, `plan`, `build`,
`review`, `autofix`, `conflict`), en dat verschil is inhoudelijk: turn-budgetten gaan over wat er
**draait**, autonomie over wie **beslist**. `build` beslist niets, `merge` draait niets. De
validator houdt beide lijsten apart.

**Vandaag kent `autonomy.stations` precies één beslispunt: `merge`** — het enige dat de resolver
daadwerkelijk aanroept (`auto-merge.yml`). `triage`, `plan` en `release` zijn echte beslispunten in
de pijplijn, maar staan er bewust **niet** in zolang geen workflow ze uitleest.

Dat is geen bescheidenheid maar de hele reden dat deze sectie bestaat. `gates.feature_approval`
stond twee jaar in elk contract zonder ooit gelezen te worden: je zette 'm, er gebeurde niets, en
niets werd rood. Een station alvast toelaten "omdat we het later wiren" bouwt diezelfde stilte
opnieuw. Nu is `stations.triage` een **harde fout in CI** in plaats van een instelling die niets
doet.

De lijst groeit per gewired station, in dezelfde PR die 'm wiret — één regel in
`check-fleet-yml.py`, één in `autonomie-beslis.sh`, en de bijbehorende test verhuist van "fout"
naar "geldig".

## 5. Runner-substraat en capaciteit

> **Showcase-noot.** De concrete capaciteitscijfers, de isolatiestatus per lane en het
> onderhoudsdraaiboek van de host stonden hier oorspronkelijk voluit. Die zijn uit deze publieke
> versie gehaald: ze zeggen niets over het ontwerp, maar wél precies waar een host op dat moment
> zwak stond. Wat overblijft is de vorm van het model — dat is het deel dat overdraagbaar is.

Het substraat bestaat uit drie lanes met elk een eigen karakter:

| Lane | Werk | Isolatievorm |
|---|---|---|
| agent | agent-runs, reviews — verwerkt onvertrouwde tekst | ephemeral container, eigen user, verse registratie per run, geen docker-daemon |
| heavy | builds, tests, migratie-checks | zwaar en langlopend; container-isolatie is hier het einddoel |
| light | git/`gh`-secondenwerk | licht en kort; mag nooit achter zwaar werk wachten |

Ontwerpkeuzes:

- **De agent-lane-vorm is het eindbeeld voor álle lanes**: ephemeral container per job, per-lane
  user, cache-volumes, verse registratie per run. De wrapper-loop + `Dockerfile.{lane}` bestaan al;
  light eerst (kleinste toolchain, laagste risico), heavy laatst (`heavy-2` blijft vangnet).
  **Gemeten valkuil:** een gemount cache-volume is niet automatisch de plek waar de toolchain z'n
  cache zoekt — een SDK-cache die stil naast het gemounte volume schreef in plaats van erin, bleek
  pas op te vallen doordat elke run de cache toch opnieuw opbouwde. De omgevingsvariabele die de
  toolchain naar het gemounte pad wijst, hoort dus met dezelfde stelligheid gezet te worden als het
  volume zelf — een cache-mount zonder die knop is geen cache, alleen schijfruimte.
- **Routering: één beslispunt.** Vandaag zijn er twee mechanismen: pick-runner (availability-check)
  en de `RUNNER_OVERRIDE_*`-vars die 'm kortsluiten (credits-modus). Dat blijft — maar expliciet
  gerangschikt: override-var = kill-switch/kostenmodus, picker = default zodra minuten geen
  schaarste zijn. De picker leest in fase 3 z'n lane-labels uit `.fleet.yml` i.p.v. inputs-per-caller.
- **Multi-consument op één host:** runner-labels zijn repo-scoped; een tweede consument krijgt
  éigen registraties op dezelfde host, of draait volledig op `ubuntu-latest`. Het aantal
  gelijktijdige slots is een RAM-som, geen smaak: elk type build heeft een gemeten piek, en het
  plafond is de som van de worst case — niet het aantal registraties dat je toevallig aanmaakte.
  Nieuwe registratie erbij betekent die som opnieuw maken.
- **Org-migratie blijft de nettere eindtoestand** (gedeelde runner-groups i.p.v.
  per-repo-registraties), maar niets hierboven wacht erop.

## 6. Invarianten en zelf-diagnose — de "fleet-doctor"

De losse guards zijn opgegaan in één samenhangende, fleet-geleverde suite. Dit zijn de modules die
`scripts/fleet-doctor.sh` daadwerkelijk kent — opvraagbaar met `--module modules`, en dat is geen
gemak maar noodzaak: een consument die op een oudere SHA staat, moet het verschil kunnen zien
tussen een typefout en een module die z'n gepinde doctor nog niet heeft.

| Module | Wat 'ie vaststelt | Invarianten | Netwerk nodig |
|---|---|---|---|
| *consistentie* | eigen triggers op fleet-logica; callers wijzen naar bestaande paden; geen `container:` op agent-lane-jobs; `workflow_run`-naamlijsten matchen echte namen | I1, I2, I5, I7 | nee |
| *permissies* | een caller verleent minstens wat z'n station nodig heeft (union van workflow- én job-permissies) | I26 | nee |
| *spine* | geen spine-workflow staat `disabled_manually`/`disabled_inactivity` | I25 | ja |
| *runners* | lanes online, labels kloppen, override-modus is nooit stilzwijgend | I10, I11 | ja |
| *contract* | `.fleet.yml` valideert tegen het schema | — | nee |
| *liveness* | reageert elke `workflow_run`-luisteraar op z'n bron? | I27 | ja |
| *afhankelijkheden* | eist een aangeroepen station een script dat de consument niet heeft? | I28 | nee |
| *pin* | pin-achterstand, verdeelde pins, geneste refs op een branch | I24 | ja (zacht) |

De modules zónder netwerk zijn offline testbaar en staan onder test in `fleet-doctor.test.sh`; van
`liveness` en `pin` is de beslislogica losgetrokken in een pure functie (`liveness_oordeel`,
`pin_oordeel`) die via een verborgen `--module …-oordeel` óók offline getoetst wordt. De
API-afhankelijke bedrading eromheen draait tegen een nagemaakte `gh` die de meegegeven `--jq` met de
échte jq toepast, zodat de jq-expressie zelf onder test staat en niet alleen de bedrading.

Belangrijk onderscheid: de doctor **rapporteert hard, muteert nooit**. Mutaties (reregistratie,
prunes) blijven bij de watchdog (repo-scope) of owner-assist (host-scope, zie
`self-hosted host-diagnostic-access.md` in BiohackOS). En de les van run 30206695669 blijft wet: diagnostiek
is best-effort, een lege grep mag nooit het rapport afkappen.

## 7. Security-model — drie vertrouwenszones

| Zone | Wat er draait | Regels |
|---|---|---|
| **Untrusted** (PR-/issue-inhoud van buiten de flow) | pr-review, autofix, alles wat vreemde tekst leest | agent-lane-container ÍS de sandbox (geen docker-daemon, geen host-mounts); least-secrets: nooit deploy-/domein-secrets in scope, ook niet via inherit; nooit `pull_request_target` naar self-hosted |
| **Trusted-automatisch** (main-push, schedule, dispatch) | gitflow, orchestrator, watchdog | app-token i.p.v. brede PAT (zie hieronder); job-permissions minimaal |
| **Owner** (host-mutaties, repo-settings, release) | registraties, ruleset, production-approve | uitsluitend de eigenaar, via een apart en expliciet gelogd kanaal — nooit vanuit een workflow |

Drie structurele token-besluiten:

1. **Classic `PROJECT_TOKEN` → GitHub App** (de `workflow-writer`-app bestaat al). App-tokens zijn
   per-repo-scoped, kort-levend, én lossen het vanavond drie keer geraakte **auteur=eigenaar-
   probleem** op: PR's geopend door de app kan de eigenaar gewoon approven; interactieve sessies horen
   via diezelfde app te openen i.p.v. onder de eigenaar z'n eigen token (drie admin-merges vanavond waren
   het gevolg).
2. **Pin-beleid gelaagd:** third-party actions → SHA (audit-blocker, staat nog open); fleet-refs →
   `@main` zolang er één consument is, **SHA/tag zodra de tweede aanhaakt** (vastgelegd in
   het migratielogboek); GitHub-eigen actions → major-tag. **Status:** de tweede consument is
   inmiddels aangehaakt, en het pin-beleid staat sindsdien ook echt aan — fleet-refs draaien op
   een SHA-pin met een nachtelijke bump-job die zichzelf ongepind laat (een kapotte pin mag zijn
   eigen reparatie niet kunnen blokkeren) en pas bumpt nadat de canary (deFleet zelf, op `@main`)
   groen is.
3. **Fleet voegt nooit netwerkbestemmingen toe.** Constitution-grenzen van consumenten (welke
   API's, welke data) zijn per definitie buiten fleet-scope; een fleet-workflow praat alleen met
   GitHub zelf.

## 8. Efficiency-ontwerp — van gemeten lek naar structureel antwoord

| Gemeten lek (nulmeting 2026-07-19) | Structureel antwoord in dit ontwerp |
|---|---|
| 6,2 permission-denials/run, 40-45% herhalingen | Per-station allowlist-profielen in de agent-run-workflow (triage hoeft minder dan build); de ci-agent-gedragslessen verhuizen mee als prompt-partial voor élke consument. **Nieuw:** de ratio wordt niet alleen gemeten maar ook bewaakt — komt hij boven een drempel, dan opent de pijplijn daar zelf een issue over, in plaats van te wachten tot iemand toevallig de KPI-log opent |
| 18,4% `error_max_turns` | Turn-budget per taaktype in `.fleet.yml` (`budgets.max_turns`); retro bewaakt de verhouding budget↔faalkans per station |
| 30,8% dubbele builds | Concurrency-groepen op subject (issue/PR), gestandaardiseerd in de fleet-skeletten — nooit meer per workflow uitgevonden |
| Wachtrij tot 78 min op 1-slot-lane | Agent-lane heeft nu 2 slots; picker + override als capaciteitsregelaar; KPI bewaakt wachttijd |
| Auto-merge ↔ workflow_run **naam**-koppeling (beet vanavond bij de rename) | De triggerlijsten zijn caller-bestanden (consument), de doctor-module *consistentie* bewaakt naam↔lijst; optioneel later: één verzamel-"gate"-check zodat auto-merge op één naam luistert |
| Rerun = oude YAML-snapshot (kostte vanavond bijna een verkeerde architectuurkeuze) | Vast diagnostiek-principe in de watchdog: nooit een fix verifiëren via `gh run rerun`; altijd verse trigger na `update-branch` |
| Model-kosten | Routering in `.fleet.yml`: sonnet default, opus alleen voor plan-/architectuurstations; de review-scope-classifier (bestaat) bepaalt of een review überhaupt draait |

**KPI-set** (nachtelijke metrics-workflow per consument, artifact + wekelijkse retro-issue):
denials/run · max-turns-ratio · dubbele builds · wachttijd per lane · mens-poort-latency (hoe lang
wacht een feature-PR op approval) · kosten per gemergde PR. De laatste twee zijn de échte
autonomie-metrieken: dalen die, dan wordt het systeem zelfstandiger.

## 9. Migratie-roadmap (vervolg op fase 2)

**Fase 2-rest — de overige `[fleet]`-workflows, klein → groot, elk als splitsing (logica → fleet,
trigger-caller → consument):**

| Volgorde | Workflow | Risico | Opmerking |
|---|---|---|---|
| 1 | `self-hosted host-diagnostics` | nul | dispatch-only, geen afhankelijkheden |
| 2 | `runner-fleet-assert` | laag | eerste schedule-caller-splitsing als patroonbewijs |
| 3 | `branch-protection-assert`, `gitflow-doctor`, `branch-janitor`, `cleanup-merged` | laag | hygiëne-groep |
| 4 | `release-storage-cleanup`, `issue-release`, `agent-track` | laag | |
| 5 | `promote-release` | midden | raakt de production-Environment-poort — verifieer de approval-flow expliciet |
| 6 | `auto-merge` | **hoog** | de spine (100% success): pas verhuizen als de doctor-module *consistentie* draait; één-op-één, geen verbeteringen |

**Fase 2½ — de poort (nieuw, uit de v1.1-verfijning):** (a) GitHub App installeren op fleet +
BiohackOS (besluit #1, nu voorwaarde); (b) `routing.yml` + fleet-intake-workflow in deFleet's
eigen context (`ubuntu-latest`), met dedupe-tegen-doelrepo, `needs-detail`-stuiter en native
transfer; (c) issue-/epic-sjablonen in deFleet gespiegeld aan de raket-sjablonen; (d) het
user-bord als cockpit: project-sync van de consument voegt getransfereerde issues (opnieuw) toe.
Validatie: één echt idee end-to-end — deFleet-issue → transfer → BiohackOS-raket → gemergde PR —
zonder handmatige stap behalve de bestaande poorten. **deFleet wordt hier meteen z'n eigen eerste
extra consument**: fleet-infra-issues routeren naar deFleet zelf en lopen door dezelfde
raket-logica via callers op `ubuntu-latest` — het veiligste proefkonijn voor het contract dat er
bestaat.

**Fase 3 — parametrisering van `[shared]` (18):** eerst het `.fleet.yml`-schema + validator, dan
één pilot (`pr-label`: kleinste prompt-oppervlak), dan de PR-flow-groep, dan de raket-stations, en
**`agent-run`/`claude.yml` als allerlaatste** (grootste bestand, elf afnemers). Elke stap: consument
draait één week op de fleet-versie naast ongewijzigd gedrag vóór de volgende.

**Fase 4 — Tweede consument als validatie: inmiddels gestart, niet meer alleen een plan.** Een
tweede project — andere taal, andere stack, volledig op `ubuntu-latest`, geen self-hosted
host-claim — is aangehaakt met een minimale `.fleet.yml` en de eerste dunne callers. Succescriterium
blijft: de complete raket zonder één regel fleet-logica te forken, en de eerste stap (een
zuivere gitflow-workflow zonder projectkennis) staat er al. Dit is ook het moment van het
SHA-pin-besluit — zie §7.2, dat besluit is genomen en staat aan.

**Fase 5 — org + runner-groups** (besluit ligt bij de eigenaar; haken in het migratielogboek). **Fase 6 —
nazorg:** oude paden opruimen, lessen → retro.

## 10. Openstaande besluiten (voor de eigenaar, met aanbeveling)

1. **GitHub App als identiteit voor álle geautomatiseerde én interactieve PR's + de poort** —
   status verzwaard van "aanbevolen" naar **voorwaarde** (fase 2½): zonder app geen
   cross-repo-transfer, en 'ie lost tegelijk de approval-flow (auteur=eigenaar) en de
   classic-PAT-blocker op.
2. **Moment van org-migratie** — aanbevolen: pas ná fase 4; de tweede consument op ubuntu bewijst eerst
   dat het zonder kan.
3. **Verzamel-"gate"-check voor auto-merge** (één check-naam i.p.v. naam-lijsten) — aanbevolen:
   ja, maar pas bij de auto-merge-verhuizing zelf (stap 6), niet eerder — spine niet twee keer
   aanraken.
4. **Lanes containeriseren (light/heavy)** — aanbevolen: light in het volgende onderhoudsvenster
   (draaiboek bestaat), heavy pas na een maand stabiel light.
5. **KPI-dashboard-locatie** — artifact-per-run is genoeg om te starten; pas bij bewezen gebruik
   iets bouwen (geen nieuwe bestemmingen).

---

*Wijzigingsbeleid van dit document: dit is de kaart, het interne migratielogboek is de status. Wie
een fase uitvoert, werkt het plan bij en laat dit document alleen aanpassen als het ontwerp zelf
wijzigt — met de reden erbij.*
