# deSchouwVloot — een AI-native CI/CD-pijplijn, als showcase

Gedeelde gitflow- en runner-infrastructuur voor meerdere projecten: herbruikbare workflows, een
routerende intake-poort, en een set machinaal toetsbare invarianten die de pijplijn zichzelf laten
bewaken. Geen productcode, geen domeinlogica, geen data — alleen de machinerie zelf.

Hierna kortweg **de Vloot**.

Dit is een **gecureerde, publieke kopie** van een privé-productierepo. Wat hier staat draait
echt; wat eruit is gehaald staat hieronder expliciet benoemd.

> **Over de naamgeving.** Bestandsnamen en scripts dragen nog het `fleet`-voorvoegsel —
> `.fleet.yml`, `fleet-doctor.sh`, het `fleet-task`-label. Dat is bewust: dat zijn echte
> identifiers waar code en tests aan hangen, geen proza. De naam in de tekst is veranderd, de
> contracten niet.

---

## Waarom dit interessant is

De meeste CI-opstellingen groeien organisch: een workflow hier, een cron daar, en na een jaar weet
niemand meer welke poort wat bewaakt. Dit is een poging tot het tegenovergestelde — een pijplijn
die is **ontworpen**, met vier ideeën als ruggengraat:

**1. Elke poort is machine-checkbaar, of het is geen poort.** Menselijke aandacht is de schaarste.
In het hele systeem zitten precies drie plekken waar een mens verschijnt: feature-approval,
release-approval, en escalatie bij `needs-human`. Al het andere is doorstroom. Zie
[docs/architectuur.md §3](docs/architectuur.md).

**2. Configuratie die gedrag stuurt, is code — dus krijgt het tests.** De intake-poort routeert
issues naar het juiste project op basis van een trefwoordtabel. Voeg één te breed trefwoord toe en
de unit-tests blijven vrolijk groen terwijl de helft van de issues naar de verkeerde plek stuitert.
Daarom staat er naast de unit-tests een [golden-set](tests/golden/README.md): bevroren echte
gevallen met een bekende-goede uitkomst. Inclusief drie **marge**-gevallen die met 2-1 winnen — een
testset waarin alles met 3-0 wint, slaagt namelijk voor altijd en bewaakt dus niets.

**3. De pijplijn repareert zichzelf; escalatie is de uitzondering.** Een watchdog, een
conflict-solver en een autofix-laag draaien zonder tussenkomst. De `fleet-doctor` rapporteert hard
maar muteert nooit — diagnose en mutatie zijn bewust gescheiden bevoegdheden.

**4. Groen is geen bewijs.** Het derde idee hierboven is een generalisatie van het tweede, en het
kostte drie afzonderlijke incidenten voordat dat opviel. De gevaarlijkste storing in een pijplijn
is niet de rode build — die ziet iedereen. Het is de check die **altijd hetzelfde antwoordt** en
daardoor van buiten niet te onderscheiden is van een check die werkt:

| | Wat er groen staat | Wat er werkelijk gebeurt |
|---|---|---|
| **I23** | de golden-set slaagt | elk geval wint met 3-0, dus geen enkel te breed trefwoord kán iets kantelen — de run slaagt voor altijd |
| **I27** | trigger, pad, naam en permissies allemaal correct | tien uur lang geen enkele run; de complete spine lag plat |
| **I28** | de spine "werkt", niets is rood | een station mist een script bij de consument, draait fail-closed, en merget per constructie nooit meer |

Drie keer dezelfde vorm, drie keer los ontdekt, elk met een datum en een gemeten aanleiding. De
verdediging is telkens hetzelfde principe: **meet het gedrag, niet de configuratie.** I27 doet dat
letterlijk (liep de bron, en reageerde de luisteraar?). I23 dwingt het af door grensgevallen met
marge 1 te eisen — een testset waarin alles met 3-0 wint, bewaakt niets. I28 leidt de eis af uit de
stationsdefinitie zelf in plaats van uit een handmatige lijst, want zo'n lijst loopt achter zonder
dat iets dat meldt. Zie [docs/gitflow.md §11](docs/gitflow.md).

**Waar te beginnen:** [docs/architectuur.md](docs/architectuur.md) is de kaart —
de vier lagen, de pijplijn met z'n drie mens-poorten, het consumer-contract en het security-model.
[docs/gitflow.md](docs/gitflow.md) is de detailspec: elk station, het capaciteitsmodel, het
storingsdraaiboek en de machine-checkbare invarianten.

## Hoe het werkt

Een consument-repo levert een dunne caller van ~15 regels; deze repo levert de logica:

```yaml
# in de consument, .github/workflows/checks.yml
on:
  pull_request:
jobs:
  checks:
    uses: KCTHolman/deSchouwVloot/.github/workflows/checks.yml@main
    secrets: inherit
```

Het dragende mechanisme is dat een reusable workflow draait in de **context van de aanroeper**:

- `runs-on: <lane>` resolvet tegen de runnerpool van de *aanroepende* repo;
- `github.repository` is de *aanroepende* repo, niet deze;
- `secrets: inherit` geeft de secrets van de *aanroeper* door.

De Vloot levert dus de logica, de consument levert de hardware en de secrets. Dat is ook waarom dit
werkt zonder GitHub-organisatie: er zijn geen org-level runners of org-secrets nodig.

Het contract tussen beide is één bestand: [`.fleet.yml`](.fleet.yml). Lanes, poorten, budgetten,
labelnamen en de "spine" (workflows waarvan uitval *stil* zou zijn). Zie
[`examples/tweede-consument.fleet.yml`](examples/tweede-consument.fleet.yml) voor hoe datzelfde
contract eruitziet bij een project met een heel andere vorm — dat is de echte test of de
abstractie draagt.

---

## Beveiliging van déze repo

Deze repo is publiek. Dat verandert de dreiging fundamenteel ten opzichte van het privé-origineel,
en dat is precies waar de meeste CI-ongelukken vandaan komen: niet uit slechte code, maar uit een
**aanname die stilletjes vervalt**. Een `on: issues`-trigger is in een privérepo een prima voordeur
die alleen de eigenaar kan gebruiken. Diezelfde trigger in een publieke repo is een anonieme
voordeur voor iedereen met een GitHub-account.

Daarom geldt hier één harde regel:

> **Geen enkele workflow in deze repo heeft een eigen trigger.**

Niet "alleen veilige triggers" — géén. Alle 16 workflows zijn `workflow_call`-only. Een reusable
workflow start nooit vanzelf; hij draait uitsluitend als een andere workflow hem expliciet
aanroept, en dan in de context van díé aanroeper: op diens runners, met diens secrets, tegen diens
repo. Roept een vreemde een workflow hieruit cross-repo aan, dan draait en betaalt hij dat volledig
zelf. Er is geen pad van "publiek internet" naar compute of secrets van de eigenaar.

Dat is geen belofte in proza maar een **machinaal gehandhaafde** eigenschap:

```bash
bash scripts/check-no-triggers.sh
```

De guard faalt op `issues`, `pull_request`, `schedule`, `push` en `workflow_dispatch`, én op het
gevaarlijkste geval: een geldige `workflow_call` mét een verboden trigger ernaast. Hij herkent ook
de YAML-vormen die een naïeve `grep` mist — de gequote `"on":` (de YAML 1.1-booleanvalkuil) en de
inline lijstvorm `on: [push, pull_request]`.
[`scripts/check-no-triggers.test.sh`](scripts/check-no-triggers.test.sh) toetst al die gevallen.

De voorbeeld-caller in [`examples/`](examples/) heeft wél een echte trigger — dat hoort ook, want
dat is nou juist het punt: **triggers leven in de consument, logica in de Vloot.** Bestanden in
`examples/` staan buiten `.github/workflows/` en worden door GitHub nooit geregistreerd.

### Wat er uit deze kopie is gehaald, en waarom

Volledigheid is hier belangrijker dan een schone indruk:

| Weggelaten | Reden |
|---|---|
| De host-diagnostiekworkflow | Bracht in kaart wáár elk credential op de runner-host stond (paden en permissies, nooit inhoud). Legitiem gereedschap voor de eigenaar, maar publiek een kant-en-klare doelwitlijst. |
| Concrete hostcijfers — RAM, schijf, co-hostende diensten | Horen bij één specifieke machine; zeggen niets over het ontwerp en wél iets over waar die machine zwak staat. |
| Isolatiestatus per lane | Vermeldde per lane of hij al geïsoleerd was of nog niet. Dat is een tijdgebonden statusregel, geen ontwerpkenmerk. |
| De twee callers met echte triggers | `pull_request`/`schedule`-callers. Hun inhoud is het lezen waard, hun trigger niet. |
| Domeintrefwoorden van de productconsument in `routing.yml` | Vervangen door neutrale voorbeelden. Dit is de énige plek waar projectkennis in de poort zit — dat is meteen het ontwerpargument: de rest van de machinerie is domeinvrij en dus deelbaar. |
| Interne draaiboek-verwijzingen | Wezen naar documenten in privérepo's; als link waardeloos, als bestandsnaam soms verklappend. |

Drie wijzigingen in [`.github/workflows/intake.yml`](.github/workflows/intake.yml) zijn geen
weglating maar een **verbetering**, en staan voluit in de kop van dat bestand: de trigger werd
`workflow_call`, het GitHub-App-token kreeg een expliciete `repositories:`-scope in plaats van
installatiebreed, en de dedupe-stap is verwijderd omdat die issue-titels uit de doelrepo in een
comment op déze repo plaatste — prima als beide repo's dezelfde zichtbaarheid hebben, een lek zodra
dat niet meer zo is.

### Wat er bewust wél in staat

Geen secrets, in geen enkel bestand en in geen enkele commit. Wél: echte workflownamen, echte
issue-nummers uit de historie, en commentaar dat benoemt wat er ooit misging. Dat commentaar is
het waardevolste deel van deze repo — een workflow zonder de reden erachter is een workflow die de
volgende persoon met een gerust hart weer stukmaakt.

---

## Zelf draaien

Alle logica die iets beslist is een **pure functie in bash of Python**, offline testbaar zonder
GitHub, zonder netwerk en zonder tokens. Dat is een ontwerpkeuze: de workflows eromheen blijven dom
en voeren alleen uit, zodat het denkwerk in iets zit dat je op je laptop in een seconde kunt
draaien.

```bash
# alle testsuites
for suite in scripts/*.test.sh; do bash "$suite"; done

# de golden-set: doet de routeringstabel nog wat we bedoelen?
bash scripts/golden-run.sh

# de invariant-checker op zichzelf
bash scripts/fleet-doctor.sh --module consistentie --root .

# I28: eist een aangeroepen station een script dat déze repo niet heeft?
bash scripts/fleet-doctor.sh --module afhankelijkheden --root . --fleet-root .

# en het bewijs dat niets hier uit zichzelf kan vuren
bash scripts/check-no-triggers.sh
```

Nodig: `bash`, `awk`, `sed`, `python3` met PyYAML. Geen netwerk.

### En daarom is de Actions-tab hier leeg

Dat is geen nalatigheid maar de rekening van de regel hierboven. Elke workflow hier is
`workflow_call`-only, inclusief `checks.yml` — en een reusable workflow die niemand aanroept,
draait nooit. Er is in deze repo dus **geen enkele automatische run**; alle guards hierboven zijn
handwerk, of ze draaien in de context van een consument die ze aanroept.

Dat is een echte afweging en het is de moeite waard om 'm hardop te maken, want in het licht van
idee 4 hierboven is het precies het scherpe randje: een testsuite die niemand aftrapt, is een
testsuite die altijd hetzelfde antwoordt. Een `pull_request`-caller op `ubuntu-latest` zonder
secrets zou hier veilig zijn — maar "alleen veilige triggers" is nou juist de formulering die deze
repo bewust niet hanteert, omdat die weer op een beoordeling per geval leunt in plaats van op een
eigenschap die een script kan vaststellen. De keuze is dus: geen triggers, en de prijs zichtbaar
opschrijven in plaats van 'm te verstoppen achter een badge.
